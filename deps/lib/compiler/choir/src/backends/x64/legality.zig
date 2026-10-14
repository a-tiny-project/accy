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
const bound_set = @import("../execution/bounds.zig");
const Excess = bound_set.Excess;
const Refused = bound_set.Refused;

const BackendError = interface.BackendError;
const FuncDialect = dialects.FuncDialect;
const ScfDialect = dialects.ScfDialect;

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
    /// A call passing more arguments than a signature records.
    too_many_arguments,
    /// A return inside an `scf.while` region. The emitter ends the enclosing block at such a
    /// return and never binds the loop's exit.
    return_in_while,
    /// An `scf.for` whose induction variable is not 32 or 64 bits wide. The emitter's guard and
    /// increment take any other width for 64 bits, and read and write past a narrower slot.
    narrow_induction_variable,
};

const Offender = struct {
    operation: ?*ir.Operation = null,
    violation: Violation = .too_many_results,
};

/// Rejects the first operation the emitter cannot represent: a function, call, or return with
/// unrepresentable results, a return inside an `scf.while` region, an `scf.for` over a narrow
/// induction variable, a call with a vector argument
/// or more arguments than a signature records, a function definition whose signature
/// this backend cannot record or pass, or an operation with malformed data-symbol attributes.
/// Fails with `error.UnsupportedOperation` and reports one error diagnostic located at that
/// operation. A non-null `refused` receives that operation and, for a violation past one of the
/// target's bounds, its figures.
pub fn checkModule(module: *ir.Operation, refused: ?*Refused) BackendError!void {
    std.debug.assert(module.regions.items.len == 1);
    var offender = Offender{};
    const walked = module.walk(.{ .order = .pre_order }, &offender, visit) catch unreachable;
    if (walked != .interrupt) {
        std.debug.assert(offender.operation == null);
        return;
    }
    if (refused) |into| into.* = .{
        .operation = offender.operation.?,
        .excess = excessOf(offender.operation.?, offender.violation),
    };
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
    if (std.mem.eql(u8, name, ScfDialect.ForOp.operation_name)) {
        return if (countsNarrow(op)) .narrow_induction_variable else null;
    }
    if (!is_function and !is_return and !is_call) return null;
    if (resultViolation(op, is_return)) |violation| return violation;
    if (is_return and standsInWhile(op)) return .return_in_while;
    if (is_call) return argumentViolation(op);
    if (!is_function or op.getRegion(0) == null) return null;
    return boundaryViolation(op);
}

/// Whether the induction variable of the `scf.for` `loop` is an integer narrower than 32 bits.
fn countsNarrow(loop: *ir.Operation) bool {
    const region = loop.getRegion(0) orelse return false;
    const body = region.getEntryBlock() orelse return false;
    if (body.arguments.items.len == 0) return false;
    const type_name = body.arguments.items[0].type.getDialectTypeName() orelse return false;
    const kind = dialects.arith.scalarKindFromTypeName(type_name) orelse return false;
    return dialects.arith.scalarBitWidth(kind) < 32;
}

/// Whether an `scf.while` encloses `ret` within its function, at any depth.
fn standsInWhile(ret: *ir.Operation) bool {
    var block = ret.parent_block;
    while (block) |inner| {
        const holder = inner.getParentOperation() orelse return false;
        const name = holder.name.name;
        if (std.mem.eql(u8, name, ScfDialect.WhileOp.operation_name)) return true;
        if (std.mem.eql(u8, name, FuncDialect.FuncOp.operation_name)) return false;
        block = holder.parent_block;
    }
    return false;
}

fn argumentViolation(call: *ir.Operation) ?Violation {
    if (call.operands.items.len > abi.max_call_arguments) return .too_many_arguments;
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

/// The figures of a violation that refuses past one of the target's bounds, or null for a
/// violation of shape. Each count is taken whole, so the program held none of it before.
fn excessOf(op: *ir.Operation, violation: Violation) ?Excess {
    return switch (violation) {
        .too_many_results => {
            const is_return = std.mem.eql(u8, op.name.name, FuncDialect.ReturnOp.operation_name);
            const count = if (is_return) op.operands.items.len else op.results.items.len;
            return Excess.of(.results, abi.max_result_count, 0, count).?;
        },
        .too_many_parameters => {
            const count = op.getRegion(0).?.getEntryBlock().?.arguments.items.len;
            return Excess.of(.parameters, artifact.Signature.max_parameters, 0, count).?;
        },
        .too_many_arguments => Excess.of(.call_arguments, abi.max_call_arguments, 0, op.operands.items.len).?,
        else => null,
    };
}

fn reject(offender: Offender) BackendError {
    const op = offender.operation.?;
    std.debug.assert(violationOf(op) == offender.violation);
    if (excessOf(op, offender.violation)) |excess| {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "x86_64 refused {f}", .{excess}) catch
            "x86_64 refused a function, call, or return past one of its bounds";
        var in_flight = op.emitError(message);
        defer in_flight.deinit();
        in_flight.addMetadata("choir.stage", stage) catch {};
        in_flight.addMetadata("choir.bound", @tagName(excess.bound)) catch {};
        _ = in_flight.emit() catch {};
        return BackendError.UnsupportedOperation;
    }
    const message = switch (offender.violation) {
        .too_many_results, .too_many_parameters, .too_many_arguments => unreachable,
        .vector_in_product => "x86_64 functions, calls, and returns with several results " ++
            "carry scalars and memrefs only",
        .malformed_data_symbol => std.fmt.comptimePrint(
            "x86_64 data symbols need an arith.constant of type arith.i64, arith.u64, or " ++
                "arith.index whose choir.backend.data_symbol attributes give a nonempty string " ++
                "name, nonempty string bytes, and an optional integer alignment that is a power " ++
                "of two up to {d}",
            .{machine.max_data_alignment},
        ),
        .unsupported_boundary_type => "x86_64 function parameters and results take memref " ++
            "and arith types other than arith.f16, arith.bf16, and their vectors",
        .vector_parameter => "x86_64 function parameters take scalars and memrefs but not vectors",
        .vector_argument => "x86_64 calls pass scalars and memrefs but not vectors",
        .return_in_while => "x86_64 refuses a func.return inside an scf.while region",
        .narrow_induction_variable => "x86_64 refuses an scf.for whose induction variable is " ++
            "narrower than 32 bits",
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
    message_bytes: [256]u8 = undefined,
    message: []const u8 = "",
    bound: []const u8 = "",

    fn handle(
        context: ?*anyopaque,
        diagnostic: *const diagnostics.Diagnostic,
    ) !diagnostics.HandlerResult {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.seen += 1;
        self.operation = diagnostic.operation;
        // The message may live in the reporter's stack buffer, so it is copied while it is live.
        const kept = @min(diagnostic.message.len, self.message_bytes.len);
        @memcpy(self.message_bytes[0..kept], diagnostic.message[0..kept]);
        self.message = self.message_bytes[0..kept];
        self.bound = "";
        for (diagnostic.metadata) |metadata| {
            if (std.mem.eql(u8, metadata.name, "choir.stage")) self.stage = metadata.value;
            if (std.mem.eql(u8, metadata.name, "choir.bound")) self.bound = metadata.value;
        }
        return .consumed;
    }
};
