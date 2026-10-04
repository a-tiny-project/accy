const std = @import("std");
const gpu_abi = @import("gpu_abi");

const artifact_product = @import("../../artifact/model/root.zig");
const shape = @import("../../choir/shape/root.zig");
const entry = @import("entry.zig");
const extent_mod = @import("extent.zig");
const geometry_mod = @import("geometry.zig");
const kernel = @import("../root.zig");

const runtimeExtentArgument = extent_mod.runtimeExtentArgument;

pub const GridCells = struct {
    count: u64,
    threads: u32 = 256,
    point_axis: []const u8 = "p",
};

pub const grid_cells_family_version: u32 = 1;
pub const grid_cells_warp_size: u32 = 32;
pub const grid_cells_max_threads: u32 = 1024;
pub const grid_cells_max_blocks: u32 = 1024;

pub const GridGeometry = struct {
    origin_x: f32,
    origin_y: f32,
    inv_cell_size: f32,
    dims_x: u32,
    dims_y: u32,

    pub fn cellCount(self: GridGeometry) u64 {
        return @as(u64, self.dims_x) * self.dims_y;
    }
};

pub fn gridCellsBlockCount(count: u64, threads: u32) u64 {
    return gridCellsBlockCountChecked(count, threads).?;
}

fn gridCellsBlockCountChecked(count: u64, threads: u32) ?u64 {
    if (threads == 0) return null;
    const biased = std.math.add(u64, count, threads - 1) catch return null;
    return biased / threads;
}

pub fn gridCellsInstanceValid(instance: GridCells) bool {
    if (instance.count == 0) return false;
    if (instance.point_axis.len == 0) return false;
    if (instance.threads == 0 or instance.threads > grid_cells_max_threads) return false;
    if (instance.threads % grid_cells_warp_size != 0) return false;
    return extent_mod.blockCountWithinLimit(
        instance.count,
        instance.threads,
        grid_cells_max_blocks,
    );
}

pub fn gridGeometryValid(geometry: GridGeometry) bool {
    if (geometry.dims_x == 0 or geometry.dims_y == 0) return false;
    if (!(geometry.inv_cell_size > 0)) return false;
    return geometry.cellCount() <= std.math.maxInt(i32);
}

fn gridCellAxisIndex(
    b: anytype,
    coordinate: kernel.Value,
    origin: kernel.Value,
    inv_cell_size: kernel.Value,
    dim: kernel.Value,
) !kernel.Value {
    const offset = try b.sub(coordinate, origin);
    const scaled = try b.mul(offset, inv_cell_size);
    const raw_index = try b.cast(scaled, .i32);
    const zero = try b.constantInt(.i32, 0);
    const one = try b.constantInt(.i32, 1);
    const last = try b.sub(dim, one);
    const non_negative = try b.max(raw_index, zero);
    return b.min(non_negative, last);
}

fn grid_cells_body_active(inner: anytype, ctx: anytype) !void {
    const x = try ctx.args.param(.x).load(inner, ctx.point);
    const y = try ctx.args.param(.y).load(inner, ctx.point);
    const cx = try gridCellAxisIndex(
        inner,
        x.raw(),
        ctx.args.param(.origin_x).raw(),
        ctx.args.param(.inv_cell_size).raw(),
        ctx.args.param(.dims_x).raw(),
    );
    const cy = try gridCellAxisIndex(
        inner,
        y.raw(),
        ctx.args.param(.origin_y).raw(),
        ctx.args.param(.inv_cell_size).raw(),
        ctx.args.param(.dims_y).raw(),
    );
    const row = try inner.mul(cy, ctx.args.param(.dims_x).raw());
    const cell = try inner.add(row, cx);
    try ctx.args.param(.cells).store(inner, cell, ctx.point);
}

fn gridCellsBody(k: anytype, spec: GridCells, args: anytype) !void {
    if (!gridCellsInstanceValid(spec)) return error.UnsupportedGridCellsInstance;
    const point = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const active = try k.compare(.lt, point, count);
    try k.guardDo(active, .{
        .args = args,
        .point = point,
    }, grid_cells_body_active);
}

fn gridCellsFamilySchedule(instance: GridCells) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn gridCellsRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_spatial_grid_cells_runtime_f32",
        .parameters = .{
            .cells = kernel.dynamicBuffer(.i32),
            .x = kernel.dynamicBuffer(.f32),
            .y = kernel.dynamicBuffer(.f32),
            .count = kernel.scalar(.i32),
            .origin_x = kernel.scalar(.f32),
            .origin_y = kernel.scalar(.f32),
            .inv_cell_size = kernel.scalar(.f32),
            .dims_x = kernel.scalar(.i32),
            .dims_y = kernel.scalar(.i32),
        },
        .Instance = GridCells,
        .schedule = gridCellsFamilySchedule,
        .body = gridCellsBody,
    });
}

pub const GridCellsRuntimeFamilyF32 = gridCellsRuntimeFamily();

pub fn gridCellsFamilyTarget(allocator: std.mem.Allocator, instance: GridCells) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.spatial.grid_cells_family_{d}_f32",
        .{instance.threads},
    );
}

pub fn gridCellsFamilyEntryName(allocator: std.mem.Allocator, instance: GridCells) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_spatial_grid_cells_family_{d}_f32",
        .{instance.threads},
    );
}

pub fn gridCellsRuntimeArguments(
    instance: GridCells,
    geometry: GridGeometry,
) ![6]gpu_abi.ScalarArgument {
    if (!gridGeometryValid(geometry)) return error.UnsupportedGridGeometry;
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.count) },
        .{ .f32 = geometry.origin_x },
        .{ .f32 = geometry.origin_y },
        .{ .f32 = geometry.inv_cell_size },
        .{ .u32 = geometry.dims_x },
        .{ .u32 = geometry.dims_y },
    };
}

const testing = std.testing;

fn hostCellId(geometry: GridGeometry, x: f32, y: f32) i32 {
    const fx = (x - geometry.origin_x) * geometry.inv_cell_size;
    const fy = (y - geometry.origin_y) * geometry.inv_cell_size;
    const cx = std.math.clamp(
        @as(i32, @intFromFloat(fx)),
        0,
        @as(i32, @intCast(geometry.dims_x - 1)),
    );
    const cy = std.math.clamp(
        @as(i32, @intFromFloat(fy)),
        0,
        @as(i32, @intCast(geometry.dims_y - 1)),
    );
    return cy * @as(i32, @intCast(geometry.dims_x)) + cx;
}

