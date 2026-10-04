//! The scalar and borrowed-word Apple arm64 Target for canonical Choir execution.

const std = @import("std");
const ir = @import("../../core/root.zig");
const backends = @import("../root.zig");
const artifact = backends.artifact;
const contract = backends.contract;
const debug_info = backends.debug_info;
const execution = @import("../execution/root.zig");
const backend = @import("backend.zig");
const invoke = @import("invoke.zig");
const placement = @import("placement.zig");
const sys = @import("sys");

const Allocator = std.mem.Allocator;
const Signature = artifact.Signature;

pub const Target = struct {
    pub const unavailable: ?[]const u8 = null;
    pub const architecture: artifact.Architecture = .aarch64;
    pub const abi: artifact.Abi = .{
        .name = "apple-arm64",
        .calling_convention = "c",
        .pointer_width_bits = 64,
        .endianness = .little,
    };
    pub const relocation_bytes: usize = 8;
    pub const allowsSerializedArtifact: bool = false;
    /// Only the inspected startup-linked, non-hardened arm64 product with a macOS 11.4+
    /// deployment target uses this policy. The fixed producer proves those properties before
    /// its hash-gated execution; it does not admit an arbitrary hardened or late-loaded host.
    pub const executable_policy: sys.memory.ExecutablePolicy = .macos_non_hardened;
    pub const builtin_count: usize = 0;
    pub const Compiler = backend.Emitter;
    pub const EmitError = @typeInfo(@typeInfo(@TypeOf(Compiler.emitFunction)).@"fn".return_type.?).error_union.error_set;

    pub fn builtin(_: usize) execution.Builtin {
        unreachable;
    }

    pub fn initCompiler(allocator: Allocator) Compiler {
        var compiler = Compiler.init(allocator);
        compiler.diagnose = false;
        return compiler;
    }

    pub fn deinitCompiler(compiler: *Compiler) void {
        compiler.deinit();
    }

    pub fn prepare(ctx: *ir.Context) Allocator.Error!void {
        return contract.loadArithDialect(ctx);
    }

    pub fn lower(_: Allocator, module: *ir.Operation) execution.LowerError!void {
        backend.lowerModule(module) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.VerificationFailed => error.VerificationFailed,
            error.UnsupportedOperation => error.UnsupportedOperation,
            else => error.CodeGenFailed,
        };
    }

    pub fn emit(compiler: *Compiler, func: *ir.Operation) EmitError!execution.Emitted {
        try compiler.emitFunction(func);
        try compiler.padCodeToImageAlignment();
        return .{
            .code = compiler.code.items,
            .calls = compiler.calls.items,
            .data = compiler.data_symbols.items(),
            .data_relocations = compiler.data_relocations.items,
            .outgrew_reservation = compiler.code.items.len > compiler.reservation_before_emit,
        };
    }

    /// The scalar emitter has no source-line mapping. An enabled line table is empty.
    pub fn takeLineTable(compiler: *Compiler) Allocator.Error!debug_info.LineTable {
        var builder = debug_info.LineTableBuilder.init(compiler.allocator);
        return builder.finish();
    }

    pub fn recordLines(_: *Compiler, _: bool) void {}

    pub fn takeCode(compiler: *Compiler) Allocator.Error![]u8 {
        return compiler.code.toOwnedSlice(compiler.allocator);
    }

    pub fn failedOperation(compiler: *const Compiler) ?*ir.Operation {
        return compiler.failed_operation;
    }

    pub fn discard(compiler: *Compiler) void {
        compiler.discard();
    }

    pub fn report(failure: execution.Failure) void {
        if (failure.err == error.OutOfMemory) return;
        var diagnostic = failure.operation.emitError(switch (failure.stage) {
            .emit => "Apple arm64 native emission failed",
            .link => "Apple arm64 native link failed",
        });
        defer diagnostic.deinit();
        _ = diagnostic.emit() catch {};
    }

    pub fn admitsSignature(signature: *const Signature) bool {
        if (!signature.isValid()) return false;
        if (signature.parameter_count > backend.max_arguments) return false;
        if (signature.result_count > backend.max_results) return false;
        var floating_width: ?artifact.ScalarType = null;
        for (signature.parameters()) |parameter| {
            switch (parameter) {
                .memref => {},
                else => if (!scalarArgument(parameter)) return false,
            }
            if (parameter == .scalar and (parameter.scalar == .f32 or parameter.scalar == .f64)) {
                if (floating_width) |width| {
                    if (width != parameter.scalar) return false;
                } else floating_width = parameter.scalar;
            }
        }
        for (signature.results()) |result| {
            if (!scalarArgument(result)) return false;
            if (result == .scalar and (result.scalar == .f32 or result.scalar == .f64)) {
                if (floating_width) |width| {
                    if (width != result.scalar) return false;
                } else floating_width = result.scalar;
            }
        }
        return true;
    }

    pub fn patch(code: []u8, offset: usize, address: u64) void {
        std.debug.assert(offset <= code.len);
        std.debug.assert(code.len - offset >= relocation_bytes);
        std.mem.writeInt(u64, code[offset..][0..relocation_bytes], address, .little);
    }

    pub fn enter(address: usize, signature: *const Signature, args: []const execution.Value, results: []execution.Value) void {
        std.debug.assert(admitsSignature(signature));
        invoke.call(address, signature, args, results);
    }
};

fn scalarArgument(value_type: artifact.ValueType) bool {
    return switch (value_type) {
        .scalar => |scalar| switch (scalar) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .bool, .index, .f32, .f64 => true,
        },
        else => false,
    };
}

fn scalarModule(
    ctx: *ir.Context,
    name: []const u8,
    kind: @import("../../dialects/root.zig").arith.ScalarKind,
    arity: usize,
    has_result: bool,
) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const scalar = try dialects.ArithDialect.getScalarType(ctx, kind);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const parameters: [backend.max_arguments]ir.Type = @splat(scalar);
    const results: [1]ir.Type = .{scalar};
    const function = try dialects.FuncDialect.FuncOp.create(
        ctx,
        loc,
        name,
        parameters[0..arity],
        if (has_result) &results else &.{},
    );
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    if (has_result) {
        const value = if (arity != 0)
            function.getArgument(arity - 1)
        else blk: {
            const constant = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, scalar, 42);
            try entry.addOperation(constant.op);
            break :blk constant.getResult();
        };
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{value});
        try entry.addOperation(ret.op);
    } else {
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{});
        try entry.addOperation(ret.op);
    }
    return module.op;
}

const global_words = [_]u8{
    0x11, 0,    0,    0,    0,    0,    0,    0x80,
    0x19, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
};

const global_first: u64 = 0x8000_0000_0000_0011;
const global_last: u64 = 0xffff_ffff_ffff_ff19;

const GlobalCase = enum { read_only, writable, zeroed, wrong_type, wrong_element, dead_wrong_type, zero_extent, nonhost, weak_alignment, missing, stored, called };

fn globalWordModule(ctx: *ir.Context, case: GlobalCase) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const signed = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const index = try dialects.ArithDialect.getIndexType(ctx);
    const table_type = try dialects.MemrefDialect.getMemrefType1D(ctx, if (case == .zero_extent) 0 else 2, word, if (case == .nonhost) .device else .host);
    const wrong_type = try dialects.MemrefDialect.getMemrefType1D(ctx, 1, word, .host);
    const wrong_element = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, signed, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    if (case != .missing) {
        const table = try dialects.MemrefDialect.GlobalOp.create(ctx, loc, .{
            .sym_name = "words",
            .memref_type = table_type,
            .alignment = if (case == .weak_alignment) 4 else 8,
            .constant = case != .writable and case != .zeroed,
            .initial = if (case == .zeroed) null else if (case == .zero_extent) &.{} else &global_words,
        });
        try module.getBodyBlock().addOperation(table.op);
    }
    if (case == .called) {
        const sink = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "global_sink", &.{table_type}, &.{});
        try module.getBodyBlock().addOperation(sink.op);
    }
    for ([_][]const u8{ "global_word", "global_word_again" }) |name| {
        const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, name, &.{word}, &.{word});
        try module.getBodyBlock().addOperation(function.op);
        const entry = function.getEntryBlock();
        const word_index = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), index);
        try entry.addOperation(word_index.op);
        const second = std.mem.eql(u8, name, "global_word_again");
        const zero = if (second) try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0) else null;
        if (zero) |constant| try entry.addOperation(constant.op);
        if (case == .dead_wrong_type) {
            const dead = try dialects.MemrefDialect.GetGlobalOp.create(ctx, loc, "words", wrong_type);
            try entry.addOperation(dead.op);
        }
        const reference = try dialects.MemrefDialect.GetGlobalOp.create(ctx, loc, "words", switch (case) {
            .wrong_type => wrong_type,
            .wrong_element => wrong_element,
            else => table_type,
        });
        try entry.addOperation(reference.op);
        if (case == .called) {
            const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "global_sink", &.{reference.getResult()}, &.{});
            try entry.addOperation(call.op);
        }
        if (case == .stored) {
            const value = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 7);
            try entry.addOperation(value.op);
            const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, value.getResult(), reference.getResult(), word_index.getResult());
            try entry.addOperation(store.op);
        }
        const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, reference.getResult(), word_index.getResult(), if (case == .wrong_element) signed else word);
        try entry.addOperation(load.op);
        const loaded = if (case == .wrong_element) blk: {
            const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, load.getResult(), word);
            try entry.addOperation(cast.op);
            break :blk cast.getResult();
        } else load.getResult();
        const value = if (zero) |constant| blk: {
            const add = try dialects.ArithDialect.AddOp.create(ctx, loc, loaded, constant.getResult());
            try entry.addOperation(add.op);
            break :blk add.getResult();
        } else loaded;
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{value});
        try entry.addOperation(ret.op);
    }
    return module.op;
}

