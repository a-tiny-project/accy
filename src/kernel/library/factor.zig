const std = @import("std");
const gpu_abi = @import("gpu_abi");

const artifact_product = @import("../../artifact/model/root.zig");
const shape = @import("../../choir/shape/root.zig");
const entry = @import("entry.zig");
const extent_mod = @import("extent.zig");
const kernel = @import("../root.zig");

const runtimeExtentArgument = extent_mod.runtimeExtentArgument;

pub const TileLayout = enum {
    row_major,
    interleaved,
};

pub const BatchedCholesky = struct {
    batch: u64,
    n: u32 = 3,
    threads: u32 = 256,
    layout: TileLayout = .row_major,
    batch_axis: []const u8 = "b",
};

pub const batched_cholesky_family_version: u32 = 1;
pub const batched_cholesky_min_n: u32 = 2;
pub const batched_cholesky_max_n: u32 = 4;
pub const batched_cholesky_max_threads: u32 = 1024;
pub const batched_cholesky_max_blocks: u32 = 1024;

pub fn batchedCholeskyBlockCount(batch: u64, threads: u32) u64 {
    return (batch + threads - 1) / threads;
}

pub fn batchedCholeskyInstanceValid(instance: BatchedCholesky) bool {
    if (instance.batch == 0) return false;
    if (instance.n < batched_cholesky_min_n or instance.n > batched_cholesky_max_n) return false;
    if (instance.threads == 0 or instance.threads > batched_cholesky_max_threads) return false;
    return extent_mod.blockCountWithinLimit(
        instance.batch,
        instance.threads,
        batched_cholesky_max_blocks,
    );
}

fn factorElementIndex(
    inner: anytype,
    layout: TileLayout,
    base: kernel.Value,
    batch_index: kernel.Value,
    system: kernel.Value,
    slot: usize,
) !kernel.Value {
    return switch (layout) {
        .row_major => inner.add(base, try inner.constantIndex(@intCast(slot))),
        .interleaved => inner.add(
            try inner.mul(try inner.constantIndex(@intCast(slot)), batch_index),
            system,
        ),
    };
}

fn batched_cholesky_body_active(inner: anytype, ctx: anytype) !void {
    const n: usize = @intCast(ctx.n);
    const tile = try inner.constantIndex(@intCast(n * n));
    const base = try inner.mul(ctx.system, tile);

    var a_values: [batched_cholesky_max_n][batched_cholesky_max_n]kernel.Value = undefined;
    for (0..n) |i| {
        for (0..i + 1) |j| {
            const index = try factorElementIndex(
                inner,
                ctx.layout,
                base,
                ctx.batch_index,
                ctx.system,
                i * n + j,
            );
            const loaded = try ctx.args.param(.a).load(inner, index);
            a_values[i][j] = loaded.raw();
        }
    }

    var l_values: [batched_cholesky_max_n][batched_cholesky_max_n]kernel.Value = undefined;
    for (0..n) |j| {
        var diagonal = a_values[j][j];
        for (0..j) |c| {
            diagonal = try inner.sub(diagonal, try inner.mul(l_values[j][c], l_values[j][c]));
        }
        l_values[j][j] = try inner.sqrt(diagonal);
        for (j + 1..n) |i| {
            var sum = a_values[i][j];
            for (0..j) |c| {
                sum = try inner.sub(sum, try inner.mul(l_values[i][c], l_values[j][c]));
            }
            l_values[i][j] = try inner.div(sum, l_values[j][j]);
        }
    }

    const zero = try inner.constantFloat(.f32, 0);
    for (0..n) |i| {
        for (0..n) |j| {
            const value = if (j <= i) l_values[i][j] else zero;
            const index = try factorElementIndex(
                inner,
                ctx.layout,
                base,
                ctx.batch_index,
                ctx.system,
                i * n + j,
            );
            try ctx.args.param(.l).store(inner, value, index);
        }
    }
}

fn batchedCholeskyBody(k: anytype, spec: BatchedCholesky, args: anytype) !void {
    if (!batchedCholeskyInstanceValid(spec)) return error.UnsupportedBatchedCholeskyInstance;
    const system = try k.globalId(.x);
    const batch = try k.castIndex(args.param(.batch).raw());
    const active = try k.compare(.lt, system, batch);
    try k.guardDo(active, .{
        .args = args,
        .system = system,
        .n = spec.n,
        .layout = spec.layout,
        .batch_index = batch,
    }, batched_cholesky_body_active);
}

fn batchedCholeskyFamilySchedule(instance: BatchedCholesky) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn batchedCholeskyRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_linalg_batched_cholesky_runtime_f32",
        .parameters = .{
            .l = kernel.dynamicBuffer(.f32),
            .a = kernel.dynamicBuffer(.f32),
            .batch = kernel.scalar(.i32),
        },
        .Instance = BatchedCholesky,
        .schedule = batchedCholeskyFamilySchedule,
        .body = batchedCholeskyBody,
    });
}

pub const BatchedCholeskyRuntimeFamilyF32 = batchedCholeskyRuntimeFamily();

fn layoutTargetSegment(layout: TileLayout) []const u8 {
    return switch (layout) {
        .row_major => "",
        .interleaved => "il_",
    };
}

pub fn batchedCholeskyFamilyTarget(allocator: std.mem.Allocator, instance: BatchedCholesky) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.linalg.batched_cholesky_family_{d}_{d}_{s}f32",
        .{ instance.n, instance.threads, layoutTargetSegment(instance.layout) },
    );
}

pub fn batchedCholeskyFamilyEntryName(
    allocator: std.mem.Allocator,
    instance: BatchedCholesky,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_linalg_batched_cholesky_family_{d}_{d}_{s}f32",
        .{ instance.n, instance.threads, layoutTargetSegment(instance.layout) },
    );
}

pub fn batchedCholeskyRuntimeArguments(instance: BatchedCholesky) ![1]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.batch) },
    };
}

const testing = std.testing;

fn hostCholesky(n: usize, a: []const f32, l: []f32) void {
    for (0..n) |i| {
        for (0..n) |j| {
            l[i * n + j] = 0;
        }
    }
    for (0..n) |j| {
        var diagonal = a[j * n + j];
        for (0..j) |c| {
            diagonal -= l[j * n + c] * l[j * n + c];
        }
        l[j * n + j] = @sqrt(diagonal);
        for (j + 1..n) |i| {
            var sum = a[i * n + j];
            for (0..j) |c| {
                sum -= l[i * n + c] * l[j * n + c];
            }
            l[i * n + j] = sum / l[j * n + j];
        }
    }
}

