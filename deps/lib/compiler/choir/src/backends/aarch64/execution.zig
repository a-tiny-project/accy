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
const target_bounds = @import("bounds.zig");
const sys = @import("sys");
const Arith = @import("../../dialects/root.zig").ArithDialect;
const Func = @import("../../dialects/root.zig").FuncDialect;

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
    /// `malloc` and `free`, then the math library, as on x64: the process's own `sys.heap` and
    /// `sys.math` functions, never the platform libm.
    pub const builtin_count: usize = 2 + sys.math.symbols.len;
    pub const bounds: execution.Bounds = target_bounds.bounds;
    pub const Compiler = backend.Emitter;
    /// The placement plan each emit builds and nothing reads after it.
    pub const Scratch = placement.Plan;
    pub const EmitError = @typeInfo(@typeInfo(@TypeOf(Compiler.emitFunction)).@"fn".return_type.?).error_union.error_set;

    pub fn builtin(index: usize) execution.Builtin {
        std.debug.assert(index < builtin_count);
        return switch (index) {
            0 => .{ .name = "malloc", .address = @intFromPtr(&sys.heap.malloc) },
            1 => .{ .name = "free", .address = @intFromPtr(&sys.heap.free) },
            else => .{
                .name = sys.math.symbols[index - 2].name(),
                .address = sys.math.symbols[index - 2].address(),
            },
        };
    }

    pub fn initCompiler(allocator: Allocator, scratch: ?*Scratch) Allocator.Error!Compiler {
        var compiler = if (scratch) |plan| Compiler.initBorrowing(allocator, plan) else try Compiler.init(allocator);
        compiler.diagnose = false;
        return compiler;
    }

    pub fn deinitCompiler(compiler: *Compiler) void {
        compiler.deinit();
    }

    pub fn prepare(ctx: *ir.Context) Allocator.Error!void {
        return contract.loadArithDialect(ctx);
    }

    pub fn lower(_: Allocator, module: *ir.Operation, refused: *execution.Refused) execution.LowerError!void {
        backend.lowerModule(module, refused) catch |err| return switch (err) {
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
            // This target places every function it emits, or refuses it, and homes values in
            // general registers only, unless the host turned placement off.
            .placement = if (compiler.place_values) .{ .placed = .{
                .general = compiler.plan.registerHomes(),
                .floating = 0,
            } } else .forced,
        };
    }

    /// The scalar emitter has no source-line mapping. An enabled line table is empty.
    pub fn takeLineTable(compiler: *Compiler) Allocator.Error!debug_info.LineTable {
        var builder = debug_info.LineTableBuilder.init(compiler.allocator);
        return builder.finish();
    }

    /// Every call takes its callee's absolute address from a literal, so the image changes none.
    pub fn shareImage(_: *Compiler, _: ?*const backends.machine_code.ImageFunctions) void {}

    pub fn recordLines(_: *Compiler, _: bool) void {}

    /// Off, the plan gives every value a frame slot and no register, from the next compile on.
    pub fn placeValues(compiler: *Compiler, on: bool) error{FrameOnlyUnsupported}!void {
        compiler.place_values = on;
    }

    pub fn takeCode(compiler: *Compiler) Allocator.Error![]u8 {
        return compiler.code.toOwnedSlice(compiler.allocator);
    }

    pub fn failedOperation(compiler: *const Compiler) ?*ir.Operation {
        return compiler.failed_operation;
    }

    pub fn failedExcess(compiler: *const Compiler) ?execution.Excess {
        return compiler.excess;
    }

    pub fn discard(compiler: *Compiler) void {
        compiler.discard();
    }

    pub fn report(failure: execution.Failure) void {
        if (failure.err == error.OutOfMemory) return;
        var buffer: [backend.excess_message_capacity]u8 = undefined;
        const message = if (failure.excess) |excess|
            backend.excessMessage(&buffer, excess)
        else switch (failure.stage) {
            // Lowering reports its own refusals, so the runtime never hands one here.
            .lower => unreachable,
            .emit => "Apple arm64 native emission failed",
            .link => "Apple arm64 native link failed",
        };
        var diagnostic = failure.operation.emitError(message);
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
    if (backend.lowerModule(module, null)) |_| {
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

/// `live` constants, one more than the placement registers or many more, stay live across a
/// call in one branch; the branch answers `pressure_oracle(1)` plus their sum, the other zero.
fn callPressureModule(ctx: *ir.Context, live: usize) !*ir.Operation {
    std.debug.assert(live > placement.max_registers and live <= placement.max_live_values);
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
    var storage: [placement.max_live_values]*ir.Value = undefined;
    const values = storage[0..live];
    for (values, 0..) |*value, index| {
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

/// The sizes the observed malloc was asked for and the addresses it returned, in call order,
/// and the addresses the observed free released.
var heap_sizes: [4]usize = undefined;
var heap_addresses: [4]usize = undefined;
var heap_size_count: usize = 0;
var heap_released: [4]usize = undefined;
var heap_release_count: usize = 0;

fn observeHeap() void {
    heap_size_count = 0;
    heap_release_count = 0;
}

fn observedMalloc(size: usize) callconv(.c) ?*anyopaque {
    if (heap_size_count == heap_sizes.len) std.c._exit(104);
    const address = sys.heap.malloc(size);
    heap_sizes[heap_size_count] = size;
    heap_addresses[heap_size_count] = @intFromPtr(address);
    heap_size_count += 1;
    return address;
}

fn observedFree(address: ?*anyopaque) callconv(.c) void {
    if (heap_release_count == heap_released.len) std.c._exit(105);
    heap_released[heap_release_count] = @intFromPtr(address);
    heap_release_count += 1;
    sys.heap.free(address);
}

fn failingMalloc(_: usize) callconv(.c) ?*anyopaque {
    return null;
}

fn expectHeap(sizes: []const usize, released: []const usize) !void {
    const testing = std.testing;
    try testing.expectEqualSlices(usize, sizes, heap_sizes[0..heap_size_count]);
    for (heap_addresses[0..heap_size_count]) |address| try testing.expect(address != 0);
    try testing.expectEqual(released.len, heap_release_count);
    for (released, heap_released[0..heap_release_count]) |allocation, address|
        try testing.expectEqual(heap_addresses[allocation], address);
}

/// heap_words stores through a dynamic word allocation, copies the word into a static one while
/// its count and value are live across the second malloc, and frees both. heap_bytes writes
/// through a word View of a byte allocation. heap_unread allocates and never reads. heap_sized
/// allocates a dynamic and an empty static extent and frees them in reverse. stack_release
/// deallocates an alloca, which calls nothing.
fn heapModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const Memref = dialects.MemrefDialect;
    const loc = ir.Location.getUnknown();
    const word = try Arith.getScalarType(ctx, .u64);
    const byte = try Arith.getScalarType(ctx, .u8);
    const signed = try Arith.getScalarType(ctx, .i64);
    const index = try Arith.getScalarType(ctx, .index);
    const words = try Memref.getMemrefTypeDynamic(ctx, word, .host);
    const bytes = try Memref.getMemrefTypeDynamic(ctx, byte, .host);
    const three = try Memref.getMemrefType1D(ctx, 3, word, .host);
    const two = try Memref.getMemrefType1D(ctx, 2, word, .host);
    const one = try Memref.getMemrefType1D(ctx, 1, word, .host);
    const empty = try Memref.getMemrefType1D(ctx, 0, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const body = module.getBodyBlock();

    const copy = try Func.FuncOp.create(ctx, loc, "heap_words", &.{ index, index, word }, &.{word});
    try body.addOperation(copy.op);
    const copy_entry = copy.getEntryBlock();
    const dynamic = try Memref.AllocOp.createDynamic(ctx, loc, copy.getArgument(0), words);
    try copy_entry.addOperation(dynamic.op);
    try copy_entry.addOperation((try Memref.StoreOp.create(ctx, loc, copy.getArgument(2), dynamic.getResult(), copy.getArgument(1))).op);
    const static = try Memref.AllocOp.createStatic(ctx, loc, three);
    try copy_entry.addOperation(static.op);
    const read = try Memref.LoadOp.create(ctx, loc, dynamic.getResult(), copy.getArgument(1), word);
    try copy_entry.addOperation(read.op);
    const last = try Arith.ConstantOp.createInt(ctx, loc, index, 2);
    try copy_entry.addOperation(last.op);
    try copy_entry.addOperation((try Memref.StoreOp.create(ctx, loc, read.getResult(), static.getResult(), last.getResult())).op);
    const copied = try Memref.LoadOp.create(ctx, loc, static.getResult(), last.getResult(), word);
    try copy_entry.addOperation(copied.op);
    try copy_entry.addOperation((try Memref.DeallocOp.create(ctx, loc, dynamic.getResult())).op);
    try copy_entry.addOperation((try Memref.DeallocOp.create(ctx, loc, static.getResult())).op);
    try copy_entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{copied.getResult()})).op);

    const viewed = try Func.FuncOp.create(ctx, loc, "heap_bytes", &.{ index, word }, &.{word});
    try body.addOperation(viewed.op);
    const viewed_entry = viewed.getEntryBlock();
    const raw = try Memref.AllocOp.createDynamic(ctx, loc, viewed.getArgument(0), bytes);
    try viewed_entry.addOperation(raw.op);
    const zero = try Arith.ConstantOp.createInt(ctx, loc, index, 0);
    try viewed_entry.addOperation(zero.op);
    const view = try Memref.ViewOp.create(ctx, loc, raw.getResult(), zero.getResult(), one);
    try viewed_entry.addOperation(view.op);
    try viewed_entry.addOperation((try Memref.StoreOp.create(ctx, loc, viewed.getArgument(1), view.getResult(), zero.getResult())).op);
    const through = try Memref.LoadOp.create(ctx, loc, view.getResult(), zero.getResult(), word);
    try viewed_entry.addOperation(through.op);
    try viewed_entry.addOperation((try Memref.DeallocOp.create(ctx, loc, raw.getResult())).op);
    try viewed_entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{through.getResult()})).op);

    const unread = try Func.FuncOp.create(ctx, loc, "heap_unread", &.{}, &.{signed});
    try body.addOperation(unread.op);
    const unread_entry = unread.getEntryBlock();
    try unread_entry.addOperation((try Memref.AllocOp.createStatic(ctx, loc, two)).op);
    const answer = try Arith.ConstantOp.createInt(ctx, loc, signed, 42);
    try unread_entry.addOperation(answer.op);
    try unread_entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{answer.getResult()})).op);

    const sized = try Func.FuncOp.create(ctx, loc, "heap_sized", &.{index}, &.{signed});
    try body.addOperation(sized.op);
    const sized_entry = sized.getEntryBlock();
    const counted = try Memref.AllocOp.createDynamic(ctx, loc, sized.getArgument(0), words);
    try sized_entry.addOperation(counted.op);
    const nothing = try Memref.AllocOp.createStatic(ctx, loc, empty);
    try sized_entry.addOperation(nothing.op);
    try sized_entry.addOperation((try Memref.DeallocOp.create(ctx, loc, nothing.getResult())).op);
    try sized_entry.addOperation((try Memref.DeallocOp.create(ctx, loc, counted.getResult())).op);
    const seven = try Arith.ConstantOp.createInt(ctx, loc, signed, 7);
    try sized_entry.addOperation(seven.op);
    try sized_entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{seven.getResult()})).op);

    const stack = try Func.FuncOp.create(ctx, loc, "stack_release", &.{word}, &.{word});
    try body.addOperation(stack.op);
    const stack_entry = stack.getEntryBlock();
    const frame = try Memref.AllocaOp.createStatic(ctx, loc, one);
    try stack_entry.addOperation(frame.op);
    const first = try Arith.ConstantOp.createInt(ctx, loc, index, 0);
    try stack_entry.addOperation(first.op);
    try stack_entry.addOperation((try Memref.StoreOp.create(ctx, loc, stack.getArgument(0), frame.getResult(), first.getResult())).op);
    const kept = try Memref.LoadOp.create(ctx, loc, frame.getResult(), first.getResult(), word);
    try stack_entry.addOperation(kept.op);
    try stack_entry.addOperation((try Memref.DeallocOp.create(ctx, loc, frame.getResult())).op);
    try stack_entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{kept.getResult()})).op);
    return module.op;
}