fn expectGlobalRefusal(module: *ir.Operation) !void {
    if (backend.lowerModule(module)) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expect(err == error.UnsupportedOperation or err == error.VerificationFailed);
    }
}

/// Eight live constants cross a conditional region, exceeding the seven placement registers.
/// The result exercises the same framed spill and branch path through canonical publication.
fn structuredPressureModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const bool_type = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(
        ctx,
        loc,
        "pressure_branch",
        &.{bool_type},
        &.{i64_type},
    );
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers + 1]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, @intCast(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const branch = try dialects.ScfDialect.IfOp.create(ctx, loc, function.getArgument(0), &.{i64_type});
    try entry.addOperation(branch.op);
    const then_block = branch.getThenBlock();
    var sum = values[0];
    for (values[1..]) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, value);
        try then_block.addOperation(add.op);
        sum = add.getResult();
    }
    const then_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{sum});
    try then_block.addOperation(then_yield.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 0);
    try branch.getElseBlock().?.addOperation(zero.op);
    const else_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{zero.getResult()});
    try branch.getElseBlock().?.addOperation(else_yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{branch.getResult(0).?});
    try entry.addOperation(ret.op);
    return module.op;
}

fn callPressureModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const bool_type = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "pressure_oracle", &.{i64_type}, &.{i64_type});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "call_pressure", &.{bool_type}, &.{i64_type});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers + 1]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, @intCast(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const branch = try dialects.ScfDialect.IfOp.create(ctx, loc, function.getArgument(0), &.{i64_type});
    try entry.addOperation(branch.op);
    const then_block = branch.getThenBlock();
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "pressure_oracle", &.{values[0]}, &.{i64_type});
    try then_block.addOperation(call.op);
    var sum = call.getResult(0).?;
    for (values) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, value);
        try then_block.addOperation(add.op);
        sum = add.getResult();
    }
    const then_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{sum});
    try then_block.addOperation(then_yield.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 0);
    try branch.getElseBlock().?.addOperation(zero.op);
    const else_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{zero.getResult()});
    try branch.getElseBlock().?.addOperation(else_yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{branch.getResult(0).?});
    try entry.addOperation(ret.op);
    return module.op;
}

fn loopCallModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const index_type = try dialects.ArithDialect.getScalarType(ctx, .index);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "loop_oracle", &.{index_type}, &.{index_type});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "loop_calls", &.{index_type}, &.{index_type});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index_type, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index_type, 1);
    try entry.addOperation(one.op);
    const loop = try dialects.ScfDialect.ForOp.create(ctx, loc, zero.getResult(), function.getArgument(0), one.getResult(), &.{zero.getResult()}, &.{index_type});
    try entry.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const called = try dialects.FuncDialect.CallOp.create(ctx, loc, "loop_oracle", &.{body.arguments.items[0]}, &.{index_type});
    try body.addOperation(called.op);
    const next = try dialects.ArithDialect.AddOp.create(ctx, loc, body.arguments.items[1], called.getResult(0).?);
    try body.addOperation(next.op);
    const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{next.getResult()});
    try body.addOperation(yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(0).?});
    try entry.addOperation(ret.op);
    return module.op;
}

fn directCallModule(ctx: *ir.Context, external_name: []const u8) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();

    const sum = try dialects.FuncDialect.FuncOp.create(ctx, loc, "sum", &.{ i64_type, i64_type }, &.{i64_type});
    try module.getBodyBlock().addOperation(sum.op);
    const addition = try dialects.ArithDialect.AddOp.create(ctx, loc, sum.getArgument(0), sum.getArgument(1));
    try sum.getEntryBlock().addOperation(addition.op);
    const sum_return = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{addition.getResult()});
    try sum.getEntryBlock().addOperation(sum_return.op);

    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, external_name, &.{i64_type}, &.{i64_type});
    try module.getBodyBlock().addOperation(external.op);

    const middle = try dialects.FuncDialect.FuncOp.create(ctx, loc, "middle", &.{i64_type}, &.{i64_type});
    try module.getBodyBlock().addOperation(middle.op);
    const forwarded = try dialects.FuncDialect.CallOp.create(ctx, loc, external_name, &.{middle.getArgument(0)}, &.{i64_type});
    try middle.getEntryBlock().addOperation(forwarded.op);
    const middle_return = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{forwarded.getResult(0).?});
    try middle.getEntryBlock().addOperation(middle_return.op);

    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "call_entry", &.{ i64_type, i64_type }, &.{i64_type});
    try module.getBodyBlock().addOperation(entry.op);
    const internal = try dialects.FuncDialect.CallOp.create(
        ctx,
        loc,
        "sum",
        &.{ entry.getArgument(1), entry.getArgument(0) },
        &.{i64_type},
    );
    try entry.getEntryBlock().addOperation(internal.op);
    const outgoing = try dialects.FuncDialect.CallOp.create(
        ctx,
        loc,
        "middle",
        &.{internal.getResult(0).?},
        &.{i64_type},
    );
    try entry.getEntryBlock().addOperation(outgoing.op);
    const retained = try dialects.ArithDialect.AddOp.create(ctx, loc, outgoing.getResult(0).?, entry.getArgument(0));
    try entry.getEntryBlock().addOperation(retained.op);
    const entry_return = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{retained.getResult()});
    try entry.getEntryBlock().addOperation(entry_return.op);
    return module.op;
}

fn scalarExternalOracle(value: i64) callconv(.c) i64 {
    return value * 3 + 1;
}

var stack_word_observed: u64 = 0;

fn staticWordOracle(value: u64) callconv(.c) void {
    stack_word_observed = value;
}

fn conflictingExternalSum(left: i64, right: i64) callconv(.c) i64 {
    return 1000 + left + right;
}

fn narrowCallModule(ctx: *ir.Context, kind: @import("../../dialects/root.zig").arith.ScalarKind, name: []const u8) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const scalar = try dialects.ArithDialect.getScalarType(ctx, kind);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, name, &.{scalar}, &.{scalar});
    try module.getBodyBlock().addOperation(external.op);
    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "narrow_entry", &.{scalar}, &.{scalar});
    try module.getBodyBlock().addOperation(entry.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, name, &.{entry.getArgument(0)}, &.{scalar});
    try entry.getEntryBlock().addOperation(call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{call.getResult(0).?});
    try entry.getEntryBlock().addOperation(ret.op);
    return module.op;
}

fn narrowWidenCallModule(
    ctx: *ir.Context,
    parameter_kind: @import("../../dialects/root.zig").arith.ScalarKind,
    result_kind: @import("../../dialects/root.zig").arith.ScalarKind,
    name: []const u8,
) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const parameter = try dialects.ArithDialect.getScalarType(ctx, parameter_kind);
    const result = try dialects.ArithDialect.getScalarType(ctx, result_kind);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, name, &.{parameter}, &.{result});
    try module.getBodyBlock().addOperation(external.op);
    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "widen_entry", &.{parameter}, &.{result});
    try module.getBodyBlock().addOperation(entry.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, name, &.{entry.getArgument(0)}, &.{result});
    try entry.getEntryBlock().addOperation(call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{call.getResult(0).?});
    try entry.getEntryBlock().addOperation(ret.op);
    return module.op;
}

