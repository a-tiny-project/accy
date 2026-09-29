const std = @import("std");
const testing = std.testing;

const core = @import("../model/core/root.zig");
const eval = @import("../../eval/root.zig");

const builder = core.builder;
const schedule_mod = core.schedule;

pub const enabled = true;
pub const Launch = schedule_mod.Launch;
pub const Argument = eval.KernelArgument;
pub const Machine = eval.Machine;
pub const Scalar = eval.Scalar;
pub const ExecutionDiagnostic = eval.Diagnostic;
pub const shared_alloc_sentinel = eval.shared_alloc_sentinel;
pub const tf32RoundF32 = eval.tf32RoundF32;

pub fn argumentBuffer(comptime T: type, values: []T) Argument {
    return .{ .memref = std.mem.sliceAsBytes(values) };
}

pub fn argumentBool(value: bool) Argument {
    return .{ .scalar = .{ .bool = value } };
}

pub fn argumentI32(value: i32) Argument {
    return .{ .scalar = .{ .i32 = value } };
}

pub fn argumentU32(value: u32) Argument {
    return .{ .scalar = .{ .u32 = value } };
}

pub fn argumentI64(value: i64) Argument {
    return .{ .scalar = .{ .i64 = value } };
}

pub fn argumentF32(value: f32) Argument {
    return .{ .scalar = .{ .f32 = value } };
}

pub fn argumentF64(value: f64) Argument {
    return .{ .scalar = .{ .f64 = value } };
}

pub fn run(allocator: std.mem.Allocator, kernel: *builder.Kernel, args: []const Argument, launch: Launch) !void {
    try kernel.verify();
    try eval.executeKernelFunction(allocator, kernel.func().op, args, launch);
}

pub fn runWithDiagnostic(
    allocator: std.mem.Allocator,
    kernel: *builder.Kernel,
    args: []const Argument,
    launch: Launch,
    diagnostic: *ExecutionDiagnostic,
) !void {
    diagnostic.len = 0;
    try kernel.verifyWithDiagnostic(diagnostic);
    try eval.executeKernelFunctionWithDiagnostic(allocator, kernel.func().op, args, launch, diagnostic);
}

pub fn run1D(allocator: std.mem.Allocator, kernel: *builder.Kernel, args: []const Argument, extent: usize) !void {
    try run(allocator, kernel, args, Launch.oneDim(extent));
}

pub fn run1DWithDiagnostic(
    allocator: std.mem.Allocator,
    kernel: *builder.Kernel,
    args: []const Argument,
    extent: usize,
    diagnostic: *ExecutionDiagnostic,
) !void {
    try runWithDiagnostic(allocator, kernel, args, Launch.oneDim(extent), diagnostic);
}

fn expectApproxSlice(actual: []const f32, expected: []const f32) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |a, e| {
        try testing.expectApproxEqAbs(e, a, 0.0001);
    }
}

test "run1D executes Choir-backed copy kernels on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "copy_f32", &.{
        builder.dynamicBuffer(.f32),
        builder.dynamicBuffer(.f32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const i = try b.globalId(.x);
    const x = try b.load(src, i);
    try b.store(x, dst, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var input = [_]f32{ 1.5, -2.0, 3.25, 4.5 };
    var output = [_]f32{ 0, 0, 0, 0 };
    try run1D(testing.allocator, &kernel, &.{
        argumentBuffer(f32, input[0..]),
        argumentBuffer(f32, output[0..]),
    }, input.len);

    try expectApproxSlice(output[0..], input[0..]);
}

test "run1D executes structured control flow kernels on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "clamp_positive", &.{
        builder.dynamicBuffer(.f32),
        builder.dynamicBuffer(.f32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const i = try b.globalId(.x);
    const x = try b.load(src, i);
    const zero = try b.constantFloat(.f32, 0.0);
    const pred = try b.compare(.gt, x, zero);
    var if_op = try b.if_(pred, &.{x.valueType()});

    {
        var scope = try b.enterBlock(if_op.thenBlock());
        defer scope.leave();
        try b.yield_(&.{x});
    }

    {
        var scope = try b.enterBlock(if_op.elseBlock().?);
        defer scope.leave();
        try b.yield_(&.{zero});
    }

    try b.store(if_op.result(0).?, dst, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var input = [_]f32{ -3.0, 2.5, 0.0, 9.0 };
    var output = [_]f32{ 7.0, 7.0, 7.0, 7.0 };
    try run1D(testing.allocator, &kernel, &.{
        argumentBuffer(f32, input[0..]),
        argumentBuffer(f32, output[0..]),
    }, input.len);

    try expectApproxSlice(output[0..], &.{ 0.0, 2.5, 0.0, 9.0 });
}

test "run1D binds scalar kernel arguments on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "fill_scalar", &.{
        builder.dynamicBuffer(.f32),
        builder.scalar(.f32),
    }, .{});
    errdefer b.deinit();

    const dst = b.argument(0);
    const value = b.argument(1);
    const i = try b.globalId(.x);
    try b.store(value, dst, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var output = [_]f32{ 0, 0, 0 };
    try run1D(testing.allocator, &kernel, &.{
        argumentBuffer(f32, output[0..]),
        argumentF32(3.5),
    }, output.len);

    try expectApproxSlice(output[0..], &.{ 3.5, 3.5, 3.5 });
}