fn expectHeapTrap(native: *const fn (usize) callconv(.c) i64, count: usize) !void {
    const child = std.c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        _ = native(count);
        std.c._exit(102);
    }
    const termination = try sys.process.waitDirect(@intCast(child));
    switch (termination) {
        .signal => |signal| try std.testing.expect(signal == .TRAP),
        else => return error.ExpectedSigtrap,
    }
}

const HeapRefusal = enum { foreign, floating, mismatched, device, annotated };

fn heapRefusalModule(ctx: *ir.Context, case: HeapRefusal) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const Memref = dialects.MemrefDialect;
    const loc = ir.Location.getUnknown();
    const word = try dialects.ArithDialect.getScalarType(ctx, .u64);
    const real = try dialects.ArithDialect.getScalarType(ctx, .f64);
    const index = try dialects.ArithDialect.getScalarType(ctx, .index);
    const borrowed = try Memref.getMemrefTypeDynamic(ctx, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, "heap_refusal", &.{ borrowed, index }, &.{});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const released = if (case == .foreign) function.getArgument(0) else released: {
        const alloc = switch (case) {
            .floating => try Memref.AllocOp.createStatic(ctx, loc, try Memref.getMemrefType1D(ctx, 2, real, .host)),
            .mismatched => try Memref.AllocOp.createDynamic(ctx, loc, function.getArgument(1), try Memref.getMemrefType1D(ctx, 2, word, .host)),
            .device => try Memref.AllocOp.createStatic(ctx, loc, try Memref.getMemrefType1D(ctx, 2, word, .device)),
            .annotated => try Memref.AllocOp.createStatic(ctx, loc, try Memref.getMemrefType1D(ctx, 2, word, .host)),
            .foreign => unreachable,
        };
        if (case == .annotated) try alloc.op.setAttr("future", try ctx.getBoolAttr(true));
        try entry.addOperation(alloc.op);
        break :released alloc.getResult();
    };
    try entry.addOperation((try Memref.DeallocOp.create(ctx, loc, released)).op);
    try entry.addOperation((try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{})).op);
    return module.op;
}

/// Each admitted vector shape with the Zig type of its lane.
const VectorCase = struct { lanes: u32, kind: dialects_root.arith.ScalarKind, Lane: type };

const dialects_root = @import("../../dialects/root.zig");

const vector_cases = [_]VectorCase{
    .{ .lanes = 2, .kind = .f32, .Lane = f32 },
    .{ .lanes = 2, .kind = .i32, .Lane = i32 },
    .{ .lanes = 2, .kind = .u32, .Lane = u32 },
    .{ .lanes = 2, .kind = .f64, .Lane = f64 },
    .{ .lanes = 2, .kind = .i64, .Lane = i64 },
    .{ .lanes = 2, .kind = .u64, .Lane = u64 },
    .{ .lanes = 4, .kind = .f32, .Lane = f32 },
    .{ .lanes = 4, .kind = .i32, .Lane = i32 },
    .{ .lanes = 4, .kind = .u32, .Lane = u32 },
    .{ .lanes = 4, .kind = .i16, .Lane = i16 },
    .{ .lanes = 4, .kind = .u16, .Lane = u16 },
};

const lane_names = [_][]const u8{ "lane_0", "lane_1", "lane_2", "lane_3" };

var vector_oracle_calls: usize = 0;

fn vectorOracle() callconv(.c) void {
    vector_oracle_calls += 1;
}

fn vectorType(ctx: *ir.Context, lanes: u32, kind: dialects_root.arith.ScalarKind) !ir.Type {
    return (try dialects_root.ArithDialect.getVecType(ctx, lanes, dialects_root.arith.scalarTypeName(kind))).?;
}

/// lane_k(a0, ..., a(n-1)) splats a0, inserts every other argument at its own lane, keeps the
/// vector across a call, and returns lane k. splat_last(a0) returns the last lane of a splat.
fn vectorLaneModule(ctx: *ir.Context, lanes: u32, kind: dialects_root.arith.ScalarKind) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const lane = try Arith.getScalarType(ctx, kind);
    const vector = try vectorType(ctx, lanes, kind);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const body = module.getBodyBlock();
    try body.addOperation((try Func.FuncOp.createDeclaration(ctx, loc, "vector_oracle", &.{}, &.{})).op);
    var parameters: [4]ir.Type = undefined;
    for (parameters[0..lanes]) |*parameter| parameter.* = lane;
    for (lane_names[0..lanes], 0..) |name, read| {
        const function = try Func.FuncOp.create(ctx, loc, name, parameters[0..lanes], &.{lane});
        try body.addOperation(function.op);
        const entry = function.getEntryBlock();
        const splat = try Arith.SplatOp.create(ctx, loc, function.getArgument(0), vector);
        try entry.addOperation(splat.op);
        var current = splat.getResult();
        for (1..lanes) |written| {
            const insert = try Arith.InsertOp.create(ctx, loc, current, function.getArgument(written), @intCast(written));
            try entry.addOperation(insert.op);
            current = insert.getResult();
        }
        try entry.addOperation((try Func.CallOp.create(ctx, loc, "vector_oracle", &.{}, &.{})).op);
        const extract = try Arith.ExtractOp.create(ctx, loc, current, @intCast(read), lane);
        try entry.addOperation(extract.op);
        try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{extract.getResult()})).op);
    }
    const last = try Func.FuncOp.create(ctx, loc, "splat_last", &.{lane}, &.{lane});
    try body.addOperation(last.op);
    const splat = try Arith.SplatOp.create(ctx, loc, last.getArgument(0), vector);
    try last.getEntryBlock().addOperation(splat.op);
    const extract = try Arith.ExtractOp.create(ctx, loc, splat.getResult(), @intCast(lanes - 1), lane);
    try last.getEntryBlock().addOperation(extract.op);
    try last.getEntryBlock().addOperation((try Func.ReturnOp.create(ctx, loc, &.{extract.getResult()})).op);
    return module.op;
}

/// Lane values whose bits a lane move must keep: sign bits, extremes, and for floating lanes a
/// signaling NaN, a payload NaN and a negative zero.
fn lanePool(comptime T: type) [5]T {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const patterns: [5]Bits = switch (@typeInfo(T)) {
        .float => if (T == f32)
            .{ 0x7fa0_0001, 0xffc1_2345, 0x8000_0000, 0x3fc0_0000, 0xc2f6_e979 }
        else
            .{ 0x7ff4_0000_0000_0001, 0xfff8_dead_beef_0001, 0x8000_0000_0000_0000, 0x3ff8_0000_0000_0000, 0xc05e_dd2f_1a9f_be77 },
        .int => .{ std.math.maxInt(Bits), 1 << (@bitSizeOf(T) - 1), 0x5a5a_5a5a_5a5a_5a5a & std.math.maxInt(Bits), 7, (1 << (@bitSizeOf(T) - 1)) - 3 },
        else => unreachable,
    };
    var pool: [5]T = undefined;
    for (patterns, &pool) |pattern, *value| value.* = @bitCast(pattern);
    return pool;
}

fn expectLaneBits(comptime T: type, expected: T, actual: T) !void {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    try std.testing.expectEqual(@as(Bits, @bitCast(expected)), @as(Bits, @bitCast(actual)));
}

fn expectVectorLanes(runtime: anytype, handle: anytype, comptime case: VectorCase) !void {
    const T = case.Lane;
    const pool = lanePool(T);
    for (0..pool.len) |shift| {
        var inputs: [4]T = undefined;
        for (&inputs, 0..) |*input, lane| input.* = pool[(shift + lane) % pool.len];
        inline for (0..case.lanes) |read| {
            const calls = vector_oracle_calls;
            const got = if (case.lanes == 2) pair: {
                const native = try runtime.getFunction(handle, lane_names[read], *const fn (T, T) callconv(.c) T);
                break :pair native(inputs[0], inputs[1]);
            } else quad: {
                const native = try runtime.getFunction(handle, lane_names[read], *const fn (T, T, T, T) callconv(.c) T);
                break :quad native(inputs[0], inputs[1], inputs[2], inputs[3]);
            };
            try expectLaneBits(T, inputs[read], got);
            try std.testing.expectEqual(calls + 1, vector_oracle_calls);
        }
        const last = try runtime.getFunction(handle, "splat_last", *const fn (T) callconv(.c) T);
        try expectLaneBits(T, inputs[0], last(inputs[0]));
    }
}

/// vector_frame(a) splats `count` vectors of a, all live at once, then sums lane 1 of each.
fn vectorFrameModule(ctx: *ir.Context, count: usize) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const word = try Arith.getScalarType(ctx, .i64);
    const vector = try vectorType(ctx, 2, .i64);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try Func.FuncOp.create(ctx, loc, "vector_frame", &.{word}, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    var splats: [placement.max_frame_slots / placement.vector_slots + 1]*ir.Value = undefined;
    for (splats[0..count]) |*held| {
        const splat = try Arith.SplatOp.create(ctx, loc, function.getArgument(0), vector);
        try entry.addOperation(splat.op);
        held.* = splat.getResult();
    }
    var sum: ?*ir.Value = null;
    for (splats[0..count]) |held| {
        const extract = try Arith.ExtractOp.create(ctx, loc, held, 1, word);
        try entry.addOperation(extract.op);
        if (sum) |partial| {
            const add = try Arith.AddOp.create(ctx, loc, partial, extract.getResult());
            try entry.addOperation(add.op);
            sum = add.getResult();
        } else sum = extract.getResult();
    }
    try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{sum.?})).op);
    return module.op;
}

/// Checks the placement statically, then runs the function when `execute` is set.
fn vectorFrameWitness(execute: bool) !void {
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects_root.registerAllDialects(&ctx);
    const fits = placement.max_frame_slots / placement.vector_slots;
    const full = try vectorFrameModule(&ctx, fits);
    defer full.erase();
    const full_function = ir.inspection.functionDefinitionByName(full, "vector_frame").?;
    var emitter = try backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(full_function);
    try testing.expectEqual(placement.max_frame_slots, emitter.plan.frame_slots);

    const over = try vectorFrameModule(&ctx, fits + 1);
    defer over.erase();
    var refused = try backend.Emitter.init(testing.allocator);
    defer refused.deinit();
    try testing.expectError(error.UnsupportedOperation, refused.emitFunction(ir.inspection.functionDefinitionByName(over, "vector_frame").?));
    try testing.expectEqualStrings(dialects_root.ArithDialect.SplatOp.operation_name, refused.failed_operation.?.name.name);
    try testing.expectEqual(execution.Excess{
        .bound = .frame_bytes,
        .limit = placement.max_frame_bytes,
        .held = placement.max_frame_bytes,
        .requested = placement.vector_slots * placement.slot_bytes,
    }, refused.excess.?);

    if (!execute) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(full);
    const native = try runtime.getFunction(handle, "vector_frame", *const fn (i64) callconv(.c) i64);
    for ([_]i64{ 3, -5, 0x0123_4567_89ab }) |value| try testing.expectEqual(value *% @as(i64, @intCast(fits)), native(value));
    try runtime.release(handle);
}

/// Scalars fill the seven registers and spill, one spill dies so its single slot frees below
/// live ones, and vectors are defined around that hole.
fn fragmentedFrameModule(ctx: *ir.Context) !struct { module: *ir.Operation, vectors: [2]*ir.Value } {
    const loc = ir.Location.getUnknown();
    const word = try Arith.getScalarType(ctx, .i64);
    const vector = try vectorType(ctx, 2, .i64);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try Func.FuncOp.create(ctx, loc, "fragmented", &.{word}, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const a = function.getArgument(0);
    var held: [10]*ir.Value = undefined;
    var previous = a;
    for (&held) |*value| {
        const add = try Arith.AddOp.create(ctx, loc, previous, a);
        try entry.addOperation(add.op);
        value.* = add.getResult();
        previous = add.getResult();
    }
    // held[8] dies here, freeing one spill slot between two live ones.
    const first = try Arith.SplatOp.create(ctx, loc, held[8], vector);
    try entry.addOperation(first.op);
    const between = try Arith.AddOp.create(ctx, loc, held[7], held[9]);
    try entry.addOperation(between.op);
    const second = try Arith.SplatOp.create(ctx, loc, between.getResult(), vector);
    try entry.addOperation(second.op);
    const late = try Arith.AddOp.create(ctx, loc, between.getResult(), a);
    try entry.addOperation(late.op);
    var sum = late.getResult();
    for ([_]*ir.Value{ first.getResult(), second.getResult() }, 0..) |source, lane| {
        const extract = try Arith.ExtractOp.create(ctx, loc, source, @intCast(lane), word);
        try entry.addOperation(extract.op);
        const add = try Arith.AddOp.create(ctx, loc, sum, extract.getResult());
        try entry.addOperation(add.op);
        sum = add.getResult();
    }
    for (held[0..7]) |value| {
        const add = try Arith.AddOp.create(ctx, loc, sum, value);
        try entry.addOperation(add.op);
        sum = add.getResult();
    }
    try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{sum})).op);
    return .{ .module = module.op, .vectors = .{ first.getResult(), second.getResult() } };
}