test "spatial grid cells matches the host reference with boundary clamping" {
    const allocator = testing.allocator;
    const count: usize = 70;
    const instance = GridCells{ .count = count, .threads = 32 };
    const geometry = GridGeometry{
        .origin_x = -1.0,
        .origin_y = -1.0,
        .inv_cell_size = 4.0,
        .dims_x = 8,
        .dims_y = 8,
    };
    const blocks: u32 = @intCast(gridCellsBlockCount(instance.count, instance.threads));
    try testing.expect(blocks > 1);

    var xs: [count]f32 = undefined;
    var ys: [count]f32 = undefined;
    var seed: u32 = 0x2545f491;
    for (&xs, &ys, 0..) |*x, *y, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const fx = @as(f32, @floatFromInt(seed % 1000)) / 250.0 - 2.0;
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const fy = @as(f32, @floatFromInt(seed % 1000)) / 250.0 - 2.0;
        x.* = fx;
        y.* = fy;
        if (index == 0) {
            x.* = -1.0;
            y.* = -1.0;
        }
        if (index == 1) {
            x.* = 5.0;
            y.* = -9.0;
        }
    }

    var cells = @as([count]i32, @splat(-1));
    var graph = try GridCellsRuntimeFamilyF32.build(
        allocator,
        GridCellsRuntimeFamilyF32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    const runtime_arguments = try gridCellsRuntimeArguments(instance, geometry);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, cells[0..]),
        kernel.argumentBuffer(f32, xs[0..]),
        kernel.argumentBuffer(f32, ys[0..]),
        kernel.argumentI32(@intCast(count)),
        kernel.argumentF32(geometry.origin_x),
        kernel.argumentF32(geometry.origin_y),
        kernel.argumentF32(geometry.inv_cell_size),
        kernel.argumentI32(@intCast(geometry.dims_x)),
        kernel.argumentI32(@intCast(geometry.dims_y)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    for (xs, ys, cells) |x, y, cell| {
        try testing.expectEqual(hostCellId(geometry, x, y), cell);
    }
    _ = runtime_arguments;
}

test "spatial grid cells identity and validity" {
    const allocator = testing.allocator;
    const instance = GridCells{ .count = 5000, .threads = 64 };
    const target = try gridCellsFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.spatial.grid_cells_family_64_f32", target);

    try testing.expect(gridCellsInstanceValid(instance));
    try testing.expect(!gridCellsInstanceValid(.{ .count = 0, .threads = 64 }));
    try testing.expect(!gridCellsInstanceValid(.{ .count = 10, .threads = 48 }));
    try testing.expect(!gridCellsInstanceValid(.{ .count = std.math.maxInt(u64), .threads = 32 }));

    try testing.expect(gridGeometryValid(
        .{ .origin_x = 0, .origin_y = 0, .inv_cell_size = 1, .dims_x = 4, .dims_y = 4 },
    ));
    try testing.expect(!gridGeometryValid(
        .{ .origin_x = 0, .origin_y = 0, .inv_cell_size = 0, .dims_x = 4, .dims_y = 4 },
    ));
    try testing.expect(!gridGeometryValid(
        .{ .origin_x = 0, .origin_y = 0, .inv_cell_size = 1, .dims_x = 0, .dims_y = 4 },
    ));

    const args = try gridCellsRuntimeArguments(instance, .{
        .origin_x = -1,
        .origin_y = -1,
        .inv_cell_size = 4,
        .dims_x = 8,
        .dims_y = 8,
    });
    try testing.expectEqual(@as(u32, 5000), args[0].u32);
    try testing.expectEqual(@as(u32, 8), args[4].u32);
}

pub const grid_count_shared_cells_cap: u32 = 4096;

pub const GridCount = struct {
    count: u64,
    cells: u32,
    threads: u32 = 256,
    point_axis: []const u8 = "p",
};

pub fn gridCountInstanceValid(instance: GridCount) bool {
    if (instance.count == 0) return false;
    if (instance.point_axis.len == 0) return false;
    if (instance.cells == 0 or instance.cells > grid_count_shared_cells_cap) return false;
    if (instance.threads == 0 or instance.threads > grid_cells_max_threads) return false;
    if (instance.threads % grid_cells_warp_size != 0) return false;
    return extent_mod.blockCountWithinLimit(
        instance.count,
        instance.threads,
        grid_cells_max_blocks,
    );
}

fn grid_count_body_zero_bin(
    loop_builder: anytype,
    bin: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    try loop_builder.storeIndex(ctx.zero_count, ctx.shared_bins, bin);
    return acc;
}

fn grid_count_body_active(inner: anytype, ctx: anytype) !void {
    const id_loaded = try ctx.args.param(.ids).load(inner, ctx.point);
    const zero = try inner.constantInt(.i32, 0);
    const one_i32 = try inner.constantInt(.i32, 1);
    const last_raw = try inner.sub(ctx.capped, one_i32);
    const last = try inner.max(last_raw, zero);
    const non_negative = try inner.max(id_loaded.raw(), zero);
    const clamped = try inner.min(non_negative, last);
    const bin = try inner.castIndex(clamped);
    _ = try inner.atomicRmwIndex(.add, one_i32, ctx.shared_bins, bin);
}

fn grid_count_body_grid(
    loop_builder: anytype,
    bin: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    const partial = try loop_builder.loadIndex(ctx.shared_bins, bin);
    const partial_value = try loop_builder.cast(partial, .f32);
    const column = try loop_builder.mul(bin, ctx.grid);
    const cell = try loop_builder.add(column, ctx.block);
    try loop_builder.storeIndex(partial_value, ctx.args.param(.counts).raw(), cell);
    return acc;
}

fn gridCountBody(k: anytype, spec: GridCount, args: anytype) !void {
    if (!gridCountInstanceValid(spec)) return error.UnsupportedGridCountInstance;
    const shared_bins = try k.sharedBuffer(.i32, spec.cells);
    const zero_count = try k.constantInt(.i32, 0);
    const thread = try k.castIndex(try k.threadId(.x));
    const stride = try k.castIndex(try k.blockDim(.x));
    const cells_cap = try k.constantInt(.i32, @intCast(spec.cells));
    const total_non_negative = try k.max(args.param(.cells_total).raw(), zero_count);
    const capped = try k.min(total_non_negative, cells_cap);
    const bins = try k.castIndex(capped);

    _ = try k.fold(thread, bins, stride, zero_count, .{
        .shared_bins = shared_bins,
        .zero_count = zero_count,
    }, grid_count_body_zero_bin);
    try k.barrier(.block);

    const point = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const active = try k.compare(.lt, point, count);
    try k.guardDo(active, .{
        .args = args,
        .point = point,
        .shared_bins = shared_bins,
        .capped = capped,
    }, grid_count_body_active);
    try k.barrier(.block);

    const block = try k.blockId(.x);
    const grid = try k.gridDim(.x);
    _ = try k.fold(thread, bins, stride, zero_count, .{
        .args = args,
        .shared_bins = shared_bins,
        .block = block,
        .grid = grid,
    }, grid_count_body_grid);
}