fn signedNarrowOracle(value: i8) callconv(.c) i8 {
    return value;
}

fn unsignedNarrowOracle(value: u8) callconv(.c) u8 {
    return value;
}

fn signedWidenOracle(value: i8) callconv(.c) i64 {
    return value;
}

fn unsignedWidenOracle(value: u8) callconv(.c) u64 {
    return value;
}

fn booleanOracle(value: bool) callconv(.c) bool {
    return !value;
}

fn indexOracle(value: usize) callconv(.c) usize {
    return value + 1;
}

fn arityCallModule(ctx: *ir.Context, arity: usize, name: []const u8) !*ir.Operation {
    std.debug.assert(arity == 0 or arity == backend.max_arguments);
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const types: [backend.max_arguments]ir.Type = @splat(i64_type);
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, name, types[0..arity], &.{i64_type});
    try module.getBodyBlock().addOperation(external.op);
    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "arity_entry", types[0..arity], &.{i64_type});
    try module.getBodyBlock().addOperation(entry.op);
    var operands: [backend.max_arguments]*ir.Value = undefined;
    for (operands[0..arity], 0..) |*operand, index| operand.* = entry.getArgument(arity - index - 1);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, name, operands[0..arity], &.{i64_type});
    try entry.getEntryBlock().addOperation(call.op);
    const result = if (arity == 0) call.getResult(0).? else blk: {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, call.getResult(0).?, entry.getArgument(0));
        try entry.getEntryBlock().addOperation(add.op);
        break :blk add.getResult();
    };
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{result});
    try entry.getEntryBlock().addOperation(ret.op);
    return module.op;
}

fn scalarExternalZero() callconv(.c) i64 {
    return 42;
}

fn scalarExternalEight(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64) callconv(.c) i64 {
    return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h;
}

var void_observed: i64 = 0;

fn scalarVoidOracle(value: i64) callconv(.c) void {
    void_observed = value;
}

fn voidCallModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "void_oracle", &.{i64_type}, &.{});
    try module.getBodyBlock().addOperation(external.op);
    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "void_entry", &.{i64_type}, &.{});
    try module.getBodyBlock().addOperation(entry.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "void_oracle", &.{entry.getArgument(0)}, &.{});
    try entry.getEntryBlock().addOperation(call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{});
    try entry.getEntryBlock().addOperation(ret.op);
    return module.op;
}

fn borrowedCopyModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "borrowed_copy", &.{ buffer, buffer, index }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, function.getArgument(0), function.getArgument(2), word);
    try entry.addOperation(load.op);
    const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, load.getResult(), function.getArgument(1), function.getArgument(2));
    try entry.addOperation(store.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

/// Every value read from this entry-local payload is stored first. No result
/// depends on a newly reserved stack slot's unspecified initial contents.
fn staticAllocaModule(ctx: *ir.Context, words: u64, with_call: bool) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefType1D(ctx, words, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    if (with_call) {
        const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "stack_void_oracle", &.{word}, &.{});
        try module.getBodyBlock().addOperation(external.op);
    }
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "stack_words", &.{ word, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const alloca = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(alloca.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const last = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, @intCast(words - 1));
    try entry.addOperation(last.op);
    const first_store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, function.getArgument(0), alloca.getResult(), zero.getResult());
    try entry.addOperation(first_store.op);
    const last_store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, function.getArgument(1), alloca.getResult(), last.getResult());
    try entry.addOperation(last_store.op);
    if (with_call) {
        const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "stack_void_oracle", &.{function.getArgument(0)}, &.{});
        try entry.addOperation(call.op);
    }
    const first_load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), zero.getResult(), word);
    try entry.addOperation(first_load.op);
    const last_load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), last.getResult(), word);
    try entry.addOperation(last_load.op);
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, first_load.getResult(), last_load.getResult());
    try entry.addOperation(sum.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

fn twoStaticAllocasModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "two_stack_words", &.{ word, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const first = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(first.op);
    const second = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(second.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try entry.addOperation(one.op);
    const marker_a = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 101);
    try entry.addOperation(marker_a.op);
    const marker_b = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 202);
    try entry.addOperation(marker_b.op);
    for ([_]struct { value: *ir.Value, memref: *ir.Value, offset: *ir.Value }{
        .{ .value = marker_a.getResult(), .memref = first.getResult(), .offset = zero.getResult() },
        .{ .value = function.getArgument(0), .memref = first.getResult(), .offset = one.getResult() },
        .{ .value = function.getArgument(1), .memref = second.getResult(), .offset = zero.getResult() },
        .{ .value = marker_b.getResult(), .memref = second.getResult(), .offset = one.getResult() },
    }) |write| {
        const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, write.value, write.memref, write.offset);
        try entry.addOperation(store.op);
    }
    const left = try dialects.MemrefDialect.LoadOp.create(ctx, loc, first.getResult(), one.getResult(), word);
    try entry.addOperation(left.op);
    const right = try dialects.MemrefDialect.LoadOp.create(ctx, loc, second.getResult(), zero.getResult(), word);
    try entry.addOperation(right.op);
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, left.getResult(), right.getResult());
    try entry.addOperation(sum.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

fn spilledStaticAllocaModule(ctx: *ir.Context) !BorrowedSpill {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const oracle = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "stack_word_oracle", &.{word}, &.{});
    try module.getBodyBlock().addOperation(oracle.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "spilled_stack_words", &.{ index, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var live: [placement.max_registers + 1]*ir.Value = undefined;
    for (&live, 0..) |*value, position| {
        const constant = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, @intCast(position + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const alloca = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(alloca.op);
    const zero_index = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero_index.op);
    const computed_index = try dialects.ArithDialect.AddOp.create(ctx, loc, function.getArgument(0), zero_index.getResult());
    try entry.addOperation(computed_index.op);
    const zero_word = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0);
    try entry.addOperation(zero_word.op);
    const computed_value = try dialects.ArithDialect.AddOp.create(ctx, loc, function.getArgument(1), zero_word.getResult());
    try entry.addOperation(computed_value.op);
    const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, computed_value.getResult(), alloca.getResult(), computed_index.getResult());
    try entry.addOperation(store.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "stack_word_oracle", &.{computed_value.getResult()}, &.{});
    try entry.addOperation(call.op);
    const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), computed_index.getResult(), word);
    try entry.addOperation(load.op);
    var total = load.getResult();
    for (live) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, total, value);
        try entry.addOperation(add.op);
        total = add.getResult();
    }
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{total});
    try entry.addOperation(ret.op);
    return .{ .module = module.op, .pointer = alloca.getResult(), .index = computed_index.getResult(), .value = computed_value.getResult() };
}

