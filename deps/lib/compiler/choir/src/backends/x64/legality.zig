//! x86_64 target legality for the SysV machine-code emitter.

const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const diagnostics = @import("../../root.zig").diagnostics;
const artifact = @import("../root.zig").artifact;
const boundary = @import("../root.zig").signature;
const interface = @import("../root.zig").interface;
const machine = @import("../root.zig").machine_code;
const abi = @import("abi.zig");
const data = @import("data.zig");

const BackendError = interface.BackendError;
const FuncDialect = dialects.FuncDialect;

/// Diagnostic stage recorded on legality failures.
pub const stage = "backend/x86_64/legality";

/// An operation shape the SysV emitter cannot represent.
pub const Violation = enum {
    /// More results than one result record holds.
    too_many_results,
    /// A vector among several results. A vector result returns alone.
    vector_in_product,
    /// Data-symbol attributes that do not name read-only bytes on a 64-bit integer constant.
    malformed_data_symbol,
    /// A function definition with more parameters than a signature records.
    too_many_parameters,
    /// A function definition parameter or result whose type has no boundary equivalent.
    unsupported_boundary_type,
    /// A vector parameter of a function definition.
    vector_parameter,
    /// A vector argument of a call.
    vector_argument,
};

const Offender = struct {
    operation: ?*ir.Operation = null,
    violation: Violation = .too_many_results,
};

/// Rejects the first operation the emitter cannot represent: a function, call, or return with
/// unrepresentable results, a call with a vector argument, a function definition whose signature
/// this backend cannot record or pass, or an operation with malformed data-symbol attributes.
/// Fails with `error.UnsupportedOperation` and reports one error diagnostic located at that
/// operation.
pub fn checkModule(module: *ir.Operation) BackendError!void {
    std.debug.assert(module.regions.items.len == 1);
    var offender = Offender{};
    const walked = module.walk(.{ .order = .pre_order }, &offender, visit) catch unreachable;
    if (walked != .interrupt) {
        std.debug.assert(offender.operation == null);
        return;
    }
    return reject(offender);
}

fn visit(offender: *Offender, op: *ir.Operation) ir.WalkResult {
    std.debug.assert(offender.operation == null);
    const violation = violationOf(op) orelse return .advance;
    offender.* = .{ .operation = op, .violation = violation };
    return .interrupt;
}

/// Classifies `op`, or returns `null` when the emitter can represent it.
pub fn violationOf(op: *ir.Operation) ?Violation {
    _ = data.symbolOf(op) catch return .malformed_data_symbol;
    const name = op.name.name;
    const is_function = std.mem.eql(u8, name, FuncDialect.FuncOp.operation_name);
    const is_return = std.mem.eql(u8, name, FuncDialect.ReturnOp.operation_name);
    const is_call = std.mem.eql(u8, name, FuncDialect.CallOp.operation_name);
    if (!is_function and !is_return and !is_call) return null;
    if (resultViolation(op, is_return)) |violation| return violation;
    if (is_call) return argumentViolation(op);
    if (!is_function or op.getRegion(0) == null) return null;
    return boundaryViolation(op);
}

fn argumentViolation(call: *ir.Operation) ?Violation {
    for (call.operands.items) |operand| {
        const type_name = operand.value.type.getDialectTypeName() orelse continue;
        if (dialects.arith.parseVectorTypeName(type_name) != null) return .vector_argument;
    }
    return null;
}

fn resultViolation(op: *ir.Operation, is_return: bool) ?Violation {
    const count = if (is_return) op.operands.items.len else op.results.items.len;
    if (count > abi.max_result_count) return .too_many_results;
    if (count < 2) return null;
    for (0..count) |index| {
        const result_type = if (is_return)
            op.operands.items[index].value.type
        else
            op.results.items[index].type;
        const type_name = result_type.getDialectTypeName() orelse continue;
        if (dialects.arith.parseVectorTypeName(type_name) != null) return .vector_in_product;
    }
    return null;
}

fn boundaryViolation(func: *ir.Operation) ?Violation {
    const recorded = boundary.ofFunction(func) catch |err| return switch (err) {
        error.TooManyParameters => .too_many_parameters,
        error.TooManyResults => unreachable,
        error.UnsupportedType => .unsupported_boundary_type,
    };
    for (recorded.parameters()) |parameter| {
        if (parameter == .vector) return .vector_parameter;
    }
    std.debug.assert(abi.admitsSignature(&recorded));
    return null;
}