fn gridCountRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_spatial_grid_count_runtime_i32",
        .parameters = .{
            .counts = kernel.dynamicBuffer(.f32),
            .ids = kernel.dynamicBuffer(.i32),
            .count = kernel.scalar(.i32),
            .cells_total = kernel.scalar(.i32),
        },
        .Instance = GridCount,
        .schedule = gridCountFamilySchedule,
        .body = gridCountBody,
    });
}

fn gridCountFamilySchedule(instance: GridCount) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

pub const GridCountRuntimeFamilyI32 = gridCountRuntimeFamily();

pub fn gridCountFamilyTarget(allocator: std.mem.Allocator, instance: GridCount) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.spatial.grid_count_family_{d}_{d}_i32",
        .{ instance.cells, instance.threads },
    );
}

pub fn gridCountFamilyEntryName(allocator: std.mem.Allocator, instance: GridCount) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_spatial_grid_count_family_{d}_{d}_i32",
        .{ instance.cells, instance.threads },
    );
}

pub fn gridCountRuntimeArguments(instance: GridCount, cells_total: u32) ![2]gpu_abi.ScalarArgument {
    if (cells_total == 0 or cells_total > instance.cells) return error.UnsupportedGridCountInstance;
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.count) },
        .{ .u32 = cells_total },
    };
}

test "spatial grid count tallies precomputed ids per block in column-major order" {
    const allocator = testing.allocator;
    const count: usize = 90;
    const cells_total: u32 = 12;
    const instance = GridCount{ .count = count, .cells = 64, .threads = 32 };
    const blocks: u32 = @intCast(gridCellsBlockCount(instance.count, instance.threads));
    try testing.expectEqual(@as(u32, 3), blocks);

    var ids: [count]i32 = undefined;
    var seed: u32 = 0x2545f491;
    for (&ids, 0..) |*id, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        id.* = @intCast(seed % cells_total);
        if (index == 7) id.* = -3;
        if (index == 13) id.* = 200;
    }

    var counts = @as([(12 * 3)]f32, @splat(-1));
    var graph = try GridCountRuntimeFamilyI32.build(
        allocator,
        GridCountRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, counts[0..]),
        kernel.argumentBuffer(i32, ids[0..]),
        kernel.argumentI32(@intCast(count)),
        kernel.argumentI32(@intCast(cells_total)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    var expected = @as([(12 * 3)]f32, @splat(0));
    for (ids, 0..) |id, index| {
        const clamped: usize = @intCast(std.math.clamp(id, 0, @as(i32, @intCast(cells_total - 1))));
        const block = index / instance.threads;
        expected[clamped * 3 + block] += 1;
    }
    try testing.expectEqualSlices(f32, expected[0..], counts[0..]);
}

test "spatial grid count clamps runtime cell totals to the compiled shared cap" {
    const allocator = testing.allocator;
    const count: usize = 32;
    const instance = GridCount{ .count = count, .cells = 4, .threads = 32 };

    var ids: [count]i32 = undefined;
    for (&ids, 0..) |*id, index| id.* = @intCast(index % 6);

    var graph = try GridCountRuntimeFamilyI32.build(
        allocator,
        GridCountRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer graph.deinit();

    var over_counts = @as([5]f32, @splat(-1));
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, over_counts[0..]),
        kernel.argumentBuffer(i32, ids[0..]),
        kernel.argumentI32(@intCast(count)),
        kernel.argumentI32(5),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });
    var expected = @as([5]f32, @splat(0));
    for (ids) |id| {
        const clamped: usize = @intCast(std.math.clamp(id, 0, 3));
        expected[clamped] += 1;
    }
    expected[4] = -1;
    try testing.expectEqualSlices(f32, expected[0..], over_counts[0..]);

    var zero_counts = @as([4]f32, @splat(-1));
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, zero_counts[0..]),
        kernel.argumentBuffer(i32, ids[0..]),
        kernel.argumentI32(@intCast(count)),
        kernel.argumentI32(0),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });
    try testing.expectEqualSlices(f32, &[_]f32{ -1, -1, -1, -1 }, zero_counts[0..]);

    var negative_counts = @as([4]f32, @splat(-1));
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, negative_counts[0..]),
        kernel.argumentBuffer(i32, ids[0..]),
        kernel.argumentI32(@intCast(count)),
        kernel.argumentI32(-7),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });
    try testing.expectEqualSlices(f32, &[_]f32{ -1, -1, -1, -1 }, negative_counts[0..]);
}

test "spatial grid count identity and validity" {
    const allocator = testing.allocator;
    const instance = GridCount{ .count = 5000, .cells = 64, .threads = 64 };
    const target = try gridCountFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.spatial.grid_count_family_64_64_i32", target);

    try testing.expect(gridCountInstanceValid(instance));
    try testing.expect(!gridCountInstanceValid(.{ .count = 5000, .cells = 0, .threads = 64 }));
    try testing.expect(!gridCountInstanceValid(.{ .count = 5000, .cells = 8192, .threads = 64 }));
    try testing.expect(
        !gridCountInstanceValid(.{ .count = std.math.maxInt(u64), .cells = 64, .threads = 32 }),
    );

    try testing.expectError(
        error.UnsupportedGridCountInstance,
        gridCountRuntimeArguments(instance, 65),
    );
    const args = try gridCountRuntimeArguments(instance, 48);
    try testing.expectEqual(@as(u32, 48), args[1].u32);
}

pub const sort_mod = @import("sort.zig");
pub const scan_mod = @import("scan.zig");

pub const GridBuildPlan = struct {
    cells_instance: GridCells,
    sort_instance: sort_mod.RadixSplit,
    count_instance: GridCount,
    offsets_scan: scan_mod.DeviceScan,
    sort_passes: u32,
    cells_total: u32,
};

pub fn gridBuildPlan(count: u64, geometry: GridGeometry, threads: u32) !GridBuildPlan {
    if (!gridGeometryValid(geometry)) return error.UnsupportedGridGeometry;
    const cells_total: u32 = @intCast(geometry.cellCount());
    if (cells_total > grid_count_shared_cells_cap) return error.UnsupportedGridGeometry;

    const cells_instance = GridCells{ .count = count, .threads = threads };
    if (!gridCellsInstanceValid(cells_instance)) return error.UnsupportedGridCellsInstance;
    const sort_instance = sort_mod.RadixSplit{ .extent = count, .threads = threads };
    if (!sort_mod.radixSplitInstanceValid(sort_instance)) return error.UnsupportedGridCellsInstance;
    const count_instance = GridCount{ .count = count, .cells = cells_total, .threads = threads };
    if (!gridCountInstanceValid(count_instance)) return error.UnsupportedGridCountInstance;
    const count_blocks = gridCellsBlockCount(count, threads);
    const counts_extent = std.math.mul(
        u64,
        cells_total,
        count_blocks,
    ) catch return error.UnsupportedGridGeometry;
    const offsets_scan = scan_mod.DeviceScan{
        .extent = counts_extent,
        .mode = .exclusive,
        .threads = scan_mod.deviceScanThreadsForExtent(counts_extent) orelse
            return error.UnsupportedGridGeometry,
    };
    if (!scan_mod.deviceScanInstanceValid(offsets_scan)) return error.UnsupportedGridGeometry;

    const id_bits: u32 = 32 - @clz(@max(cells_total - 1, 1));
    const digit_passes = (id_bits + sort_mod.radix_digit_bits - 1) / sort_mod.radix_digit_bits;

    return .{
        .cells_instance = cells_instance,
        .sort_instance = sort_instance,
        .count_instance = count_instance,
        .offsets_scan = offsets_scan,
        .sort_passes = digit_passes,
        .cells_total = cells_total,
    };
}

