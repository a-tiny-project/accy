const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");

const artifact_product = @import("../../artifact/model/root.zig");
const shape = @import("../../choir/shape/root.zig");
const entry = @import("entry.zig");
const extent_mod = @import("extent.zig");
const kernel = @import("../root.zig");
const tuning = @import("tuning.zig");

const DType = gpu_abi.DType;
const indexExtent = extent_mod.indexExtent;
const runtimeExtentArgument = extent_mod.runtimeExtentArgument;

pub const PrefixSumMode = enum {
    inclusive,
    exclusive,

    pub fn operation(self: PrefixSumMode) entry.ScanOperator {
        return switch (self) {
            .inclusive => .prefix_sum,
            .exclusive => .prefix_sum_exclusive,
        };
    }

    pub fn fromOperation(operator: entry.ScanOperator) PrefixSumMode {
        return switch (operator) {
            .prefix_sum => .inclusive,
            .prefix_sum_exclusive => .exclusive,
        };
    }
};

pub const PrefixSum = struct {
    extent: u64,
    dtype: DType = .f32,
    mode: PrefixSumMode = .inclusive,
    threads: u32 = 256,
    element_axis: []const u8 = "e",
};

pub const prefix_sum_family_version: u32 = 1;
pub const prefix_sum_warp_size: u32 = 32;
pub const prefix_sum_max_threads: u32 = 1024;

pub fn prefixSumDTypeSupported(dtype: DType) bool {
    return switch (dtype) {
        .f32, .f16, .u32 => true,
        else => false,
    };
}

pub fn prefixSumInstanceValid(instance: PrefixSum) bool {
    if (!prefixSumDTypeSupported(instance.dtype)) return false;
    if (instance.extent == 0) return false;
    if (instance.threads == 0 or instance.threads > prefix_sum_max_threads) return false;
    if (instance.threads % prefix_sum_warp_size != 0) return false;
    return instance.extent <= instance.threads;
}

pub fn prefixSumThreadsForExtent(extent: u64) ?u32 {
    if (extent == 0 or extent > prefix_sum_max_threads) return null;
    const wide: u64 = extent + prefix_sum_warp_size - 1;
    const rounded: u32 = @intCast((wide / prefix_sum_warp_size) * prefix_sum_warp_size);
    return @max(rounded, prefix_sum_warp_size);
}

pub const PrefixSumThreadCandidates = struct {
    count: usize = 0,
    items: [6]u32 = @as([6]u32, @splat(0)),

    pub fn slice(self: *const PrefixSumThreadCandidates) []const u32 {
        return self.items[0..self.count];
    }
};

pub fn prefixSumThreadCandidatesForExtent(extent: u64) PrefixSumThreadCandidates {
    var result = PrefixSumThreadCandidates{};
    const base = prefixSumThreadsForExtent(extent) orelse return result;
    result.items[result.count] = base;
    result.count += 1;
    var threads: u32 = prefix_sum_warp_size;
    while (threads <= prefix_sum_max_threads) : (threads *= 2) {
        if (threads == base) continue;
        if (@as(u64, threads) < extent) continue;
        if (result.count >= result.items.len) break;
        result.items[result.count] = threads;
        result.count += 1;
    }
    return result;
}

fn prefix_sum_scan_core_seeds_zero(inner: anytype, ctx: anytype) !void {
    try inner.storeIndex(ctx.zero_value, ctx.warp_sums, ctx.local);
}

fn prefix_sum_scan_core_is_last_lane(inner: anytype, ctx: anytype) !void {
    try inner.storeIndex(ctx.scanned, ctx.warp_sums, ctx.warp);
}

fn prefix_sum_scan_core_is_first_warp(inner: anytype, ctx: anytype) !void {
    const warp_sum = try inner.loadIndex(ctx.warp_sums, ctx.lane);
    const warp_scan = try inner.warpScan(.add, .inclusive, warp_sum);
    try inner.storeIndex(warp_scan, ctx.warp_sums, ctx.lane);
}

fn prefix_sum_scan_core_in_range(inner: anytype, ctx: anytype) !void {
    try ctx.args.param(.dst).store(inner, ctx.result, ctx.tid);
}

fn prefixSumScanCore(
    k: anytype,
    spec: PrefixSum,
    args: anytype,
    extent: kernel.Value,
    local: kernel.Value,
) !kernel.Value {
    const tid = try k.globalId(.x);
    const lane = try k.laneId();
    const warp = try k.warpId();
    const zero = try k.constantIndex(0);
    const one = try k.constantIndex(1);

    const in_range = try k.compare(.lt, tid, extent);
    const extent_minus_one = try k.sub(extent, one);
    const clamped_tid = try k.min(tid, extent_minus_one);
    const loaded = try args.param(.data).load(k, clamped_tid);
    const accumulator_dtype = comptime prefixSumAccumulatorDType(@TypeOf(loaded).scalar_dtype);
    const loaded_accumulated = if (comptime @TypeOf(loaded).scalar_dtype == accumulator_dtype)
        loaded.raw()
    else
        (try loaded.cast(k, accumulator_dtype)).raw();
    const zero_value = try zeroForDType(k, accumulator_dtype);
    const element = try k.select(in_range, loaded_accumulated, zero_value);

    const scanned = try k.warpScan(.add, .inclusive, element);

    const warp_sums = try k.sharedBuffer(accumulator_dtype, prefix_sum_warp_size);
    const lane_limit = try k.constantIndex(prefix_sum_warp_size - 1);
    const warp_count_value = try k.constantIndex(prefix_sum_warp_size);

    const seeds_zero = try k.compare(.lt, local, warp_count_value);
    try k.guardDo(
        seeds_zero,
        .{ .warp_sums = warp_sums, .local = local, .zero_value = zero_value },
        prefix_sum_scan_core_seeds_zero,
    );
    try k.barrier(.block);

    const is_last_lane = try k.compare(.eq, lane, lane_limit);
    try k.guardDo(
        is_last_lane,
        .{ .warp_sums = warp_sums, .warp = warp, .scanned = scanned },
        prefix_sum_scan_core_is_last_lane,
    );
    try k.barrier(.block);

    const is_first_warp = try k.compare(.eq, warp, zero);
    try k.guardDo(
        is_first_warp,
        .{ .warp_sums = warp_sums, .lane = lane },
        prefix_sum_scan_core_is_first_warp,
    );
    try k.barrier(.block);

    const has_base = try k.compare(.gt, warp, zero);
    const warp_minus_one = try k.sub(warp, one);
    const base_index = try k.select(has_base, warp_minus_one, zero);
    const base_loaded = try k.loadIndex(warp_sums, base_index);
    const base = try k.select(has_base, base_loaded, zero_value);
    const inclusive = try k.add(scanned, base);
    const accumulated = switch (spec.mode) {
        .inclusive => inclusive,
        .exclusive => try k.sub(inclusive, element),
    };
    const dst_dtype = comptime @TypeOf(args.param(.dst)).element_dtype;
    const result = switch (dst_dtype) {
        .f32 => accumulated,
        .u32 => accumulated,
        .f16 => try k.cast(accumulated, .f16),
        else => return error.UnsupportedDType,
    };

    try k.guardDo(
        in_range,
        .{ .args = args, .tid = tid, .result = result },
        prefix_sum_scan_core_in_range,
    );

    return warp_sums;
}