/// Checks the placement statically, then runs the function when `execute` is set.
fn vectorExtentWitness(execute: bool) !void {
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects_root.registerAllDialects(&ctx);
    const fragmented = try fragmentedFrameModule(&ctx);
    defer fragmented.module.erase();
    const function = ir.inspection.functionDefinitionByName(fragmented.module, "fragmented").?;
    const plan = try std.testing.allocator.create(placement.Plan);
    defer std.testing.allocator.destroy(plan);
    plan.* = .{};
    try plan.build(function.getRegion(0).?.getEntryBlock().?, true);
    var odd_spill_under_vector = false;
    for (plan.entries[0..plan.count]) |entry| {
        const slot = switch (entry.location) {
            .stack => |slot| slot,
            else => continue,
        };
        const width: u16 = if (placement.isVector(entry.value)) placement.vector_slots else 1;
        if (width == placement.vector_slots) {
            try testing.expectEqual(@as(u16, 0), slot % placement.vector_slots);
            try testing.expectEqual(@as(u16, 0), slot * placement.slot_bytes % 16);
        }
        for (plan.entries[0..plan.count]) |other| {
            if (other.value == entry.value) continue;
            const other_slot = switch (other.location) {
                .stack => |other_slot| other_slot,
                else => continue,
            };
            const other_width: u16 = if (placement.isVector(other.value)) placement.vector_slots else 1;
            const live_together = entry.range.start <= other.range.end and other.range.start <= entry.range.end;
            const share = slot < other_slot + other_width and other_slot < slot + width;
            // Two homes share a slot only where one ends exactly where the other is defined,
            // which the source-then-definition order allows.
            if (live_together and share)
                try testing.expect(entry.range.end == other.range.start or other.range.end == entry.range.start);
            if (width == 1 and other_width == placement.vector_slots and slot % 2 == 1 and live_together)
                odd_spill_under_vector = true;
        }
    }
    for (fragmented.vectors) |vector| try testing.expect(plan.get(vector).? == .stack);
    try testing.expect(odd_spill_under_vector);

    if (!execute) return;
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(testing.allocator, .testing, .macos_non_hardened);
    defer runtime.deinit();
    const handle = try runtime.compile(fragmented.module);
    const native = try runtime.getFunction(handle, "fragmented", *const fn (i64) callconv(.c) i64);
    for ([_]i64{ 1, -7, 0x1234_5678 }) |a| {
        var held: [10]i64 = undefined;
        var previous = a;
        for (&held) |*value| {
            value.* = previous +% a;
            previous = value.*;
        }
        const between = held[7] +% held[9];
        var expected = (between +% a) +% held[8] +% between;
        for (held[0..7]) |value| expected +%= value;
        try testing.expectEqual(expected, native(a));
    }
    try runtime.release(handle);
}

/// Scalar floating operations and vector lane moves alternate on shared values, so a vector
/// sequence's v16 meets a value a scalar sequence left in a general register, never in v16.
fn interleavedFloatModule(ctx: *ir.Context) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const single = try Arith.getScalarType(ctx, .f32);
    const vector = try vectorType(ctx, 4, .f32);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try Func.FuncOp.create(ctx, loc, "interleaved", &.{ single, single }, &.{single});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const sum = try Arith.AddOp.create(ctx, loc, function.getArgument(0), function.getArgument(1));
    try entry.addOperation(sum.op);
    const splat = try Arith.SplatOp.create(ctx, loc, sum.getResult(), vector);
    try entry.addOperation(splat.op);
    const product = try Arith.MulOp.create(ctx, loc, function.getArgument(0), function.getArgument(1));
    try entry.addOperation(product.op);
    const insert = try Arith.InsertOp.create(ctx, loc, splat.getResult(), product.getResult(), 2);
    try entry.addOperation(insert.op);
    const inserted = try Arith.ExtractOp.create(ctx, loc, insert.getResult(), 2, single);
    try entry.addOperation(inserted.op);
    const kept = try Arith.ExtractOp.create(ctx, loc, insert.getResult(), 0, single);
    try entry.addOperation(kept.op);
    const total = try Arith.AddOp.create(ctx, loc, inserted.getResult(), kept.getResult());
    try entry.addOperation(total.op);
    try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{total.getResult()})).op);
    return module.op;
}

const Elementwise = enum { add, sub, mul, div, min, max, @"and", @"or", xor, neg, not, select };

/// The elementwise operations aarch64 lowers for a lane class: those no lane can fail.
fn elementwiseOperations(comptime floating: bool) []const Elementwise {
    return if (floating)
        &.{ .add, .sub, .mul, .div, .neg, .select }
    else
        &.{ .add, .sub, .mul, .min, .max, .@"and", .@"or", .xor, .neg, .not, .select };
}

/// The function that returns lane `read` of `operation`, such as "add_1".
fn elementwiseName(comptime operation: Elementwise, comptime read: usize) []const u8 {
    return @tagName(operation) ++ "_" ++ &[_]u8{'0' + read};
}

fn ElementwiseOp(comptime operation: Elementwise) type {
    return switch (operation) {
        .add => Arith.AddOp,
        .sub => Arith.SubOp,
        .mul => Arith.MulOp,
        .div => Arith.DivOp,
        .min => Arith.MinOp,
        .max => Arith.MaxOp,
        .@"and" => Arith.AndOp,
        .@"or" => Arith.OrOp,
        .xor => Arith.XorOp,
        .neg => Arith.NegOp,
        .not => Arith.NotOp,
        .select => Arith.SelectOp,
    };
}

fn elementwiseArity(comptime operation: Elementwise) usize {
    return switch (operation) {
        .neg, .not => 1,
        .select => 0,
        else => 2,
    };
}

/// The vector of `values` in lane order: a splat of the first, then one insert per lane.
fn vectorOf(ctx: *ir.Context, entry: *ir.Block, values: []const *ir.Value, vector: ir.Type) !*ir.Value {
    const loc = ir.Location.getUnknown();
    const splat = try Arith.SplatOp.create(ctx, loc, values[0], vector);
    try entry.addOperation(splat.op);
    var current = splat.getResult();
    for (values[1..], 1..) |value, lane| {
        const insert = try Arith.InsertOp.create(ctx, loc, current, value, @intCast(lane));
        try entry.addOperation(insert.op);
        current = insert.getResult();
    }
    return current;
}

/// <op>_k(a0, ..., a(n-1), b0, ..., b(n-1)) applies op to the vectors of a and b and returns
/// lane k; neg and not read only a. select_k(flag, a0, ..., a(n-1)) chooses the vector of a
/// when flag is nonzero and otherwise the vector of a in reverse lane order.
fn elementwiseModule(ctx: *ir.Context, comptime lanes: u32, comptime kind: dialects_root.arith.ScalarKind) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const lane = try Arith.getScalarType(ctx, kind);
    const word = try Arith.getScalarType(ctx, .i64);
    const vector = try vectorType(ctx, lanes, kind);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const body = module.getBodyBlock();
    inline for (comptime elementwiseOperations(dialects_root.arith.scalarKindIsFloat(kind))) |operation| {
        inline for (0..lanes) |read| {
            const name = elementwiseName(operation, read);
            const arity = comptime elementwiseArity(operation);
            var parameters: [2 * lanes]ir.Type = undefined;
            for (&parameters) |*parameter| parameter.* = lane;
            const function = if (operation == .select) select: {
                var choosing: [lanes + 1]ir.Type = undefined;
                choosing[0] = word;
                for (choosing[1..]) |*parameter| parameter.* = lane;
                break :select try Func.FuncOp.create(ctx, loc, name, &choosing, &.{lane});
            } else try Func.FuncOp.create(ctx, loc, name, parameters[0 .. arity * lanes], &.{lane});
            try body.addOperation(function.op);
            const entry = function.getEntryBlock();
            var arguments: [2 * lanes]*ir.Value = undefined;
            for (0..function.getNumArguments()) |index| arguments[index] = function.getArgument(index);
            const computed = switch (operation) {
                .select => select: {
                    const zero = try Arith.ConstantOp.createInt(ctx, loc, word, 0);
                    try entry.addOperation(zero.op);
                    const flag = try Arith.CmpOp.create(ctx, loc, .ne, arguments[0], zero.getResult());
                    try entry.addOperation(flag.op);
                    var reversed: [lanes]*ir.Value = undefined;
                    for (&reversed, 0..) |*value, index| value.* = arguments[lanes - index];
                    const chosen = try vectorOf(ctx, entry, arguments[1 .. lanes + 1], vector);
                    const other = try vectorOf(ctx, entry, &reversed, vector);
                    const select = try Arith.SelectOp.create(ctx, loc, flag.getResult(), chosen, other);
                    try entry.addOperation(select.op);
                    break :select select.op;
                },
                .neg, .not => unary: {
                    const input = try vectorOf(ctx, entry, arguments[0..lanes], vector);
                    const unary = try ElementwiseOp(operation).create(ctx, loc, input);
                    try entry.addOperation(unary.op);
                    break :unary unary.op;
                },
                else => binary: {
                    const lhs = try vectorOf(ctx, entry, arguments[0..lanes], vector);
                    const rhs = try vectorOf(ctx, entry, arguments[lanes .. 2 * lanes], vector);
                    const binary = try ElementwiseOp(operation).create(ctx, loc, lhs, rhs);
                    try entry.addOperation(binary.op);
                    break :binary binary.op;
                },
            };
            const extract = try Arith.ExtractOp.create(ctx, loc, computed.getResult(0).?, @intCast(read), lane);
            try entry.addOperation(extract.op);
            try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{extract.getResult()})).op);
        }
    }
    return module.op;
}

/// The lane pool plus values arithmetic must carry: zero, one and a product past the lane for
/// integers; infinity, the smallest subnormal and the largest finite value for floats.
fn elementPool(comptime T: type) [8]T {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const extra: [3]T = switch (@typeInfo(T)) {
        .float => .{ std.math.inf(T), @bitCast(@as(Bits, 1)), std.math.floatMax(T) },
        .int => .{ 0, 1, @bitCast(@as(Bits, (1 << (@bitSizeOf(T) / 2)) + 3)) },
        else => unreachable,
    };
    return lanePool(T) ++ extra;
}

/// One lane of each operation as the scalar operation computes it. Integer lanes wrap, and
/// float neg flips the sign bit, as aarch64's scalar neg and x64's packed neg both do.
fn laneOracle(comptime T: type, comptime operation: Elementwise, a: T, b: T) T {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    return switch (@typeInfo(T)) {
        .float => switch (operation) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => a / b,
            .neg => @bitCast(@as(Bits, @bitCast(a)) ^ (@as(Bits, 1) << (@bitSizeOf(T) - 1))),
            else => unreachable,
        },
        .int => switch (operation) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
            .min => @min(a, b),
            .max => @max(a, b),
            .@"and" => a & b,
            .@"or" => a | b,
            .xor => a ^ b,
            .neg => 0 -% a,
            .not => ~a,
            else => unreachable,
        },
        else => unreachable,
    };
}

/// Arithmetic promises no NaN payload, so a NaN lane matches any quiet NaN. Every other lane,
/// and every lane neg produces, must match bit for bit.
fn expectLaneResult(comptime T: type, comptime operation: Elementwise, expected: T, actual: T) !void {
    if (@typeInfo(T) == .float and operation != .neg and std.math.isNan(expected)) {
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        const quiet = @as(Bits, 1) << (std.math.floatMantissaBits(T) - 1);
        try std.testing.expect(std.math.isNan(actual));
        try std.testing.expect(@as(Bits, @bitCast(actual)) & quiet != 0);
        return;
    }
    try expectLaneBits(T, expected, actual);
}