fn fillSpdTile(n: usize, seed_base: u32, a: []f32) void {
    var m: [batched_cholesky_max_n * batched_cholesky_max_n]f32 = undefined;
    var seed: u32 = seed_base | 1;
    for (m[0 .. n * n]) |*value| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        value.* = @as(f32, @floatFromInt(seed % 1000)) / 1000.0;
    }
    for (0..n) |i| {
        for (0..n) |j| {
            var sum: f32 = 0;
            for (0..n) |c| {
                sum += m[i * n + c] * m[j * n + c];
            }
            if (i == j) sum += @floatFromInt(n);
            a[i * n + j] = sum;
        }
    }
}

fn expectBatchedCholeskyMatchesHost(comptime n: usize, threads: u32) !void {
    const allocator = testing.allocator;
    const batch: usize = 40;
    const instance = BatchedCholesky{ .batch = batch, .n = n, .threads = threads };
    const blocks: u32 = @intCast(batchedCholeskyBlockCount(instance.batch, instance.threads));
    try testing.expect(blocks > 1);

    const a = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(a);
    for (0..batch) |b| {
        fillSpdTile(n, @intCast(b * 977 + 13), a[b * n * n ..][0 .. n * n]);
    }

    const expected = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(expected);
    for (0..batch) |b| {
        hostCholesky(n, a[b * n * n ..][0 .. n * n], expected[b * n * n ..][0 .. n * n]);
    }

    const l = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(l);
    @memset(l, -1);

    var graph = try BatchedCholeskyRuntimeFamilyF32.build(
        allocator,
        BatchedCholeskyRuntimeFamilyF32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, l),
        kernel.argumentBuffer(f32, a),
        kernel.argumentI32(@intCast(batch)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    try testing.expectEqualSlices(f32, expected, l);
}

test "linalg batched cholesky matches the host reference at every supported size" {
    try expectBatchedCholeskyMatchesHost(2, 32);
    try expectBatchedCholeskyMatchesHost(3, 32);
    try expectBatchedCholeskyMatchesHost(4, 32);
}

test "linalg batched cholesky propagates NaN for non-SPD tiles in band" {
    const allocator = testing.allocator;
    const n: usize = 3;
    const batch: usize = 2;
    const instance = BatchedCholesky{ .batch = batch, .n = n, .threads = 32 };

    var a = @as([(batch * n * n)]f32, @splat(0));
    fillSpdTile(n, 17, a[0 .. n * n]);
    fillSpdTile(n, 18, a[n * n ..][0 .. n * n]);
    a[n * n] = -4.0;

    var l = @as([(batch * n * n)]f32, @splat(-1));
    var graph = try BatchedCholeskyRuntimeFamilyF32.build(
        allocator,
        BatchedCholeskyRuntimeFamilyF32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, l[0..]),
        kernel.argumentBuffer(f32, a[0..]),
        kernel.argumentI32(@intCast(batch)),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    var expected_good: [n * n]f32 = undefined;
    hostCholesky(n, a[0 .. n * n], expected_good[0..]);
    try testing.expectEqualSlices(f32, expected_good[0..], l[0 .. n * n]);
    try testing.expect(std.math.isNan(l[n * n]));
    try testing.expect(std.math.isNan(l[n * n + n + 1]));
}

test "linalg batched cholesky identity and validity" {
    const allocator = testing.allocator;
    const instance = BatchedCholesky{ .batch = 5000, .n = 3, .threads = 64 };
    const target = try batchedCholeskyFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.linalg.batched_cholesky_family_3_64_f32", target);
    const entry_name = try batchedCholeskyFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    try testing.expectEqualStrings(
        "accy_kernel_linalg_batched_cholesky_family_3_64_f32",
        entry_name,
    );

    try testing.expect(batchedCholeskyInstanceValid(instance));
    try testing.expect(!batchedCholeskyInstanceValid(.{ .batch = 0, .n = 3, .threads = 64 }));
    try testing.expect(!batchedCholeskyInstanceValid(.{ .batch = 100, .n = 1, .threads = 64 }));
    try testing.expect(!batchedCholeskyInstanceValid(.{ .batch = 100, .n = 5, .threads = 64 }));
    try testing.expect(!batchedCholeskyInstanceValid(.{ .batch = 100, .n = 3, .threads = 0 }));
    try testing.expect(
        !batchedCholeskyInstanceValid(.{ .batch = std.math.maxInt(u64), .n = 3, .threads = 32 }),
    );

    const args = try batchedCholeskyRuntimeArguments(instance);
    try testing.expectEqual(@as(u32, 5000), args[0].u32);
}

pub const BatchedCholeskySolve = struct {
    batch: u64,
    n: u32 = 3,
    threads: u32 = 256,
    layout: TileLayout = .row_major,
    batch_axis: []const u8 = "b",
};

pub const batched_cholesky_solve_family_version: u32 = 1;

pub fn batchedCholeskySolveInstanceValid(instance: BatchedCholeskySolve) bool {
    if (instance.batch == 0) return false;
    if (instance.n < batched_cholesky_min_n or instance.n > batched_cholesky_max_n) return false;
    if (instance.threads == 0 or instance.threads > batched_cholesky_max_threads) return false;
    return extent_mod.blockCountWithinLimit(
        instance.batch,
        instance.threads,
        batched_cholesky_max_blocks,
    );
}

fn batched_cholesky_solve_body_active(inner: anytype, ctx: anytype) !void {
    const n: usize = @intCast(ctx.n);
    const tile = try inner.constantIndex(@intCast(n * n));
    const tile_base = try inner.mul(ctx.system, tile);
    const width = try inner.constantIndex(@intCast(n));
    const vector_base = try inner.mul(ctx.system, width);

    var l_values: [batched_cholesky_max_n][batched_cholesky_max_n]kernel.Value = undefined;
    for (0..n) |i| {
        for (0..i + 1) |j| {
            const index = try factorElementIndex(
                inner,
                ctx.layout,
                tile_base,
                ctx.batch_index,
                ctx.system,
                i * n + j,
            );
            const loaded = try ctx.args.param(.l).load(inner, index);
            l_values[i][j] = loaded.raw();
        }
    }

    var solution: [batched_cholesky_max_n]kernel.Value = undefined;
    for (0..n) |i| {
        const index = try factorElementIndex(
            inner,
            ctx.layout,
            vector_base,
            ctx.batch_index,
            ctx.system,
            i,
        );
        const loaded = try ctx.args.param(.rhs).load(inner, index);
        var sum = loaded.raw();
        for (0..i) |j| {
            sum = try inner.sub(sum, try inner.mul(l_values[i][j], solution[j]));
        }
        solution[i] = try inner.div(sum, l_values[i][i]);
    }

    var row = n;
    while (row > 0) {
        row -= 1;
        var sum = solution[row];
        for (row + 1..n) |j| {
            sum = try inner.sub(sum, try inner.mul(l_values[j][row], solution[j]));
        }
        solution[row] = try inner.div(sum, l_values[row][row]);
    }

    for (0..n) |i| {
        const index = try factorElementIndex(
            inner,
            ctx.layout,
            vector_base,
            ctx.batch_index,
            ctx.system,
            i,
        );
        try ctx.args.param(.x).store(inner, solution[i], index);
    }
}

fn batchedCholeskySolveBody(k: anytype, spec: BatchedCholeskySolve, args: anytype) !void {
    if (!batchedCholeskySolveInstanceValid(spec)) {
        return error.UnsupportedBatchedCholeskySolveInstance;
    }
    const system = try k.globalId(.x);
    const batch = try k.castIndex(args.param(.batch).raw());
    const active = try k.compare(.lt, system, batch);
    try k.guardDo(active, .{
        .args = args,
        .system = system,
        .n = spec.n,
        .layout = spec.layout,
        .batch_index = batch,
    }, batched_cholesky_solve_body_active);
}

fn batchedCholeskySolveFamilySchedule(
    instance: BatchedCholeskySolve,
) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn batchedCholeskySolveRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_linalg_batched_cholesky_solve_runtime_f32",
        .parameters = .{
            .x = kernel.dynamicBuffer(.f32),
            .l = kernel.dynamicBuffer(.f32),
            .rhs = kernel.dynamicBuffer(.f32),
            .batch = kernel.scalar(.i32),
        },
        .Instance = BatchedCholeskySolve,
        .schedule = batchedCholeskySolveFamilySchedule,
        .body = batchedCholeskySolveBody,
    });
}