fn prefixSumAccumulatorDType(dtype: DType) DType {
    return switch (dtype) {
        .f16 => .f32,
        else => dtype,
    };
}

fn zeroForDType(k: anytype, comptime dtype: DType) !kernel.Value {
    return switch (dtype) {
        .f32 => k.constantFloat(.f32, 0.0),
        .u32 => k.constantInt(.u32, 0),
        else => error.UnsupportedDType,
    };
}

fn prefixSumBody(k: anytype, spec: PrefixSum, args: anytype) !void {
    if (!prefixSumInstanceValid(spec)) return error.UnsupportedPrefixSumInstance;
    const extent = try k.constantIndex(try indexExtent(spec.extent));
    const local = try k.threadId(.x);
    _ = try prefixSumScanCore(k, spec, args, extent, local);
}

fn prefixSumRuntimeBody(k: anytype, spec: PrefixSum, args: anytype) !void {
    if (!prefixSumInstanceValid(spec)) return error.UnsupportedPrefixSumInstance;
    const extent = try k.castIndex(args.param(.extent).raw());
    const local = try k.threadId(.x);
    _ = try prefixSumScanCore(k, spec, args, extent, local);
}

fn prefixSumFamilySchedule(instance: PrefixSum) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn prefixSumRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_scan_prefix_sum_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .data = kernel.dynamicBuffer(dtype),
            .extent = kernel.scalar(.i32),
        },
        .Instance = PrefixSum,
        .schedule = prefixSumFamilySchedule,
        .body = prefixSumRuntimeBody,
    });
}

pub const PrefixSumRuntimeFamilyF32 = prefixSumRuntimeFamily(.f32);
pub const PrefixSumRuntimeFamilyF16 = prefixSumRuntimeFamily(.f16);
pub const PrefixSumRuntimeFamilyU32 = prefixSumRuntimeFamily(.u32);

pub const DeviceScan = struct {
    extent: u64,
    dtype: DType = .f32,
    mode: PrefixSumMode = .inclusive,
    threads: u32 = 256,
    element_axis: []const u8 = "e",
};

pub const device_scan_family_version: u32 = 1;
pub const device_scan_max_blocks: u32 = prefix_sum_max_threads;

pub fn deviceScanBlockCount(extent: u64, threads: u32) u64 {
    return (extent + threads - 1) / threads;
}

pub fn deviceScanDTypeSupported(dtype: DType) bool {
    return switch (dtype) {
        .f32, .f16, .u32 => true,
        else => false,
    };
}

pub fn deviceScanInstanceValid(instance: DeviceScan) bool {
    if (!deviceScanDTypeSupported(instance.dtype)) return false;
    if (instance.extent == 0) return false;
    if (instance.threads == 0 or instance.threads > prefix_sum_max_threads) return false;
    if (instance.threads % prefix_sum_warp_size != 0) return false;
    return extent_mod.blockCountWithinLimit(
        instance.extent,
        instance.threads,
        device_scan_max_blocks,
    );
}

fn deviceScanPrefixSum(spec: DeviceScan) PrefixSum {
    return .{
        .extent = spec.extent,
        .dtype = spec.dtype,
        .mode = spec.mode,
        .threads = spec.threads,
        .element_axis = spec.element_axis,
    };
}

fn device_scan_block_scan_body_writes_total(inner: anytype, ctx: anytype) !void {
    try ctx.args.param(.sums).store(inner, ctx.total, ctx.block);
}

fn deviceScanBlockScanBody(k: anytype, spec: DeviceScan, args: anytype) !void {
    if (!deviceScanInstanceValid(spec)) return error.UnsupportedDeviceScanInstance;
    const extent = try k.castIndex(args.param(.extent).raw());
    const local = try k.threadId(.x);
    const warp_sums = try prefixSumScanCore(k, deviceScanPrefixSum(spec), args, extent, local);
    const block = try k.blockId(.x);
    const zero = try k.constantIndex(0);
    const last_slot = try k.constantIndex(prefix_sum_warp_size - 1);
    const total = try k.loadIndex(warp_sums, last_slot);
    const writes_total = try k.compare(.eq, local, zero);
    try k.guardDo(
        writes_total,
        .{ .args = args, .total = total, .block = block },
        device_scan_block_scan_body_writes_total,
    );
}

fn device_scan_add_base_body_in_range(inner: anytype, ctx: anytype) !void {
    const current = try ctx.args.param(.dst).load(inner, ctx.tid);
    const updated = try inner.add(current.raw(), ctx.base.raw());
    try ctx.args.param(.dst).store(inner, updated, ctx.tid);
}