test "spatial grid build plan derives pass counts and stage instances" {
    const geometry = GridGeometry{
        .origin_x = -1.0,
        .origin_y = -1.0,
        .inv_cell_size = 4.0,
        .dims_x = 8,
        .dims_y = 8,
    };
    const plan = try gridBuildPlan(5000, geometry, 64);
    try testing.expectEqual(@as(u32, 64), plan.cells_total);
    try testing.expectEqual(@as(u32, 2), plan.sort_passes);
    try testing.expectEqual(@as(u64, 64 * 79), plan.offsets_scan.extent);
    try testing.expectEqual(scan_mod.PrefixSumMode.exclusive, plan.offsets_scan.mode);
    try testing.expectEqual(
        plan.offsets_scan.extent,
        @as(u64, plan.cells_total) * gridCellsBlockCount(5000, plan.count_instance.threads),
    );

    const wide = GridGeometry{
        .origin_x = 0,
        .origin_y = 0,
        .inv_cell_size = 1.0,
        .dims_x = 64,
        .dims_y = 64,
    };
    const wide_plan = try gridBuildPlan(5000, wide, 64);
    try testing.expectEqual(@as(u32, 4096), wide_plan.cells_total);
    try testing.expectEqual(@as(u32, 3), wide_plan.sort_passes);
    try testing.expectEqual(@as(u64, 4096 * 79), wide_plan.offsets_scan.extent);

    try testing.expectError(error.UnsupportedGridGeometry, gridBuildPlan(5000, .{
        .origin_x = 0,
        .origin_y = 0,
        .inv_cell_size = 1.0,
        .dims_x = 128,
        .dims_y = 64,
    }, 64));
}

pub const GridNeighborCount = struct {
    count: u64,
    offsets_extent: u64 = 1,
    threads: u32 = 256,
    point_axis: []const u8 = "p",
};

pub fn gridNeighborCountInstanceValid(instance: GridNeighborCount) bool {
    if (instance.count == 0) return false;
    if (instance.offsets_extent == 0) return false;
    if (instance.point_axis.len == 0) return false;
    if (instance.threads == 0 or instance.threads > grid_cells_max_threads) return false;
    if (instance.threads % grid_cells_warp_size != 0) return false;
    return extent_mod.blockCountWithinLimit(
        instance.count,
        instance.threads,
        grid_cells_max_blocks,
    );
}

fn grid_neighbor_count_body_active(inner: anytype, ctx: anytype) !void {
    const px = try ctx.args.param(.x).load(inner, ctx.point);
    const py = try ctx.args.param(.y).load(inner, ctx.point);
    const dims_x = ctx.args.param(.dims_x).raw();
    const dims_y = ctx.args.param(.dims_y).raw();
    const cx = try gridCellAxisIndex(
        inner,
        px.raw(),
        ctx.args.param(.origin_x).raw(),
        ctx.args.param(.inv_cell_size).raw(),
        dims_x,
    );
    const cy = try gridCellAxisIndex(
        inner,
        py.raw(),
        ctx.args.param(.origin_y).raw(),
        ctx.args.param(.inv_cell_size).raw(),
        dims_y,
    );
    const zero = try inner.constantInt(.i32, 0);
    const one = try inner.constantInt(.i32, 1);
    const step = try inner.constantIndex(1);
    const cells_total = try inner.mul(dims_x, dims_y);
    const stride = ctx.args.param(.stride).raw();
    const count_scalar = ctx.args.param(.count).raw();
    const col_lo = try inner.max(try inner.sub(cx, one), zero);
    const col_hi = try inner.min(try inner.add(cx, one), try inner.sub(dims_x, one));

    var total = zero;
    inline for ([_]i64{ -1, 0, 1 }) |row_offset| {
        const offset_const = try inner.constantInt(.i32, row_offset);
        const ny = try inner.add(cy, offset_const);
        const row_low = try inner.compare(.ge, ny, zero);
        const row_high = try inner.compare(.lt, ny, dims_y);
        const row_valid = try inner.and_(row_low, row_high);
        const row_base = try inner.mul(ny, dims_x);
        const first_cell = try inner.add(row_base, col_lo);
        const next_cell = try inner.add(try inner.add(row_base, col_hi), one);
        const has_next = try inner.compare(.lt, next_cell, cells_total);

        const first_safe = try inner.select(row_valid, first_cell, zero);
        const start_loaded = try ctx.args.param(.offsets).load(
            inner,
            try inner.castIndex(try inner.mul(first_safe, stride)),
        );
        const start_value = try inner.cast(start_loaded.raw(), .i32);

        const next_guard = try inner.and_(row_valid, has_next);
        const next_safe = try inner.select(next_guard, next_cell, zero);
        const end_loaded = try ctx.args.param(.offsets).load(
            inner,
            try inner.castIndex(try inner.mul(next_safe, stride)),
        );
        const end_value = try inner.select(
            has_next,
            try inner.cast(end_loaded.raw(), .i32),
            count_scalar,
        );

        const start_position = try inner.select(row_valid, start_value, zero);
        const end_position = try inner.select(row_valid, end_value, zero);
        total = try inner.fold(
            try inner.castIndex(start_position),
            try inner.castIndex(end_position),
            step,
            total,
            .{
                .args = ctx.args,
                .point = ctx.point,
                .px = px,
                .py = py,
                .one = one,
                .zero = zero,
            },
            grid_neighbor_count_body_visit,
        );
    }
    try ctx.args.param(.neighbors).store(inner, total, ctx.point);
}

fn grid_neighbor_count_body_visit(
    loop_builder: anytype,
    position: kernel.Value,
    acc: kernel.Value,
    fold_ctx: anytype,
) !kernel.Value {
    const candidate = try fold_ctx.args.param(.sorted_indices).load(loop_builder, position);
    const candidate_index = try loop_builder.castIndex(candidate.raw());
    const qx = try fold_ctx.args.param(.x).load(loop_builder, candidate_index);
    const qy = try fold_ctx.args.param(.y).load(loop_builder, candidate_index);
    const dx = try loop_builder.sub(fold_ctx.px.raw(), qx.raw());
    const dy = try loop_builder.sub(fold_ctx.py.raw(), qy.raw());
    const dist2 = try loop_builder.add(
        try loop_builder.mul(dx, dx),
        try loop_builder.mul(dy, dy),
    );
    const within = try loop_builder.compare(.le, dist2, fold_ctx.args.param(.radius2).raw());
    const not_self = try loop_builder.compare(.ne, candidate_index, fold_ctx.point);
    const hit = try loop_builder.and_(within, not_self);
    const contribution = try loop_builder.select(hit, fold_ctx.one, fold_ctx.zero);
    return loop_builder.add(acc, contribution);
}