pub const BatchedCholeskySolveRuntimeFamilyF32 = batchedCholeskySolveRuntimeFamily();

pub fn batchedCholeskySolveFamilyTarget(
    allocator: std.mem.Allocator,
    instance: BatchedCholeskySolve,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.linalg.batched_cholesky_solve_family_{d}_{d}_{s}f32",
        .{ instance.n, instance.threads, layoutTargetSegment(instance.layout) },
    );
}

pub fn batchedCholeskySolveFamilyEntryName(
    allocator: std.mem.Allocator,
    instance: BatchedCholeskySolve,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_linalg_batched_cholesky_solve_family_{d}_{d}_{s}f32",
        .{ instance.n, instance.threads, layoutTargetSegment(instance.layout) },
    );
}

pub fn batchedCholeskySolveRuntimeArguments(
    instance: BatchedCholeskySolve,
) ![1]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.batch) },
    };
}

fn hostCholeskySolve(n: usize, l: []const f32, rhs: []const f32, x: []f32) void {
    var solution: [batched_cholesky_max_n]f32 = undefined;
    for (0..n) |i| {
        var sum = rhs[i];
        for (0..i) |j| {
            sum -= l[i * n + j] * solution[j];
        }
        solution[i] = sum / l[i * n + i];
    }
    var row = n;
    while (row > 0) {
        row -= 1;
        var sum = solution[row];
        for (row + 1..n) |j| {
            sum -= l[j * n + row] * solution[j];
        }
        solution[row] = sum / l[row * n + row];
    }
    for (0..n) |i| {
        x[i] = solution[i];
    }
}

fn expectBatchedCholeskySolveMatchesHost(comptime n: usize, threads: u32) !void {
    const allocator = testing.allocator;
    const batch: usize = 40;
    const instance = BatchedCholeskySolve{ .batch = batch, .n = n, .threads = threads };
    const blocks: u32 = @intCast(batchedCholeskyBlockCount(instance.batch, instance.threads));
    try testing.expect(blocks > 1);

    const a = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(a);
    const l = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(l);
    const rhs = try allocator.alloc(f32, batch * n);
    defer allocator.free(rhs);
    var seed: u32 = 0x51f15eed;
    for (0..batch) |b| {
        fillSpdTile(n, @intCast(b * 977 + 13), a[b * n * n ..][0 .. n * n]);
        hostCholesky(n, a[b * n * n ..][0 .. n * n], l[b * n * n ..][0 .. n * n]);
        for (rhs[b * n ..][0..n]) |*value| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            value.* = @as(f32, @floatFromInt(seed % 1000)) / 500.0 - 1.0;
        }
    }

    const expected = try allocator.alloc(f32, batch * n);
    defer allocator.free(expected);
    for (0..batch) |b| {
        hostCholeskySolve(
            n,
            l[b * n * n ..][0 .. n * n],
            rhs[b * n ..][0..n],
            expected[b * n ..][0..n],
        );
    }

    const x = try allocator.alloc(f32, batch * n);
    defer allocator.free(x);
    @memset(x, -1);

    var graph = try BatchedCholeskySolveRuntimeFamilyF32.build(
        allocator,
        BatchedCholeskySolveRuntimeFamilyF32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, x),
        kernel.argumentBuffer(f32, l),
        kernel.argumentBuffer(f32, rhs),
        kernel.argumentI32(@intCast(batch)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    try testing.expectEqualSlices(f32, expected, x);
}

test "linalg batched cholesky solve matches the host reference at every supported size" {
    try expectBatchedCholeskySolveMatchesHost(2, 32);
    try expectBatchedCholeskySolveMatchesHost(3, 32);
    try expectBatchedCholeskySolveMatchesHost(4, 32);
}

test "linalg batched cholesky solve identity and validity" {
    const allocator = testing.allocator;
    const instance = BatchedCholeskySolve{ .batch = 5000, .n = 3, .threads = 64 };
    const target = try batchedCholeskySolveFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings(
        "accy.kernel.linalg.batched_cholesky_solve_family_3_64_f32",
        target,
    );

    try testing.expect(batchedCholeskySolveInstanceValid(instance));
    try testing.expect(!batchedCholeskySolveInstanceValid(.{ .batch = 0, .n = 3, .threads = 64 }));
    try testing.expect(
        !batchedCholeskySolveInstanceValid(.{ .batch = 100, .n = 5, .threads = 64 }),
    );
    try testing.expect(!batchedCholeskySolveInstanceValid(
        .{ .batch = std.math.maxInt(u64), .n = 3, .threads = 32 },
    ));

    const args = try batchedCholeskySolveRuntimeArguments(instance);
    try testing.expectEqual(@as(u32, 5000), args[0].u32);
}