fn deviceScanAddBaseBody(k: anytype, spec: DeviceScan, args: anytype) !void {
    if (!deviceScanInstanceValid(spec)) return error.UnsupportedDeviceScanInstance;
    const extent = try k.castIndex(args.param(.extent).raw());
    const tid = try k.globalId(.x);
    const block = try k.blockId(.x);
    const base = try args.param(.base).load(k, block);
    const in_range = try k.compare(.lt, tid, extent);
    try k.guardDo(
        in_range,
        .{ .args = args, .tid = tid, .base = base },
        device_scan_add_base_body_in_range,
    );
}

fn deviceScanFamilySchedule(instance: DeviceScan) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn deviceScanBlockScanRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_scan_device_block_scan_runtime_{s}",
            .{dtype.name()},
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(deviceScanBlockScanOutputDType(dtype)),
            .data = kernel.dynamicBuffer(dtype),
            .sums = kernel.dynamicBuffer(prefixSumAccumulatorDType(dtype)),
            .extent = kernel.scalar(.i32),
        },
        .Instance = DeviceScan,
        .schedule = deviceScanFamilySchedule,
        .body = deviceScanBlockScanBody,
    });
}

fn deviceScanBlockScanOutputDType(comptime dtype: DType) DType {
    return switch (dtype) {
        .f16 => .f32,
        else => dtype,
    };
}

fn device_scan_add_base_body_f16_in_range(inner: anytype, ctx: anytype) !void {
    const local = try ctx.args.param(.local).load(inner, ctx.tid);
    const updated = try inner.add(local.raw(), ctx.base.raw());
    const result = try inner.cast(updated, .f16);
    try ctx.args.param(.dst).store(inner, result, ctx.tid);
}

fn deviceScanAddBaseBodyF16(k: anytype, spec: DeviceScan, args: anytype) !void {
    if (!deviceScanInstanceValid(spec)) return error.UnsupportedDeviceScanInstance;
    const extent = try k.castIndex(args.param(.extent).raw());
    const tid = try k.globalId(.x);
    const block = try k.blockId(.x);
    const base = try args.param(.base).load(k, block);
    const in_range = try k.compare(.lt, tid, extent);
    try k.guardDo(
        in_range,
        .{ .args = args, .tid = tid, .base = base },
        device_scan_add_base_body_f16_in_range,
    );
}

fn deviceScanAddBaseRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_scan_device_add_base_runtime_{s}",
            .{dtype.name()},
        ),
        .parameters = switch (dtype) {
            .f16 => .{
                .dst = kernel.dynamicBuffer(dtype),
                .local = kernel.dynamicBuffer(.f32),
                .base = kernel.dynamicBuffer(.f32),
                .extent = kernel.scalar(.i32),
            },
            else => .{
                .dst = kernel.dynamicBuffer(dtype),
                .base = kernel.dynamicBuffer(prefixSumAccumulatorDType(dtype)),
                .extent = kernel.scalar(.i32),
            },
        },
        .Instance = DeviceScan,
        .schedule = deviceScanFamilySchedule,
        .body = switch (dtype) {
            .f16 => deviceScanAddBaseBodyF16,
            else => deviceScanAddBaseBody,
        },
    });
}

pub const DeviceScanBlockScanRuntimeFamilyF32 = deviceScanBlockScanRuntimeFamily(.f32);
pub const DeviceScanBlockScanRuntimeFamilyF16 = deviceScanBlockScanRuntimeFamily(.f16);
pub const DeviceScanBlockScanRuntimeFamilyU32 = deviceScanBlockScanRuntimeFamily(.u32);
pub const DeviceScanAddBaseRuntimeFamilyF32 = deviceScanAddBaseRuntimeFamily(.f32);
pub const DeviceScanAddBaseRuntimeFamilyF16 = deviceScanAddBaseRuntimeFamily(.f16);
pub const DeviceScanAddBaseRuntimeFamilyU32 = deviceScanAddBaseRuntimeFamily(.u32);

pub const DeviceScanStages = struct {
    block_count: u32,
    block_scan: DeviceScan,
    sums_scan: PrefixSum,
    add_base: DeviceScan,
};

pub fn deviceScanStages(instance: DeviceScan) !DeviceScanStages {
    if (!deviceScanInstanceValid(instance)) return error.UnsupportedDeviceScanInstance;
    const blocks: u32 = @intCast(deviceScanBlockCount(instance.extent, instance.threads));
    const sums_threads = prefixSumThreadsForExtent(blocks) orelse
        return error.UnsupportedDeviceScanInstance;
    return .{
        .block_count = blocks,
        .block_scan = instance,
        .sums_scan = .{
            .extent = blocks,
            .dtype = prefixSumAccumulatorDType(instance.dtype),
            .mode = .exclusive,
            .threads = sums_threads,
            .element_axis = "b",
        },
        .add_base = instance,
    };
}

pub fn deviceScanBlockScanFamilyTarget(allocator: std.mem.Allocator, instance: DeviceScan) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.scan.device_{s}_block_scan_family_{d}_{s}",
        .{ prefixSumModePrefix(instance.mode), instance.threads, instance.dtype.name() },
    );
}

pub fn deviceScanBlockScanFamilyEntryName(
    allocator: std.mem.Allocator,
    instance: DeviceScan,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_scan_device_{s}_block_scan_family_{d}_{s}",
        .{ prefixSumModePrefix(instance.mode), instance.threads, instance.dtype.name() },
    );
}

pub fn deviceScanAddBaseFamilyTarget(allocator: std.mem.Allocator, instance: DeviceScan) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.scan.device_add_base_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

pub fn deviceScanAddBaseFamilyEntryName(allocator: std.mem.Allocator, instance: DeviceScan) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_scan_device_add_base_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

pub fn deviceScanFamilyTarget(allocator: std.mem.Allocator, instance: DeviceScan) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.scan.device_{s}_family_{d}_{s}",
        .{ prefixSumModePrefix(instance.mode), instance.threads, instance.dtype.name() },
    );
}