test "run1D executes u32 scalar and buffer kernels on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "wrap_neg_u32", &.{
        builder.dynamicBuffer(.u32),
        builder.dynamicBuffer(.u32),
        builder.scalar(.u32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const delta = b.argument(2);
    const i = try b.globalId(.x);
    const loaded = try b.load(src, i);
    const sum = try b.add(loaded, delta);
    const wrapped = try b.neg(sum);
    try b.store(wrapped, dst, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var input = [_]u32{ 0, std.math.maxInt(u32), 41 };
    var output = [_]u32{ 7, 7, 7 };
    try run1D(testing.allocator, &kernel, &.{
        argumentBuffer(u32, input[0..]),
        argumentBuffer(u32, output[0..]),
        argumentU32(1),
    }, input.len);

    try testing.expectEqualSlices(u32, &.{
        std.math.maxInt(u32),
        0,
        std.math.maxInt(u32) - 41,
    }, output[0..]);
}

test "run executes loop kernels on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "fill_loop", &.{
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const dst = b.argument(0);
    const lower = try b.constantIndex(0);
    const upper = try b.constantIndex(4);
    const step = try b.constantIndex(1);
    var loop = try b.for_(lower, upper, step, &.{}, &.{});

    {
        var scope = try b.enterBlock(loop.bodyBlock());
        defer scope.leave();
        const one = try b.constantInt(.i32, 1);
        try b.store(one, dst, loop.inductionVar());
        try b.yield_(&.{});
    }

    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var output = [_]i32{ 0, 0, 0, 0 };
    try run(testing.allocator, &kernel, &.{
        argumentBuffer(i32, output[0..]),
    }, .{});

    try testing.expectEqualSlices(i32, &.{ 1, 1, 1, 1 }, output[0..]);
}

test "run1D executes atomic add kernels with old-value results on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "atomic_add_f32", &.{
        builder.dynamicBuffer(.f32),
        builder.dynamicBuffer(.f32),
    }, .{});
    errdefer b.deinit();

    const bins = b.argument(0);
    const olds = b.argument(1);
    const i = try b.globalId(.x);
    const bin = try b.constantIndex(0);
    const delta = try b.constantFloat(.f32, 2.5);
    const old = try b.atomicRmw(.add, delta, bins, bin);
    try b.store(old, olds, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var bin_values = [_]f32{0};
    var old_values = [_]f32{ -1, -1, -1, -1 };
    try run1D(testing.allocator, &kernel, &.{
        argumentBuffer(f32, bin_values[0..]),
        argumentBuffer(f32, old_values[0..]),
    }, old_values.len);

    try testing.expectApproxEqAbs(@as(f32, 10.0), bin_values[0], 0.0001);
    try expectApproxSlice(old_values[0..], &.{ 0.0, 2.5, 5.0, 7.5 });
}