fn staticAllocaLoopModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const oracle = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "stack_scalar_oracle", &.{word}, &.{word});
    try module.getBodyBlock().addOperation(oracle.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "stack_loop", &.{ index, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const alloca = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(alloca.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try entry.addOperation(one.op);
    const nine = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 9);
    try entry.addOperation(nine.op);
    const initial_store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, function.getArgument(1), alloca.getResult(), zero.getResult());
    try entry.addOperation(initial_store.op);
    const second_store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, nine.getResult(), alloca.getResult(), one.getResult());
    try entry.addOperation(second_store.op);
    const loop = try dialects.ScfDialect.ForOp.create(ctx, loc, zero.getResult(), function.getArgument(0), one.getResult(), &.{}, &.{});
    try entry.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const before = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), zero.getResult(), word);
    try body.addOperation(before.op);
    const called = try dialects.FuncDialect.CallOp.create(ctx, loc, "stack_scalar_oracle", &.{before.getResult()}, &.{word});
    try body.addOperation(called.op);
    const updated = try dialects.MemrefDialect.StoreOp.create(ctx, loc, called.getResult(0).?, alloca.getResult(), zero.getResult());
    try body.addOperation(updated.op);
    const reread = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), zero.getResult(), word);
    try body.addOperation(reread.op);
    const accumulated = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), one.getResult(), word);
    try body.addOperation(accumulated.op);
    const next = try dialects.ArithDialect.AddOp.create(ctx, loc, reread.getResult(), accumulated.getResult());
    try body.addOperation(next.op);
    const store_sum = try dialects.MemrefDialect.StoreOp.create(ctx, loc, next.getResult(), alloca.getResult(), one.getResult());
    try body.addOperation(store_sum.op);
    const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{});
    try body.addOperation(yield.op);
    const first = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), zero.getResult(), word);
    try entry.addOperation(first.op);
    const second = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), one.getResult(), word);
    try entry.addOperation(second.op);
    const total = try dialects.ArithDialect.AddOp.create(ctx, loc, first.getResult(), second.getResult());
    try entry.addOperation(total.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{total.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

const StaticAllocaCase = enum { unused, dynamic, zero, nonhost, annotated, nested, escaped };

fn staticAllocaCaseModule(ctx: *ir.Context, case: StaticAllocaCase) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = if (case == .dynamic)
        try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, word, .host)
    else
        try dialects.MemrefDialect.getMemrefType1D(ctx, if (case == .zero) 0 else 2, word, if (case == .nonhost) .device else .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    if (case == .escaped) {
        const sink = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "stack_sink", &.{buffer}, &.{});
        try module.getBodyBlock().addOperation(sink.op);
    }
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "stack_case", &.{index}, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const container = if (case == .nested) nested: {
        const condition = try dialects.ArithDialect.ConstantOp.createBool(ctx, loc, true);
        try entry.addOperation(condition.op);
        const branch = try dialects.ScfDialect.IfOp.createWithoutElse(ctx, loc, condition.getResult());
        try entry.addOperation(branch.op);
        break :nested branch.getThenBlock();
    } else entry;
    const alloca = if (case == .dynamic)
        try dialects.MemrefDialect.AllocaOp.createDynamic(ctx, loc, function.getArgument(0), buffer)
    else
        try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    if (case == .annotated)
        try alloca.op.setAttr("future", try ctx.getBoolAttr(true));
    try container.addOperation(alloca.op);
    if (case == .nested) {
        const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{});
        try container.addOperation(yield.op);
    }
    if (case == .escaped) {
        const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "stack_sink", &.{alloca.getResult()}, &.{});
        try entry.addOperation(call.op);
    }
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0);
    try entry.addOperation(zero.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{zero.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

fn borrowedViewModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const byte = try dialects.ArithDialect.getScalarType(ctx, .u8);
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const bytes = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, byte, .host);
    const words = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "borrowed_view", &.{ bytes, index, index, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const view = try dialects.MemrefDialect.ViewOp.create(ctx, loc, function.getArgument(0), function.getArgument(1), words);
    try entry.addOperation(view.op);
    const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, function.getArgument(3), view.getResult(), function.getArgument(2));
    try entry.addOperation(store.op);
    const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, view.getResult(), function.getArgument(2), word);
    try entry.addOperation(load.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

fn borrowedLoopModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "borrowed_step_oracle", &.{ buffer, index, word }, &.{word});
    try module.getBodyBlock().addOperation(external.op);
    const step = try dialects.FuncDialect.FuncOp.create(ctx, loc, "borrowed_step", &.{ buffer, index, word }, &.{word});
    try module.getBodyBlock().addOperation(step.op);
    const step_call = try dialects.FuncDialect.CallOp.create(ctx, loc, "borrowed_step_oracle", &.{ step.getArgument(0), step.getArgument(1), step.getArgument(2) }, &.{word});
    try step.getEntryBlock().addOperation(step_call.op);
    const step_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{step_call.getResult(0).?});
    try step.getEntryBlock().addOperation(step_ret.op);

    const entry = try dialects.FuncDialect.FuncOp.create(ctx, loc, "borrowed_loop", &.{ index, buffer, word }, &.{word});
    try module.getBodyBlock().addOperation(entry.op);
    const body = entry.getEntryBlock();
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try body.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try body.addOperation(one.op);
    const one_word = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 1);
    try body.addOperation(one_word.op);
    const initial = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0);
    try body.addOperation(initial.op);
    const loop = try dialects.ScfDialect.ForOp.create(ctx, loc, zero.getResult(), entry.getArgument(0), one.getResult(), &.{initial.getResult()}, &.{word});
    try body.addOperation(loop.op);
    const loop_body = loop.getBodyBlock();
    const before = try dialects.MemrefDialect.LoadOp.create(ctx, loc, entry.getArgument(1), loop_body.arguments.items[0], word);
    try loop_body.addOperation(before.op);
    const called = try dialects.FuncDialect.CallOp.create(ctx, loc, "borrowed_step", &.{ entry.getArgument(1), loop_body.arguments.items[0], entry.getArgument(2) }, &.{word});
    try loop_body.addOperation(called.op);
    const incremented = try dialects.ArithDialect.AddOp.create(ctx, loc, called.getResult(0).?, one_word.getResult());
    try loop_body.addOperation(incremented.op);
    const stored = try dialects.MemrefDialect.StoreOp.create(ctx, loc, incremented.getResult(), entry.getArgument(1), loop_body.arguments.items[0]);
    try loop_body.addOperation(stored.op);
    const seen = try dialects.MemrefDialect.LoadOp.create(ctx, loc, entry.getArgument(1), loop_body.arguments.items[0], word);
    try loop_body.addOperation(seen.op);
    const prior_sum = try dialects.ArithDialect.AddOp.create(ctx, loc, loop_body.arguments.items[1], before.getResult());
    try loop_body.addOperation(prior_sum.op);
    const next = try dialects.ArithDialect.AddOp.create(ctx, loc, prior_sum.getResult(), seen.getResult());
    try loop_body.addOperation(next.op);
    const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{next.getResult()});
    try loop_body.addOperation(yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(0).?});
    try body.addOperation(ret.op);
    return module.op;
}

fn borrowedStepOracle(buffer: [*]u64, index: usize, delta: u64) callconv(.c) u64 {
    buffer[index] +%= delta;
    return buffer[index];
}

fn refusedBorrowedModule(ctx: *ir.Context, annotated: bool) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, word, if (annotated) .host else .device);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "refused_borrow", &.{ buffer, index }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const unused_load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, function.getArgument(0), function.getArgument(1), word);
    if (annotated) try unused_load.op.setAttr("cache", try ctx.getDialectAttr("memref.cache", "future"));
    try entry.addOperation(unused_load.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0);
    try entry.addOperation(zero.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{zero.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

const BorrowedSpill = struct {
    module: *ir.Operation,
    pointer: *ir.Value,
    index: *ir.Value,
    value: *ir.Value,
};

fn borrowedSpillModule(ctx: *ir.Context) !BorrowedSpill {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const byte = try dialects.ArithDialect.getScalarType(ctx, .u8);
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const bytes = try dialects.MemrefDialect.getMemrefTypeDynamic(ctx, byte, .host);
    const words = try dialects.MemrefDialect.getMemrefType1D(ctx, 2, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "borrowed_spill", &.{ bytes, index, index, word }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var live: [placement.max_registers + 1]*ir.Value = undefined;
    for (&live, 0..) |*value, position| {
        const constant = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, @intCast(position + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const view = try dialects.MemrefDialect.ViewOp.create(ctx, loc, function.getArgument(0), function.getArgument(1), words);
    try entry.addOperation(view.op);
    const zero_index = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero_index.op);
    const computed_index = try dialects.ArithDialect.AddOp.create(ctx, loc, function.getArgument(2), zero_index.getResult());
    try entry.addOperation(computed_index.op);
    const zero_word = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, word, 0);
    try entry.addOperation(zero_word.op);
    const computed_value = try dialects.ArithDialect.AddOp.create(ctx, loc, function.getArgument(3), zero_word.getResult());
    try entry.addOperation(computed_value.op);
    const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, computed_value.getResult(), view.getResult(), computed_index.getResult());
    try entry.addOperation(store.op);
    const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, view.getResult(), computed_index.getResult(), word);
    try entry.addOperation(load.op);
    var total = load.getResult();
    for (live) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, total, value);
        try entry.addOperation(add.op);
        total = add.getResult();
    }
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{total});
    try entry.addOperation(ret.op);
    return .{ .module = module.op, .pointer = view.getResult(), .index = computed_index.getResult(), .value = computed_value.getResult() };
}

comptime {
    execution.assertTarget(Target);
}

fn mixedFloatModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const args = [_]ir.Type{ floating, integer, floating };
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "mixed_float_oracle", &args, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "mixed_float_entry", &args, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const seven = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 7);
    try entry.addOperation(seven.op);
    const condition = try dialects.ArithDialect.CmpOp.create(ctx, loc, .eq, function.getArgument(1), seven.getResult());
    try entry.addOperation(condition.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "mixed_float_oracle", &.{ function.getArgument(0), function.getArgument(1), function.getArgument(2) }, &.{floating});
    try entry.addOperation(call.op);
    const added = try dialects.ArithDialect.AddOp.create(ctx, loc, call.getResult(0).?, function.getArgument(0));
    try entry.addOperation(added.op);
    const selected = try dialects.ArithDialect.SelectOp.create(ctx, loc, condition.getResult(), added.getResult(), function.getArgument(2));
    try entry.addOperation(selected.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{selected.getResult()});
    try entry.addOperation(ret.op);
    const wrapper = try dialects.FuncDialect.FuncOp.create(ctx, loc, "mixed_float_wrapper", &args, &.{floating});
    try module.getBodyBlock().addOperation(wrapper.op);
    const internal = try dialects.FuncDialect.CallOp.create(ctx, loc, "mixed_float_entry", wrapper.getArguments(), &.{floating});
    try wrapper.getEntryBlock().addOperation(internal.op);
    const wrapper_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{internal.getResult(0).?});
    try wrapper.getEntryBlock().addOperation(wrapper_ret.op);
    return module.op;
}