pub fn deviceScanThreadsForExtent(extent: u64) ?u32 {
    if (extent == 0) return null;
    const max_extent = @as(u64, prefix_sum_max_threads) * device_scan_max_blocks;
    if (extent > max_extent) return null;
    const needed = (extent + device_scan_max_blocks - 1) / device_scan_max_blocks;
    const wide = needed + prefix_sum_warp_size - 1;
    const rounded: u32 = @intCast((wide / prefix_sum_warp_size) * prefix_sum_warp_size);
    return @max(rounded, prefix_sum_warp_size);
}

pub const DeviceScanThreadCandidates = struct {
    count: usize = 0,
    items: [6]u32 = @as([6]u32, @splat(0)),

    pub fn slice(self: *const DeviceScanThreadCandidates) []const u32 {
        return self.items[0..self.count];
    }
};

pub fn deviceScanThreadCandidatesForExtent(extent: u64) DeviceScanThreadCandidates {
    var result = DeviceScanThreadCandidates{};
    const base = deviceScanThreadsForExtent(extent) orelse return result;
    result.items[result.count] = base;
    result.count += 1;
    var threads: u32 = prefix_sum_warp_size;
    while (threads <= prefix_sum_max_threads) : (threads *= 2) {
        if (threads == base) continue;
        if (threads < base) continue;
        if (result.count >= result.items.len) break;
        result.items[result.count] = threads;
        result.count += 1;
    }
    return result;
}

pub fn deviceScanFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: DeviceScan,
) !entry.OwnedSpecialization {
    if (!deviceScanInstanceValid(instance)) return error.UnsupportedDeviceScanInstance;
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 1);
    inputs[0] = try entry.runtimeShape1D(
        lifetime_allocator,
        instance.element_axis,
        instance.extent,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(
        lifetime_allocator,
        instance.element_axis,
        instance.extent,
    );

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .scan = instance.mode.operation() },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.element_axis,
            instance.extent,
            instance.threads,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try deviceScanBlockScanShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn deviceScanInstanceFromSpecialization(specialization: entry.Specialization) ?DeviceScan {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const mode: PrefixSumMode = if (specialization.operationIs(.{ .scan = .prefix_sum }))
        .inclusive
    else if (specialization.operationIs(.{ .scan = .prefix_sum_exclusive }))
        .exclusive
    else
        return null;
    const dtype = specialization.dtype orelse return null;
    if (!deviceScanDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const data = specialization.inputs[0];
    const output = specialization.outputs[0];
    if (data.axes.len != 1 or output.axes.len != 1) return null;
    const extent = data.axes[0].extent;
    if (output.axes[0].extent != extent) return null;
    const launch = specialization.launch orelse return null;
    if (launch.grid[0] <= 1) return null;
    const instance = DeviceScan{
        .extent = extent,
        .dtype = dtype,
        .mode = mode,
        .threads = launch.threadgroup[0],
        .element_axis = data.axes[0].name,
    };
    if (!deviceScanInstanceValid(instance)) return null;
    if (launch.grid[0] != deviceScanBlockCount(extent, instance.threads)) return null;
    return instance;
}

pub fn deviceScanPipeline(
    backing_allocator: std.mem.Allocator,
    instance: DeviceScan,
) !artifact_product.OwnedKernelCallPipeline {
    if (!deviceScanInstanceValid(instance)) return error.UnsupportedDeviceScanInstance;
    const stages = try deviceScanStages(instance);
    var owned = artifact_product.OwnedKernelCallPipeline.init(backing_allocator);
    errdefer owned.deinit();
    const arena = owned.allocator();

    const block_count_extent = artifact_product.PipelineScalarDerivation{
        .ceil_div = .{ .argument_index = 0, .divisor = instance.threads },
    };
    const accumulator_dtype = prefixSumAccumulatorDType(instance.dtype);
    const local_prefix_index: ?u32 = if (instance.dtype == .f16) 2 else null;
    const intermediate_count: usize = if (local_prefix_index != null) 3 else 2;
    const intermediates = try arena.alloc(
        artifact_product.PipelineIntermediate,
        intermediate_count,
    );
    intermediates[0] = .{ .dtype = accumulator_dtype, .extent = block_count_extent };
    intermediates[1] = .{ .dtype = accumulator_dtype, .extent = block_count_extent };
    if (local_prefix_index) |index| {
        intermediates[index] = .{ .dtype = accumulator_dtype, .extent = .{ .forward = 0 } };
    }
    const runtime_scalar_bounds = try arena.alloc(artifact_product.PipelineRuntimeScalarBound, 1);
    runtime_scalar_bounds[0] = .{
        .argument_index = 0,
        .max_u32 = try deviceScanPipelineRuntimeExtentCapacity(instance, stages),
    };

    const pipeline_stages = try arena.alloc(artifact_product.PipelineStage, 3);
    pipeline_stages[0] = .{
        .target = try deviceScanBlockScanFamilyTarget(arena, instance),
        .version = device_scan_family_version,
        .buffers = try arena.dupe(
            artifact_product.PipelineValueRef,
            if (local_prefix_index) |index| &.{
                .{ .intermediate = index }, .{ .operand = 0 }, .{ .intermediate = 0 },
            } else &.{
                .{ .result = 0 }, .{ .operand = 0 }, .{ .intermediate = 0 },
            },
        ),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            .{ .forward = 0 },
        }),
    };
    pipeline_stages[1] = .{
        .target = try prefixSumFamilyTarget(arena, stages.sums_scan),
        .version = prefix_sum_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 1 }, .{ .intermediate = 0 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            block_count_extent,
        }),
    };
    pipeline_stages[2] = .{
        .target = try deviceScanAddBaseFamilyTarget(arena, instance),
        .version = device_scan_family_version,
        .buffers = try arena.dupe(
            artifact_product.PipelineValueRef,
            if (local_prefix_index) |index| &.{
                .{ .result = 0 }, .{ .intermediate = index }, .{ .intermediate = 1 },
            } else &.{
                .{ .result = 0 }, .{ .intermediate = 1 },
            },
        ),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            .{ .forward = 0 },
        }),
    };

    owned.value = .{
        .target = try deviceScanFamilyTarget(arena, instance),
        .version = device_scan_family_version,
        .operand_count = 1,
        .result_count = 1,
        .runtime_scalar_argument_count = 1,
        .runtime_scalar_bounds = runtime_scalar_bounds,
        .intermediates = intermediates,
        .stages = pipeline_stages,
    };
    return owned;
}