test "run1D executes integer atomic max and exchange kernels on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "atomic_max_exchange_i32", &.{
        builder.dynamicBuffer(.i32),
        builder.dynamicBuffer(.i32),
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const peak = b.argument(0);
    const last = b.argument(1);
    const values = b.argument(2);
    const i = try b.globalId(.x);
    const slot = try b.constantIndex(0);
    const value = try b.load(values, i);
    _ = try b.atomicRmw(.max, value, peak, slot);
    _ = try b.atomicRmw(.exchange, value, last, slot);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var peak_values = [_]i32{std.math.minInt(i32)};
    var last_values = [_]i32{0};
    var inputs = [_]i32{ 4, 9, -3, 7 };
    try run1D(testing.allocator, &kernel, &.{
        argumentBuffer(i32, peak_values[0..]),
        argumentBuffer(i32, last_values[0..]),
        argumentBuffer(i32, inputs[0..]),
    }, inputs.len);

    try testing.expectEqual(@as(i32, 9), peak_values[0]);
    try testing.expectEqual(@as(i32, 7), last_values[0]);
}

test "run1D executes integer atomic cas kernels on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "atomic_cas_i32", &.{
        builder.dynamicBuffer(.i32),
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const slot_values = b.argument(0);
    const old_values = b.argument(1);
    const i = try b.globalId(.x);
    const slot = try b.constantIndex(0);
    const expected = try b.constantInt(.i32, 0);
    const desired = try b.constantInt(.i32, 11);
    const old = try b.atomicCas(expected, desired, slot_values, slot);
    try b.store(old, old_values, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var slot_data = [_]i32{0};
    var old_data = [_]i32{ -1, -1, -1, -1 };
    try run1D(testing.allocator, &kernel, &.{
        argumentBuffer(i32, slot_data[0..]),
        argumentBuffer(i32, old_data[0..]),
    }, old_data.len);

    try testing.expectEqual(@as(i32, 11), slot_data[0]);
    try testing.expectEqualSlices(i32, &.{ 0, 11, 11, 11 }, old_data[0..]);
}

test "run executes warp mma.sync fragments against a scalar product" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "mma_sync_m16n8k8", &.{
        builder.dynamicBuffer(.f32),
        builder.dynamicBuffer(.f32),
        builder.dynamicBuffer(.f32),
        builder.dynamicBuffer(.f32),
    }, .{});
    errdefer b.deinit();

    const a_buf = b.argument(0);
    const b_buf = b.argument(1);
    const c_buf = b.argument(2);
    const d_buf = b.argument(3);

    const lane = try b.laneId();
    const four = try b.constantIndex(4);
    const eight = try b.constantIndex(8);
    const group = try b.div(lane, four);
    const tid = try b.sub(lane, try b.mul(group, four));
    const group_hi = try b.add(group, eight);
    const tid_hi = try b.add(tid, four);

    const row_lo = try b.mul(group, eight);
    const row_hi = try b.mul(group_hi, eight);
    const a = [4]builder.Value{
        try b.load(a_buf, try b.add(row_lo, tid)),
        try b.load(a_buf, try b.add(row_hi, tid)),
        try b.load(a_buf, try b.add(row_lo, tid_hi)),
        try b.load(a_buf, try b.add(row_hi, tid_hi)),
    };
    const bv = [2]builder.Value{
        try b.load(b_buf, try b.add(try b.mul(tid, eight), group)),
        try b.load(b_buf, try b.add(try b.mul(tid_hi, eight), group)),
    };
    const two = try b.constantIndex(2);
    const one = try b.constantIndex(1);
    const col_lo = try b.mul(tid, two);
    const col_hi = try b.add(col_lo, one);
    const c = [4]builder.Value{
        try b.load(c_buf, try b.add(row_lo, col_lo)),
        try b.load(c_buf, try b.add(row_lo, col_hi)),
        try b.load(c_buf, try b.add(row_hi, col_lo)),
        try b.load(c_buf, try b.add(row_hi, col_hi)),
    };

    const d = try b.mmaSync(.{ .m = 16, .n = 8, .k = 8 }, a, bv, c);
    try b.store(d[0], d_buf, try b.add(row_lo, col_lo));
    try b.store(d[1], d_buf, try b.add(row_lo, col_hi));
    try b.store(d[2], d_buf, try b.add(row_hi, col_lo));
    try b.store(d[3], d_buf, try b.add(row_hi, col_hi));
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var a_values: [16 * 8]f32 = undefined;
    var b_values: [8 * 8]f32 = undefined;
    var c_values: [16 * 8]f32 = undefined;
    var d_values: [16 * 8]f32 = @splat(0);
    for (&a_values, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index % 13)) * 0.25 - 1.0;
    for (&b_values, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index % 7)) * 0.5 - 1.5;
    for (&c_values, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index % 5)) - 2.0;

    try run(testing.allocator, &kernel, &.{
        argumentBuffer(f32, a_values[0..]),
        argumentBuffer(f32, b_values[0..]),
        argumentBuffer(f32, c_values[0..]),
        argumentBuffer(f32, d_values[0..]),
    }, .{ .grid = .{ 1, 1, 1 }, .block = .{ 32, 1, 1 } });

    for (0..16) |row| {
        for (0..8) |col| {
            var expected = c_values[row * 8 + col];
            for (0..8) |k| {
                expected += a_values[row * 8 + k] * b_values[k * 8 + col];
            }
            try testing.expectApproxEqAbs(expected, d_values[row * 8 + col], 0.001);
        }
    }
}