fn mixedFloatOracle(first: f64, middle: i64, last: f64) callconv(.c) f64 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(middle == 7 or middle == 8);
    return first * 2 + last;
}

fn bitRoundtripModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const bits = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_bits", &.{bits}, &.{bits});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const to_float = try dialects.ArithDialect.BitcastOp.create(ctx, loc, function.getArgument(0), floating);
    try entry.addOperation(to_float.op);
    const to_bits = try dialects.ArithDialect.BitcastOp.create(ctx, loc, to_float.getResult(), bits);
    try entry.addOperation(to_bits.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{to_bits.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

fn eightMixedModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const narrow = try dialects.ArithDialect.getScalarType(ctx, .u8);
    const signed = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const types = [_]ir.Type{ floating, narrow, floating, signed, floating, boolean, floating, index };
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "eight_mixed_oracle", &types, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "eight_mixed_entry", &types, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "eight_mixed_oracle", function.getArguments(), &.{floating});
    try function.getEntryBlock().addOperation(call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{call.getResult(0).?});
    try function.getEntryBlock().addOperation(ret.op);
    return module.op;
}

fn eightMixedOracle(a: f64, b: u8, c: f64, d: i64, e: f64, f: bool, g: f64, h: usize) callconv(.c) f64 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(a == 1.5 and b == 0xff and c == 2.5 and d == -7);
    std.debug.assert(e == 3.5 and f and g == 4.5 and h == std.math.maxInt(usize));
    return a + c + e + g;
}

fn eightFloatOracle(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64) callconv(.c) f64 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(a == 1 and b == 2 and c == 3 and d == 4);
    std.debug.assert(e == 5 and f == 6 and g == 7 and h == 8);
    return a + b + c + d + e + f + g + h;
}

fn mixedPointerOracle(address: [*]const u64, floating: f64, narrow: u8) callconv(.c) u64 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(floating == 1.25 and narrow == 0xff);
    return address[0] + narrow;
}

var floating_void_bits: u64 = 0;

fn floatingVoidOracle(floating: f64, integer: i64) callconv(.c) void {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(integer == -3);
    floating_void_bits = @bitCast(floating);
}

fn floatSignModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const bits = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    for ([_][]const u8{ "float_neg_bits", "float_abs_bits" }, 0..) |name, index| {
        const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, name, &.{bits}, &.{bits});
        try module.getBodyBlock().addOperation(function.op);
        const entry = function.getEntryBlock();
        const to_float = try dialects.ArithDialect.BitcastOp.create(ctx, loc, function.getArgument(0), floating);
        try entry.addOperation(to_float.op);
        const transformed = if (index == 0) blk: {
            const negated = try dialects.ArithDialect.NegOp.create(ctx, loc, to_float.getResult());
            try entry.addOperation(negated.op);
            break :blk negated.getResult();
        } else blk: {
            const absolute = try dialects.ArithDialect.AbsOp.create(ctx, loc, to_float.getResult());
            try entry.addOperation(absolute.op);
            break :blk absolute.getResult();
        };
        const to_bits = try dialects.ArithDialect.BitcastOp.create(ctx, loc, transformed, bits);
        try entry.addOperation(to_bits.op);
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{to_bits.getResult()});
        try entry.addOperation(ret.op);
    }
    const selected = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_select_bits", &.{ boolean, bits, bits }, &.{bits});
    try module.getBodyBlock().addOperation(selected.op);
    const entry = selected.getEntryBlock();
    const left = try dialects.ArithDialect.BitcastOp.create(ctx, loc, selected.getArgument(1), floating);
    try entry.addOperation(left.op);
    const right = try dialects.ArithDialect.BitcastOp.create(ctx, loc, selected.getArgument(2), floating);
    try entry.addOperation(right.op);
    const choice = try dialects.ArithDialect.SelectOp.create(ctx, loc, selected.getArgument(0), left.getResult(), right.getResult());
    try entry.addOperation(choice.op);
    const to_bits = try dialects.ArithDialect.BitcastOp.create(ctx, loc, choice.getResult(), bits);
    try entry.addOperation(to_bits.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{to_bits.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

const float_predicates = [_]@import("../../dialects/root.zig").arith.CmpPredicate{ .eq, .ne, .lt, .le, .gt, .ge };
const float_predicate_names = [_][]const u8{ "float_eq", "float_ne", "float_lt", "float_le", "float_gt", "float_ge" };

fn floatComparisonModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    for (float_predicates, float_predicate_names) |predicate, name| {
        const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, name, &.{ floating, floating }, &.{boolean});
        try module.getBodyBlock().addOperation(function.op);
        const comparison = try dialects.ArithDialect.CmpOp.create(ctx, loc, predicate, function.getArgument(0), function.getArgument(1));
        try function.getEntryBlock().addOperation(comparison.op);
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{comparison.getResult()});
        try function.getEntryBlock().addOperation(ret.op);
    }
    return module.op;
}

fn floatArithmeticModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_arithmetic", &.{ floating, floating }, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, function.getArgument(0), function.getArgument(1));
    try entry.addOperation(sum.op);
    const difference = try dialects.ArithDialect.SubOp.create(ctx, loc, function.getArgument(0), function.getArgument(1));
    try entry.addOperation(difference.op);
    const product = try dialects.ArithDialect.MulOp.create(ctx, loc, sum.getResult(), difference.getResult());
    try entry.addOperation(product.op);
    const quotient = try dialects.ArithDialect.DivOp.create(ctx, loc, product.getResult(), function.getArgument(1));
    try entry.addOperation(quotient.op);
    const negated = try dialects.ArithDialect.NegOp.create(ctx, loc, quotient.getResult());
    try entry.addOperation(negated.op);
    const absolute = try dialects.ArithDialect.AbsOp.create(ctx, loc, negated.getResult());
    try entry.addOperation(absolute.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{absolute.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

fn floatStepOracle(value: f64) callconv(.c) f64 {
    std.debug.assert(invoke.defaultFpcr());
    return value + 1;
}

fn f32NewtonModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_newton_steps", &.{floating}, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const guess = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, 1);
    try entry.addOperation(guess.op);
    const half = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, 0.5);
    try entry.addOperation(half.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 1);
    try entry.addOperation(one.op);
    const limit = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 60);
    try entry.addOperation(limit.op);
    const loop = try dialects.ScfDialect.WhileOp.create(ctx, loc, &.{ guess.getResult(), zero.getResult() }, &.{ floating, integer });
    try entry.addOperation(loop.op);
    const before = loop.getBeforeBlock();
    const divided = try dialects.ArithDialect.DivOp.create(ctx, loc, function.getArgument(0), before.arguments.items[0]);
    try before.addOperation(divided.op);
    const summed = try dialects.ArithDialect.AddOp.create(ctx, loc, before.arguments.items[0], divided.getResult());
    try before.addOperation(summed.op);
    const next = try dialects.ArithDialect.MulOp.create(ctx, loc, summed.getResult(), half.getResult());
    try before.addOperation(next.op);
    const converged = try dialects.ArithDialect.CmpOp.create(ctx, loc, .eq, next.getResult(), before.arguments.items[0]);
    try before.addOperation(converged.op);
    const not_converged = try dialects.ArithDialect.NotOp.create(ctx, loc, converged.getResult());
    try before.addOperation(not_converged.op);
    const below_limit = try dialects.ArithDialect.CmpOp.create(ctx, loc, .slt, before.arguments.items[1], limit.getResult());
    try before.addOperation(below_limit.op);
    const continuing = try dialects.ArithDialect.AndOp.create(ctx, loc, not_converged.getResult(), below_limit.getResult());
    try before.addOperation(continuing.op);
    const condition = try dialects.ScfDialect.ConditionOp.create(ctx, loc, continuing.getResult(), &.{ next.getResult(), before.arguments.items[1] });
    try before.addOperation(condition.op);
    const after = loop.getAfterBlock();
    const incremented = try dialects.ArithDialect.AddOp.create(ctx, loc, after.arguments.items[1], one.getResult());
    try after.addOperation(incremented.op);
    const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{ after.arguments.items[0], incremented.getResult() });
    try after.addOperation(yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(1).?});
    try entry.addOperation(ret.op);
    return module.op;
}