pub const DeviceScanPipelineArtifacts = struct {
    block_scan: kernel.OwnedKernelCallArtifact,
    sums_scan: kernel.OwnedKernelCallArtifact,
    add_base: kernel.OwnedKernelCallArtifact,

    pub fn entries(
        self: *const DeviceScanPipelineArtifacts,
    ) [3]artifact_product.KernelCallArtifact {
        return .{ self.block_scan.entry(), self.sums_scan.entry(), self.add_base.entry() };
    }

    pub fn deinit(self: *DeviceScanPipelineArtifacts) void {
        self.block_scan.deinit();
        self.sums_scan.deinit();
        self.add_base.deinit();
        self.* = undefined;
    }
};

pub fn createDeviceScanPipelineArtifacts(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: DeviceScan,
    options: entry.ArtifactOptions,
) !DeviceScanPipelineArtifacts {
    if (!deviceScanInstanceValid(instance)) return error.UnsupportedDeviceScanInstance;
    const stages = try deviceScanStages(instance);
    var block_scan = try createDeviceScanBlockScanFamilyArtifact(
        allocator,
        handle,
        instance,
        options,
    );
    errdefer block_scan.deinit();
    var sums_scan = try createPrefixSumFamilyArtifact(allocator, handle, stages.sums_scan, options);
    errdefer sums_scan.deinit();
    const add_base = try createDeviceScanAddBaseFamilyArtifact(
        allocator,
        handle,
        instance,
        options,
    );
    return .{ .block_scan = block_scan, .sums_scan = sums_scan, .add_base = add_base };
}

pub fn deviceScanRuntimeArguments(instance: DeviceScan) ![1]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.extent) },
    };
}

fn deviceScanPipelineRuntimeExtentCapacity(instance: DeviceScan, stages: DeviceScanStages) !u32 {
    if (!deviceScanInstanceValid(instance)) return error.UnsupportedDeviceScanInstance;
    return std.math.mul(
        u32,
        instance.threads,
        stages.sums_scan.threads,
    ) catch return error.UnsupportedDeviceScanInstance;
}

pub fn deviceScanMaxExtent(instance: DeviceScan) u64 {
    return @as(u64, instance.threads) * device_scan_max_blocks;
}

pub fn deviceScanShapeProfileDimensions(
    instance: DeviceScan,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.element_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = .{ .min = 1, .max = deviceScanMaxExtent(instance) },
        },
    };
}

fn deviceScanLaunch(instance: DeviceScan) !artifact_product.KernelCallLaunch {
    if (!deviceScanInstanceValid(instance)) return error.UnsupportedDeviceScanInstance;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = instance.threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn deviceScanBlockScanShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: DeviceScan,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "device_scan_block_scan");
    errdefer builder.deinit();

    const elements = try builder.symbol(instance.element_axis);
    const elements_expr = try builder.symbolExpression(elements);
    const blocks = try builder.symbol("blocks");
    const blocks_expr = try builder.symbolExpression(blocks);

    _ = try builder.tensor("data", &.{elements_expr});
    _ = try builder.tensor("out", &.{elements_expr});
    _ = try builder.tensor("sums", &.{blocks_expr});
    try builder.assumeBounds(elements_expr, .{ .min = 1, .max = deviceScanMaxExtent(instance) });
    try builder.assumeBounds(blocks_expr, .{ .min = 1, .max = device_scan_max_blocks });

    return builder.finish();
}

pub fn deviceScanBlockScanFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: DeviceScan,
) !u64 {
    var family = try deviceScanBlockScanShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn deviceScanAddBaseShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: DeviceScan,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "device_scan_add_base");
    errdefer builder.deinit();

    const elements = try builder.symbol(instance.element_axis);
    const elements_expr = try builder.symbolExpression(elements);
    const blocks = try builder.symbol("blocks");
    const blocks_expr = try builder.symbolExpression(blocks);

    _ = try builder.tensor("out", &.{elements_expr});
    if (instance.dtype == .f16) {
        _ = try builder.tensor("local", &.{elements_expr});
    }
    _ = try builder.tensor("base", &.{blocks_expr});
    try builder.assumeBounds(elements_expr, .{ .min = 1, .max = deviceScanMaxExtent(instance) });
    try builder.assumeBounds(blocks_expr, .{ .min = 1, .max = device_scan_max_blocks });

    return builder.finish();
}

pub fn deviceScanAddBaseFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: DeviceScan,
) !u64 {
    var family = try deviceScanAddBaseShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn createDeviceScanBlockScanFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: DeviceScan,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!deviceScanInstanceValid(instance)) return error.UnsupportedDeviceScanInstance;
    const target = try deviceScanBlockScanFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try deviceScanBlockScanFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try deviceScanBlockScanFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = deviceScanShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "device_scan_block_scan",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try DeviceScanBlockScanRuntimeFamilyF32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .f16 => try DeviceScanBlockScanRuntimeFamilyF16.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .u32 => try DeviceScanBlockScanRuntimeFamilyU32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = device_scan_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try deviceScanLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn createDeviceScanAddBaseFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: DeviceScan,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!deviceScanInstanceValid(instance)) return error.UnsupportedDeviceScanInstance;
    const target = try deviceScanAddBaseFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try deviceScanAddBaseFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try deviceScanAddBaseFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = deviceScanShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "device_scan_add_base",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try DeviceScanAddBaseRuntimeFamilyF32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .f16 => try DeviceScanAddBaseRuntimeFamilyF16.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .u32 => try DeviceScanAddBaseRuntimeFamilyU32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = device_scan_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try deviceScanLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn prefixSumInstanceTarget(allocator: std.mem.Allocator, instance: PrefixSum) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.scan.prefix_sum{d}_{d}_{s}",
        .{ instance.extent, instance.threads, instance.dtype.name() },
    );
}