fn gridNeighborCountBody(k: anytype, spec: GridNeighborCount, args: anytype) !void {
    if (!gridNeighborCountInstanceValid(spec)) return error.UnsupportedGridNeighborCountInstance;
    const point = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const active = try k.compare(.lt, point, count);
    try k.guardDo(active, .{
        .args = args,
        .point = point,
    }, grid_neighbor_count_body_active);
}

fn gridNeighborCountFamilySchedule(
    instance: GridNeighborCount,
) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn gridNeighborCountRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_spatial_grid_neighbor_count_runtime_f32",
        .parameters = .{
            .neighbors = kernel.dynamicBuffer(.i32),
            .x = kernel.dynamicBuffer(.f32),
            .y = kernel.dynamicBuffer(.f32),
            .sorted_indices = kernel.dynamicBuffer(.i32),
            .offsets = kernel.dynamicBuffer(.f32),
            .count = kernel.scalar(.i32),
            .origin_x = kernel.scalar(.f32),
            .origin_y = kernel.scalar(.f32),
            .inv_cell_size = kernel.scalar(.f32),
            .dims_x = kernel.scalar(.i32),
            .dims_y = kernel.scalar(.i32),
            .stride = kernel.scalar(.i32),
            .radius2 = kernel.scalar(.f32),
        },
        .Instance = GridNeighborCount,
        .schedule = gridNeighborCountFamilySchedule,
        .body = gridNeighborCountBody,
    });
}

pub const GridNeighborCountRuntimeFamilyF32 = gridNeighborCountRuntimeFamily();

pub fn gridNeighborCountFamilyTarget(
    allocator: std.mem.Allocator,
    instance: GridNeighborCount,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.spatial.grid_neighbor_count_family_{d}_f32",
        .{instance.threads},
    );
}

pub fn gridNeighborCountFamilyEntryName(
    allocator: std.mem.Allocator,
    instance: GridNeighborCount,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_spatial_grid_neighbor_count_family_{d}_f32",
        .{instance.threads},
    );
}

/// Builds the eight scalar arguments for a neighbor-count kernel launch: the function returns, in
/// order, the point count, the grid origin along x and y, the inverse cell size, the cell counts
/// along x and y, the stride, and the squared radius. The radius must be finite, zero or greater,
/// and at most one grid cell, so the search reaches only the neighboring cells. The call returns
/// `error.UnsupportedGridGeometry` for a grid with zero cells, an inverse cell size of zero or
/// less, or more cells than a signed 32-bit count. The call returns
/// `error.UnsupportedGridNeighborCountInstance` for a zero stride or a radius that is NaN, infinite
/// or negative, and `error.NeighborRadiusExceedsCellSize` for a radius larger than one cell. The
/// call returns `error.ExtentOverflowsIndexRange` when the point count is zero or too large for the
/// kernel's index range.
pub fn gridNeighborCountRuntimeArguments(
    instance: GridNeighborCount,
    geometry: GridGeometry,
    stride: u32,
    radius: f32,
) ![8]gpu_abi.ScalarArgument {
    if (!gridGeometryValid(geometry)) return error.UnsupportedGridGeometry;
    if (stride == 0) return error.UnsupportedGridNeighborCountInstance;
    if (!std.math.isFinite(radius) or radius < 0) return error.UnsupportedGridNeighborCountInstance;
    if (radius * geometry.inv_cell_size > 1.0) return error.NeighborRadiusExceedsCellSize;
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.count) },
        .{ .f32 = geometry.origin_x },
        .{ .f32 = geometry.origin_y },
        .{ .f32 = geometry.inv_cell_size },
        .{ .u32 = geometry.dims_x },
        .{ .u32 = geometry.dims_y },
        .{ .u32 = stride },
        .{ .f32 = radius * radius },
    };
}

test "spatial grid neighbor count matches the quadratic host reference" {
    const allocator = testing.allocator;
    const count: usize = 48;
    const geometry = GridGeometry{
        .origin_x = 0,
        .origin_y = 0,
        .inv_cell_size = 1.0,
        .dims_x = 4,
        .dims_y = 4,
    };
    const radius: f32 = 0.75;
    const instance = GridNeighborCount{ .count = count, .threads = 32 };
    const blocks: u32 = @intCast(gridCellsBlockCount(instance.count, instance.threads));

    var xs: [count]f32 = undefined;
    var ys: [count]f32 = undefined;
    var seed: u32 = 0x9e3779b9;
    for (&xs, &ys, 0..) |*x, *y, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        x.* = @as(f32, @floatFromInt(seed % 1000)) / 200.0 - 0.5;
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        y.* = @as(f32, @floatFromInt(seed % 1000)) / 200.0 - 0.5;
        if (index == 0) {
            x.* = -2.0;
            y.* = -2.0;
        }
        if (index == 1) {
            x.* = -1.6;
            y.* = -2.0;
        }
    }

    var host_ids: [count]i32 = undefined;
    for (xs, ys, &host_ids) |x, y, *id| id.* = hostCellId(geometry, x, y);

    var order: [count]i32 = undefined;
    for (&order, 0..) |*value, index| value.* = @intCast(index);
    var sort_index: usize = 1;
    while (sort_index < count) : (sort_index += 1) {
        const key = order[sort_index];
        const key_cell = host_ids[@intCast(key)];
        var slot = sort_index;
        while (slot > 0 and host_ids[@intCast(order[slot - 1])] > key_cell) : (slot -= 1) {
            order[slot] = order[slot - 1];
        }
        order[slot] = key;
    }

    const cells_total: usize = 16;
    var counts_by_cell = @as([cells_total]u32, @splat(0));
    for (host_ids) |id| counts_by_cell[@intCast(id)] += 1;
    var offsets: [cells_total]f32 = undefined;
    var prefix: u32 = 0;
    for (&offsets, counts_by_cell) |*offset, cell_count| {
        offset.* = @floatFromInt(prefix);
        prefix += cell_count;
    }

    var expected: [count]i32 = undefined;
    for (0..count) |a| {
        var total: i32 = 0;
        for (0..count) |b| {
            if (a == b) continue;
            const dx = xs[a] - xs[b];
            const dy = ys[a] - ys[b];
            if (dx * dx + dy * dy <= radius * radius) total += 1;
        }
        expected[a] = total;
    }

    var neighbors = @as([count]i32, @splat(-1));
    var graph = try GridNeighborCountRuntimeFamilyF32.build(
        allocator,
        GridNeighborCountRuntimeFamilyF32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, neighbors[0..]),
        kernel.argumentBuffer(f32, xs[0..]),
        kernel.argumentBuffer(f32, ys[0..]),
        kernel.argumentBuffer(i32, order[0..]),
        kernel.argumentBuffer(f32, offsets[0..]),
        kernel.argumentI32(@intCast(count)),
        kernel.argumentF32(geometry.origin_x),
        kernel.argumentF32(geometry.origin_y),
        kernel.argumentF32(geometry.inv_cell_size),
        kernel.argumentI32(@intCast(geometry.dims_x)),
        kernel.argumentI32(@intCast(geometry.dims_y)),
        kernel.argumentI32(1),
        kernel.argumentF32(radius * radius),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    try testing.expectEqualSlices(i32, expected[0..], neighbors[0..]);
    try testing.expect(expected[0] >= 1);
}