fn expectElementwiseLanes(runtime: anytype, handle: anytype, comptime case: VectorCase) !void {
    const T = case.Lane;
    const lanes = case.lanes;
    const pool = elementPool(T);
    inline for (comptime elementwiseOperations(@typeInfo(T) == .float)) |operation| {
        inline for (0..lanes) |read| {
            const name = elementwiseName(operation, read);
            const Function = comptime switch (operation) {
                .select => if (lanes == 2) fn (i64, T, T) callconv(.c) T else fn (i64, T, T, T, T) callconv(.c) T,
                .neg, .not => if (lanes == 2) fn (T, T) callconv(.c) T else fn (T, T, T, T) callconv(.c) T,
                else => if (lanes == 2) fn (T, T, T, T) callconv(.c) T else fn (T, T, T, T, T, T, T, T) callconv(.c) T,
            };
            const native = try runtime.getFunction(handle, name, *const Function);
            for (0..pool.len) |shift_a| {
                for (0..pool.len) |shift_b| {
                    var a: [lanes]T = undefined;
                    var b: [lanes]T = undefined;
                    for (&a, &b, 0..) |*lhs, *rhs, index| {
                        lhs.* = pool[(shift_a + index) % pool.len];
                        rhs.* = pool[(shift_b + 3 * index) % pool.len];
                    }
                    var arguments: std.meta.ArgsTuple(Function) = undefined;
                    switch (operation) {
                        .select => {
                            const flag: i64 = if (shift_b % 2 == 0) 0 else -@as(i64, @intCast(shift_b));
                            arguments[0] = flag;
                            inline for (0..lanes) |index| arguments[index + 1] = a[index];
                            const expected = if (flag != 0) a[read] else a[lanes - 1 - read];
                            try expectLaneBits(T, expected, @call(.auto, native, arguments));
                        },
                        else => {
                            inline for (0..lanes) |index| arguments[index] = a[index];
                            if (comptime elementwiseArity(operation) == 2) {
                                inline for (0..lanes) |index| arguments[lanes + index] = b[index];
                            }
                            try expectLaneResult(T, operation, laneOracle(T, operation, a[read], b[read]), @call(.auto, native, arguments));
                        },
                    }
                }
            }
        }
    }
}

/// Builds `Op` over two splats of the argument, or one for a unary `Op`, of the given shape,
/// and returns the operation for the emitter to refuse.
fn refusedVectorOperation(ctx: *ir.Context, module: dialects_root.BuiltinDialect.ModuleOp, comptime Op: type, comptime unary: bool, lanes: u32, kind: dialects_root.arith.ScalarKind) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const lane = try Arith.getScalarType(ctx, kind);
    const vector = try vectorType(ctx, lanes, kind);
    const function = try Func.FuncOp.create(ctx, loc, "refused", &.{lane}, &.{lane});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const splat = try Arith.SplatOp.create(ctx, loc, function.getArgument(0), vector);
    try entry.addOperation(splat.op);
    const op = if (unary)
        try Op.create(ctx, loc, splat.getResult())
    else
        try Op.create(ctx, loc, splat.getResult(), splat.getResult());
    try entry.addOperation(op.op);
    const extract = try Arith.ExtractOp.create(ctx, loc, op.op.getResult(0).?, 0, lane);
    try entry.addOperation(extract.op);
    try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{extract.getResult()})).op);
    return op.op;
}

const CmpPredicate = dialects_root.arith.CmpPredicate;

/// The predicates arith declares valid for a lane class: every predicate on integers, and the
/// six unsigned-agnostic ones on floats.
fn comparePredicates(comptime floating: bool) []const CmpPredicate {
    return if (floating) &.{ .eq, .ne, .lt, .le, .gt, .ge } else comptime std.enums.values(CmpPredicate);
}

/// The unsigned integer lane of the same width, which every comparison may use as its mask.
fn unsignedMask(comptime kind: dialects_root.arith.ScalarKind) dialects_root.arith.ScalarKind {
    return switch (kind) {
        .i16, .u16 => .u16,
        .f32, .i32, .u32 => .u32,
        .f64, .i64, .u64 => .u64,
        else => unreachable,
    };
}

/// An unsigned integer mask, and the operands' own lane type when that differs.
fn maskKinds(comptime kind: dialects_root.arith.ScalarKind) []const dialects_root.arith.ScalarKind {
    return if (unsignedMask(kind) == kind) &.{kind} else &.{ unsignedMask(kind), kind };
}

fn ScalarOf(comptime kind: dialects_root.arith.ScalarKind) type {
    return switch (kind) {
        .i16 => i16,
        .u16 => u16,
        .i32 => i32,
        .u32 => u32,
        .i64 => i64,
        .u64 => u64,
        .f32 => f32,
        .f64 => f64,
        else => unreachable,
    };
}

fn compareName(comptime predicate: CmpPredicate, comptime read: usize) []const u8 {
    return "cmp_" ++ @tagName(predicate) ++ "_" ++ &[_]u8{'0' + read};
}

/// cmp_<predicate>_k(a0, ..., a(n-1), b0, ..., b(n-1)) compares the vectors of a and b into a
/// mask of `mask` lanes and returns lane k.
fn compareModule(ctx: *ir.Context, comptime lanes: u32, comptime kind: dialects_root.arith.ScalarKind, comptime mask: dialects_root.arith.ScalarKind) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const lane = try Arith.getScalarType(ctx, kind);
    const mask_lane = try Arith.getScalarType(ctx, mask);
    const vector = try vectorType(ctx, lanes, kind);
    const mask_vector = try vectorType(ctx, lanes, mask);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    inline for (comptime comparePredicates(dialects_root.arith.scalarKindIsFloat(kind))) |predicate| {
        inline for (0..lanes) |read| {
            var parameters: [2 * lanes]ir.Type = undefined;
            for (&parameters) |*parameter| parameter.* = lane;
            const function = try Func.FuncOp.create(ctx, loc, compareName(predicate, read), &parameters, &.{mask_lane});
            try module.getBodyBlock().addOperation(function.op);
            const entry = function.getEntryBlock();
            var arguments: [2 * lanes]*ir.Value = undefined;
            for (&arguments, 0..) |*argument, index| argument.* = function.getArgument(index);
            const lhs = try vectorOf(ctx, entry, arguments[0..lanes], vector);
            const rhs = try vectorOf(ctx, entry, arguments[lanes..], vector);
            const compare = try Arith.VecCmpOp.create(ctx, loc, predicate, lhs, rhs, mask_vector);
            try entry.addOperation(compare.op);
            const extract = try Arith.ExtractOp.create(ctx, loc, compare.getResult(), @intCast(read), mask_lane);
            try entry.addOperation(extract.op);
            try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{extract.getResult()})).op);
        }
    }
    return module.op;
}

/// The scalar comparison: ordered for every float predicate but ne, and signed or unsigned
/// by the predicate for integers whatever the lane's own signedness.
fn compareOracle(comptime T: type, predicate: CmpPredicate, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .float => return switch (predicate) {
            .eq => a == b,
            .ne => a != b,
            .lt => a < b,
            .le => a <= b,
            .gt => a > b,
            .ge => a >= b,
            else => unreachable,
        },
        .int => {
            const Signed = @Int(.signed, @bitSizeOf(T));
            const Unsigned = @Int(.unsigned, @bitSizeOf(T));
            const sa: Signed = @bitCast(a);
            const sb: Signed = @bitCast(b);
            const ua: Unsigned = @bitCast(a);
            const ub: Unsigned = @bitCast(b);
            return switch (predicate) {
                .eq => ua == ub,
                .ne => ua != ub,
                .lt, .slt => sa < sb,
                .le, .sle => sa <= sb,
                .gt, .sgt => sa > sb,
                .ge, .sge => sa >= sb,
                .ult => ua < ub,
                .ule => ua <= ub,
                .ugt => ua > ub,
                .uge => ua >= ub,
            };
        },
        else => unreachable,
    }
}

fn expectCompareLanes(runtime: anytype, handle: anytype, comptime case: VectorCase, comptime mask: dialects_root.arith.ScalarKind) !void {
    const T = case.Lane;
    const Mask = ScalarOf(mask);
    const MaskBits = @Int(.unsigned, @bitSizeOf(Mask));
    const lanes = case.lanes;
    const pool = elementPool(T);
    inline for (comptime comparePredicates(@typeInfo(T) == .float)) |predicate| {
        inline for (0..lanes) |read| {
            const Function = if (lanes == 2) fn (T, T, T, T) callconv(.c) Mask else fn (T, T, T, T, T, T, T, T) callconv(.c) Mask;
            const native = try runtime.getFunction(handle, compareName(predicate, read), *const Function);
            for (0..pool.len) |shift_a| {
                for (0..pool.len) |shift_b| {
                    var arguments: std.meta.ArgsTuple(Function) = undefined;
                    var a: [lanes]T = undefined;
                    var b: [lanes]T = undefined;
                    inline for (0..lanes) |index| {
                        a[index] = pool[(shift_a + index) % pool.len];
                        b[index] = pool[(shift_b + 3 * index) % pool.len];
                        arguments[index] = a[index];
                        arguments[lanes + index] = b[index];
                    }
                    const got: MaskBits = @bitCast(@call(.auto, native, arguments));
                    const expected: MaskBits = @intFromBool(compareOracle(T, predicate, a[read], b[read]));
                    if (got != expected) {
                        std.debug.print("{s} {s}: lane {d} of {any} against {any} gave {d}\n", .{ @typeName(T), @tagName(predicate), read, a, b, got });
                        return error.TestExpectedEqual;
                    }
                }
            }
        }
    }
}

/// Four index patterns for a shuffle from `from` lanes to `to` lanes: identity, reverse,
/// broadcast of the last lane, and an interleave.
fn shuffleIndices(comptime from: u32, comptime to: u32, comptime pattern: usize) [to]i64 {
    var indices: [to]i64 = undefined;
    for (&indices, 0..) |*index, lane| index.* = @intCast(switch (pattern) {
        0 => lane % from,
        1 => from - 1 - lane % from,
        2 => from - 1,
        3 => (3 * lane + 1) % from,
        else => unreachable,
    });
    return indices;
}

fn shuffleName(comptime pattern: usize, comptime read: usize) []const u8 {
    return "shuffle_" ++ &[_]u8{ '0' + pattern, '_', '0' + read };
}

/// shuffle_<pattern>_k(a0, ..., a(from-1)) shuffles the vector of a into `to` lanes by the
/// pattern and returns lane k.
fn shuffleModule(ctx: *ir.Context, comptime from: u32, comptime to: u32, comptime kind: dialects_root.arith.ScalarKind) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const lane = try Arith.getScalarType(ctx, kind);
    const source = try vectorType(ctx, from, kind);
    const shuffled = try vectorType(ctx, to, kind);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    inline for (0..4) |pattern| {
        inline for (0..to) |read| {
            var parameters: [from]ir.Type = undefined;
            for (&parameters) |*parameter| parameter.* = lane;
            const function = try Func.FuncOp.create(ctx, loc, shuffleName(pattern, read), &parameters, &.{lane});
            try module.getBodyBlock().addOperation(function.op);
            const entry = function.getEntryBlock();
            var arguments: [from]*ir.Value = undefined;
            for (&arguments, 0..) |*argument, index| argument.* = function.getArgument(index);
            const vector = try vectorOf(ctx, entry, &arguments, source);
            const shuffle = try Arith.VecShuffleOp.create(ctx, loc, vector, shuffled, &shuffleIndices(from, to, pattern));
            try entry.addOperation(shuffle.op);
            const extract = try Arith.ExtractOp.create(ctx, loc, shuffle.getResult(), @intCast(read), lane);
            try entry.addOperation(extract.op);
            try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{extract.getResult()})).op);
        }
    }
    return module.op;
}

/// Integer attributes past every lane width and of both signs: -1 on unsigned lanes is all ones.
const integer_constants = [_]i64{ -1, 0x1_2345, 0x1_0000_8001, std.math.minInt(i64), 7 };

/// Float attributes whose conversion to f32 lanes rounds: two halfway cases that round to even,
/// the largest f32, a value past it that overflows to infinity, a NaN, negative zero, an f64
/// subnormal that flushes to zero in f32, and 0.1.
const float_constants = [_]f64{ 1.0 + 0x1p-24, 1.0 + 0x3p-24, std.math.floatMax(f32), 0x1.ffffffp127, std.math.nan(f64), -0.0, 0x1p-1060, 0.1 };

fn constantName(comptime value: usize, comptime read: usize) []const u8 {
    return "constant_" ++ &[_]u8{ '0' + value, '_', '0' + read };
}