pub fn prefixSumInstanceEntryName(allocator: std.mem.Allocator, instance: PrefixSum) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_scan_prefix_sum{d}_{d}_{s}",
        .{ instance.extent, instance.threads, instance.dtype.name() },
    );
}

fn prefixSumModePrefix(mode: PrefixSumMode) []const u8 {
    return switch (mode) {
        .inclusive => "prefix_sum",
        .exclusive => "prefix_sum_exclusive",
    };
}

pub fn prefixSumFamilyTarget(allocator: std.mem.Allocator, instance: PrefixSum) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.scan.{s}_family_{d}_{s}",
        .{ prefixSumModePrefix(instance.mode), instance.threads, instance.dtype.name() },
    );
}

pub fn prefixSumFamilyEntryName(allocator: std.mem.Allocator, instance: PrefixSum) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_scan_{s}_family_{d}_{s}",
        .{ prefixSumModePrefix(instance.mode), instance.threads, instance.dtype.name() },
    );
}

pub fn prefixSumTuningExtents(instance: PrefixSum) [1]u64 {
    return .{instance.extent};
}

pub fn prefixSumTuningOperation(instance: PrefixSum) entry.Operation {
    return .{ .scan = instance.mode.operation() };
}

pub fn prefixSumFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: PrefixSum,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try prefixSumFamilyFingerprint(backing_allocator, instance);
    const extents = prefixSumTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(prefixSumTuningOperation(instance)),
        instance.dtype,
        prefix_sum_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn prefixSumRuntimeArguments(instance: PrefixSum) ![1]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.extent) },
    };
}

pub fn prefixSumShapeProfileDimensions(
    instance: PrefixSum,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.element_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = .{ .min = 1, .max = instance.threads },
        },
    };
}

fn prefixSumLaunch(instance: PrefixSum) !artifact_product.KernelCallLaunch {
    if (!prefixSumInstanceValid(instance)) return error.UnsupportedPrefixSumInstance;
    return .{ .derived = .{
        .grid = .{
            .{ .fixed = 1 },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn createPrefixSumFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: PrefixSum,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!prefixSumInstanceValid(instance)) return error.UnsupportedPrefixSumInstance;
    const target = try prefixSumFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try prefixSumFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try prefixSumFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = prefixSumShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "prefix_sum",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try PrefixSumRuntimeFamilyF32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .f16 => try PrefixSumRuntimeFamilyF16.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .u32 => try PrefixSumRuntimeFamilyU32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = prefix_sum_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try prefixSumLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn prefixSumFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: PrefixSum) !u64 {
    var family = try prefixSumShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn prefixSumShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: PrefixSum,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "prefix_sum");
    errdefer builder.deinit();

    const elements = try builder.symbol(instance.element_axis);
    const elements_expr = try builder.symbolExpression(elements);

    _ = try builder.tensor("data", &.{elements_expr});
    _ = try builder.tensor("out", &.{elements_expr});
    try builder.assumeBounds(elements_expr, .{ .min = 1, .max = instance.threads });

    return builder.finish();
}

pub fn prefixSumFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: PrefixSum,
) !entry.OwnedSpecialization {
    if (!prefixSumInstanceValid(instance)) return error.UnsupportedPrefixSumInstance;
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 1);
    inputs[0] = try entry.runtimeShape1D(
        lifetime_allocator,
        instance.element_axis,
        instance.extent,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(
        lifetime_allocator,
        instance.element_axis,
        instance.extent,
    );

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .scan = instance.mode.operation() },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.element_axis,
            instance.threads,
            instance.threads,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try prefixSumShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn prefixSumInstanceFromSpecialization(specialization: entry.Specialization) ?PrefixSum {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const mode: PrefixSumMode = if (specialization.operationIs(.{ .scan = .prefix_sum }))
        .inclusive
    else if (specialization.operationIs(.{ .scan = .prefix_sum_exclusive }))
        .exclusive
    else
        return null;
    const dtype = specialization.dtype orelse return null;
    if (!prefixSumDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const data = specialization.inputs[0];
    const output = specialization.outputs[0];
    if (data.axes.len != 1 or output.axes.len != 1) return null;
    const extent = data.axes[0].extent;
    if (output.axes[0].extent != extent) return null;
    const launch = specialization.launch orelse return null;
    if (launch.grid[0] != 1) return null;
    const instance = PrefixSum{
        .extent = extent,
        .dtype = dtype,
        .mode = mode,
        .threads = launch.threadgroup[0],
        .element_axis = data.axes[0].name,
    };
    if (!prefixSumInstanceValid(instance)) return null;
    return instance;
}

fn prefixSumSpecialization(comptime spec: PrefixSum) entry.Specialization {
    return .{
        .dtype = spec.dtype,
        .operation = .{ .scan = spec.mode.operation() },
        .inputs = &.{entry.shape1D(spec.element_axis, spec.extent)},
        .outputs = &.{entry.shape1D(spec.element_axis, spec.extent)},
        .launch = entry.launch1D(1, spec.threads),
        .schedule = entry.threadBlocks1D(spec.element_axis, spec.threads, spec.threads),
    };
}

fn prefixSumProgram(comptime spec: PrefixSum) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            try prefixSumBody(k, spec, args);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_scan_prefix_sum{}_{}_{s}",
            .{ spec.extent, spec.threads, spec.dtype.name() },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(spec.dtype),
            .data = kernel.dynamicBuffer(spec.dtype),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

pub fn prefixSumF32(comptime spec: PrefixSum) type {
    return entry.Entry(prefixSumProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.scan.prefix_sum{}_{}_{s}",
            .{ spec.extent, spec.threads, spec.dtype.name() },
        ),
        .layer = .logical,
        .category = .scan,
        .specialization = prefixSumSpecialization(spec),
    });
}