pub const BatchedInverse = struct {
    batch: u64,
    n: u32 = 3,
    threads: u32 = 256,
    layout: TileLayout = .row_major,
    batch_axis: []const u8 = "b",
};

pub const batched_inverse_family_version: u32 = 1;

pub fn batchedInverseInstanceValid(instance: BatchedInverse) bool {
    if (instance.batch == 0) return false;
    if (instance.n < batched_cholesky_min_n or instance.n > batched_cholesky_max_n) return false;
    if (instance.threads == 0 or instance.threads > batched_cholesky_max_threads) return false;
    return extent_mod.blockCountWithinLimit(
        instance.batch,
        instance.threads,
        batched_cholesky_max_blocks,
    );
}

fn batched_inverse_body_active(inner: anytype, ctx: anytype) !void {
    const n: usize = @intCast(ctx.n);
    const tile = try inner.constantIndex(@intCast(n * n));
    const base = try inner.mul(ctx.system, tile);

    var a_values: [batched_cholesky_max_n][batched_cholesky_max_n]kernel.Value = undefined;
    var inv_values: [batched_cholesky_max_n][batched_cholesky_max_n]kernel.Value = undefined;
    const zero = try inner.constantFloat(.f32, 0);
    const one = try inner.constantFloat(.f32, 1);
    for (0..n) |i| {
        for (0..n) |j| {
            const index = try factorElementIndex(
                inner,
                ctx.layout,
                base,
                ctx.batch_index,
                ctx.system,
                i * n + j,
            );
            const loaded = try ctx.args.param(.a).load(inner, index);
            a_values[i][j] = loaded.raw();
            inv_values[i][j] = if (i == j) one else zero;
        }
    }

    for (0..n) |pivot_index| {
        const pivot = a_values[pivot_index][pivot_index];
        for (0..n) |j| {
            a_values[pivot_index][j] = try inner.div(a_values[pivot_index][j], pivot);
            inv_values[pivot_index][j] = try inner.div(inv_values[pivot_index][j], pivot);
        }
        for (0..n) |row| {
            if (row == pivot_index) continue;
            const factor = a_values[row][pivot_index];
            for (0..n) |j| {
                a_values[row][j] = try inner.sub(
                    a_values[row][j],
                    try inner.mul(factor, a_values[pivot_index][j]),
                );
                inv_values[row][j] = try inner.sub(
                    inv_values[row][j],
                    try inner.mul(factor, inv_values[pivot_index][j]),
                );
            }
        }
    }

    for (0..n) |i| {
        for (0..n) |j| {
            const index = try factorElementIndex(
                inner,
                ctx.layout,
                base,
                ctx.batch_index,
                ctx.system,
                i * n + j,
            );
            try ctx.args.param(.inv).store(inner, inv_values[i][j], index);
        }
    }
}

fn batchedInverseBody(k: anytype, spec: BatchedInverse, args: anytype) !void {
    if (!batchedInverseInstanceValid(spec)) return error.UnsupportedBatchedInverseInstance;
    const system = try k.globalId(.x);
    const batch = try k.castIndex(args.param(.batch).raw());
    const active = try k.compare(.lt, system, batch);
    try k.guardDo(active, .{
        .args = args,
        .system = system,
        .n = spec.n,
        .layout = spec.layout,
        .batch_index = batch,
    }, batched_inverse_body_active);
}

fn batchedInverseFamilySchedule(instance: BatchedInverse) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn batchedInverseRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_linalg_batched_inverse_runtime_f32",
        .parameters = .{
            .inv = kernel.dynamicBuffer(.f32),
            .a = kernel.dynamicBuffer(.f32),
            .batch = kernel.scalar(.i32),
        },
        .Instance = BatchedInverse,
        .schedule = batchedInverseFamilySchedule,
        .body = batchedInverseBody,
    });
}

pub const BatchedInverseRuntimeFamilyF32 = batchedInverseRuntimeFamily();

pub fn batchedInverseFamilyTarget(allocator: std.mem.Allocator, instance: BatchedInverse) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.linalg.batched_inverse_family_{d}_{d}_{s}f32",
        .{ instance.n, instance.threads, layoutTargetSegment(instance.layout) },
    );
}

pub fn batchedInverseFamilyEntryName(allocator: std.mem.Allocator, instance: BatchedInverse) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_linalg_batched_inverse_family_{d}_{d}_{s}f32",
        .{ instance.n, instance.threads, layoutTargetSegment(instance.layout) },
    );
}

pub fn batchedInverseRuntimeArguments(instance: BatchedInverse) ![1]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.batch) },
    };
}