/// constant_<j>_k() returns lane k of a vec_constant of the j-th attribute for the lane class.
fn constantModule(ctx: *ir.Context, comptime lanes: u32, comptime kind: dialects_root.arith.ScalarKind) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const lane = try Arith.getScalarType(ctx, kind);
    const vector = try vectorType(ctx, lanes, kind);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const floating = comptime dialects_root.arith.scalarKindIsFloat(kind);
    const count = if (floating) float_constants.len else integer_constants.len;
    inline for (0..count) |value| {
        inline for (0..lanes) |read| {
            const function = try Func.FuncOp.create(ctx, loc, constantName(value, read), &.{}, &.{lane});
            try module.getBodyBlock().addOperation(function.op);
            const entry = function.getEntryBlock();
            const constant = if (floating)
                try Arith.VecConstantOp.createFloat(ctx, loc, vector, float_constants[value])
            else
                try Arith.VecConstantOp.createInt(ctx, loc, vector, integer_constants[value]);
            try entry.addOperation(constant.op);
            const extract = try Arith.ExtractOp.create(ctx, loc, constant.getResult(), @intCast(read), lane);
            try entry.addOperation(extract.op);
            try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{extract.getResult()})).op);
        }
    }
    return module.op;
}

const MemrefOps = dialects_root.MemrefDialect;
const FenceOrdering = dialects_root.memref.FenceOrdering;
const FenceScope = dialects_root.memref.FenceScope;

const AtomicCase = struct { kind: dialects_root.arith.ScalarKind, T: type };

const atomic_cases = [_]AtomicCase{
    .{ .kind = .i32, .T = i32 },
    .{ .kind = .u32, .T = u32 },
    .{ .kind = .i64, .T = i64 },
    .{ .kind = .u64, .T = u64 },
    .{ .kind = .index, .T = usize },
};

const load_orderings = [_]FenceOrdering{ .acquire, .seq_cst };
const store_orderings = [_]FenceOrdering{ .release, .seq_cst };
const cas_orderings = [_]?FenceOrdering{ null, .acquire, .release, .acq_rel, .seq_cst };

fn casName(comptime ordering: ?FenceOrdering) []const u8 {
    return "cas_" ++ (if (ordering) |spelled| @tagName(spelled) else "none");
}

/// One function per ordered access and ordering, each reaching element `index` of a borrowed
/// host buffer of `kind`.
fn atomicModule(ctx: *ir.Context, kind: dialects_root.arith.ScalarKind) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const element = try Arith.getScalarType(ctx, kind);
    const index = try Arith.getScalarType(ctx, .index);
    const buffer = try MemrefOps.getMemrefTypeDynamic(ctx, element, .host);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    inline for (load_orderings) |ordering| {
        const function = try Func.FuncOp.create(ctx, loc, "load_" ++ @tagName(ordering), &.{ buffer, index }, &.{element});
        try module.getBodyBlock().addOperation(function.op);
        const entry = function.getEntryBlock();
        const load = try MemrefOps.AtomicLoadOp.create(ctx, loc, function.getArgument(0), function.getArgument(1), element, ordering);
        try entry.addOperation(load.op);
        try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{load.getResult()})).op);
    }
    inline for (store_orderings) |ordering| {
        const function = try Func.FuncOp.create(ctx, loc, "store_" ++ @tagName(ordering), &.{ buffer, index, element }, &.{});
        try module.getBodyBlock().addOperation(function.op);
        const entry = function.getEntryBlock();
        const store = try MemrefOps.AtomicStoreOp.create(ctx, loc, function.getArgument(2), function.getArgument(0), function.getArgument(1), ordering);
        try entry.addOperation(store.op);
        try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{})).op);
    }
    inline for (cas_orderings) |ordering| {
        const function = try Func.FuncOp.create(ctx, loc, casName(ordering), &.{ buffer, index, element, element }, &.{element});
        try module.getBodyBlock().addOperation(function.op);
        const entry = function.getEntryBlock();
        const cas = if (ordering) |spelled|
            try MemrefOps.AtomicCasOp.createOrdered(ctx, loc, function.getArgument(2), function.getArgument(3), function.getArgument(0), function.getArgument(1), element, spelled)
        else
            try MemrefOps.AtomicCasOp.create(ctx, loc, function.getArgument(2), function.getArgument(3), function.getArgument(0), function.getArgument(1), element);
        try entry.addOperation(cas.op);
        try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{cas.getResult()})).op);
    }
    return module.op;
}

fn atomicPool(comptime T: type) [7]T {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    return .{
        0,
        1,
        std.math.maxInt(T),
        std.math.minInt(T),
        @bitCast(@as(Bits, @truncate(@as(u64, 0x8000_0000_8000_0001)))),
        @bitCast(@as(Bits, @truncate(@as(u64, 0x7fff_ffff_0000_ffff)))),
        @bitCast(@as(Bits, @truncate(@as(u64, 0x0123_4567_89ab_cdef)))),
    };
}

/// Words either side of the one reached, which no access may touch.
fn atomicSentinels(comptime T: type) [3]T {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    return .{
        @bitCast(@as(Bits, @truncate(@as(u64, 0xa5a5_a5a5_a5a5_a5a5)))),
        @bitCast(@as(Bits, @truncate(@as(u64, 0x3c3c_3c3c_3c3c_3c3c)))),
        @bitCast(@as(Bits, @truncate(@as(u64, 0xc3c3_c3c3_c3c3_c3c3)))),
    };
}

fn expectAtomicNeighbors(comptime T: type, words: *const [4]T) !void {
    const sentinels = atomicSentinels(T);
    try std.testing.expectEqual(sentinels[0], words[0]);
    try std.testing.expectEqual(sentinels[1], words[2]);
    try std.testing.expectEqual(sentinels[2], words[3]);
}

fn expectAtomicValues(runtime: anytype, handle: anytype, comptime case: AtomicCase) !void {
    const T = case.T;
    const testing = std.testing;
    const sentinels = atomicSentinels(T);
    var words = [_]T{ sentinels[0], 0, sentinels[1], sentinels[2] };
    const pool = atomicPool(T);
    for (pool) |value| {
        inline for (store_orderings) |ordering| {
            const store = try runtime.getFunction(handle, "store_" ++ @tagName(ordering), *const fn ([*]T, usize, T) callconv(.c) void);
            words[1] = ~value;
            store(&words, 1, value);
            try testing.expectEqual(value, words[1]);
            try expectAtomicNeighbors(T, &words);
        }
        inline for (load_orderings) |ordering| {
            const load = try runtime.getFunction(handle, "load_" ++ @tagName(ordering), *const fn ([*]T, usize) callconv(.c) T);
            words[1] = value;
            try testing.expectEqual(value, load(&words, 1));
            try testing.expectEqual(value, words[1]);
            try expectAtomicNeighbors(T, &words);
        }
        for (pool) |expected| {
            inline for (cas_orderings) |ordering| {
                const cas = try runtime.getFunction(handle, casName(ordering), *const fn ([*]T, usize, T, T) callconv(.c) T);
                words[1] = value;
                // The result is the word observed, whether or not the exchange happened.
                try testing.expectEqual(value, cas(&words, 1, expected, ~value));
                try testing.expectEqual(if (expected == value) ~value else value, words[1]);
                try expectAtomicNeighbors(T, &words);
            }
        }
    }
}

/// Each fence alone, then a release store, a sequentially consistent fence and an acquire load
/// of the same word.
fn fenceModule(ctx: *ir.Context) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const element = try Arith.getScalarType(ctx, .u64);
    const index = try Arith.getScalarType(ctx, .index);
    const buffer = try MemrefOps.getMemrefTypeDynamic(ctx, element, .host);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    inline for (comptime std.meta.tags(FenceScope)) |scope| {
        inline for (comptime std.meta.tags(FenceOrdering)) |ordering| {
            const function = try Func.FuncOp.create(ctx, loc, "fence_" ++ @tagName(scope) ++ "_" ++ @tagName(ordering), &.{}, &.{});
            try module.getBodyBlock().addOperation(function.op);
            const entry = function.getEntryBlock();
            try entry.addOperation((try MemrefOps.FenceOp.create(ctx, loc, scope, ordering)).op);
            try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{})).op);
        }
    }
    const function = try Func.FuncOp.create(ctx, loc, "fenced", &.{ buffer, index, element }, &.{element});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    try entry.addOperation((try MemrefOps.AtomicStoreOp.create(ctx, loc, function.getArgument(2), function.getArgument(0), function.getArgument(1), .release)).op);
    try entry.addOperation((try MemrefOps.FenceOp.create(ctx, loc, .system, .seq_cst)).op);
    const load = try MemrefOps.AtomicLoadOp.create(ctx, loc, function.getArgument(0), function.getArgument(1), element, .acquire);
    try entry.addOperation(load.op);
    try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{load.getResult()})).op);
    return module.op;
}

/// A two-word static payload: an atomic store to word 0 and a plain store to word 1, then a
/// compare-and-swap and an atomic load of word 0 and a plain load of word 1. `read` names which
/// of the three the function returns.
fn atomicAllocaModule(ctx: *ir.Context, kind: dialects_root.arith.ScalarKind) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const element = try Arith.getScalarType(ctx, kind);
    const index = try Arith.getScalarType(ctx, .index);
    const buffer = try MemrefOps.getMemrefType1D(ctx, 2, element, .host);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    inline for (0..3) |read| {
        const function = try Func.FuncOp.create(ctx, loc, "alloca_" ++ &[_]u8{'0' + read}, &.{ element, element, element, element }, &.{element});
        try module.getBodyBlock().addOperation(function.op);
        const entry = function.getEntryBlock();
        const alloca = try MemrefOps.AllocaOp.createStatic(ctx, loc, buffer);
        try entry.addOperation(alloca.op);
        const zero = try Arith.ConstantOp.createInt(ctx, loc, index, 0);
        try entry.addOperation(zero.op);
        const one = try Arith.ConstantOp.createInt(ctx, loc, index, 1);
        try entry.addOperation(one.op);
        try entry.addOperation((try MemrefOps.AtomicStoreOp.create(ctx, loc, function.getArgument(0), alloca.getResult(), zero.getResult(), .seq_cst)).op);
        try entry.addOperation((try MemrefOps.StoreOp.create(ctx, loc, function.getArgument(1), alloca.getResult(), one.getResult())).op);
        const cas = try MemrefOps.AtomicCasOp.createOrdered(ctx, loc, function.getArgument(2), function.getArgument(3), alloca.getResult(), zero.getResult(), element, .acq_rel);
        try entry.addOperation(cas.op);
        const atomic = try MemrefOps.AtomicLoadOp.create(ctx, loc, alloca.getResult(), zero.getResult(), element, .acquire);
        try entry.addOperation(atomic.op);
        const plain = try MemrefOps.LoadOp.create(ctx, loc, alloca.getResult(), one.getResult(), element);
        try entry.addOperation(plain.op);
        const results = [_]*ir.Value{ cas.getResult(), atomic.getResult(), plain.getResult() };
        try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{results[read]})).op);
    }
    return module.op;
}

const MisalignedAccess = enum { ldar, stlr, casal };
const MisalignedPlace = enum { inside, crossing };
const MisalignedOutcome = union(enum) { completed, wrong, signal: sys.signal.RawSignal };

/// An address `size / 2` bytes past a 16-byte boundary stays inside that block; one `size / 2`
/// bytes before the next boundary crosses it.
fn misalignedOffset(comptime T: type, place: MisalignedPlace) usize {
    return switch (place) {
        .inside => 16 + @sizeOf(T) / 2,
        .crossing => 32 - @sizeOf(T) / 2,
    };
}