test "spatial grid neighbor count identity and validity" {
    const allocator = testing.allocator;
    const instance = GridNeighborCount{ .count = 5000, .threads = 64 };
    const target = try gridNeighborCountFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.spatial.grid_neighbor_count_family_64_f32", target);

    try testing.expect(gridNeighborCountInstanceValid(instance));
    try testing.expect(!gridNeighborCountInstanceValid(.{ .count = 0, .threads = 64 }));
    try testing.expect(!gridNeighborCountInstanceValid(.{ .count = 10, .threads = 48 }));
    try testing.expect(
        !gridNeighborCountInstanceValid(.{ .count = std.math.maxInt(u64), .threads = 32 }),
    );

    const geometry = GridGeometry{
        .origin_x = -1,
        .origin_y = -1,
        .inv_cell_size = 4,
        .dims_x = 8,
        .dims_y = 8,
    };
    const args = try gridNeighborCountRuntimeArguments(instance, geometry, 3, 0.2);
    try testing.expectEqual(@as(u32, 5000), args[0].u32);
    try testing.expectEqual(@as(u32, 3), args[6].u32);
    const radius_runtime: f32 = 0.2;
    try testing.expectEqual(radius_runtime * radius_runtime, args[7].f32);

    try testing.expectError(
        error.UnsupportedGridNeighborCountInstance,
        gridNeighborCountRuntimeArguments(instance, geometry, 0, 0.2),
    );
    try testing.expectError(
        error.UnsupportedGridNeighborCountInstance,
        gridNeighborCountRuntimeArguments(instance, geometry, 3, -0.5),
    );
    try testing.expectError(
        error.UnsupportedGridNeighborCountInstance,
        gridNeighborCountRuntimeArguments(instance, geometry, 3, std.math.nan(f32)),
    );
    try testing.expectError(
        error.NeighborRadiusExceedsCellSize,
        gridNeighborCountRuntimeArguments(instance, geometry, 3, 0.3),
    );
}

pub const grid_count_family_version: u32 = 1;
pub const grid_neighbor_count_family_version: u32 = 1;
pub const grid_count_cell_axis = "c";
pub const grid_count_block_axis = "b";
pub const grid_neighbor_offsets_axis = "o";
const spatial_thread_caps = geometry_mod.ThreadCaps1D{};

pub fn spatialThreadsForCount(count: u64) u32 {
    const raw = geometry_mod.threadsForExtent(count, spatial_thread_caps);
    if (raw % grid_cells_warp_size != 0) return grid_cells_warp_size;
    return raw;
}

pub fn spatialThreadCandidatesForCount(count: u64) geometry_mod.Thread1DCandidates {
    var candidates = geometry_mod.threadCandidatesForExtent(count, spatial_thread_caps);
    for (candidates.items[0..candidates.count]) |*threads| {
        if (threads.* % grid_cells_warp_size != 0) threads.* = grid_cells_warp_size;
    }
    return candidates;
}

fn spatialRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

pub fn gridCellsShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: GridCells,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "grid_cells");
    errdefer builder.deinit();

    const point = try builder.symbol(instance.point_axis);
    const point_expr = try builder.symbolExpression(point);
    _ = try builder.tensor("cells", &.{point_expr});
    _ = try builder.tensor("x", &.{point_expr});
    _ = try builder.tensor("y", &.{point_expr});
    try builder.assumeBounds(point_expr, spatialRuntimeExtentBounds());

    return builder.finish();
}

pub fn gridCellsFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: GridCells) !u64 {
    var family = try gridCellsShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn gridCellsFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: GridCells,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.point_axis, instance.count);
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, instance.point_axis, instance.count);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.point_axis, instance.count);

    owned.value = .{
        .dtype = .f32,
        .operation = .{ .spatial = .grid_cells },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.point_axis,
            instance.count,
            instance.threads,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try gridCellsShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn gridCellsInstanceFromSpecialization(specialization: entry.Specialization) ?GridCells {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const schedule = specialization.schedule orelse return null;
    if (!specialization.operationIs(.{ .spatial = .grid_cells })) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .f32) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const cells = specialization.outputs[0];
    if (cells.axes.len != 1) return null;
    const point_axis = cells.axes[0].name;
    const count = cells.axes[0].extent;
    if (!spatialShape1DMatches(specialization.inputs[0], point_axis, count)) return null;
    if (!spatialShape1DMatches(specialization.inputs[1], point_axis, count)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const instance = GridCells{
        .count = count,
        .threads = launch.threadgroup[0],
        .point_axis = point_axis,
    };
    if (!gridCellsInstanceValid(instance)) return null;
    if (!spatialThreadBlocksMatch(
        schedule,
        instance.point_axis,
        instance.count,
        instance.threads,
    )) return null;
    return instance;
}

pub fn gridCellsShapeProfileDimensions(
    instance: GridCells,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.point_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = spatialRuntimeExtentBounds(),
        },
    };
}

fn spatialDerivedLaunch(threads: u32) !artifact_product.KernelCallLaunch {
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

pub fn createGridCellsFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: GridCells,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!gridCellsInstanceValid(instance)) return error.InvalidKernelLibraryEntry;
    const target = try gridCellsFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try gridCellsFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try gridCellsFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = gridCellsShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "grid_cells",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try GridCellsRuntimeFamilyF32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = grid_cells_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try spatialDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            6
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn gridCountShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: GridCount,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "grid_count");
    errdefer builder.deinit();

    const point = try builder.symbol(instance.point_axis);
    const cell = try builder.symbol(grid_count_cell_axis);
    const block = try builder.symbol(grid_count_block_axis);
    const point_expr = try builder.symbolExpression(point);
    const cell_expr = try builder.symbolExpression(cell);
    const block_expr = try builder.symbolExpression(block);
    _ = try builder.tensor("counts", &.{ cell_expr, block_expr });
    _ = try builder.tensor("ids", &.{point_expr});
    try builder.assumeBounds(point_expr, spatialRuntimeExtentBounds());
    try builder.assumeBounds(cell_expr, spatialRuntimeExtentBounds());
    try builder.assumeBounds(block_expr, spatialRuntimeExtentBounds());

    return builder.finish();
}