fn expectBatchedInverseResidual(comptime n: usize, threads: u32) !void {
    const allocator = testing.allocator;
    const batch: usize = 40;
    const instance = BatchedInverse{ .batch = batch, .n = n, .threads = threads };
    const blocks: u32 = @intCast(batchedCholeskyBlockCount(instance.batch, instance.threads));
    try testing.expect(blocks > 1);

    const a = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(a);
    for (0..batch) |b| {
        fillSpdTile(n, @intCast(b * 977 + 13), a[b * n * n ..][0 .. n * n]);
    }

    const inv = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(inv);
    @memset(inv, -1);

    var graph = try BatchedInverseRuntimeFamilyF32.build(
        allocator,
        BatchedInverseRuntimeFamilyF32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, inv),
        kernel.argumentBuffer(f32, a),
        kernel.argumentI32(@intCast(batch)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    for (0..batch) |b| {
        const a_tile = a[b * n * n ..][0 .. n * n];
        const inv_tile = inv[b * n * n ..][0 .. n * n];
        for (0..n) |i| {
            for (0..n) |j| {
                var product: f32 = 0;
                for (0..n) |c| {
                    product += a_tile[i * n + c] * inv_tile[c * n + j];
                }
                const expected: f32 = if (i == j) 1 else 0;
                try testing.expectApproxEqAbs(expected, product, 0.001);
            }
        }
    }
}

test "linalg batched inverse residual matches identity at every supported size" {
    try expectBatchedInverseResidual(2, 32);
    try expectBatchedInverseResidual(3, 32);
    try expectBatchedInverseResidual(4, 32);
}

test "linalg batched inverse interleaved layout matches residual contract" {
    const allocator = testing.allocator;
    const n: usize = 3;
    const batch: usize = 40;
    const instance = BatchedInverse{
        .batch = batch,
        .n = n,
        .threads = 32,
        .layout = .interleaved,
    };
    const blocks: u32 = @intCast(batchedCholeskyBlockCount(batch, instance.threads));

    const a = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(a);
    for (0..batch) |b| {
        fillSpdTile(n, @intCast(b * 977 + 13), a[b * n * n ..][0 .. n * n]);
    }

    const a_interleaved = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(a_interleaved);
    packInterleavedTiles(n, batch, a, a_interleaved);

    const inv_interleaved = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(inv_interleaved);
    @memset(inv_interleaved, -1);

    var graph = try BatchedInverseRuntimeFamilyF32.build(
        allocator,
        BatchedInverseRuntimeFamilyF32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, inv_interleaved),
        kernel.argumentBuffer(f32, a_interleaved),
        kernel.argumentI32(@intCast(batch)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    for (0..batch) |b| {
        const a_tile = a[b * n * n ..][0 .. n * n];
        for (0..n) |i| {
            for (0..n) |j| {
                var product: f32 = 0;
                for (0..n) |c| {
                    product += a_tile[i * n + c] * inv_interleaved[(c * n + j) * batch + b];
                }
                const expected: f32 = if (i == j) 1 else 0;
                try testing.expectApproxEqAbs(expected, product, 0.001);
            }
        }
    }
}

test "linalg batched inverse identity and validity" {
    const allocator = testing.allocator;
    const instance = BatchedInverse{ .batch = 5000, .n = 3, .threads = 64 };
    const target = try batchedInverseFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.linalg.batched_inverse_family_3_64_f32", target);
    const entry_name = try batchedInverseFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    try testing.expectEqualStrings(
        "accy_kernel_linalg_batched_inverse_family_3_64_f32",
        entry_name,
    );

    try testing.expect(batchedInverseInstanceValid(instance));
    try testing.expect(!batchedInverseInstanceValid(.{ .batch = 0, .n = 3, .threads = 64 }));
    try testing.expect(!batchedInverseInstanceValid(.{ .batch = 100, .n = 1, .threads = 64 }));
    try testing.expect(!batchedInverseInstanceValid(.{ .batch = 100, .n = 5, .threads = 64 }));
    try testing.expect(!batchedInverseInstanceValid(.{ .batch = 100, .n = 3, .threads = 0 }));
    try testing.expect(
        !batchedInverseInstanceValid(.{ .batch = std.math.maxInt(u64), .n = 3, .threads = 32 }),
    );

    const args = try batchedInverseRuntimeArguments(instance);
    try testing.expectEqual(@as(u32, 5000), args[0].u32);
}

pub const batched_cholesky_row_axis = "i";
pub const batched_cholesky_col_axis = "j";

fn factorBatchBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

fn factorTileBounds() shape.Bounds {
    return .{ .min = batched_cholesky_min_n, .max = batched_cholesky_max_n };
}

pub fn batchedCholeskyShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: BatchedCholesky,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "batched_cholesky");
    errdefer builder.deinit();
    const batch_symbol = try builder.symbol(instance.batch_axis);
    const row = try builder.symbol(batched_cholesky_row_axis);
    const col = try builder.symbol(batched_cholesky_col_axis);
    const batch_expr = try builder.symbolExpression(batch_symbol);
    const row_expr = try builder.symbolExpression(row);
    const col_expr = try builder.symbolExpression(col);
    _ = try builder.tensor("l", &.{ batch_expr, row_expr, col_expr });
    _ = try builder.tensor("a", &.{ batch_expr, row_expr, col_expr });
    try builder.assumeBounds(batch_expr, factorBatchBounds());
    try builder.assumeBounds(row_expr, factorTileBounds());
    try builder.assumeBounds(col_expr, factorTileBounds());
    return builder.finish();
}

pub fn batchedCholeskyFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: BatchedCholesky,
) !u64 {
    var family = try batchedCholeskyShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn batchedCholeskyFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: BatchedCholesky,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 1);
    inputs[0] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.batch_axis,
        instance.batch,
        batched_cholesky_row_axis,
        instance.n,
        batched_cholesky_col_axis,
        instance.n,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.batch_axis,
        instance.batch,
        batched_cholesky_row_axis,
        instance.n,
        batched_cholesky_col_axis,
        instance.n,
    );

    owned.value = .{
        .dtype = .f32,
        .operation = .{ .linalg = .batched_cholesky },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.batch_axis,
            instance.batch,
            instance.threads,
        ),
        .layout = @tagName(instance.layout),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try batchedCholeskyShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn batchedCholeskyInstanceFromSpecialization(
    specialization: entry.Specialization,
) ?BatchedCholesky {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .linalg = .batched_cholesky })) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .f32) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const tiles = specialization.outputs[0];
    if (tiles.axes.len != 3) return null;
    const batch_axis = tiles.axes[0].name;
    const batch = tiles.axes[0].extent;
    const tile_extent = tiles.axes[1].extent;
    if (!factorTileShapeMatches(tiles, batch_axis, batch, tile_extent)) return null;
    if (!factorTileShapeMatches(specialization.inputs[0], batch_axis, batch, tile_extent)) {
        return null;
    }
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const n = std.math.cast(u32, tile_extent) orelse return null;
    const layout_name = specialization.layout orelse return null;
    const layout = std.meta.stringToEnum(TileLayout, layout_name) orelse return null;
    const instance = BatchedCholesky{
        .batch = batch,
        .n = n,
        .threads = launch.threadgroup[0],
        .layout = layout,
        .batch_axis = batch_axis,
    };
    if (!batchedCholeskyInstanceValid(instance)) return null;
    return instance;
}

fn factorAxisMatches(axis: entry.Axis, name: []const u8, extent: u64) bool {
    if (name.len == 0) return false;
    if (!std.mem.eql(u8, axis.name, name)) return false;
    return axis.extent == extent;
}

fn factorTileShapeMatches(candidate: entry.Shape, batch_axis: []const u8, batch: u64, n: u64) bool {
    if (candidate.axes.len != 3) return false;
    return factorAxisMatches(candidate.axes[0], batch_axis, batch) and
        factorAxisMatches(candidate.axes[1], batched_cholesky_row_axis, n) and
        factorAxisMatches(candidate.axes[2], batched_cholesky_col_axis, n);
}