/// Runs one access on a misaligned base in a child, which exits 0 when the access completes with
/// the whole value and no byte outside the element changes, and 1 when it completes otherwise.
fn probeMisaligned(comptime T: type, runtime: anytype, handle: anytype, access: MisalignedAccess, place: MisalignedPlace) !MisalignedOutcome {
    var bytes: [64]u8 align(16) = @splat(0x5a);
    const offset = misalignedOffset(T, place);
    const address = @intFromPtr(&bytes) + offset;
    const initial: T = @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), @truncate(@as(u64, 0x0123_4567_89ab_cdef))));
    const value = ~initial;
    const load = try runtime.getFunction(handle, "load_acquire", *const fn ([*]align(1) T, usize) callconv(.c) T);
    const store = try runtime.getFunction(handle, "store_release", *const fn ([*]align(1) T, usize, T) callconv(.c) void);
    const cas = try runtime.getFunction(handle, "cas_none", *const fn ([*]align(1) T, usize, T, T) callconv(.c) T);
    const base: [*]align(1) T = @ptrFromInt(address);
    const element = &base[0];
    element.* = initial;
    const child = std.c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        // The test runner turns a bus error into an abort; the child reports the hardware's own.
        sys.signal.restoreDefault(.BUS);
        sys.signal.restoreDefault(.SEGV);
        const completed = switch (access) {
            .ldar => load(base, 0) == initial and element.* == initial,
            .stlr => store: {
                store(base, 0, value);
                break :store element.* == value;
            },
            .casal => cas(base, 0, initial, value) == initial and element.* == value,
        };
        var untouched = true;
        for (bytes, 0..) |byte, at| {
            if (at >= offset and at < offset + @sizeOf(T)) continue;
            untouched = untouched and byte == 0x5a;
        }
        std.c._exit(if (completed and untouched) 0 else 1);
    }
    return switch (try sys.process.waitDirect(@intCast(child))) {
        .exited => |code| if (code == 0) .completed else .wrong,
        .signal => |signal| .{ .signal = signal },
        else => error.UnexpectedTermination,
    };
}

/// A compare-and-swap built on a u64 buffer, then changed past memref's constructor: its buffer
/// operand moved to one of `kind`, or its expected operand moved to a value of `kind`.
fn refusedAtomicModule(ctx: *ir.Context, kind: dialects_root.arith.ScalarKind, operand: enum { buffer, expected }) !struct { module: *ir.Operation, function: *ir.Operation, cas: *ir.Operation } {
    const loc = ir.Location.getUnknown();
    const word = try Arith.getScalarType(ctx, .u64);
    const index = try Arith.getScalarType(ctx, .index);
    const narrow = try Arith.getScalarType(ctx, kind);
    const words = try MemrefOps.getMemrefTypeDynamic(ctx, word, .host);
    const narrow_buffer = try MemrefOps.getMemrefTypeDynamic(ctx, narrow, .host);
    const module = try dialects_root.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const function = try Func.FuncOp.create(ctx, loc, "refused", &.{ words, narrow_buffer, index, word, word, narrow }, &.{word});
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const cas = try MemrefOps.AtomicCasOp.create(ctx, loc, function.getArgument(3), function.getArgument(4), function.getArgument(0), function.getArgument(2), word);
    try entry.addOperation(cas.op);
    switch (operand) {
        .buffer => cas.op.setOperandValue(2, function.getArgument(1)),
        .expected => cas.op.setOperandValue(0, function.getArgument(5)),
    }
    try entry.addOperation((try Func.ReturnOp.create(ctx, loc, &.{cas.getResult()})).op);
    return .{ .module = module.op, .function = function.op, .cas = cas.op };
}