fn f32MixedOracle(first: f32, middle: i64) callconv(.c) f32 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(middle == 7);
    return first + @as(f32, @floatFromInt(middle));
}

fn f32StepOracle(value: f32) callconv(.c) f32 {
    std.debug.assert(invoke.defaultFpcr());
    return value + 1;
}

fn f32EightOracle(a: f32, b: u8, c: f32, d: i64, e: f32, f: bool, g: f32, h: usize) callconv(.c) f32 {
    std.debug.assert(invoke.defaultFpcr());
    std.debug.assert(b == 0xff and d == -7 and f and h == std.math.maxInt(usize));
    return ((a + c) + e) + g;
}

fn f32EightModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const narrow = try dialects.ArithDialect.getScalarType(ctx, .u8);
    const signed = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const index = try dialects.ArithDialect.getIndexType(ctx);
    const types = [_]ir.Type{ floating, narrow, floating, signed, floating, boolean, floating, index };
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "f32_eight_oracle", &types, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_eight_mixed", &types, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "f32_eight_oracle", function.getArguments(), &.{floating});
    try function.getEntryBlock().addOperation(call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{call.getResult(0).?});
    try function.getEntryBlock().addOperation(ret.op);
    const floats: [8]ir.Type = @splat(floating);
    const all_floats = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_eight_floats", &floats, &.{floating});
    try module.getBodyBlock().addOperation(all_floats.op);
    var sum = all_floats.getArgument(0);
    for (1..8) |ordinal| {
        const added = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, all_floats.getArgument(ordinal));
        try all_floats.getEntryBlock().addOperation(added.op);
        sum = added.getResult();
    }
    const floats_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum});
    try all_floats.getEntryBlock().addOperation(floats_ret.op);
    return module.op;
}

fn f32MixedModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "f32_mixed_oracle", &.{ floating, integer }, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_mixed_entry", &.{ floating, integer, floating }, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "f32_mixed_oracle", &.{ function.getArgument(0), function.getArgument(1) }, &.{floating});
    try entry.addOperation(call.op);
    const added = try dialects.ArithDialect.AddOp.create(ctx, loc, call.getResult(0).?, function.getArgument(2));
    try entry.addOperation(added.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{added.getResult()});
    try entry.addOperation(ret.op);
    const wrapper = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_mixed_wrapper", &.{ floating, integer, floating }, &.{floating});
    try module.getBodyBlock().addOperation(wrapper.op);
    const internal = try dialects.FuncDialect.CallOp.create(ctx, loc, "f32_mixed_entry", wrapper.getArguments(), &.{floating});
    try wrapper.getEntryBlock().addOperation(internal.op);
    const wrapper_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{internal.getResult(0).?});
    try wrapper.getEntryBlock().addOperation(wrapper_ret.op);
    return module.op;
}

fn f32PressureModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "f32_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_pressure", &.{}, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers + 1]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, @floatFromInt(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "f32_step_oracle", &.{values[0]}, &.{floating});
    try entry.addOperation(call.op);
    var sum = call.getResult(0).?;
    for (values) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, value);
        try entry.addOperation(add.op);
        sum = add.getResult();
    }
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum});
    try entry.addOperation(ret.op);
    return module.op;
}

fn f32EqualityModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_equal", &.{ floating, floating }, &.{boolean});
    try module.getBodyBlock().addOperation(function.op);
    const comparison = try dialects.ArithDialect.CmpOp.create(ctx, loc, .eq, function.getArgument(0), function.getArgument(1));
    try function.getEntryBlock().addOperation(comparison.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{comparison.getResult()});
    try function.getEntryBlock().addOperation(ret.op);
    const integer_function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_equal_integer", &.{ floating, floating }, &.{integer});
    try module.getBodyBlock().addOperation(integer_function.op);
    const compared = try dialects.ArithDialect.CmpOp.create(ctx, loc, .eq, integer_function.getArgument(0), integer_function.getArgument(1));
    try integer_function.getEntryBlock().addOperation(compared.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 1);
    try integer_function.getEntryBlock().addOperation(one.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 0);
    try integer_function.getEntryBlock().addOperation(zero.op);
    const selected = try dialects.ArithDialect.SelectOp.create(ctx, loc, compared.getResult(), one.getResult(), zero.getResult());
    try integer_function.getEntryBlock().addOperation(selected.op);
    const integer_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{selected.getResult()});
    try integer_function.getEntryBlock().addOperation(integer_ret.op);
    return module.op;
}

fn f32RoundingModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const one_ulp = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_one_ulp", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(one_ulp.op);
    const delta = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, 1.0 / 8388608.0);
    try one_ulp.getEntryBlock().addOperation(delta.op);
    const added = try dialects.ArithDialect.AddOp.create(ctx, loc, one_ulp.getArgument(0), delta.getResult());
    try one_ulp.getEntryBlock().addOperation(added.op);
    const one_ulp_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{added.getResult()});
    try one_ulp.getEntryBlock().addOperation(one_ulp_ret.op);
    const unfused = try dialects.FuncDialect.FuncOp.create(ctx, loc, "f32_unfused", &.{ floating, floating }, &.{floating});
    try module.getBodyBlock().addOperation(unfused.op);
    const negative_one = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, -1);
    try unfused.getEntryBlock().addOperation(negative_one.op);
    const multiplied = try dialects.ArithDialect.MulOp.create(ctx, loc, unfused.getArgument(0), unfused.getArgument(1));
    try unfused.getEntryBlock().addOperation(multiplied.op);
    const summed = try dialects.ArithDialect.AddOp.create(ctx, loc, multiplied.getResult(), negative_one.getResult());
    try unfused.getEntryBlock().addOperation(summed.op);
    const unfused_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{summed.getResult()});
    try unfused.getEntryBlock().addOperation(unfused_ret.op);
    return module.op;
}

fn floatControlModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "float_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_control", &.{ boolean, index, floating }, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try entry.addOperation(one.op);
    const one_float = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, 1);
    try entry.addOperation(one_float.op);
    const conditional = try dialects.ScfDialect.IfOp.create(ctx, loc, function.getArgument(0), &.{floating});
    try entry.addOperation(conditional.op);
    const then_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{function.getArgument(2)});
    try conditional.getThenBlock().addOperation(then_yield.op);
    const negative_zero = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, -0.0);
    try conditional.getElseBlock().?.addOperation(negative_zero.op);
    const else_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{negative_zero.getResult()});
    try conditional.getElseBlock().?.addOperation(else_yield.op);
    const counted = try dialects.ScfDialect.ForOp.create(ctx, loc, zero.getResult(), function.getArgument(1), one.getResult(), &.{conditional.op.getResult(0).?}, &.{floating});
    try entry.addOperation(counted.op);
    const for_body = counted.getBodyBlock();
    const next_float = try dialects.ArithDialect.AddOp.create(ctx, loc, for_body.arguments.items[1], one_float.getResult());
    try for_body.addOperation(next_float.op);
    const for_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{next_float.getResult()});
    try for_body.addOperation(for_yield.op);
    const repeated = try dialects.ScfDialect.WhileOp.create(ctx, loc, &.{ zero.getResult(), counted.op.getResult(0).? }, &.{ index, floating });
    try entry.addOperation(repeated.op);
    const before = repeated.getBeforeBlock();
    const comparison = try dialects.ArithDialect.CmpOp.create(ctx, loc, .slt, before.arguments.items[0], function.getArgument(1));
    try before.addOperation(comparison.op);
    const condition = try dialects.ScfDialect.ConditionOp.create(ctx, loc, comparison.getResult(), before.arguments.items);
    try before.addOperation(condition.op);
    const after = repeated.getAfterBlock();
    const next_index = try dialects.ArithDialect.AddOp.create(ctx, loc, after.arguments.items[0], one.getResult());
    try after.addOperation(next_index.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "float_step_oracle", &.{after.arguments.items[1]}, &.{floating});
    try after.addOperation(call.op);
    const while_yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{ next_index.getResult(), call.getResult(0).? });
    try after.addOperation(while_yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{repeated.op.getResult(1).?});
    try entry.addOperation(ret.op);
    return module.op;
}