fn factorVectorShapeMatches(
    candidate: entry.Shape,
    batch_axis: []const u8,
    batch: u64,
    n: u64,
) bool {
    if (candidate.axes.len != 2) return false;
    return factorAxisMatches(candidate.axes[0], batch_axis, batch) and
        factorAxisMatches(candidate.axes[1], batched_cholesky_row_axis, n);
}

pub fn batchedCholeskyShapeProfileDimensions(
    instance: BatchedCholesky,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.batch_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = factorBatchBounds(),
        },
    };
}

fn factorDerivedLaunch(threads: u32) !artifact_product.KernelCallLaunch {
    if (threads == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ threads, 1, 1 },
    } };
}

pub fn createBatchedCholeskyFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: BatchedCholesky,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!batchedCholeskyInstanceValid(instance)) return error.InvalidKernelLibraryEntry;
    const target = try batchedCholeskyFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try batchedCholeskyFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try batchedCholeskyFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = batchedCholeskyShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "batched_cholesky",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try BatchedCholeskyRuntimeFamilyF32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = batched_cholesky_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try factorDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn batchedCholeskySolveShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: BatchedCholeskySolve,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "batched_cholesky_solve");
    errdefer builder.deinit();
    const batch_symbol = try builder.symbol(instance.batch_axis);
    const row = try builder.symbol(batched_cholesky_row_axis);
    const col = try builder.symbol(batched_cholesky_col_axis);
    const batch_expr = try builder.symbolExpression(batch_symbol);
    const row_expr = try builder.symbolExpression(row);
    const col_expr = try builder.symbolExpression(col);
    _ = try builder.tensor("x", &.{ batch_expr, row_expr });
    _ = try builder.tensor("l", &.{ batch_expr, row_expr, col_expr });
    _ = try builder.tensor("rhs", &.{ batch_expr, row_expr });
    try builder.assumeBounds(batch_expr, factorBatchBounds());
    try builder.assumeBounds(row_expr, factorTileBounds());
    try builder.assumeBounds(col_expr, factorTileBounds());
    return builder.finish();
}

pub fn batchedCholeskySolveFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: BatchedCholeskySolve,
) !u64 {
    var family = try batchedCholeskySolveShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn batchedCholeskySolveFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: BatchedCholeskySolve,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.batch_axis,
        instance.batch,
        batched_cholesky_row_axis,
        instance.n,
        batched_cholesky_col_axis,
        instance.n,
    );
    inputs[1] = try entry.runtimeShape2D(
        lifetime_allocator,
        instance.batch_axis,
        instance.batch,
        batched_cholesky_row_axis,
        instance.n,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape2D(
        lifetime_allocator,
        instance.batch_axis,
        instance.batch,
        batched_cholesky_row_axis,
        instance.n,
    );

    owned.value = .{
        .dtype = .f32,
        .operation = .{ .linalg = .batched_cholesky_solve },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.batch_axis,
            instance.batch,
            instance.threads,
        ),
        .layout = @tagName(instance.layout),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try batchedCholeskySolveShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn batchedCholeskySolveInstanceFromSpecialization(
    specialization: entry.Specialization,
) ?BatchedCholeskySolve {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .linalg = .batched_cholesky_solve })) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .f32) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const tiles = specialization.inputs[0];
    const rhs = specialization.inputs[1];
    const solution = specialization.outputs[0];
    if (solution.axes.len != 2) return null;
    const batch_axis = solution.axes[0].name;
    const batch = solution.axes[0].extent;
    const tile_extent = solution.axes[1].extent;
    if (!factorVectorShapeMatches(solution, batch_axis, batch, tile_extent)) return null;
    if (!factorTileShapeMatches(tiles, batch_axis, batch, tile_extent)) return null;
    if (!factorVectorShapeMatches(rhs, batch_axis, batch, tile_extent)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const n = std.math.cast(u32, tile_extent) orelse return null;
    const layout_name = specialization.layout orelse return null;
    const layout = std.meta.stringToEnum(TileLayout, layout_name) orelse return null;
    const instance = BatchedCholeskySolve{
        .batch = batch,
        .n = n,
        .threads = launch.threadgroup[0],
        .layout = layout,
        .batch_axis = batch_axis,
    };
    if (!batchedCholeskySolveInstanceValid(instance)) return null;
    return instance;
}

pub fn batchedCholeskySolveShapeProfileDimensions(
    instance: BatchedCholeskySolve,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.batch_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = factorBatchBounds(),
        },
    };
}

pub fn createBatchedCholeskySolveFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: BatchedCholeskySolve,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!batchedCholeskySolveInstanceValid(instance)) return error.InvalidKernelLibraryEntry;
    const target = try batchedCholeskySolveFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try batchedCholeskySolveFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try batchedCholeskySolveFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = batchedCholeskySolveShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "batched_cholesky_solve",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try BatchedCholeskySolveRuntimeFamilyF32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = batched_cholesky_solve_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try factorDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn batchedInverseShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: BatchedInverse,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "batched_inverse");
    errdefer builder.deinit();
    const batch_symbol = try builder.symbol(instance.batch_axis);
    const row = try builder.symbol(batched_cholesky_row_axis);
    const col = try builder.symbol(batched_cholesky_col_axis);
    const batch_expr = try builder.symbolExpression(batch_symbol);
    const row_expr = try builder.symbolExpression(row);
    const col_expr = try builder.symbolExpression(col);
    _ = try builder.tensor("inv", &.{ batch_expr, row_expr, col_expr });
    _ = try builder.tensor("a", &.{ batch_expr, row_expr, col_expr });
    try builder.assumeBounds(batch_expr, factorBatchBounds());
    try builder.assumeBounds(row_expr, factorTileBounds());
    try builder.assumeBounds(col_expr, factorTileBounds());
    return builder.finish();
}