fn expectAtomicCode(function: *ir.Operation, words: []const u32, lines: []const []const u8) !void {
    const testing = std.testing;
    var emitter = try backend.Emitter.init(testing.allocator);
    defer emitter.deinit();
    try emitter.emitFunction(function);
    const code = emitter.code.items;
    var listing: std.ArrayListUnmanaged(u8) = .empty;
    defer listing.deinit(testing.allocator);
    var emitted: std.ArrayListUnmanaged(u32) = .empty;
    defer emitted.deinit(testing.allocator);
    var offset: usize = 0;
    while (offset + 4 <= code.len) : (offset += 4) {
        const word = std.mem.readInt(u32, code[offset..][0..4], .little);
        try emitted.append(testing.allocator, word);
        var buf: [96]u8 = undefined;
        try listing.appendSlice(testing.allocator, @import("disassemble/format.zig").formatInstructionRaw(word, &buf));
        try listing.append(testing.allocator, '\n');
    }
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (lines) |line| {
        try joined.appendSlice(testing.allocator, line);
        try joined.append(testing.allocator, '\n');
    }
    if (std.mem.indexOf(u32, emitted.items, words) == null or std.mem.indexOf(u8, listing.items, joined.items) == null) {
        std.debug.print("missing\n{s}in\n{s}", .{ joined.items, listing.items });
        return error.TestExpectedEqual;
    }
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

/// One f128 computation of `a * b + c`: the product is exact (at most 106 significand
/// bits), and TwoSum recovers the sum's rounding error exactly. Soft-float f128 shares no
/// instruction with the FMADD and FSQRT it checks.
fn exactFusedSum(a: f128, b: f128, c: f128) struct { sum: f128, err: f128 } {
    const product = a * b;
    const sum = product + c;
    const b_part = sum - product;
    const err = (product - (sum - b_part)) + (c - b_part);
    return .{ .sum = sum, .err = err };
}

/// The correctly rounded `T` of `sum + err`, where `sum` is the f128 rounding of that exact
/// value. Only a `sum` on a `T` midpoint can round differently from the exact value, since
/// every `T` midpoint is an f128; there `err` breaks the tie.
fn roundExact(comptime T: type, sum: f128, err: f128) T {
    const nearest: T = @floatCast(sum);
    if (err == 0 or !std.math.isFinite(nearest) or !std.math.isFinite(sum)) return nearest;
    const below: T = if (@as(f128, nearest) > sum)
        std.math.nextAfter(T, nearest, -std.math.inf(T))
    else
        nearest;
    const above = std.math.nextAfter(T, below, std.math.inf(T));
    if (!std.math.isFinite(above)) return nearest;
    const midpoint = (@as(f128, below) + @as(f128, above)) / 2;
    if (sum != midpoint) return nearest;
    return if (err > 0) above else below;
}

fn expectFused(comptime T: type, a: T, b: T, c: T, actual: T) !void {
    const exact = exactFusedSum(a, b, c);
    const expected = roundExact(T, exact.sum, exact.err);
    if (std.math.isNan(expected)) return std.testing.expect(std.math.isNan(actual));
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    try std.testing.expectEqual(@as(Bits, @bitCast(expected)), @as(Bits, @bitCast(actual)));
}

/// A square root is correct exactly when the input lies between the squares of the two
/// midpoints around it; those squares are exact in f128.
fn expectRoot(comptime T: type, x: T, actual: T) !void {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    if (std.math.isNan(x) or x < 0) return std.testing.expect(std.math.isNan(actual));
    if (x == 0 or std.math.isInf(x))
        return std.testing.expectEqual(@as(Bits, @bitCast(x)), @as(Bits, @bitCast(actual)));
    try std.testing.expect(std.math.isFinite(actual) and actual > 0);
    const low = (@as(f128, std.math.nextAfter(T, actual, 0)) + actual) / 2;
    const high = (@as(f128, std.math.nextAfter(T, actual, std.math.inf(T))) + actual) / 2;
    try std.testing.expect(low * low <= x and x <= high * high);
}

fn floatingEdges(comptime T: type) [19]T {
    return .{
        0,                           -0.0,
        1,                           -1,
        2,                           0.5,
        3,                           1 + std.math.pow(T, 2, -12),
        1 - std.math.pow(T, 2, -12), 1 + std.math.floatEps(T),
        0.1,                         -7.25,
        std.math.floatMax(T) / 4,    -std.math.floatMax(T) / 4,
        std.math.floatMin(T),        std.math.floatTrueMin(T),
        std.math.inf(T),             -std.math.inf(T),
        std.math.nan(T),
    };
}

fn rootAndFusedModule(ctx: *ir.Context, comptime T: type) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try Arith.getScalarType(ctx, if (T == f32) .f32 else .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const body = module.getBodyBlock();

    const root = try Func.FuncOp.create(ctx, loc, "root", &.{floating}, &.{floating});
    try body.addOperation(root.op);
    const sqrt = try Arith.SqrtOp.create(ctx, loc, root.getArgument(0));
    try returnOne(ctx, root, sqrt.op, sqrt.getResult());

    const operands = [_]ir.Type{ floating, floating, floating };
    const fused = try Func.FuncOp.create(ctx, loc, "fused", &operands, &.{floating});
    try body.addOperation(fused.op);
    const fma = try Arith.FmaOp.create(
        ctx,
        loc,
        fused.getArgument(0),
        fused.getArgument(1),
        fused.getArgument(2),
    );
    try returnOne(ctx, fused, fma.op, fma.getResult());

    for (fixed_operands, 0..) |fixed, fixed_index| {
        for (0..3) |position| try addFixedFused(ctx, body, floating, fixed, fixed_index, position);
        var name: [24]u8 = undefined;
        const root_name = try std.fmt.bufPrint(&name, "root_{d}", .{fixed_index});
        const function = try Func.FuncOp.create(ctx, loc, root_name, &.{}, &.{floating});
        try body.addOperation(function.op);
        const literal = try Arith.ConstantOp.createFloat(ctx, loc, floating, fixed);
        try function.getEntryBlock().addOperation(literal.op);
        const constant_root = try Arith.SqrtOp.create(ctx, loc, literal.getResult());
        try returnOne(ctx, function, constant_root.op, constant_root.getResult());
    }

    // Neither result is used, so both operations compile and leave the argument intact.
    const dead = try Func.FuncOp.create(ctx, loc, "dead", &.{floating}, &.{floating});
    try body.addOperation(dead.op);
    const argument = dead.getArgument(0);
    const dead_root = try Arith.SqrtOp.create(ctx, loc, argument);
    try dead.getEntryBlock().addOperation(dead_root.op);
    const dead_fma = try Arith.FmaOp.create(ctx, loc, argument, argument, argument);
    try returnOne(ctx, dead, dead_fma.op, argument);

    try addSpilledFused(ctx, body, floating, T);
    return module.op;
}

/// Adds `operation` to `function`'s entry block, then returns `value`.
fn returnOne(
    ctx: *ir.Context,
    function: Func.FuncOp,
    operation: *ir.Operation,
    value: *ir.Value,
) !void {
    const loc = ir.Location.getUnknown();
    try function.getEntryBlock().addOperation(operation);
    const ret = try Func.ReturnOp.create(ctx, loc, &.{value});
    try function.getEntryBlock().addOperation(ret.op);
}

/// `fused_{position}_{fixed_index}` takes two arguments and holds `fixed` as the constant
/// fma operand at `position`.
fn addFixedFused(
    ctx: *ir.Context,
    body: *ir.Block,
    floating: ir.Type,
    fixed: f64,
    fixed_index: usize,
    position: usize,
) !void {
    const loc = ir.Location.getUnknown();
    var buffer: [24]u8 = undefined;
    const name = try std.fmt.bufPrint(&buffer, "fused_{d}_{d}", .{ position, fixed_index });
    const parameters = [_]ir.Type{ floating, floating };
    const function = try Func.FuncOp.create(ctx, loc, name, &parameters, &.{floating});
    try body.addOperation(function.op);
    const literal = try Arith.ConstantOp.createFloat(ctx, loc, floating, fixed);
    try function.getEntryBlock().addOperation(literal.op);
    var operands: [3]*ir.Value = undefined;
    var argument: usize = 0;
    for (&operands, 0..) |*operand, index| {
        if (index == position) {
            operand.* = literal.getResult();
        } else {
            operand.* = function.getArgument(argument);
            argument += 1;
        }
    }
    const fma = try Arith.FmaOp.create(ctx, loc, operands[0], operands[1], operands[2]);
    try returnOne(ctx, function, fma.op, fma.getResult());
}

/// Every placement register holds a constant live past the fma, so its three operands and
/// its result all live in the frame.
fn addSpilledFused(ctx: *ir.Context, body: *ir.Block, floating: ir.Type, comptime T: type) !void {
    const loc = ir.Location.getUnknown();
    const spilled = try Func.FuncOp.create(ctx, loc, "spilled", &.{}, &.{floating});
    try body.addOperation(spilled.op);
    const block = spilled.getEntryBlock();
    var constants: [spilled_constants]*ir.Value = undefined;
    for (&constants, 0..) |*constant, index| {
        const value = spilledConstant(T, index);
        const literal = try Arith.ConstantOp.createFloat(ctx, loc, floating, value);
        try block.addOperation(literal.op);
        constant.* = literal.getResult();
    }
    const last = spilled_constants - 1;
    const fma = try Arith.FmaOp.create(
        ctx,
        loc,
        constants[last - 2],
        constants[last - 1],
        constants[last],
    );
    try block.addOperation(fma.op);
    var total = fma.getResult();
    for (constants) |constant| {
        const add = try Arith.AddOp.create(ctx, loc, total, constant);
        try block.addOperation(add.op);
        total = add.getResult();
    }
    try block.addOperation((try Func.ReturnOp.create(ctx, loc, &.{total})).op);
}

const fixed_operands = [_]f64{ -0.0, 1 + 1.0 / 1073741824.0, -std.math.inf(f64), 3, 0.1 };
const spilled_constants = placement.max_registers + 4;

fn spilledConstant(comptime T: type, index: usize) T {
    return @as(T, @floatFromInt(index + 1)) / 8 + 1.0 / 3.0;
}

fn expectRootAndFused(comptime T: type) !void {
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    const module = try rootAndFusedModule(&ctx, T);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(
        testing.allocator,
        .testing,
        .macos_non_hardened,
    );
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    defer runtime.release(handle) catch {};

    const edges = floatingEdges(T);
    var random = std.Random.DefaultPrng.init(0x5eed_f0a7);
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const root = try runtime.getFunction(handle, "root", *const fn (T) callconv(.c) T);
    for (edges) |x| try expectRoot(T, x, root(x));
    for (0..4096) |_| {
        const x: T = @bitCast(random.random().int(Bits));
        try expectRoot(T, x, root(x));
    }

    const fused = try runtime.getFunction(handle, "fused", *const fn (T, T, T) callconv(.c) T);
    for (edges) |a| for (edges) |b| for (edges) |c| try expectFused(T, a, b, c, fused(a, b, c));
    for (0..4096) |_| {
        const a: T = @bitCast(random.random().int(Bits));
        const b: T = @bitCast(random.random().int(Bits));
        const c: T = @bitCast(random.random().int(Bits));
        try expectFused(T, a, b, c, fused(a, b, c));
    }
    // A product that cancels against the addend shows one rounding, not two.
    const near = 1 + std.math.pow(T, 2, -12);
    const far = 1 - std.math.pow(T, 2, -12);
    try testing.expectEqual(-std.math.pow(T, 2, -24), fused(near, far, -1));

    for (fixed_operands, 0..) |fixed_wide, fixed_index| {
        const fixed: T = @floatCast(fixed_wide);
        var name_buf: [24]u8 = undefined;
        for (0..3) |position| {
            const name =
                try std.fmt.bufPrint(&name_buf, "fused_{d}_{d}", .{ position, fixed_index });
            const function = try runtime.getFunction(handle, name, *const fn (T, T) callconv(.c) T);
            for (edges) |x| for (edges) |y| {
                const operands: [3]T = switch (position) {
                    0 => .{ fixed, x, y },
                    1 => .{ x, fixed, y },
                    else => .{ x, y, fixed },
                };
                try expectFused(T, operands[0], operands[1], operands[2], function(x, y));
            };
        }
        const name = try std.fmt.bufPrint(&name_buf, "root_{d}", .{fixed_index});
        const constant_root = try runtime.getFunction(handle, name, *const fn () callconv(.c) T);
        try expectRoot(T, fixed, constant_root());
    }

    const dead = try runtime.getFunction(handle, "dead", *const fn (T) callconv(.c) T);
    for (edges) |x| try testing.expectEqual(@as(Bits, @bitCast(x)), @as(Bits, @bitCast(dead(x))));

    const spilled = try runtime.getFunction(handle, "spilled", *const fn () callconv(.c) T);
    const n = spilled_constants;
    const a = spilledConstant(T, n - 3);
    const exact = exactFusedSum(a, spilledConstant(T, n - 2), spilledConstant(T, n - 1));
    var expected = roundExact(T, exact.sum, exact.err);
    for (0..n) |index| expected += spilledConstant(T, index);
    try testing.expectEqual(@as(Bits, @bitCast(expected)), @as(Bits, @bitCast(spilled())));
}

/// One library operation, the `sys.math` function it calls at each width, and its op type.
const LibraryCase = struct {
    name: []const u8,
    op: type,
    double: sys.math.MathSymbol,
    single: sys.math.MathSymbol,
};

const library_unary = [_]LibraryCase{
    .{ .name = "exp", .op = Arith.ExpOp, .double = .exp, .single = .expf },
    .{ .name = "log", .op = Arith.LogOp, .double = .log, .single = .logf },
    .{ .name = "sin", .op = Arith.SinOp, .double = .sin, .single = .sinf },
    .{ .name = "cos", .op = Arith.CosOp, .double = .cos, .single = .cosf },
    .{ .name = "tan", .op = Arith.TanOp, .double = .tan, .single = .tanf },
    .{ .name = "tanh", .op = Arith.TanhOp, .double = .tanh, .single = .tanhf },
};

fn librarySymbol(comptime T: type, comptime case: LibraryCase) sys.math.MathSymbol {
    return if (T == f32) case.single else case.double;
}

/// The `sys.math` function itself, called directly: the code under test must reach it with
/// the same arguments and hand back its exact bits.
fn shim(comptime Fn: type, symbol: sys.math.MathSymbol) Fn {
    return @ptrFromInt(symbol.address());
}

/// Floor from the bits alone: clear the fraction below the binary point, then step a negative
/// non-integer down by one, which is exact below 2^mantissa.
fn exactFloor(comptime T: type, x: T) T {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const mantissa_bits: i32 = std.math.floatMantissaBits(T);
    const exponent_bits = std.math.floatExponentBits(T);
    const bias: i32 = (1 << (exponent_bits - 1)) - 1;
    const bits: Bits = @bitCast(x);
    const sign_bit: Bits = @as(Bits, 1) << (@bitSizeOf(T) - 1);
    const negative = bits & sign_bit != 0;
    const biased: i32 = @intCast((bits >> @intCast(mantissa_bits)) & ((1 << exponent_bits) - 1));
    const exponent = biased - bias;
    // Integral already, or infinite, or NaN.
    if (exponent >= mantissa_bits) return x;
    if (exponent < 0) {
        if (bits & ~sign_bit == 0) return x;
        return if (negative) -1 else 0;
    }
    const fraction: Bits = (@as(Bits, 1) << @intCast(mantissa_bits - exponent)) - 1;
    if (bits & fraction == 0) return x;
    const truncated: T = @bitCast(bits & ~fraction);
    return if (negative) truncated - 1 else truncated;
}

fn expectBits(comptime T: type, expected: T, actual: T) !void {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    try std.testing.expectEqual(@as(Bits, @bitCast(expected)), @as(Bits, @bitCast(actual)));
}

/// Arith promises no NaN payload, so a NaN floor compares by class.
fn expectFloor(comptime T: type, x: T, actual: T) !void {
    if (std.math.isNan(x)) return std.testing.expect(std.math.isNan(actual));
    try expectBits(T, exactFloor(T, x), actual);
}

/// The shared edges, then halves, the last fractional magnitude, a signaling NaN and a quiet
/// NaN with a payload.
fn floorEdges(comptime T: type) [31]T {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const mantissa_bits = std.math.floatMantissaBits(T);
    const integral = std.math.pow(T, 2, mantissa_bits);
    const quiet: Bits = @as(Bits, 1) << (mantissa_bits - 1);
    const exponent: Bits = @as(Bits, @bitCast(std.math.inf(T)));
    return floatingEdges(T) ++ [_]T{
        0.5,
        -0.5,
        1.5,
        -1.5,
        -2.5,
        integral - 0.5,
        -(integral - 0.5),
        integral,
        -integral,
        @bitCast(exponent | 1),
        @bitCast(exponent | quiet | 0x123),
        @bitCast(exponent | (@as(Bits, 1) << (@bitSizeOf(T) - 1)) | quiet | 0x45),
    };
}

fn libraryModule(ctx: *ir.Context, comptime T: type) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try Arith.getScalarType(ctx, if (T == f32) .f32 else .f64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    const body = module.getBodyBlock();
    const pair = [_]ir.Type{ floating, floating };

    inline for (library_unary) |case| {
        const name = "call_" ++ case.name;
        const function = try Func.FuncOp.create(ctx, loc, name, &.{floating}, &.{floating});
        try body.addOperation(function.op);
        const call = try case.op.create(ctx, loc, function.getArgument(0));
        try returnOne(ctx, function, call.op, call.getResult());
    }
    const floor = try Func.FuncOp.create(ctx, loc, "call_floor", &.{floating}, &.{floating});
    try body.addOperation(floor.op);
    const rounded = try Arith.FloorOp.create(ctx, loc, floor.getArgument(0));
    try returnOne(ctx, floor, rounded.op, rounded.getResult());

    const pow = try Func.FuncOp.create(ctx, loc, "call_pow", &pair, &.{floating});
    try body.addOperation(pow.op);
    const power = try Arith.PowOp.create(ctx, loc, pow.getArgument(0), pow.getArgument(1));
    try returnOne(ctx, pow, power.op, power.getResult());

    // A constant base, a constant exponent, and a constant argument with no arguments.
    for ([_][]const u8{ "pow_base", "pow_exponent" }, 0..) |name, position| {
        const function = try Func.FuncOp.create(ctx, loc, name, &.{floating}, &.{floating});
        try body.addOperation(function.op);
        const literal = try Arith.ConstantOp.createFloat(ctx, loc, floating, library_constant);
        try function.getEntryBlock().addOperation(literal.op);
        const x = function.getArgument(0);
        const call = if (position == 0)
            try Arith.PowOp.create(ctx, loc, literal.getResult(), x)
        else
            try Arith.PowOp.create(ctx, loc, x, literal.getResult());
        try returnOne(ctx, function, call.op, call.getResult());
    }
    const constant = try Func.FuncOp.create(ctx, loc, "exp_constant", &.{}, &.{floating});
    try body.addOperation(constant.op);
    const literal = try Arith.ConstantOp.createFloat(ctx, loc, floating, library_constant);
    try constant.getEntryBlock().addOperation(literal.op);
    const constant_exp = try Arith.ExpOp.create(ctx, loc, literal.getResult());
    try returnOne(ctx, constant, constant_exp.op, constant_exp.getResult());

    // The argument lives across the call in a placement register the call saves.
    const across = try Func.FuncOp.create(ctx, loc, "across", &pair, &.{floating});
    try body.addOperation(across.op);
    const crossing = try Arith.ExpOp.create(ctx, loc, across.getArgument(0));
    try across.getEntryBlock().addOperation(crossing.op);
    const sum = try Arith.AddOp.create(ctx, loc, crossing.getResult(), across.getArgument(1));
    try returnOne(ctx, across, sum.op, sum.getResult());

    // Neither result is read, so neither call is made and the argument comes back.
    const dead = try Func.FuncOp.create(ctx, loc, "dead", &.{floating}, &.{floating});
    try body.addOperation(dead.op);
    const argument = dead.getArgument(0);
    const dead_exp = try Arith.ExpOp.create(ctx, loc, argument);
    try dead.getEntryBlock().addOperation(dead_exp.op);
    const dead_pow = try Arith.PowOp.create(ctx, loc, argument, argument);
    try returnOne(ctx, dead, dead_pow.op, argument);

    try addSpilledLibrary(ctx, body, floating, T);
    return module.op;
}

const library_constant: f64 = 0.75;

/// Every placement register holds a constant live past the call, so its argument and its
/// result live in the frame and every saved home must come back intact.
fn addSpilledLibrary(ctx: *ir.Context, body: *ir.Block, floating: ir.Type, comptime T: type) !void {
    const loc = ir.Location.getUnknown();
    const spilled = try Func.FuncOp.create(ctx, loc, "spilled", &.{}, &.{floating});
    try body.addOperation(spilled.op);
    const block = spilled.getEntryBlock();
    var constants: [spilled_constants]*ir.Value = undefined;
    for (&constants, 0..) |*constant, index| {
        const value = spilledConstant(T, index);
        const literal = try Arith.ConstantOp.createFloat(ctx, loc, floating, value);
        try block.addOperation(literal.op);
        constant.* = literal.getResult();
    }
    const call = try Arith.ExpOp.create(ctx, loc, constants[spilled_constants - 1]);
    try block.addOperation(call.op);
    var total = call.getResult();
    for (constants) |constant| {
        const add = try Arith.AddOp.create(ctx, loc, total, constant);
        try block.addOperation(add.op);
        total = add.getResult();
    }
    try block.addOperation((try Func.ReturnOp.create(ctx, loc, &.{total})).op);
}

fn expectLibrary(comptime T: type) !void {
    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);
    const module = try libraryModule(&ctx, T);
    defer module.erase();
    var runtime = try execution.Runtime(Target).initWithExecutablePolicy(
        testing.allocator,
        .testing,
        .macos_non_hardened,
    );
    defer runtime.deinit();
    const handle = try runtime.compile(module);
    defer runtime.release(handle) catch {};

    const Unary = *const fn (T) callconv(.c) T;
    const Binary = *const fn (T, T) callconv(.c) T;
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const edges = floorEdges(T);
    var random = std.Random.DefaultPrng.init(0x11b_ca11);
    inline for (library_unary) |case| {
        const function = try runtime.getFunction(handle, "call_" ++ case.name, Unary);
        const expected = shim(Unary, librarySymbol(T, case));
        for (edges) |x| try expectBits(T, expected(x), function(x));
        for (0..1024) |_| {
            const x: T = @bitCast(random.random().int(Bits));
            try expectBits(T, expected(x), function(x));
        }
        // An independent fact each function must meet, so a call to the wrong one fails.
        const one = std.mem.eql(u8, case.name, "exp") or std.mem.eql(u8, case.name, "cos");
        const at_zero: T = if (one) 1 else 0;
        const argument: T = if (std.mem.eql(u8, case.name, "log")) 1 else 0;
        try expectBits(T, at_zero, function(argument));
    }

    const floor = try runtime.getFunction(handle, "call_floor", Unary);
    for (edges) |x| try expectFloor(T, x, floor(x));
    for (0..4096) |_| {
        const x: T = @bitCast(random.random().int(Bits));
        try expectFloor(T, x, floor(x));
    }

    const pow = try runtime.getFunction(handle, "call_pow", Binary);
    const power = shim(Binary, if (T == f32) .powf else .pow);
    for (edges) |x| for (edges) |y| try expectBits(T, power(x, y), pow(x, y));
    for (0..1024) |_| {
        const x: T = @bitCast(random.random().int(Bits));
        const y: T = @bitCast(random.random().int(Bits));
        try expectBits(T, power(x, y), pow(x, y));
    }
    try expectBits(T, 1024, pow(2, 10));

    const constant: T = @floatCast(library_constant);
    const base = try runtime.getFunction(handle, "pow_base", Unary);
    const exponent = try runtime.getFunction(handle, "pow_exponent", Unary);
    for (edges) |x| {
        try expectBits(T, power(constant, x), base(x));
        try expectBits(T, power(x, constant), exponent(x));
    }
    const exp = shim(Unary, if (T == f32) .expf else .exp);
    const Nullary = *const fn () callconv(.c) T;
    const exp_constant = try runtime.getFunction(handle, "exp_constant", Nullary);
    try expectBits(T, exp(constant), exp_constant());

    const across = try runtime.getFunction(handle, "across", Binary);
    for (edges) |x| for (edges) |y| try expectBits(T, exp(x) + y, across(x, y));

    const dead = try runtime.getFunction(handle, "dead", Unary);
    for (edges) |x| try expectBits(T, x, dead(x));

    const spilled = try runtime.getFunction(handle, "spilled", *const fn () callconv(.c) T);
    var expected = exp(spilledConstant(T, spilled_constants - 1));
    for (0..spilled_constants) |index| expected += spilledConstant(T, index);
    try expectBits(T, expected, spilled());
}