pub const PrefixSum8F32 = prefixSumF32(.{ .extent = 8, .threads = 32 });

const testing = std.testing;

fn expectPrefixSumMatchesOracle(extent: usize, threads: u32) !void {
    try expectPrefixSumModeMatchesOracle(extent, threads, .inclusive);
}

fn expectPrefixSumModeMatchesOracle(extent: usize, threads: u32, mode: PrefixSumMode) !void {
    const allocator = testing.allocator;
    const compiled = PrefixSum{ .extent = 1, .threads = threads, .mode = mode };
    const runtime = PrefixSum{ .extent = extent, .threads = threads, .mode = mode };

    var graph = try PrefixSumRuntimeFamilyF32.build(
        allocator,
        PrefixSumRuntimeFamilyF32.Limits.testing,
        compiled,
    );
    defer graph.deinit();

    const data = try allocator.alloc(f32, extent);
    defer allocator.free(data);
    for (data, 0..) |*value, index| value.* = @floatFromInt((index % 7) + 1);
    const dst = try allocator.alloc(f32, extent);
    defer allocator.free(dst);
    @memset(dst, 0);

    const expected = try allocator.alloc(f32, extent);
    defer allocator.free(expected);
    var running: f32 = 0;
    for (data, 0..) |value, index| {
        switch (mode) {
            .inclusive => {
                running += value;
                expected[index] = running;
            },
            .exclusive => {
                expected[index] = running;
                running += value;
            },
        }
    }

    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst),
        kernel.argumentBuffer(f32, data),
        kernel.argumentI32(@intCast(runtime.extent)),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ runtime.threads, 1, 1 },
    });
    for (expected, dst) |want, got| {
        try testing.expectApproxEqAbs(want, got, 0.001);
    }
}

fn expectPrefixSumU32ModeMatchesOracle(extent: usize, threads: u32, mode: PrefixSumMode) !void {
    const allocator = testing.allocator;
    const compiled = PrefixSum{ .extent = 1, .dtype = .u32, .threads = threads, .mode = mode };
    const runtime = PrefixSum{ .extent = extent, .dtype = .u32, .threads = threads, .mode = mode };

    var graph = try PrefixSumRuntimeFamilyU32.build(
        allocator,
        PrefixSumRuntimeFamilyU32.Limits.testing,
        compiled,
    );
    defer graph.deinit();

    const data = try allocator.alloc(u32, extent);
    defer allocator.free(data);
    for (data, 0..) |*value, index| value.* = @intCast((index % 7) + 1);
    const dst = try allocator.alloc(u32, extent);
    defer allocator.free(dst);
    @memset(dst, 0);

    const expected = try allocator.alloc(u32, extent);
    defer allocator.free(expected);
    var running: u32 = 0;
    for (data, 0..) |value, index| {
        switch (mode) {
            .inclusive => {
                running += value;
                expected[index] = running;
            },
            .exclusive => {
                expected[index] = running;
                running += value;
            },
        }
    }

    const launch_value = try entry.runtimeLaunch1D(runtime.threads, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(u32, dst),
        kernel.argumentBuffer(u32, data),
        kernel.argumentI32(@intCast(runtime.extent)),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });
    try testing.expectEqualSlices(u32, expected, dst);
}

fn expectDeviceScanMatchesOracle(extent: usize, threads: u32, mode: PrefixSumMode) !void {
    const allocator = testing.allocator;
    const compiled = DeviceScan{ .extent = 1, .threads = threads, .mode = mode };
    const runtime = DeviceScan{ .extent = extent, .threads = threads, .mode = mode };
    const stages = try deviceScanStages(runtime);

    const data = try allocator.alloc(f32, extent);
    defer allocator.free(data);
    for (data, 0..) |*value, index| value.* = @floatFromInt((index % 7) + 1);
    const dst = try allocator.alloc(f32, extent);
    defer allocator.free(dst);
    @memset(dst, 0);
    const sums = try allocator.alloc(f32, stages.block_count);
    defer allocator.free(sums);
    @memset(sums, 0);
    const bases = try allocator.alloc(f32, stages.block_count);
    defer allocator.free(bases);
    @memset(bases, 0);

    var block_scan = try DeviceScanBlockScanRuntimeFamilyF32.build(
        allocator,
        DeviceScanBlockScanRuntimeFamilyF32.Limits.testing,
        compiled,
    );
    defer block_scan.deinit();
    try block_scan.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst),
        kernel.argumentBuffer(f32, data),
        kernel.argumentBuffer(f32, sums),
        kernel.argumentI32(@intCast(runtime.extent)),
    }, .{
        .grid = .{ stages.block_count, 1, 1 },
        .block = .{ runtime.threads, 1, 1 },
    });

    var sums_scan = try PrefixSumRuntimeFamilyF32.build(
        allocator,
        PrefixSumRuntimeFamilyF32.Limits.testing,
        .{
            .extent = 1,
            .mode = .exclusive,
            .threads = stages.sums_scan.threads,
        },
    );
    defer sums_scan.deinit();
    try sums_scan.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, bases),
        kernel.argumentBuffer(f32, sums),
        kernel.argumentI32(@intCast(stages.block_count)),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ stages.sums_scan.threads, 1, 1 },
    });

    var add_base = try DeviceScanAddBaseRuntimeFamilyF32.build(
        allocator,
        DeviceScanAddBaseRuntimeFamilyF32.Limits.testing,
        compiled,
    );
    defer add_base.deinit();
    try add_base.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst),
        kernel.argumentBuffer(f32, bases),
        kernel.argumentI32(@intCast(runtime.extent)),
    }, .{
        .grid = .{ stages.block_count, 1, 1 },
        .block = .{ runtime.threads, 1, 1 },
    });

    var running: f32 = 0;
    for (data, dst) |value, got| {
        switch (mode) {
            .inclusive => {
                running += value;
                try testing.expectEqual(running, got);
            },
            .exclusive => {
                try testing.expectEqual(running, got);
                running += value;
            },
        }
    }
}