pub fn batchedInverseFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: BatchedInverse,
) !u64 {
    var family = try batchedInverseShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn batchedInverseFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: BatchedInverse,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 1);
    inputs[0] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.batch_axis,
        instance.batch,
        batched_cholesky_row_axis,
        instance.n,
        batched_cholesky_col_axis,
        instance.n,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.batch_axis,
        instance.batch,
        batched_cholesky_row_axis,
        instance.n,
        batched_cholesky_col_axis,
        instance.n,
    );

    owned.value = .{
        .dtype = .f32,
        .operation = .{ .linalg = .batched_inverse },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.batch_axis,
            instance.batch,
            instance.threads,
        ),
        .layout = @tagName(instance.layout),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try batchedInverseShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn batchedInverseInstanceFromSpecialization(
    specialization: entry.Specialization,
) ?BatchedInverse {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .linalg = .batched_inverse })) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .f32) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const tiles = specialization.outputs[0];
    if (tiles.axes.len != 3) return null;
    const batch_axis = tiles.axes[0].name;
    const batch = tiles.axes[0].extent;
    const tile_extent = tiles.axes[1].extent;
    if (!factorTileShapeMatches(tiles, batch_axis, batch, tile_extent)) return null;
    if (!factorTileShapeMatches(specialization.inputs[0], batch_axis, batch, tile_extent)) {
        return null;
    }
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const n = std.math.cast(u32, tile_extent) orelse return null;
    const layout_name = specialization.layout orelse return null;
    const layout = std.meta.stringToEnum(TileLayout, layout_name) orelse return null;
    const instance = BatchedInverse{
        .batch = batch,
        .n = n,
        .threads = launch.threadgroup[0],
        .layout = layout,
        .batch_axis = batch_axis,
    };
    if (!batchedInverseInstanceValid(instance)) return null;
    return instance;
}

pub fn batchedInverseShapeProfileDimensions(
    instance: BatchedInverse,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.batch_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = factorBatchBounds(),
        },
    };
}

pub fn createBatchedInverseFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: BatchedInverse,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!batchedInverseInstanceValid(instance)) return error.InvalidKernelLibraryEntry;
    const target = try batchedInverseFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try batchedInverseFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try batchedInverseFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = batchedInverseShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "batched_inverse",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try BatchedInverseRuntimeFamilyF32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = batched_inverse_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try factorDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

test "linalg batched factor specializations round-trip their instances" {
    const allocator = testing.allocator;

    var cholesky_owned = try batchedCholeskyFamilySpecialization(
        allocator,
        .{ .batch = 5000, .n = 3, .threads = 64 },
    );
    defer cholesky_owned.deinit();
    try testing.expect(cholesky_owned.value.operationIs(.{ .linalg = .batched_cholesky }));
    const cholesky_recovered = batchedCholeskyInstanceFromSpecialization(
        cholesky_owned.value,
    ) orelse {
        return error.TestExpectedBatchedCholeskyInstance;
    };
    try testing.expectEqual(@as(u64, 5000), cholesky_recovered.batch);
    try testing.expectEqual(@as(u32, 3), cholesky_recovered.n);
    try testing.expectEqual(@as(u32, 64), cholesky_recovered.threads);
    try testing.expectEqual(
        @as(?BatchedCholesky, null),
        batchedCholeskyInstanceFromSpecialization(.{}),
    );

    var solve_owned = try batchedCholeskySolveFamilySpecialization(
        allocator,
        .{ .batch = 5000, .n = 4, .threads = 32 },
    );
    defer solve_owned.deinit();
    const solve_recovered = batchedCholeskySolveInstanceFromSpecialization(solve_owned.value) orelse
        {
            return error.TestExpectedBatchedCholeskySolveInstance;
        };
    try testing.expectEqual(@as(u64, 5000), solve_recovered.batch);
    try testing.expectEqual(@as(u32, 4), solve_recovered.n);
    try testing.expectEqual(@as(u32, 32), solve_recovered.threads);
    try testing.expectEqual(
        @as(?BatchedCholeskySolve, null),
        batchedCholeskySolveInstanceFromSpecialization(cholesky_owned.value),
    );
    try testing.expectEqual(
        @as(?BatchedCholesky, null),
        batchedCholeskyInstanceFromSpecialization(solve_owned.value),
    );

    var inverse_owned = try batchedInverseFamilySpecialization(
        allocator,
        .{ .batch = 4096, .n = 2, .threads = 128 },
    );
    defer inverse_owned.deinit();
    const inverse_recovered = batchedInverseInstanceFromSpecialization(inverse_owned.value) orelse {
        return error.TestExpectedBatchedInverseInstance;
    };
    try testing.expectEqual(@as(u64, 4096), inverse_recovered.batch);
    try testing.expectEqual(@as(u32, 2), inverse_recovered.n);
    try testing.expectEqual(@as(u32, 128), inverse_recovered.threads);
    try testing.expectEqual(
        @as(?BatchedInverse, null),
        batchedInverseInstanceFromSpecialization(cholesky_owned.value),
    );
}