pub fn gridCountFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: GridCount) !u64 {
    var family = try gridCountShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn gridCountFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: GridCount,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 1);
    inputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.point_axis, instance.count);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape2D(
        lifetime_allocator,
        grid_count_cell_axis,
        instance.cells,
        grid_count_block_axis,
        gridCellsBlockCount(instance.count, instance.threads),
    );

    owned.value = .{
        .dtype = .i32,
        .operation = .{ .spatial = .grid_count },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.point_axis,
            instance.count,
            instance.threads,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try gridCountShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn gridCountInstanceFromSpecialization(specialization: entry.Specialization) ?GridCount {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const schedule = specialization.schedule orelse return null;
    if (!specialization.operationIs(.{ .spatial = .grid_count })) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .i32) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const ids = specialization.inputs[0];
    const counts = specialization.outputs[0];
    if (ids.axes.len != 1 or counts.axes.len != 2) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const cells = std.math.cast(u32, counts.axes[0].extent) orelse return null;
    if (!spatialAxisMatches(counts.axes[0], grid_count_cell_axis, cells)) return null;
    const instance = GridCount{
        .count = ids.axes[0].extent,
        .cells = cells,
        .threads = launch.threadgroup[0],
        .point_axis = ids.axes[0].name,
    };
    if (!gridCountInstanceValid(instance)) return null;
    const blocks = gridCellsBlockCountChecked(instance.count, instance.threads) orelse return null;
    if (!spatialAxisMatches(counts.axes[1], grid_count_block_axis, blocks)) return null;
    if (!spatialThreadBlocksMatch(
        schedule,
        instance.point_axis,
        instance.count,
        instance.threads,
    )) return null;
    return instance;
}

pub fn gridCountShapeProfileDimensions(
    instance: GridCount,
) [2]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.point_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = spatialRuntimeExtentBounds(),
        },
        .{
            .name = grid_count_cell_axis,
            .runtime_scalar_argument_index = 1,
            .bounds = spatialRuntimeExtentBounds(),
        },
    };
}

pub fn createGridCountFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: GridCount,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!gridCountInstanceValid(instance)) return error.InvalidKernelLibraryEntry;
    const target = try gridCountFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try gridCountFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try gridCountFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = gridCountShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "grid_count",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try GridCountRuntimeFamilyI32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = grid_count_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try spatialDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            2
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn gridNeighborCountShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: GridNeighborCount,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "grid_neighbor_count");
    errdefer builder.deinit();

    const point = try builder.symbol(instance.point_axis);
    const offsets = try builder.symbol(grid_neighbor_offsets_axis);
    const point_expr = try builder.symbolExpression(point);
    const offsets_expr = try builder.symbolExpression(offsets);
    _ = try builder.tensor("neighbors", &.{point_expr});
    _ = try builder.tensor("x", &.{point_expr});
    _ = try builder.tensor("y", &.{point_expr});
    _ = try builder.tensor("sorted_indices", &.{point_expr});
    _ = try builder.tensor("offsets", &.{offsets_expr});
    try builder.assumeBounds(point_expr, spatialRuntimeExtentBounds());
    try builder.assumeBounds(offsets_expr, spatialRuntimeExtentBounds());

    return builder.finish();
}

pub fn gridNeighborCountFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: GridNeighborCount,
) !u64 {
    var family = try gridNeighborCountShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn gridNeighborCountFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: GridNeighborCount,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
    inputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.point_axis, instance.count);
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, instance.point_axis, instance.count);
    inputs[2] = try entry.runtimeShape1D(lifetime_allocator, instance.point_axis, instance.count);
    inputs[3] = try entry.runtimeShape1D(
        lifetime_allocator,
        grid_neighbor_offsets_axis,
        instance.offsets_extent,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.point_axis, instance.count);

    owned.value = .{
        .dtype = .f32,
        .operation = .{ .spatial = .grid_neighbor_count },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.point_axis,
            instance.count,
            instance.threads,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try gridNeighborCountShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn gridNeighborCountInstanceFromSpecialization(
    specialization: entry.Specialization,
) ?GridNeighborCount {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const schedule = specialization.schedule orelse return null;
    if (!specialization.operationIs(.{ .spatial = .grid_neighbor_count })) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .f32) return null;
    if (specialization.inputs.len != 4 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const points = specialization.outputs[0];
    if (points.axes.len != 1) return null;
    const point_axis = points.axes[0].name;
    const count = points.axes[0].extent;
    if (!spatialShape1DMatches(specialization.inputs[0], point_axis, count)) return null;
    if (!spatialShape1DMatches(specialization.inputs[1], point_axis, count)) return null;
    if (!spatialShape1DMatches(specialization.inputs[2], point_axis, count)) return null;
    const offsets = specialization.inputs[3];
    if (offsets.axes.len != 1) return null;
    const offsets_extent = offsets.axes[0].extent;
    if (!spatialAxisMatches(offsets.axes[0], grid_neighbor_offsets_axis, offsets_extent)) {
        return null;
    }
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const instance = GridNeighborCount{
        .count = count,
        .offsets_extent = offsets_extent,
        .threads = launch.threadgroup[0],
        .point_axis = point_axis,
    };
    if (!gridNeighborCountInstanceValid(instance)) return null;
    if (!spatialThreadBlocksMatch(
        schedule,
        instance.point_axis,
        instance.count,
        instance.threads,
    )) return null;
    return instance;
}

fn spatialAxisMatches(axis: entry.Axis, name: []const u8, extent: u64) bool {
    if (name.len == 0) return false;
    if (!std.mem.eql(u8, axis.name, name)) return false;
    return axis.extent == extent;
}

fn spatialShape1DMatches(candidate: entry.Shape, name: []const u8, extent: u64) bool {
    if (candidate.axes.len != 1) return false;
    return spatialAxisMatches(candidate.axes[0], name, extent);
}

fn spatialScheduleAxisNameMatches(
    actual: []const u8,
    point_axis: []const u8,
    suffix: []const u8,
) bool {
    if (actual.len != point_axis.len + suffix.len) return false;
    return std.mem.eql(u8, actual[0..point_axis.len], point_axis) and
        std.mem.eql(u8, actual[point_axis.len..], suffix);
}

fn spatialThreadBlocksMatch(
    schedule: entry.Schedule,
    point_axis: []const u8,
    count: u64,
    threads: u32,
) bool {
    const blocks = gridCellsBlockCountChecked(count, threads) orelse return false;
    if (count <= threads) {
        if (schedule.bindings.len != 1) return false;
        const binding = schedule.bindings[0];
        return binding.target == .thread_x and
            spatialAxisMatches(.{
                .name = binding.axis,
                .extent = binding.extent,
            }, point_axis, count);
    }
    if (schedule.bindings.len != 2) return false;
    const tile = schedule.bindings[0];
    const lane = schedule.bindings[1];
    return tile.target == .block_x and
        tile.extent == blocks and
        spatialScheduleAxisNameMatches(tile.axis, point_axis, "_tile") and
        lane.target == .thread_x and
        lane.extent == threads and
        spatialScheduleAxisNameMatches(lane.axis, point_axis, "_lane");
}

pub fn gridNeighborCountShapeProfileDimensions(
    instance: GridNeighborCount,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.point_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = spatialRuntimeExtentBounds(),
        },
    };
}