const FloatShapeStep = struct {
    op: enum { cast, bitcast },
    kind: @import("../../dialects/root.zig").arith.ScalarKind,
};

/// Adds `name`, which takes one `source` and returns it after each step in turn.
fn floatShapeChain(
    ctx: *ir.Context,
    module: *ir.Operation,
    name: []const u8,
    source: @import("../../dialects/root.zig").arith.ScalarKind,
    steps: []const FloatShapeStep,
) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const first = try dialects.ArithDialect.getScalarType(ctx, source);
    const last = try dialects.ArithDialect.getScalarType(ctx, steps[steps.len - 1].kind);
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, name, &.{first}, &.{last});
    try (dialects.BuiltinDialect.ModuleOp{ .op = module }).getBodyBlock().addOperation(function.op);
    var value = function.getArgument(0);
    for (steps) |step| {
        const typ = try dialects.ArithDialect.getScalarType(ctx, step.kind);
        const op = switch (step.op) {
            .cast => (try dialects.ArithDialect.CastOp.create(ctx, loc, value, typ)).op,
            .bitcast => (try dialects.ArithDialect.BitcastOp.create(ctx, loc, value, typ)).op,
        };
        try function.getEntryBlock().addOperation(op);
        value = op.getResult(0).?;
    }
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{value});
    try function.getEntryBlock().addOperation(ret.op);
    return function.op;
}

const f32_predicates = [_]@import("../../dialects/root.zig").arith.CmpPredicate{ .eq, .ne, .lt, .le, .gt, .ge };

const f32_bitcasts = [_]struct { name: []const u8, from: @import("../../dialects/root.zig").arith.ScalarKind, to: @import("../../dialects/root.zig").arith.ScalarKind }{
    .{ .name = "bits_f32_u32", .from = .f32, .to = .u32 },
    .{ .name = "bits_f32_i32", .from = .f32, .to = .i32 },
    .{ .name = "bits_u32_f32", .from = .u32, .to = .f32 },
    .{ .name = "bits_i32_f32", .from = .i32, .to = .f32 },
    .{ .name = "bits_f64_i64", .from = .f64, .to = .i64 },
    .{ .name = "bits_i64_f64", .from = .i64, .to = .f64 },
    .{ .name = "bits_f64_u64", .from = .f64, .to = .u64 },
    .{ .name = "bits_i32_u32", .from = .i32, .to = .u32 },
    .{ .name = "bits_u32_i32", .from = .u32, .to = .i32 },
    .{ .name = "bits_i64_u64", .from = .i64, .to = .u64 },
    .{ .name = "bits_u8_i8", .from = .u8, .to = .i8 },
};

const f32_integer_kinds = [_]NumericCastFunction{
    .{ .name = "i8", .kind = .i8 },
    .{ .name = "i16", .kind = .i16 },
    .{ .name = "i32", .kind = .i32 },
    .{ .name = "i64", .kind = .i64 },
    .{ .name = "u8", .kind = .u8 },
    .{ .name = "u16", .kind = .u16 },
    .{ .name = "u32", .kind = .u32 },
    .{ .name = "u64", .kind = .u64 },
    .{ .name = "index", .kind = .index },
};

/// One module holding every f32 shape: the six ordered comparisons, the bitcasts, the two
/// width conversions (entered and left as words, since one function carries one float width),
/// and a conversion to and from f32 for each integer kind.
fn f32ShapeModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();
    const floating = try dialects.ArithDialect.getScalarType(ctx, .f32);
    const boolean = try dialects.ArithDialect.getScalarType(ctx, .bool);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    for (f32_predicates) |predicate| {
        var name: [16]u8 = undefined;
        const function = try dialects.FuncDialect.FuncOp.create(
            ctx,
            loc,
            try std.fmt.bufPrint(&name, "f32_{s}", .{@tagName(predicate)}),
            &.{ floating, floating },
            &.{boolean},
        );
        try module.getBodyBlock().addOperation(function.op);
        const comparison = try dialects.ArithDialect.CmpOp.create(ctx, loc, predicate, function.getArgument(0), function.getArgument(1));
        try function.getEntryBlock().addOperation(comparison.op);
        const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{comparison.getResult()});
        try function.getEntryBlock().addOperation(ret.op);
    }
    for (f32_bitcasts) |shape| {
        _ = try floatShapeChain(ctx, module.op, shape.name, shape.from, &.{.{ .op = .bitcast, .kind = shape.to }});
    }
    _ = try floatShapeChain(ctx, module.op, "wide_f32_i32", .f32, &.{
        .{ .op = .bitcast, .kind = .i32 },
        .{ .op = .cast, .kind = .i64 },
    });
    _ = try floatShapeChain(ctx, module.op, "wide_i32_f32", .i32, &.{
        .{ .op = .bitcast, .kind = .f32 },
        .{ .op = .bitcast, .kind = .u32 },
        .{ .op = .cast, .kind = .u64 },
    });
    _ = try floatShapeChain(ctx, module.op, "widen", .u32, &.{
        .{ .op = .bitcast, .kind = .f32 },
        .{ .op = .cast, .kind = .f64 },
        .{ .op = .bitcast, .kind = .u64 },
    });
    _ = try floatShapeChain(ctx, module.op, "narrow", .u64, &.{
        .{ .op = .bitcast, .kind = .f64 },
        .{ .op = .cast, .kind = .f32 },
        .{ .op = .bitcast, .kind = .u32 },
    });
    _ = try floatShapeChain(ctx, module.op, "same_f32", .f32, &.{.{ .op = .cast, .kind = .f32 }});
    for (f32_integer_kinds) |definition| {
        var name: [24]u8 = undefined;
        _ = try floatShapeChain(
            ctx,
            module.op,
            try std.fmt.bufPrint(&name, "to_f32_{s}", .{definition.name}),
            definition.kind,
            &.{.{ .op = .cast, .kind = .f32 }},
        );
        _ = try floatShapeChain(
            ctx,
            module.op,
            try std.fmt.bufPrint(&name, "from_f32_{s}", .{definition.name}),
            .f32,
            &.{.{ .op = .cast, .kind = definition.kind }},
        );
    }
    return module.op;
}

/// Zeros, the subnormal extremes, one ULP either side of one, the finite extremes, both
/// infinities, and a quiet and a signaling NaN with payloads.
const f32_pool = [_]u32{
    0x0000_0000, 0x8000_0000, 0x0000_0001, 0x807f_ffff, 0x0080_0000, 0x3f7f_ffff,
    0x3f80_0000, 0x3f80_0001, 0xbf80_0000, 0x7f7f_ffff, 0xff7f_ffff, 0x7f80_0000,
    0xff80_0000, 0x7fc1_2345, 0xffc1_2345, 0x7f81_2345,
};

fn f32Compare(predicate: @import("../../dialects/root.zig").arith.CmpPredicate, lhs: f32, rhs: f32) bool {
    return switch (predicate) {
        .eq => lhs == rhs,
        .ne => lhs != rhs,
        .lt => lhs < rhs,
        .le => lhs <= rhs,
        .gt => lhs > rhs,
        .ge => lhs >= rhs,
        else => unreachable,
    };
}

fn integerSampleValue(kind: @import("../../dialects/root.zig").arith.ScalarKind, raw: i128) execution.Value {
    return switch (kind) {
        .i8 => .{ .i8 = @intCast(raw) },
        .i16 => .{ .i16 = @intCast(raw) },
        .i32 => .{ .i32 = @intCast(raw) },
        .i64 => .{ .i64 = @intCast(raw) },
        .u8 => .{ .u8 = @intCast(raw) },
        .u16 => .{ .u16 = @intCast(raw) },
        .u32 => .{ .u32 = @intCast(raw) },
        .u64 => .{ .u64 = @intCast(raw) },
        .index => .{ .index = @intCast(raw) },
        else => unreachable,
    };
}

fn f32ConversionSamples(kind: @import("../../dialects/root.zig").arith.ScalarKind) [20]f32 {
    const arith = @import("../../dialects/root.zig").arith;
    const unsigned = arith.scalarKindIsUnsignedInteger(kind) or kind == .index;
    const bits = arith.scalarBitWidth(kind);
    const exponent: u7 = @intCast(bits - @as(u8, if (unsigned) 0 else 1));
    const upper: f32 = @floatFromInt(@as(u128, 1) << exponent);
    const upper_bits: u32 = @bitCast(upper);
    return .{
        0,                  -0.0,                                @bitCast(@as(u32, 1)),           @bitCast(@as(u32, 0x8000_0001)),
        0.5,                -0.5,                                1.75,                            -1.75,
        -1,                 upper,                               @bitCast(upper_bits - 1),        @bitCast(upper_bits + 1),
        -upper,             -@as(f32, @bitCast(upper_bits + 1)), -upper - 1,                      std.math.inf(f32),
        -std.math.inf(f32), @bitCast(@as(u32, 0x7fc1_2345)),     @bitCast(@as(u32, 0x7f81_2345)), @bitCast(@as(u32, 0x7f7f_ffff)),
    };
}

fn expectF32ConversionTrap(comptime Result: type, native: *const fn (f32) callconv(.c) Result, input: f32) !void {
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