test "linalg batched factor specializations reject malformed tensor facts" {
    const allocator = testing.allocator;

    {
        var owned = try batchedCholeskyFamilySpecialization(
            allocator,
            .{ .batch = 5000, .n = 3, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        owned.value.inputs = &.{
            try entry.runtimeShape3D(lifetime_allocator, "b", 4096, "i", 3, "j", 3),
        };
        try testing.expectEqual(
            @as(?BatchedCholesky, null),
            batchedCholeskyInstanceFromSpecialization(owned.value),
        );
    }

    {
        var owned = try batchedCholeskyFamilySpecialization(
            allocator,
            .{ .batch = 5000, .n = 3, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        owned.value.outputs = &.{
            try entry.runtimeShape3D(lifetime_allocator, "b", 5000, "row", 3, "j", 3),
        };
        try testing.expectEqual(
            @as(?BatchedCholesky, null),
            batchedCholeskyInstanceFromSpecialization(owned.value),
        );
    }

    {
        var owned = try batchedCholeskySolveFamilySpecialization(
            allocator,
            .{ .batch = 5000, .n = 3, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
        inputs[0] = owned.value.inputs[0];
        inputs[1] = try entry.runtimeShape2D(lifetime_allocator, "b", 4096, "i", 3);
        owned.value.inputs = inputs;
        try testing.expectEqual(
            @as(?BatchedCholeskySolve, null),
            batchedCholeskySolveInstanceFromSpecialization(owned.value),
        );
    }

    {
        var owned = try batchedCholeskySolveFamilySpecialization(
            allocator,
            .{ .batch = 5000, .n = 3, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
        inputs[0] = owned.value.inputs[0];
        inputs[1] = try entry.runtimeShape2D(lifetime_allocator, "b", 5000, "i", 4);
        owned.value.inputs = inputs;
        try testing.expectEqual(
            @as(?BatchedCholeskySolve, null),
            batchedCholeskySolveInstanceFromSpecialization(owned.value),
        );
    }

    {
        var owned = try batchedInverseFamilySpecialization(
            allocator,
            .{ .batch = 5000, .n = 3, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        owned.value.outputs = &.{
            try entry.runtimeShape3D(lifetime_allocator, "b", 5000, "i", 3, "k", 3),
        };
        try testing.expectEqual(
            @as(?BatchedInverse, null),
            batchedInverseInstanceFromSpecialization(owned.value),
        );
    }
}

/// A caller uses this to rearrange a batch of square matrices on the host before a factorization
/// kernel reads them: the function copies `batch` matrices of `n` by `n` values, stored one matrix
/// after another in row order, into an interleaved layout, where the same element of every matrix
/// sits side by side. Element `slot` of matrix `b` lands at index `slot * batch + b`. The caller
/// sizes both slices to hold `n * n * batch` values, and the function neither checks those lengths
/// nor allocates.
pub fn packInterleavedTiles(
    n: usize,
    batch: usize,
    row_major: []const f32,
    interleaved: []f32,
) void {
    for (0..batch) |b| {
        for (0..n * n) |slot| {
            interleaved[slot * batch + b] = row_major[b * n * n + slot];
        }
    }
}

/// A caller uses this to rearrange a batch of vectors, such as right-hand sides for a solve: the
/// function copies `batch` vectors of `n` values, stored one vector after another, into an
/// interleaved layout, where the same element of every vector sits side by side. Element `slot` of
/// vector `b` lands at index `slot * batch + b`. The caller sizes both slices to hold `n * batch`
/// values, and the function neither checks those lengths nor allocates.
pub fn packInterleavedVectors(
    n: usize,
    batch: usize,
    row_major: []const f32,
    interleaved: []f32,
) void {
    for (0..batch) |b| {
        for (0..n) |slot| {
            interleaved[slot * batch + b] = row_major[b * n + slot];
        }
    }
}

test "linalg batched cholesky interleaved layout matches the row-major results" {
    const allocator = testing.allocator;
    const n: usize = 3;
    const batch: usize = 40;
    const instance = BatchedCholesky{
        .batch = batch,
        .n = n,
        .threads = 32,
        .layout = .interleaved,
    };
    const blocks: u32 = @intCast(batchedCholeskyBlockCount(batch, instance.threads));

    const a = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(a);
    for (0..batch) |b| {
        fillSpdTile(n, @intCast(b * 977 + 13), a[b * n * n ..][0 .. n * n]);
    }
    const expected = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(expected);
    for (0..batch) |b| {
        hostCholesky(n, a[b * n * n ..][0 .. n * n], expected[b * n * n ..][0 .. n * n]);
    }

    const a_interleaved = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(a_interleaved);
    packInterleavedTiles(n, batch, a, a_interleaved);
    const expected_interleaved = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(expected_interleaved);
    packInterleavedTiles(n, batch, expected, expected_interleaved);

    const l = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(l);
    @memset(l, -1);

    var graph = try BatchedCholeskyRuntimeFamilyF32.build(
        allocator,
        BatchedCholeskyRuntimeFamilyF32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, l),
        kernel.argumentBuffer(f32, a_interleaved),
        kernel.argumentI32(@intCast(batch)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    try testing.expectEqualSlices(f32, expected_interleaved, l);
}

test "linalg batched cholesky solve interleaved layout matches the row-major results" {
    const allocator = testing.allocator;
    const n: usize = 3;
    const batch: usize = 40;
    const instance = BatchedCholeskySolve{
        .batch = batch,
        .n = n,
        .threads = 32,
        .layout = .interleaved,
    };
    const blocks: u32 = @intCast(batchedCholeskyBlockCount(batch, instance.threads));

    const a = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(a);
    const l_row = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(l_row);
    const rhs_row = try allocator.alloc(f32, batch * n);
    defer allocator.free(rhs_row);
    var seed: u32 = 0x1a40a75d;
    for (0..batch) |b| {
        fillSpdTile(n, @intCast(b * 977 + 13), a[b * n * n ..][0 .. n * n]);
        hostCholesky(n, a[b * n * n ..][0 .. n * n], l_row[b * n * n ..][0 .. n * n]);
        for (rhs_row[b * n ..][0..n]) |*value| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            value.* = @as(f32, @floatFromInt(seed % 1000)) / 500.0 - 1.0;
        }
    }
    const expected_row = try allocator.alloc(f32, batch * n);
    defer allocator.free(expected_row);
    for (0..batch) |b| {
        hostCholeskySolve(
            n,
            l_row[b * n * n ..][0 .. n * n],
            rhs_row[b * n ..][0..n],
            expected_row[b * n ..][0..n],
        );
    }

    const l_interleaved = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(l_interleaved);
    packInterleavedTiles(n, batch, l_row, l_interleaved);
    const rhs_interleaved = try allocator.alloc(f32, batch * n);
    defer allocator.free(rhs_interleaved);
    packInterleavedVectors(n, batch, rhs_row, rhs_interleaved);
    const expected_interleaved = try allocator.alloc(f32, batch * n);
    defer allocator.free(expected_interleaved);
    packInterleavedVectors(n, batch, expected_row, expected_interleaved);

    const x = try allocator.alloc(f32, batch * n);
    defer allocator.free(x);
    @memset(x, -1);

    var graph = try BatchedCholeskySolveRuntimeFamilyF32.build(
        allocator,
        BatchedCholeskySolveRuntimeFamilyF32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, x),
        kernel.argumentBuffer(f32, l_interleaved),
        kernel.argumentBuffer(f32, rhs_interleaved),
        kernel.argumentI32(@intCast(batch)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    try testing.expectEqualSlices(f32, expected_interleaved, x);
}

test "linalg batched factor layout rides identity and round-trips" {
    const allocator = testing.allocator;
    const instance = BatchedCholesky{
        .batch = 5000,
        .n = 3,
        .threads = 64,
        .layout = .interleaved,
    };
    const target = try batchedCholeskyFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings(
        "accy.kernel.linalg.batched_cholesky_family_3_64_il_f32",
        target,
    );

    var owned = try batchedCholeskyFamilySpecialization(allocator, instance);
    defer owned.deinit();
    try testing.expect(owned.value.layoutIs("interleaved"));
    const recovered = batchedCholeskyInstanceFromSpecialization(owned.value) orelse {
        return error.TestExpectedBatchedCholeskyInstance;
    };
    try testing.expectEqual(TileLayout.interleaved, recovered.layout);
}