test "run1D executes shared atomic accumulation on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "shared_atomic_add_i32", &.{
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const out = b.argument(0);
    const i = try b.globalId(.x);
    const bins = try b.sharedBuffer(.i32, 4);
    const zero = try b.constantInt(.i32, 0);
    try b.store(zero, bins, i);
    try b.barrier(.block);
    const slot = try b.constantIndex(0);
    const one = try b.constantInt(.i32, 1);
    const old = try b.atomicRmw(.add, one, bins, slot);
    try b.store(old, out, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var olds = [_]i32{ -1, -1, -1, -1 };
    try run(testing.allocator, &kernel, &.{
        argumentBuffer(i32, olds[0..]),
    }, .{ .grid = .{ 1, 1, 1 }, .block = .{ 4, 1, 1 } });

    try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3 }, olds[0..]);
}

test "run1D stages async shared copies before reading them back" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "cp_async_shared_f32", &.{
        builder.dynamicBuffer(.f32),
        builder.dynamicBuffer(.f32),
    }, .{});
    errdefer b.deinit();

    const input = b.argument(0);
    const out = b.argument(1);
    const i = try b.globalId(.x);
    const staged = try b.sharedBuffer(.f32, 8);
    const four = try b.constantIndex(4);
    const quad_base = try b.mul(i, four);
    try b.asyncCopyShared(staged, quad_base, input, quad_base, 16);
    try b.asyncCopyCommit();
    try b.asyncCopyWait(0);
    try b.barrier(.block);
    const seven = try b.constantIndex(7);
    const flipped = try b.sub(seven, i);
    const value = try b.load(staged, flipped);
    try b.store(value, out, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var input_values = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    var out_values = @as([8]f32, @splat(0.0));
    try run(testing.allocator, &kernel, &.{
        argumentBuffer(f32, input_values[0..]),
        argumentBuffer(f32, out_values[0..]),
    }, .{ .grid = .{ 1, 1, 1 }, .block = .{ 2, 1, 1 } });

    try testing.expectEqualSlices(f32, &.{ 8.0, 7.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, out_values[0..]);
}

test "run1D executes shared integer atomic cas kernels on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "shared_atomic_cas_i32", &.{
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const out = b.argument(0);
    const i = try b.globalId(.x);
    const bins = try b.sharedBuffer(.i32, 4);
    const zero = try b.constantInt(.i32, 0);
    try b.store(zero, bins, i);
    try b.barrier(.block);
    const slot = try b.constantIndex(0);
    const desired = try b.constantInt(.i32, 7);
    const old = try b.atomicCas(zero, desired, bins, slot);
    try b.store(old, out, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var olds = [_]i32{ -1, -1, -1, -1 };
    try run(testing.allocator, &kernel, &.{
        argumentBuffer(i32, olds[0..]),
    }, .{ .grid = .{ 1, 1, 1 }, .block = .{ 4, 1, 1 } });

    try testing.expectEqualSlices(i32, &.{ 0, 7, 7, 7 }, olds[0..]);
}

test "run1D resets unseeded shared memory to the sentinel per block" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "shared_atomic_unseeded_i32", &.{
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const out = b.argument(0);
    const i = try b.globalId(.x);
    const bins = try b.sharedBuffer(.i32, 4);
    const slot = try b.constantIndex(0);
    const one = try b.constantInt(.i32, 1);
    const old = try b.atomicRmw(.add, one, bins, slot);
    try b.store(old, out, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    const fill: u8 = shared_alloc_sentinel;
    const word: u32 = @as(u32, fill) << 24 | @as(u32, fill) << 16 | @as(u32, fill) << 8 | @as(u32, fill);
    const sentinel_value: i32 = @bitCast(word);

    var per_block = [_]i32{ -1, -1, -1, -1 };
    try run1D(testing.allocator, &kernel, &.{
        argumentBuffer(i32, per_block[0..]),
    }, per_block.len);

    try testing.expectEqualSlices(
        i32,
        &.{ sentinel_value, sentinel_value, sentinel_value, sentinel_value },
        per_block[0..],
    );
}

test "run1D executes while loops with divergent lane trip counts on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "while_triangular_i32", &.{
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const dst = b.argument(0);
    const i = try b.globalId(.x);
    const start = try b.cast(i, .i32);
    const zero = try b.constantInt(.i32, 0);
    const one = try b.constantInt(.i32, 1);

    var scope = try b.whileScope(&.{ start, zero }, &.{ start.valueType(), zero.valueType() });
    errdefer scope.abort();
    const remaining = scope.beforeArg(0).?;
    const total = scope.beforeArg(1).?;
    const proceed = try b.compare(.gt, remaining, zero);
    try scope.condition(proceed, &.{ remaining, total });
    const after_remaining = scope.afterArg(0).?;
    const after_total = scope.afterArg(1).?;
    const next_total = try b.add(after_total, after_remaining);
    const next_remaining = try b.sub(after_remaining, one);
    try scope.leave(&.{ next_remaining, next_total });

    try b.store(scope.result(1).?, dst, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var out = @as([8]i32, @splat(-1));
    try run1D(testing.allocator, &kernel, &.{
        argumentBuffer(i32, out[0..]),
    }, out.len);

    try testing.expectEqualSlices(i32, &.{ 0, 1, 3, 6, 10, 15, 21, 28 }, out[0..]);
}

fn buildClampedFillKernel(allocator: std.mem.Allocator) !builder.Kernel {
    var b = try builder.Builder.init(allocator, builder.Builder.Limits.testing, "clamped_fill_f32", &.{
        builder.dynamicBuffer(.f32),
        builder.dynamicBuffer(.f32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const i = try b.globalId(.x);
    const x = try b.load(src, i);
    const zero = try b.constantFloat(.f32, 0.0);
    const pred = try b.compare(.gt, x, zero);
    var if_op = try b.if_(pred, &.{x.valueType()});

    {
        var scope = try b.enterBlock(if_op.thenBlock());
        defer scope.leave();
        try b.yield_(&.{x});
    }

    {
        var scope = try b.enterBlock(if_op.elseBlock().?);
        defer scope.leave();
        try b.yield_(&.{zero});
    }

    const clamped = if_op.result(0).?;
    const lower = try b.constantIndex(0);
    const upper = try b.constantIndex(4);
    const step = try b.constantIndex(1);
    var loop = try b.for_(lower, upper, step, &.{}, &.{});

    {
        var scope = try b.enterBlock(loop.bodyBlock());
        defer scope.leave();
        try b.store(clamped, dst, i);
        try b.yield_(&.{});
    }

    try b.return_();
    return b.finish();
}

const clamped_fill_input = [_]f32{ 1.5, -2.0, 3.25, -4.5, 0.5, -1.0, 2.0, 6.0 };
const clamped_fill_expected = [_]f32{ 1.5, 0.0, 3.25, 0.0, 0.5, 0.0, 2.0, 6.0 };

test "Machine steady launches make no allocator calls" {
    var kernel = try buildClampedFillKernel(testing.allocator);
    defer kernel.deinit();
    try kernel.verify();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var machine = Machine.init(failing.allocator());
    defer machine.deinit();

    var input = clamped_fill_input;
    var output = @as([8]f32, @splat(0));
    const launch = Launch{ .grid = .{ 2, 1, 1 }, .block = .{ 4, 1, 1 } };
    try machine.run(kernel.func().op, &.{
        argumentBuffer(f32, input[0..]),
        argumentBuffer(f32, output[0..]),
    }, launch);
    try expectApproxSlice(output[0..], clamped_fill_expected[0..]);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    for (0..8) |_| {
        @memset(output[0..], -1.0);
        try machine.run(kernel.func().op, &.{
            argumentBuffer(f32, input[0..]),
            argumentBuffer(f32, output[0..]),
        }, launch);
        try expectApproxSlice(output[0..], clamped_fill_expected[0..]);
    }
    try testing.expect(!failing.has_induced_failure);
}

test "Machine grown grids reuse warmed block storage" {
    var kernel = try buildClampedFillKernel(testing.allocator);
    defer kernel.deinit();
    try kernel.verify();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var machine = Machine.init(failing.allocator());
    defer machine.deinit();

    var input = clamped_fill_input;
    var output = @as([8]f32, @splat(0));
    try machine.run(kernel.func().op, &.{
        argumentBuffer(f32, input[0..4]),
        argumentBuffer(f32, output[0..4]),
    }, Launch{ .grid = .{ 1, 1, 1 }, .block = .{ 4, 1, 1 } });
    try expectApproxSlice(output[0..4], clamped_fill_expected[0..4]);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    @memset(output[0..], -1.0);
    try machine.run(kernel.func().op, &.{
        argumentBuffer(f32, input[0..]),
        argumentBuffer(f32, output[0..]),
    }, Launch{ .grid = .{ 2, 1, 1 }, .block = .{ 4, 1, 1 } });
    try expectApproxSlice(output[0..], clamped_fill_expected[0..]);
    try testing.expect(!failing.has_induced_failure);
}

fn buildUnseededSharedKernel(allocator: std.mem.Allocator) !builder.Kernel {
    var b = try builder.Builder.init(allocator, builder.Builder.Limits.testing, "machine_shared_unseeded_i32", &.{
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const out = b.argument(0);
    const i = try b.globalId(.x);
    const bins = try b.sharedBuffer(.i32, 4);
    const slot = try b.constantIndex(0);
    const one = try b.constantInt(.i32, 1);
    const old = try b.atomicRmw(.add, one, bins, slot);
    try b.store(old, out, i);
    try b.return_();
    return b.finish();
}

test "Machine steady shared launches reuse bytes and reset the sentinel" {
    var kernel = try buildUnseededSharedKernel(testing.allocator);
    defer kernel.deinit();
    try kernel.verify();

    const fill: u8 = shared_alloc_sentinel;
    const word: u32 = @as(u32, fill) << 24 | @as(u32, fill) << 16 | @as(u32, fill) << 8 | @as(u32, fill);
    const sentinel_value: i32 = @bitCast(word);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var machine = Machine.init(failing.allocator());
    defer machine.deinit();

    var out = [_]i32{ -1, -1, -1, -1 };
    try machine.run(kernel.func().op, &.{
        argumentBuffer(i32, out[0..]),
    }, Launch.oneDim(out.len));
    try testing.expectEqualSlices(i32, &.{ sentinel_value, sentinel_value, sentinel_value, sentinel_value }, out[0..]);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    for (0..8) |_| {
        @memset(out[0..], -1);
        try machine.run(kernel.func().op, &.{
            argumentBuffer(i32, out[0..]),
        }, Launch.oneDim(out.len));
        try testing.expectEqualSlices(i32, &.{ sentinel_value, sentinel_value, sentinel_value, sentinel_value }, out[0..]);
    }
    try testing.expect(!failing.has_induced_failure);
}

test "Machine failed acquisition leaves the machine reusable" {
    var kernel = try buildClampedFillKernel(testing.allocator);
    defer kernel.deinit();
    try kernel.verify();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var machine = Machine.init(failing.allocator());
    defer machine.deinit();

    var input = clamped_fill_input;
    var output = @as([8]f32, @splat(0));
    const launch = Launch{ .grid = .{ 2, 1, 1 }, .block = .{ 4, 1, 1 } };
    try testing.expectError(error.OutOfMemory, machine.run(kernel.func().op, &.{
        argumentBuffer(f32, input[0..]),
        argumentBuffer(f32, output[0..]),
    }, launch));
    try testing.expect(failing.has_induced_failure);

    failing.fail_index = std.math.maxInt(usize);
    try machine.run(kernel.func().op, &.{
        argumentBuffer(f32, input[0..]),
        argumentBuffer(f32, output[0..]),
    }, launch);
    try expectApproxSlice(output[0..], clamped_fill_expected[0..]);
}

fn runMachineLifecycle(allocator: std.mem.Allocator, kernel: *builder.Kernel) !void {
    var machine = Machine.init(allocator);
    defer machine.deinit();

    var input = clamped_fill_input;
    var output = @as([8]f32, @splat(0));
    try machine.run(kernel.func().op, &.{
        argumentBuffer(f32, input[0..4]),
        argumentBuffer(f32, output[0..4]),
    }, Launch{ .grid = .{ 1, 1, 1 }, .block = .{ 4, 1, 1 } });
    for (output[0..4], clamped_fill_expected[0..4]) |actual, expected| {
        if (actual != expected) return error.TestUnexpectedResult;
    }

    try machine.run(kernel.func().op, &.{
        argumentBuffer(f32, input[0..]),
        argumentBuffer(f32, output[0..]),
    }, Launch{ .grid = .{ 1, 1, 1 }, .block = .{ 8, 1, 1 } });
    for (output[0..], clamped_fill_expected[0..]) |actual, expected| {
        if (actual != expected) return error.TestUnexpectedResult;
    }
}

test "Machine lifecycle releases every acquisition failure and retries" {
    var kernel = try buildClampedFillKernel(testing.allocator);
    defer kernel.deinit();
    try kernel.verify();

    try @import("../../fixture/root.zig").checkAllAllocationFailures(runMachineLifecycle, .{&kernel});
    try runMachineLifecycle(testing.allocator, &kernel);
}

test "Machine runs zero-thread launches without touching output" {
    var kernel = try buildClampedFillKernel(testing.allocator);
    defer kernel.deinit();
    try kernel.verify();

    var machine = Machine.init(testing.allocator);
    defer machine.deinit();

    var input = clamped_fill_input;
    var output = @as([8]f32, @splat(-7.0));
    try machine.run(kernel.func().op, &.{
        argumentBuffer(f32, input[0..]),
        argumentBuffer(f32, output[0..]),
    }, Launch{ .grid = .{ 2, 1, 1 }, .block = .{ 0, 1, 1 } });
    try expectApproxSlice(output[0..], &(@as([8]f32, @splat(-7.0))));
}

test "run executes popcount on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "popcount_i32", &.{
        builder.dynamicBuffer(.i32),
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const out = b.argument(0);
    const keys = b.argument(1);
    const i = try b.globalId(.x);
    const key = try b.load(keys, i);
    const bits = try b.popcount(key);
    try b.store(bits, out, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var keys_data = [_]i32{ 0, 1, 3, 7, 255, -1, 0x55555555, @bitCast(@as(u32, 0x80000000)) };
    var counts = @as([8]i32, @splat(-1));
    try run(testing.allocator, &kernel, &.{
        argumentBuffer(i32, counts[0..]),
        argumentBuffer(i32, keys_data[0..]),
    }, .{ .grid = .{ 1, 1, 1 }, .block = .{ 8, 1, 1 } });

    try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3, 8, 32, 16, 1 }, counts[0..]);
}

test "run executes ballot rank on CPU" {
    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "ballot_rank_i32", &.{
        builder.dynamicBuffer(.i32),
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const out = b.argument(0);
    const keys = b.argument(1);
    const i = try b.globalId(.x);
    const key = try b.load(keys, i);
    const one = try b.constantInt(.i32, 1);
    const low_bit = try b.and_(key, one);
    const is_odd = try b.compare(.eq, low_bit, one);
    const mask = try b.ballotSync(is_odd);
    const lane = try b.laneId();
    const lane_i32 = try b.cast(lane, .i32);
    const lane_bit = try b.shl(one, lane_i32);
    const lower = try b.sub(lane_bit, one);
    const below = try b.and_(mask, lower);
    const rank = try b.popcount(below);
    try b.store(rank, out, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var keys_data: [32]i32 = undefined;
    for (&keys_data, 0..) |*entry_value, index| entry_value.* = @intCast(index);
    var ranks = @as([32]i32, @splat(-1));
    try run(testing.allocator, &kernel, &.{
        argumentBuffer(i32, ranks[0..]),
        argumentBuffer(i32, keys_data[0..]),
    }, .{ .grid = .{ 1, 1, 1 }, .block = .{ 32, 1, 1 } });

    for (ranks, 0..) |observed_rank, index| {
        const odd_below: i32 = @intCast(index / 2);
        try testing.expectEqual(odd_below, observed_rank);
    }
}