fn floatPayloadModule(ctx: *ir.Context, words: u64) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const buffer = try dialects.MemrefDialect.getMemrefType1D(ctx, words, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "float_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_payload", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const alloca = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, buffer);
    try entry.addOperation(alloca.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const bits = try dialects.ArithDialect.BitcastOp.create(ctx, loc, function.getArgument(0), word);
    try entry.addOperation(bits.op);
    const store = try dialects.MemrefDialect.StoreOp.create(ctx, loc, bits.getResult(), alloca.getResult(), zero.getResult());
    try entry.addOperation(store.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "float_step_oracle", &.{function.getArgument(0)}, &.{floating});
    try entry.addOperation(call.op);
    const load = try dialects.MemrefDialect.LoadOp.create(ctx, loc, alloca.getResult(), zero.getResult(), word);
    try entry.addOperation(load.op);
    const restored = try dialects.ArithDialect.BitcastOp.create(ctx, loc, load.getResult(), floating);
    try entry.addOperation(restored.op);
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, restored.getResult(), call.getResult(0).?);
    try entry.addOperation(sum.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum.getResult()});
    try entry.addOperation(ret.op);
    return module.op;
}

const NumericCastFunction = struct {
    name: []const u8,
    kind: @import("../../dialects/root.zig").arith.ScalarKind,
};

const numeric_cast_functions = [_]NumericCastFunction{
    .{ .name = "cast_i8", .kind = .i8 },
    .{ .name = "cast_i16", .kind = .i16 },
    .{ .name = "cast_i32", .kind = .i32 },
    .{ .name = "cast_i64", .kind = .i64 },
    .{ .name = "cast_u8", .kind = .u8 },
    .{ .name = "cast_u16", .kind = .u16 },
    .{ .name = "cast_u32", .kind = .u32 },
    .{ .name = "cast_u64", .kind = .u64 },
    .{ .name = "cast_index", .kind = .index },
};

fn numericCastModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    for (numeric_cast_functions) |definition| {
        const integer = try dialects.ArithDialect.getScalarType(ctx, definition.kind);
        const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, definition.name, &.{integer}, &.{floating});
        try module.getBodyBlock().addOperation(function.op);
        const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), floating);
        try function.getEntryBlock().addOperation(cast.op);
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{cast.getResult()});
        try function.getEntryBlock().addOperation(ret.op);
    }
    return module.op;
}

fn numericCastExpected(value: execution.Value) f64 {
    return switch (value) {
        .i8 => |integer| @floatFromInt(integer),
        .i16 => |integer| @floatFromInt(integer),
        .i32 => |integer| @floatFromInt(integer),
        .i64 => |integer| @floatFromInt(integer),
        .u8 => |integer| @floatFromInt(integer),
        .u16 => |integer| @floatFromInt(integer),
        .u32 => |integer| @floatFromInt(integer),
        .u64 => |integer| @floatFromInt(integer),
        .index => |integer| @floatFromInt(integer),
        else => unreachable,
    };
}

const float_to_integer_functions = [_]NumericCastFunction{
    .{ .name = "reverse_i8", .kind = .i8 },
    .{ .name = "reverse_i16", .kind = .i16 },
    .{ .name = "reverse_i32", .kind = .i32 },
    .{ .name = "reverse_i64", .kind = .i64 },
    .{ .name = "reverse_u8", .kind = .u8 },
    .{ .name = "reverse_u16", .kind = .u16 },
    .{ .name = "reverse_u32", .kind = .u32 },
    .{ .name = "reverse_u64", .kind = .u64 },
    .{ .name = "reverse_index", .kind = .index },
};

fn floatToIntegerModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    for (float_to_integer_functions) |definition| {
        const integer = try dialects.ArithDialect.getScalarType(ctx, definition.kind);
        const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, definition.name, &.{floating}, &.{integer});
        try module.getBodyBlock().addOperation(function.op);
        const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), integer);
        try function.getEntryBlock().addOperation(cast.op);
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{cast.getResult()});
        try function.getEntryBlock().addOperation(ret.op);
    }
    return module.op;
}

/// Twenty-four exact raw f64 inputs per declared width; invalid rows are
/// compared with the dialect's optional oracle without executing a trap here.
fn floatToIntegerSamples(kind: @import("../../dialects/root.zig").arith.ScalarKind) [24]f64 {
    const arith = @import("../../dialects/root.zig").arith;
    const unsigned = arith.scalarKindIsUnsignedInteger(kind) or kind == .index;
    const bits = arith.scalarBitWidth(kind);
    const exponent: u7 = @intCast(bits - @as(u8, if (unsigned) 0 else 1));
    const upper: f64 = @floatFromInt(@as(u128, 1) << exponent);
    const lower: f64 = if (unsigned) -1 else if (bits == 64) -upper else -upper - 1;
    const lower_bits: u64 = @bitCast(lower);
    const upper_bits: u64 = @bitCast(upper);
    const subnormal: f64 = @bitCast(@as(u64, 1));
    return .{
        0,                                         -0.0,                                      subnormal,                                 -subnormal,                                0.5,                                       -0.5,                     1.75,               -1.75,
        lower,                                     @bitCast(lower_bits + 1),                  @bitCast(lower_bits - 1),                  upper,                                     @bitCast(upper_bits - 1),                  @bitCast(upper_bits + 1), -1,                 @bitCast(@as(u64, 0xfff8_1234_5678_9abc)),
        @bitCast(@as(u64, 0x7ff0_1234_5678_9abc)), @bitCast(@as(u64, 0xfff0_1234_5678_9abc)), @bitCast(@as(u64, 0x43e0_0000_0000_0000)), @bitCast(@as(u64, 0x43ef_ffff_ffff_ffff)), @bitCast(@as(u64, 0x43f0_0000_0000_0000)), std.math.inf(f64),        -std.math.inf(f64), @bitCast(@as(u64, 0x7ff8_1234_5678_9abc)),
    };
}

fn floatToIntegerValue(kind: @import("../../dialects/root.zig").arith.ScalarKind, raw: i64) execution.Value {
    const bits: u64 = @bitCast(raw);
    return switch (kind) {
        .i8 => .{ .i8 = @intCast(raw) },
        .i16 => .{ .i16 = @intCast(raw) },
        .i32 => .{ .i32 = @intCast(raw) },
        .i64 => .{ .i64 = raw },
        .u8 => .{ .u8 = @truncate(bits) },
        .u16 => .{ .u16 = @truncate(bits) },
        .u32 => .{ .u32 = @truncate(bits) },
        .u64 => .{ .u64 = bits },
        .index => .{ .index = bits },
        else => unreachable,
    };
}

fn expectInvalidFloatToIntegerTrap(comptime Result: type, native: *const fn (f64) callconv(.c) Result, input: f64) !void {
    const child = std.c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        _ = native(input);
        std.c._exit(102);
    }
    const termination = try sys.process.waitDirect(@intCast(child));
    switch (termination) {
        .signal => |signal| try std.testing.expect(signal == .TRAP),
        else => return error.ExpectedSigtrap,
    }
}

fn expectValidFloatToIntegerChild(comptime Result: type, native: *const fn (f64) callconv(.c) Result) !void {
    const child = std.c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        if (native(1.75) != @as(Result, 1)) std.c._exit(101);
        std.c._exit(0);
    }
    const termination = try sys.process.waitDirect(@intCast(child));
    switch (termination) {
        .exited => |status| try std.testing.expectEqual(@as(u8, 0), status),
        else => return error.ExpectedNormalChildExit,
    }
}

fn reverseMixedModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const to_float = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "reverse_to_float", &.{integer}, &.{floating});
    try module.getBodyBlock().addOperation(to_float.op);
    const to_integer = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "reverse_to_integer", &.{floating}, &.{integer});
    try module.getBodyBlock().addOperation(to_integer.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "reverse_mixed", &.{floating}, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), integer);
    try entry.addOperation(cast.op);
    const floating_call = try dialects.FuncDialect.CallOp.create(ctx, loc, "reverse_to_float", &.{cast.getResult()}, &.{floating});
    try entry.addOperation(floating_call.op);
    const integer_call = try dialects.FuncDialect.CallOp.create(ctx, loc, "reverse_to_integer", &.{floating_call.getResult(0).?}, &.{integer});
    try entry.addOperation(integer_call.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{integer_call.getResult(0).?});
    try entry.addOperation(ret.op);
    return module.op;
}

fn reverseToFloat(value: i64) callconv(.c) f64 {
    std.debug.assert(invoke.defaultFpcr());
    return @as(f64, @floatFromInt(value)) + 0.75;
}