fn expectDeviceScanF16MatchesOracle(extent: usize, threads: u32, mode: PrefixSumMode) !void {
    const allocator = testing.allocator;
    const compiled = DeviceScan{ .extent = 1, .dtype = .f16, .threads = threads, .mode = mode };
    const runtime = DeviceScan{ .extent = extent, .dtype = .f16, .threads = threads, .mode = mode };
    const stages = try deviceScanStages(runtime);

    const data = try allocator.alloc(f16, extent);
    defer allocator.free(data);
    for (data, 0..) |*value, index| value.* = @floatFromInt((index % 5) + 1);
    const local = try allocator.alloc(f32, extent);
    defer allocator.free(local);
    @memset(local, 0);
    const dst = try allocator.alloc(f16, extent);
    defer allocator.free(dst);
    @memset(dst, 0);
    const sums = try allocator.alloc(f32, stages.block_count);
    defer allocator.free(sums);
    @memset(sums, 0);
    const bases = try allocator.alloc(f32, stages.block_count);
    defer allocator.free(bases);
    @memset(bases, 0);

    var block_scan = try DeviceScanBlockScanRuntimeFamilyF16.build(
        allocator,
        DeviceScanBlockScanRuntimeFamilyF16.Limits.testing,
        compiled,
    );
    defer block_scan.deinit();
    try block_scan.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, local),
        kernel.argumentBuffer(f16, data),
        kernel.argumentBuffer(f32, sums),
        kernel.argumentI32(@intCast(runtime.extent)),
    }, .{
        .grid = .{ stages.block_count, 1, 1 },
        .block = .{ runtime.threads, 1, 1 },
    });

    var sums_scan = try PrefixSumRuntimeFamilyF32.build(
        allocator,
        PrefixSumRuntimeFamilyF32.Limits.testing,
        .{
            .extent = 1,
            .mode = .exclusive,
            .threads = stages.sums_scan.threads,
        },
    );
    defer sums_scan.deinit();
    try sums_scan.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, bases),
        kernel.argumentBuffer(f32, sums),
        kernel.argumentI32(@intCast(stages.block_count)),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ stages.sums_scan.threads, 1, 1 },
    });

    var add_base = try DeviceScanAddBaseRuntimeFamilyF16.build(
        allocator,
        DeviceScanAddBaseRuntimeFamilyF16.Limits.testing,
        compiled,
    );
    defer add_base.deinit();
    try add_base.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f16, dst),
        kernel.argumentBuffer(f32, local),
        kernel.argumentBuffer(f32, bases),
        kernel.argumentI32(@intCast(runtime.extent)),
    }, .{
        .grid = .{ stages.block_count, 1, 1 },
        .block = .{ runtime.threads, 1, 1 },
    });

    var running: f32 = 0;
    for (data, dst) |value, got| {
        const value_f32: f32 = @floatCast(value);
        switch (mode) {
            .inclusive => {
                running += value_f32;
                const expected: f16 = @floatCast(running);
                try testing.expectEqual(expected, got);
            },
            .exclusive => {
                const expected: f16 = @floatCast(running);
                try testing.expectEqual(expected, got);
                running += value_f32;
            },
        }
    }
}

fn expectDeviceScanU32MatchesOracle(extent: usize, threads: u32, mode: PrefixSumMode) !void {
    const allocator = testing.allocator;
    const compiled = DeviceScan{ .extent = 1, .dtype = .u32, .threads = threads, .mode = mode };
    const runtime = DeviceScan{ .extent = extent, .dtype = .u32, .threads = threads, .mode = mode };
    const stages = try deviceScanStages(runtime);

    const data = try allocator.alloc(u32, extent);
    defer allocator.free(data);
    for (data, 0..) |*value, index| value.* = @intCast((index % 7) + 1);
    const dst = try allocator.alloc(u32, extent);
    defer allocator.free(dst);
    @memset(dst, 0);
    const sums = try allocator.alloc(u32, stages.block_count);
    defer allocator.free(sums);
    @memset(sums, 0);
    const bases = try allocator.alloc(u32, stages.block_count);
    defer allocator.free(bases);
    @memset(bases, 0);

    var block_scan = try DeviceScanBlockScanRuntimeFamilyU32.build(
        allocator,
        DeviceScanBlockScanRuntimeFamilyU32.Limits.testing,
        compiled,
    );
    defer block_scan.deinit();
    try block_scan.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(u32, dst),
        kernel.argumentBuffer(u32, data),
        kernel.argumentBuffer(u32, sums),
        kernel.argumentI32(@intCast(runtime.extent)),
    }, .{
        .grid = .{ stages.block_count, 1, 1 },
        .block = .{ runtime.threads, 1, 1 },
    });

    var sums_scan = try PrefixSumRuntimeFamilyU32.build(
        allocator,
        PrefixSumRuntimeFamilyU32.Limits.testing,
        .{
            .extent = 1,
            .dtype = .u32,
            .mode = .exclusive,
            .threads = stages.sums_scan.threads,
        },
    );
    defer sums_scan.deinit();
    try sums_scan.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(u32, bases),
        kernel.argumentBuffer(u32, sums),
        kernel.argumentI32(@intCast(stages.block_count)),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ stages.sums_scan.threads, 1, 1 },
    });

    var add_base = try DeviceScanAddBaseRuntimeFamilyU32.build(
        allocator,
        DeviceScanAddBaseRuntimeFamilyU32.Limits.testing,
        compiled,
    );
    defer add_base.deinit();
    try add_base.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(u32, dst),
        kernel.argumentBuffer(u32, bases),
        kernel.argumentI32(@intCast(runtime.extent)),
    }, .{
        .grid = .{ stages.block_count, 1, 1 },
        .block = .{ runtime.threads, 1, 1 },
    });

    var running: u32 = 0;
    for (data, dst) |value, got| {
        switch (mode) {
            .inclusive => {
                running += value;
                try testing.expectEqual(running, got);
            },
            .exclusive => {
                try testing.expectEqual(running, got);
                running += value;
            },
        }
    }
}