pub fn createGridNeighborCountFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: GridNeighborCount,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!gridNeighborCountInstanceValid(instance)) return error.InvalidKernelLibraryEntry;
    const target = try gridNeighborCountFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try gridNeighborCountFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try gridNeighborCountFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = gridNeighborCountShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "grid_neighbor_count",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try GridNeighborCountRuntimeFamilyF32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = grid_neighbor_count_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try spatialDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            8
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

test "spatial specializations round-trip their instances" {
    const allocator = std.testing.allocator;

    var cells_owned = try gridCellsFamilySpecialization(
        allocator,
        .{ .count = 5000, .threads = 64 },
    );
    defer cells_owned.deinit();
    try std.testing.expect(cells_owned.value.operationIs(.{ .spatial = .grid_cells }));
    const cells_recovered = gridCellsInstanceFromSpecialization(cells_owned.value) orelse {
        return error.TestExpectedGridCellsInstance;
    };
    try std.testing.expectEqual(@as(u64, 5000), cells_recovered.count);
    try std.testing.expectEqual(@as(u32, 64), cells_recovered.threads);
    try std.testing.expectEqual(@as(?GridCells, null), gridCellsInstanceFromSpecialization(.{}));

    var count_owned = try gridCountFamilySpecialization(
        allocator,
        .{ .count = 5000, .cells = 64, .threads = 64 },
    );
    defer count_owned.deinit();
    const count_recovered = gridCountInstanceFromSpecialization(count_owned.value) orelse {
        return error.TestExpectedGridCountInstance;
    };
    try std.testing.expectEqual(@as(u64, 5000), count_recovered.count);
    try std.testing.expectEqual(@as(u32, 64), count_recovered.cells);
    try std.testing.expectEqual(@as(u32, 64), count_recovered.threads);
    try std.testing.expectEqual(
        @as(?GridCount, null),
        gridCountInstanceFromSpecialization(cells_owned.value),
    );

    var neighbor_owned = try gridNeighborCountFamilySpecialization(
        allocator,
        .{ .count = 5000, .offsets_extent = 64 * 79, .threads = 64 },
    );
    defer neighbor_owned.deinit();
    const neighbor_recovered = gridNeighborCountInstanceFromSpecialization(
        neighbor_owned.value,
    ) orelse {
        return error.TestExpectedGridNeighborCountInstance;
    };
    try std.testing.expectEqual(@as(u64, 5000), neighbor_recovered.count);
    try std.testing.expectEqual(@as(u64, 64 * 79), neighbor_recovered.offsets_extent);
    try std.testing.expectEqual(@as(u32, 64), neighbor_recovered.threads);
    try std.testing.expectEqual(
        @as(?GridNeighborCount, null),
        gridNeighborCountInstanceFromSpecialization(count_owned.value),
    );
}

test "spatial specializations reject malformed descriptor shapes" {
    const allocator = std.testing.allocator;

    {
        var owned = try gridCellsFamilySpecialization(allocator, .{ .count = 5000, .threads = 64 });
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
        inputs[0] = try entry.runtimeShape1D(lifetime_allocator, "bad_p", 5000);
        inputs[1] = owned.value.inputs[1];
        owned.value.inputs = inputs;
        try std.testing.expectEqual(
            @as(?GridCells, null),
            gridCellsInstanceFromSpecialization(owned.value),
        );
    }

    {
        var owned = try gridCellsFamilySpecialization(allocator, .{ .count = 5000, .threads = 64 });
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        owned.value.schedule = try entry.runtimeThreadBlocks1D(lifetime_allocator, "q", 5000, 64);
        owned.value.launch = owned.value.schedule.?.launch();
        try std.testing.expectEqual(
            @as(?GridCells, null),
            gridCellsInstanceFromSpecialization(owned.value),
        );
    }

    {
        var owned = try gridCountFamilySpecialization(
            allocator,
            .{ .count = 5000, .cells = 64, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
        outputs[0] = try entry.runtimeShape2D(
            lifetime_allocator,
            grid_count_cell_axis,
            64,
            "bad_b",
            gridCellsBlockCount(5000, 64),
        );
        owned.value.outputs = outputs;
        try std.testing.expectEqual(
            @as(?GridCount, null),
            gridCountInstanceFromSpecialization(owned.value),
        );
    }

    {
        var owned = try gridNeighborCountFamilySpecialization(
            allocator,
            .{ .count = 5000, .offsets_extent = 64 * 79, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        inputs[0] = owned.value.inputs[0];
        inputs[1] = owned.value.inputs[1];
        inputs[2] = try entry.runtimeShape1D(lifetime_allocator, "p", 4999);
        inputs[3] = owned.value.inputs[3];
        owned.value.inputs = inputs;
        try std.testing.expectEqual(
            @as(?GridNeighborCount, null),
            gridNeighborCountInstanceFromSpecialization(owned.value),
        );
    }

    {
        var owned = try gridNeighborCountFamilySpecialization(
            allocator,
            .{ .count = 5000, .offsets_extent = 64 * 79, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        const zero_offsets_axes = try lifetime_allocator.alloc(entry.Axis, 1);
        zero_offsets_axes[0] = .{ .name = grid_neighbor_offsets_axis, .extent = 0 };
        inputs[0] = owned.value.inputs[0];
        inputs[1] = owned.value.inputs[1];
        inputs[2] = owned.value.inputs[2];
        inputs[3] = .{ .axes = zero_offsets_axes };
        owned.value.inputs = inputs;
        try std.testing.expectEqual(
            @as(?GridNeighborCount, null),
            gridNeighborCountInstanceFromSpecialization(owned.value),
        );
    }
}

test "spatial thread selection rounds to warps" {
    try std.testing.expectEqual(@as(u32, 32), spatialThreadsForCount(5));
    try std.testing.expect(spatialThreadsForCount(8192) % grid_cells_warp_size == 0);
    const candidates = spatialThreadCandidatesForCount(8192);
    try std.testing.expect(candidates.count >= 2);
    for (candidates.slice()) |threads| {
        try std.testing.expect(threads % grid_cells_warp_size == 0);
    }
}