fn reverseToInteger(value: f64) callconv(.c) i64 {
    std.debug.assert(invoke.defaultFpcr());
    return @as(i64, @intFromFloat(value)) + 2;
}

const ReversePressure = struct { module: *ir.Operation, converted: *ir.Value };

fn reversePressureModule(ctx: *ir.Context) !ReversePressure {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "reverse_integer_step", &.{integer}, &.{integer});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "reverse_pressure", &.{floating}, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, @floatFromInt(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const converted = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), integer);
    try entry.addOperation(converted.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "reverse_integer_step", &.{converted.getResult()}, &.{integer});
    try entry.addOperation(call.op);
    var float_sum = values[0];
    for (values[1..]) |value| {
        const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, float_sum, value);
        try entry.addOperation(sum.op);
        float_sum = sum.getResult();
    }
    const constant_sum = try dialects.ArithDialect.CastOp.create(ctx, loc, float_sum, integer);
    try entry.addOperation(constant_sum.op);
    const first_sum = try dialects.ArithDialect.AddOp.create(ctx, loc, call.getResult(0).?, converted.getResult());
    try entry.addOperation(first_sum.op);
    const second_sum = try dialects.ArithDialect.AddOp.create(ctx, loc, first_sum.getResult(), constant_sum.getResult());
    try entry.addOperation(second_sum.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{second_sum.getResult()});
    try entry.addOperation(ret.op);
    return .{ .module = module.op, .converted = converted.getResult() };
}

fn reverseIntegerStep(value: i64) callconv(.c) i64 {
    std.debug.assert(invoke.defaultFpcr());
    return value + 1;
}

fn reverseLoopModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const integer = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "reverse_loop", &.{ floating, index }, &.{integer});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const zero_index = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero_index.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try entry.addOperation(one.op);
    const zero_integer = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, integer, 0);
    try entry.addOperation(zero_integer.op);
    const loop = try dialects.ScfDialect.ForOp.create(ctx, loc, zero_index.getResult(), function.getArgument(1), one.getResult(), &.{zero_integer.getResult()}, &.{integer});
    try entry.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const converted = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), integer);
    try body.addOperation(converted.op);
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, body.arguments.items[1], converted.getResult());
    try body.addOperation(sum.op);
    const yield = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{sum.getResult()});
    try body.addOperation(yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(0).?});
    try entry.addOperation(ret.op);
    return module.op;
}

fn unusedNumericCastModule(
    ctx: *ir.Context,
    source_kind: @import("../../dialects/root.zig").arith.ScalarKind,
    result_kind: @import("../../dialects/root.zig").arith.ScalarKind,
) !struct { module: *ir.Operation, function: *ir.Operation, cast: *ir.Operation } {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const source = try dialects.ArithDialect.getScalarType(ctx, source_kind);
    const result = try dialects.ArithDialect.getScalarType(ctx, result_kind);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "unused_numeric_cast", &.{source}, &.{source});
    try module.getBodyBlock().addOperation(function.op);
    const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), result);
    try function.getEntryBlock().addOperation(cast.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{function.getArgument(0)});
    try function.getEntryBlock().addOperation(ret.op);
    return .{ .module = module.op, .function = function.op, .cast = cast.op };
}

fn constantFloatToIntegerModule(
    ctx: *ir.Context,
    number: f64,
    result_kind: @import("../../dialects/root.zig").arith.ScalarKind,
) !struct { module: *ir.Operation, function: *ir.Operation, cast: *ir.Operation } {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const integer = try dialects.ArithDialect.getScalarType(ctx, result_kind);
    const return_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "constant_float_cast", &.{}, &.{return_type});
    try module.getBodyBlock().addOperation(function.op);
    const constant = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, number);
    try function.getEntryBlock().addOperation(constant.op);
    const cast = try dialects.ArithDialect.CastOp.create(ctx, loc, constant.getResult(), integer);
    try function.getEntryBlock().addOperation(cast.op);
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, return_type, 0);
    try function.getEntryBlock().addOperation(zero.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{zero.getResult()});
    try function.getEntryBlock().addOperation(ret.op);
    return .{ .module = module.op, .function = function.op, .cast = cast.op };
}

const FloatToIntegerDiagnostic = struct {
    operation: []const u8 = "",
    message: []const u8 = "",

    fn record(context: ?*anyopaque, diagnostic: *const @import("../../root.zig").diagnostics.Diagnostic) !@import("../../root.zig").diagnostics.HandlerResult {
        const self: *FloatToIntegerDiagnostic = @ptrCast(@alignCast(context.?));
        self.operation = diagnostic.operationName() orelse "";
        self.message = diagnostic.message;
        return .consumed;
    }
};

fn numericCastLoopModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "float_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "numeric_cast_loop", &.{index}, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 0);
    try entry.addOperation(zero.op);
    const one = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index, 1);
    try entry.addOperation(one.op);
    const floating_zero = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, 0);
    try entry.addOperation(floating_zero.op);
    const loop = try dialects.ScfDialect.ForOp.create(ctx, loc, zero.getResult(), function.getArgument(0), one.getResult(), &.{floating_zero.getResult()}, &.{floating});
    try entry.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const converted = try dialects.ArithDialect.CastOp.create(ctx, loc, body.arguments.items[0], floating);
    try body.addOperation(converted.op);
    const sum = try dialects.ArithDialect.AddOp.create(ctx, loc, body.arguments.items[1], converted.getResult());
    try body.addOperation(sum.op);
    const step = try dialects.FuncDialect.CallOp.create(ctx, loc, "float_step_oracle", &.{sum.getResult()}, &.{floating});
    try body.addOperation(step.op);
    const yielded = try dialects.ScfDialect.YieldOp.create(ctx, loc, &.{step.getResult(0).?});
    try body.addOperation(yielded.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(0).?});
    try entry.addOperation(ret.op);
    const wrapper = try dialects.FuncDialect.FuncOp.create(ctx, loc, "numeric_cast_wrapper", &.{index}, &.{floating});
    try module.getBodyBlock().addOperation(wrapper.op);
    const internal = try dialects.FuncDialect.CallOp.create(ctx, loc, "numeric_cast_loop", wrapper.getArguments(), &.{floating});
    try wrapper.getEntryBlock().addOperation(internal.op);
    const wrapper_ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{internal.getResult(0).?});
    try wrapper.getEntryBlock().addOperation(wrapper_ret.op);
    return module.op;
}

const NumericCastPressure = struct { module: *ir.Operation, source: *ir.Value, converted: *ir.Value };

fn numericCastPressureModule(ctx: *ir.Context) !NumericCastPressure {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "float_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "numeric_cast_pressure", &.{word}, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, @floatFromInt(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const source = try dialects.ArithDialect.CastOp.create(ctx, loc, function.getArgument(0), word);
    try entry.addOperation(source.op);
    const converted = try dialects.ArithDialect.CastOp.create(ctx, loc, source.getResult(), floating);
    try entry.addOperation(converted.op);
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "float_step_oracle", &.{values[0]}, &.{floating});
    try entry.addOperation(call.op);
    var sum = call.getResult(0).?;
    const first_sum = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, converted.getResult());
    try entry.addOperation(first_sum.op);
    sum = first_sum.getResult();
    for (values) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, value);
        try entry.addOperation(add.op);
        sum = add.getResult();
    }
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum});
    try entry.addOperation(ret.op);
    return .{ .module = module.op, .source = source.getResult(), .converted = converted.getResult() };
}

fn floatPressureModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const external = try dialects.FuncDialect.FuncOp.createDeclaration(ctx, loc, "float_step_oracle", &.{floating}, &.{floating});
    try module.getBodyBlock().addOperation(external.op);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "float_pressure", &.{}, &.{floating});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var values: [placement.max_registers + 1]*ir.Value = undefined;
    for (&values, 0..) |*value, index| {
        const constant = try dialects.ArithDialect.ConstantOp.createFloat(ctx, loc, floating, @floatFromInt(index + 1));
        try entry.addOperation(constant.op);
        value.* = constant.getResult();
    }
    const call = try dialects.FuncDialect.CallOp.create(ctx, loc, "float_step_oracle", &.{values[0]}, &.{floating});
    try entry.addOperation(call.op);
    var sum = call.getResult(0).?;
    for (values) |value| {
        const add = try dialects.ArithDialect.AddOp.create(ctx, loc, sum, value);
        try entry.addOperation(add.op);
        sum = add.getResult();
    }
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{sum});
    try entry.addOperation(ret.op);
    return module.op;
}