fn reject(offender: Offender) BackendError {
    const op = offender.operation.?;
    std.debug.assert(violationOf(op) == offender.violation);
    const message = switch (offender.violation) {
        .too_many_results => std.fmt.comptimePrint(
            "x86_64 functions, calls, and returns carry at most {d} results",
            .{abi.max_result_count},
        ),
        .vector_in_product => "x86_64 functions, calls, and returns with several results " ++
            "carry scalars and memrefs only",
        .malformed_data_symbol => std.fmt.comptimePrint(
            "x86_64 data symbols need an arith.constant of type arith.i64, arith.u64, or " ++
                "arith.index whose choir.backend.data_symbol attributes give a nonempty string " ++
                "name, nonempty string bytes, and an optional integer alignment that is a power " ++
                "of two up to {d}",
            .{machine.max_data_alignment},
        ),
        .too_many_parameters => std.fmt.comptimePrint(
            "x86_64 functions take at most {d} parameters",
            .{artifact.Signature.max_parameters},
        ),
        .unsupported_boundary_type => "x86_64 function parameters and results take memref " ++
            "and arith types other than arith.f16, arith.bf16, and their vectors",
        .vector_parameter => "x86_64 function parameters take scalars and memrefs but not vectors",
        .vector_argument => "x86_64 calls pass scalars and memrefs but not vectors",
    };
    var in_flight = op.emitError(message);
    defer in_flight.deinit();
    in_flight.addMetadata("choir.stage", stage) catch {};
    _ = in_flight.emit() catch {};
    return BackendError.UnsupportedOperation;
}

const Recorder = struct {
    seen: usize = 0,
    operation: ?*ir.Operation = null,
    stage: []const u8 = "",

    fn handle(
        context: ?*anyopaque,
        diagnostic: *const diagnostics.Diagnostic,
    ) !diagnostics.HandlerResult {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.seen += 1;
        self.operation = diagnostic.operation;
        for (diagnostic.metadata) |metadata| {
            if (std.mem.eql(u8, metadata.name, "choir.stage")) self.stage = metadata.value;
        }
        return .consumed;
    }
};

test "x86_64 legality admits scalar products and rejects unrepresentable results" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getFile("legality.choir", 3, 5);
    const i64_type = try dialects.ArithDialect.getScalarType(&ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    const pair_types = [_]ir.Type{ i64_type, i64_type };
    const pair = try FuncDialect.FuncOp.create(&ctx, loc, "pair", &.{i64_type}, &pair_types);
    try module.getBodyBlock().addOperation(pair.op);
    const argument = pair.getArgument(0);
    const pair_ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{ argument, argument });
    try pair.getEntryBlock().addOperation(pair_ret.op);

    var recorder = Recorder{};
    _ = try ctx.registerDiagnosticHandler(.{ .context = &recorder, .handle = Recorder.handle });
    try checkModule(module.op);
    try std.testing.expectEqual(@as(usize, 0), recorder.seen);

    var wide_types: [abi.max_result_count + 1]ir.Type = undefined;
    @memset(&wide_types, i64_type);
    const wide = try FuncDialect.FuncOp.create(&ctx, loc, "wide", &.{i64_type}, &wide_types);
    try module.getBodyBlock().addOperation(wide.op);
    try std.testing.expectError(BackendError.UnsupportedOperation, checkModule(module.op));
    try std.testing.expectEqual(@as(usize, 1), recorder.seen);
    try std.testing.expectEqual(wide.op, recorder.operation.?);
    try std.testing.expectEqualStrings(stage, recorder.stage);

    const float64 = dialects.arith.type_names.float64;
    const vec_type = (try dialects.ArithDialect.getVecType(&ctx, 2, float64)).?;
    const vectors = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    const mixed_types = [_]ir.Type{ vec_type, i64_type };
    const mixed = try FuncDialect.FuncOp.create(&ctx, loc, "mixed", &.{vec_type}, &mixed_types);
    try vectors.getBodyBlock().addOperation(mixed.op);
    try std.testing.expectEqual(Violation.vector_in_product, violationOf(mixed.op).?);
    try std.testing.expectError(BackendError.UnsupportedOperation, checkModule(vectors.op));
    try std.testing.expectEqual(@as(usize, 2), recorder.seen);
    try std.testing.expectEqual(mixed.op, recorder.operation.?);
}

test "x86_64 legality rejects function boundaries it cannot record" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getFile("legality.choir", 12, 1);
    const i64_type = try dialects.ArithDialect.getScalarType(&ctx, .i64);
    const f16_type = try dialects.ArithDialect.getScalarType(&ctx, .f16);
    const float64 = dialects.arith.type_names.float64;
    const vec_type = (try dialects.ArithDialect.getVecType(&ctx, 2, float64)).?;
    var wide: [artifact.Signature.max_parameters + 1]ir.Type = undefined;
    @memset(&wide, i64_type);
    const Case = struct { parameters: []const ir.Type, violation: Violation };
    const cases = [_]Case{
        .{ .parameters = &.{f16_type}, .violation = .unsupported_boundary_type },
        .{ .parameters = &.{ i64_type, vec_type }, .violation = .vector_parameter },
        .{ .parameters = &wide, .violation = .too_many_parameters },
    };

    var recorder = Recorder{};
    _ = try ctx.registerDiagnosticHandler(.{ .context = &recorder, .handle = Recorder.handle });
    for (cases, 1..) |case, seen| {
        const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
        const results = [_]ir.Type{i64_type};
        const function = try FuncDialect.FuncOp.create(&ctx, loc, "f", case.parameters, &results);
        try module.getBodyBlock().addOperation(function.op);
        try std.testing.expectEqual(@as(?Violation, case.violation), violationOf(function.op));
        try std.testing.expectError(BackendError.UnsupportedOperation, checkModule(module.op));
        try std.testing.expectEqual(seen, recorder.seen);
        try std.testing.expectEqual(function.op, recorder.operation.?);
        try std.testing.expectEqualStrings(stage, recorder.stage);
    }

    const halves = [_]ir.Type{f16_type};
    const declared = try FuncDialect.FuncOp.createDeclaration(&ctx, loc, "d", &halves, &halves);
    try std.testing.expectEqual(@as(?Violation, null), violationOf(declared.op));
}

test "x86_64 legality rejects vector call arguments at the call" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getFile("legality.choir", 21, 9);
    const f64_type = try dialects.ArithDialect.getF64Type(&ctx);
    const float64 = dialects.arith.type_names.float64;
    const vec_type = (try dialects.ArithDialect.getVecType(&ctx, 2, float64)).?;
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    const sink_types = [_]ir.Type{vec_type};
    const results = [_]ir.Type{f64_type};
    const sink = try FuncDialect.FuncOp.createDeclaration(&ctx, loc, "sink", &sink_types, &results);
    try module.getBodyBlock().addOperation(sink.op);
    const function = try FuncDialect.FuncOp.create(&ctx, loc, "f", &.{f64_type}, &.{f64_type});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const splat = dialects.ArithDialect.SplatOp;
    const lanes = try splat.create(&ctx, loc, function.getArgument(0), vec_type);
    try entry.addOperation(lanes.op);
    const call = try FuncDialect.CallOp.create(&ctx, loc, "sink", &.{lanes.getResult()}, &results);
    try entry.addOperation(call.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{call.getResult(0).?});
    try entry.addOperation(ret.op);

    var recorder = Recorder{};
    _ = try ctx.registerDiagnosticHandler(.{ .context = &recorder, .handle = Recorder.handle });
    try std.testing.expectEqual(@as(?Violation, .vector_argument), violationOf(call.op));
    try std.testing.expectEqual(@as(?Violation, null), violationOf(sink.op));
    try std.testing.expectError(BackendError.UnsupportedOperation, checkModule(module.op));
    try std.testing.expectEqual(@as(usize, 1), recorder.seen);
    try std.testing.expectEqual(call.op, recorder.operation.?);
    try std.testing.expectEqualStrings(stage, recorder.stage);
}

test "x86_64 legality rejects malformed data symbols at their constant" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getFile("legality.choir", 9, 3);
    const i64_type = try dialects.ArithDialect.getScalarType(&ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    const function = try FuncDialect.FuncOp.create(&ctx, loc, "table", &.{}, &.{i64_type});
    try module.getBodyBlock().addOperation(function.op);
    const constant = try dialects.ArithDialect.ConstantOp.createInt(&ctx, loc, i64_type, 0);
    try function.getEntryBlock().addOperation(constant.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{constant.getResult()});
    try function.getEntryBlock().addOperation(ret.op);

    var recorder = Recorder{};
    _ = try ctx.registerDiagnosticHandler(.{ .context = &recorder, .handle = Recorder.handle });
    const names = machine.data_symbol_attr_names;
    try constant.op.setAttr(names.bytes, try ctx.getStringAttr("\x01\x02"));
    try std.testing.expectEqual(Violation.malformed_data_symbol, violationOf(constant.op).?);
    try std.testing.expectError(BackendError.UnsupportedOperation, checkModule(module.op));
    try std.testing.expectEqual(@as(usize, 1), recorder.seen);
    try std.testing.expectEqual(constant.op, recorder.operation.?);
    try std.testing.expectEqualStrings(stage, recorder.stage);

    try constant.op.setAttr(names.name, try ctx.getStringAttr("table"));
    try std.testing.expectEqual(@as(?Violation, null), violationOf(constant.op));
    try checkModule(module.op);
    try std.testing.expectEqual(@as(usize, 1), recorder.seen);
}
