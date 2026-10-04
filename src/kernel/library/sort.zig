const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");

const artifact_product = @import("../../artifact/model/root.zig");
const shape = @import("../../choir/shape/root.zig");
const entry = @import("entry.zig");
const extent_mod = @import("extent.zig");
const kernel = @import("../root.zig");
const scan = @import("scan.zig");
const tuning = @import("tuning.zig");

const runtimeExtentArgument = extent_mod.runtimeExtentArgument;

pub const RadixSplit = struct {
    extent: u64,
    threads: u32 = 256,
    element_axis: []const u8 = "e",
};

pub const BitonicBlock = struct {
    extent: u64,
    threads: u32 = 256,
    element_axis: []const u8 = "e",
};

pub const TopKBlock = struct {
    extent: u64,
    k: u64,
    threads: u32 = 256,
    element_axis: []const u8 = "e",
};

pub const TopKBlockPairs = struct {
    extent: u64,
    k: u64,
    threads: u32 = 256,
    element_axis: []const u8 = "e",
};

pub const radix_split_family_version: u32 = 1;
pub const radix_split_warp_size: u32 = 32;
pub const radix_split_max_threads: u32 = 1024;
pub const radix_split_max_blocks: u32 = 1024;
pub const radix_split_key_bits: u32 = 32;
pub const radix_digit_bins: u32 = 16;
pub const radix_digit_bits: u32 = 4;
pub const bitonic_block_family_version: u32 = 1;
pub const bitonic_block_structure_name = "bitonic_block";
pub const top_k_block_structure_name = "top_k_block";
pub const top_k_block_pairs_structure_name = "top_k_block_pairs";
pub const bitonic_block_min_threads: u32 = 32;
pub const bitonic_block_max_threads: u32 = 1024;
pub const top_k_block_family_version: u32 = 1;
pub const top_k_block_pairs_family_version: u32 = 1;

pub const RadixSplitResolvedStructure = enum {
    radix_split,
    radix_digit,
};

pub fn radixSplitBlockCount(extent: u64, threads: u32) u64 {
    return (extent + threads - 1) / threads;
}

pub fn radixSplitInstanceValid(instance: RadixSplit) bool {
    if (instance.extent == 0) return false;
    if (instance.threads == 0 or instance.threads > radix_split_max_threads) return false;
    if (instance.threads % radix_split_warp_size != 0) return false;
    return extent_mod.blockCountWithinLimit(
        instance.extent,
        instance.threads,
        radix_split_max_blocks,
    );
}

fn powerOfTwo(value: u32) bool {
    return value != 0 and (value & (value - 1)) == 0;
}

pub fn bitonicBlockInstanceValid(instance: BitonicBlock) bool {
    if (instance.extent == 0) return false;
    if (instance.threads < bitonic_block_min_threads or
        instance.threads > bitonic_block_max_threads) return false;
    if (!powerOfTwo(instance.threads)) return false;
    return instance.extent <= instance.threads;
}

pub fn bitonicBlockThreadsForExtent(extent: u64) ?u32 {
    if (extent == 0 or extent > bitonic_block_max_threads) return null;
    var threads = bitonic_block_min_threads;
    while (@as(u64, threads) < extent) : (threads *= 2) {}
    return threads;
}

pub fn topKBlockInstanceValid(instance: TopKBlock) bool {
    if (instance.k == 0 or instance.k > instance.extent) return false;
    return bitonicBlockInstanceValid(.{
        .extent = instance.extent,
        .threads = instance.threads,
        .element_axis = instance.element_axis,
    });
}

pub fn topKBlockPairsInstanceValid(instance: TopKBlockPairs) bool {
    return topKBlockInstanceValid(.{
        .extent = instance.extent,
        .k = instance.k,
        .threads = instance.threads,
        .element_axis = instance.element_axis,
    });
}

pub fn radixSplitTuningOperation(_: RadixSplit) entry.Operation {
    return .{ .sort = .radix_ascending };
}

pub fn radixSplitTuningExtents(instance: RadixSplit) [1]u64 {
    return .{instance.extent};
}

pub fn radixSplitFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: RadixSplit,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try radixSplitScatterFamilyFingerprint(backing_allocator, instance);
    const extents = radixSplitTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(radixSplitTuningOperation(instance)),
        .i32,
        radix_split_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn resolveRadixSplitStructure(
    backing_allocator: std.mem.Allocator,
    reader: tuning.FamilyTuningReader,
    instance: RadixSplit,
) !?RadixSplitResolvedStructure {
    const key = try radixSplitFamilyTuningKey(
        backing_allocator,
        reader.device_fingerprint,
        instance,
    );
    const record = reader.table.find(key) orelse return null;
    const split_target = try radixSplitPipelineTarget(backing_allocator, instance);
    defer backing_allocator.free(split_target);
    if (std.mem.eql(u8, split_target, record.target)) return .radix_split;
    const digit_target = try radixDigitPipelineTarget(backing_allocator, instance);
    defer backing_allocator.free(digit_target);
    if (std.mem.eql(u8, digit_target, record.target)) return .radix_digit;
    return null;
}

fn radix_split_flags_body_in_range(inner: anytype, ctx: anytype) !void {
    const key = try ctx.args.param(.keys).load(inner, ctx.tid);
    const shifted = try inner.shr(key.raw(), ctx.bit);
    const one_i32 = try inner.constantInt(.i32, 1);
    const masked = try inner.and_(shifted, one_i32);
    const first_bucket = try inner.compare(.eq, masked, ctx.polarity);
    const one_value = try inner.constantFloat(.f32, 1.0);
    const zero_value = try inner.constantFloat(.f32, 0.0);
    const flag = try inner.select(first_bucket, one_value, zero_value);
    try ctx.args.param(.dst).store(inner, flag, ctx.tid);
}

fn radixSplitFlagsBody(k: anytype, spec: RadixSplit, args: anytype) !void {
    if (!radixSplitInstanceValid(spec)) return error.UnsupportedRadixSplitInstance;
    const extent = try k.castIndex(args.param(.extent).raw());
    const tid = try k.globalId(.x);
    const in_range = try k.compare(.lt, tid, extent);
    const bit = args.param(.bit).raw();
    const polarity = args.param(.polarity).raw();
    try k.guardDo(
        in_range,
        .{ .args = args, .tid = tid, .bit = bit, .polarity = polarity },
        radix_split_flags_body_in_range,
    );
}

fn radix_split_scatter_body_in_range(inner: anytype, ctx: anytype) !void {
    const key = try ctx.args.param(.keys).load(inner, ctx.tid);
    const flag = try ctx.args.param(.flags).load(inner, ctx.tid);
    const scanned = try ctx.args.param(.scanned).load(inner, ctx.tid);
    const last_scanned = try ctx.args.param(.scanned).load(inner, ctx.last);
    const last_flag = try ctx.args.param(.flags).load(inner, ctx.last);
    const total_zeros_value = try inner.add(last_scanned.raw(), last_flag.raw());
    const zeros_before = try inner.castIndex(try inner.cast(scanned.raw(), .i32));
    const total_zeros = try inner.castIndex(try inner.cast(total_zeros_value, .i32));
    const ones_before = try inner.sub(ctx.tid, zeros_before);
    const ones_position = try inner.add(total_zeros, ones_before);
    const one_value = try inner.constantFloat(.f32, 1.0);
    const zeros_bucket = try inner.compare(.eq, flag.raw(), one_value);
    const position = try inner.select(zeros_bucket, zeros_before, ones_position);
    try ctx.args.param(.dst).store(inner, key.raw(), position);
}

fn radixSplitScatterBody(k: anytype, spec: RadixSplit, args: anytype) !void {
    if (!radixSplitInstanceValid(spec)) return error.UnsupportedRadixSplitInstance;
    const extent = try k.castIndex(args.param(.extent).raw());
    const tid = try k.globalId(.x);
    const one = try k.constantIndex(1);
    const last = try k.sub(extent, one);
    const in_range = try k.compare(.lt, tid, extent);
    try k.guardDo(
        in_range,
        .{ .args = args, .tid = tid, .last = last },
        radix_split_scatter_body_in_range,
    );
}

fn radixSplitFamilySchedule(instance: RadixSplit) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn radixSplitFlagsRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_sort_radix_split_flags_runtime_i32",
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .keys = kernel.dynamicBuffer(.i32),
            .extent = kernel.scalar(.i32),
            .bit = kernel.scalar(.i32),
            .polarity = kernel.scalar(.i32),
        },
        .Instance = RadixSplit,
        .schedule = radixSplitFamilySchedule,
        .body = radixSplitFlagsBody,
    });
}

fn radixSplitScatterRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_sort_radix_split_scatter_runtime_i32",
        .parameters = .{
            .dst = kernel.dynamicBuffer(.i32),
            .keys = kernel.dynamicBuffer(.i32),
            .flags = kernel.dynamicBuffer(.f32),
            .scanned = kernel.dynamicBuffer(.f32),
            .extent = kernel.scalar(.i32),
        },
        .Instance = RadixSplit,
        .schedule = radixSplitFamilySchedule,
        .body = radixSplitScatterBody,
    });
}

fn sort_shared_pair(inner: anytype, ctx: anytype) !void {
    const lhs = try inner.loadIndex(ctx.shared, ctx.local);
    const rhs = try inner.loadIndex(ctx.shared, ctx.partner);
    const lower = try inner.min(lhs, rhs);
    const upper = try inner.max(lhs, rhs);
    const segment = try inner.and_(ctx.local_i32, ctx.direction_bit);
    const ascending = try inner.compare(.eq, segment, ctx.zero_i32);
    const first = try inner.select(ascending, lower, upper);
    const second = try inner.select(ascending, upper, lower);
    try inner.storeIndex(first, ctx.shared, ctx.local);
    try inner.storeIndex(second, ctx.shared, ctx.partner);
}

fn bitonic_block_body_in_range(inner: anytype, ctx: anytype) !void {
    try ctx.args.param(.dst).store(inner, ctx.sorted, ctx.local);
}

fn bitonicBlockBody(k: anytype, spec: BitonicBlock, args: anytype) !void {
    if (!bitonicBlockInstanceValid(spec)) return error.UnsupportedBitonicBlockInstance;
    const shared = try k.sharedBuffer(.i32, spec.threads);
    const extent = try k.castIndex(args.param(.extent).raw());
    const local = try k.castIndex(try k.threadId(.x));
    const local_i32 = try k.cast(local, .i32);
    const one = try k.constantIndex(1);
    const last = try k.sub(extent, one);
    const clamped = try k.min(local, last);
    const in_range = try k.compare(.lt, local, extent);
    const loaded = try args.param(.keys).load(k, clamped);
    const padding = try k.constantInt(.i32, std.math.maxInt(i32));
    const value = try k.select(in_range, loaded.raw(), padding);
    try k.storeIndex(value, shared, local);
    try k.barrier(.block);

    var size: u32 = 2;
    while (size <= spec.threads) : (size *= 2) {
        var stride_value: u32 = size / 2;
        while (stride_value > 0) : (stride_value /= 2) {
            const stride_i32 = try k.constantInt(.i32, @as(i32, @intCast(stride_value)));
            const partner_i32 = try k.xor(local_i32, stride_i32);
            const partner = try k.castIndex(partner_i32);
            const writes_pair = try k.compare(.lt, local_i32, partner_i32);
            const direction_bit = try k.constantInt(.i32, @as(i32, @intCast(size)));
            const zero_i32 = try k.constantInt(.i32, 0);
            try k.guardDo(writes_pair, .{
                .shared = shared,
                .local = local,
                .partner = partner,
                .local_i32 = local_i32,
                .direction_bit = direction_bit,
                .zero_i32 = zero_i32,
            }, sort_shared_pair);
            try k.barrier(.block);
        }
    }

    const sorted = try k.loadIndex(shared, local);
    try k.guardDo(
        in_range,
        .{ .args = args, .sorted = sorted, .local = local },
        bitonic_block_body_in_range,
    );
}

fn top_k_block_body_writes_output(inner: anytype, ctx: anytype) !void {
    try ctx.args.param(.dst).store(inner, ctx.selected, ctx.local);
}

fn topKBlockBody(k: anytype, spec: TopKBlock, args: anytype) !void {
    if (!topKBlockInstanceValid(spec)) return error.UnsupportedTopKBlockInstance;
    const shared = try k.sharedBuffer(.i32, spec.threads);
    const extent = try k.castIndex(args.param(.extent).raw());
    const local = try k.castIndex(try k.threadId(.x));
    const local_i32 = try k.cast(local, .i32);
    const one = try k.constantIndex(1);
    const last = try k.sub(extent, one);
    const clamped = try k.min(local, last);
    const in_range = try k.compare(.lt, local, extent);
    const loaded = try args.param(.keys).load(k, clamped);
    const padding = try k.constantInt(.i32, std.math.maxInt(i32));
    const value = try k.select(in_range, loaded.raw(), padding);
    try k.storeIndex(value, shared, local);
    try k.barrier(.block);

    var size: u32 = 2;
    while (size <= spec.threads) : (size *= 2) {
        var stride_value: u32 = size / 2;
        while (stride_value > 0) : (stride_value /= 2) {
            const stride_i32 = try k.constantInt(.i32, @as(i32, @intCast(stride_value)));
            const partner_i32 = try k.xor(local_i32, stride_i32);
            const partner = try k.castIndex(partner_i32);
            const writes_pair = try k.compare(.lt, local_i32, partner_i32);
            const direction_bit = try k.constantInt(.i32, @as(i32, @intCast(size)));
            const zero_i32 = try k.constantInt(.i32, 0);
            try k.guardDo(writes_pair, .{
                .shared = shared,
                .local = local,
                .partner = partner,
                .local_i32 = local_i32,
                .direction_bit = direction_bit,
                .zero_i32 = zero_i32,
            }, sort_shared_pair);
            try k.barrier(.block);
        }
    }

    const top_count = try k.constantIndex(@intCast(spec.k));
    const writes_output = try k.compare(.lt, local, top_count);
    const selected = try k.loadIndex(shared, local);
    try k.guardDo(
        writes_output,
        .{ .args = args, .selected = selected, .local = local },
        top_k_block_body_writes_output,
    );
}

fn top_k_block_pairs_body_writes_pair(inner: anytype, ctx: anytype) !void {
    const lhs_key = try inner.loadIndex(ctx.shared_keys, ctx.local);
    const rhs_key = try inner.loadIndex(ctx.shared_keys, ctx.partner);
    const lhs_value = try inner.loadIndex(ctx.shared_values, ctx.local);
    const rhs_value = try inner.loadIndex(ctx.shared_values, ctx.partner);
    const key_lt = try inner.compare(.lt, lhs_key, rhs_key);
    const key_eq = try inner.compare(.eq, lhs_key, rhs_key);
    const value_le = try inner.compare(.le, lhs_value, rhs_value);
    const tie_before = try inner.and_(key_eq, value_le);
    const lhs_first = try inner.or_(key_lt, tie_before);
    const lower_key = try inner.select(lhs_first, lhs_key, rhs_key);
    const upper_key = try inner.select(lhs_first, rhs_key, lhs_key);
    const lower_value = try inner.select(lhs_first, lhs_value, rhs_value);
    const upper_value = try inner.select(lhs_first, rhs_value, lhs_value);
    const segment = try inner.and_(ctx.local_i32, ctx.direction_bit);
    const ascending = try inner.compare(.eq, segment, ctx.zero_i32);
    const first_key = try inner.select(ascending, lower_key, upper_key);
    const second_key = try inner.select(ascending, upper_key, lower_key);
    const first_value = try inner.select(ascending, lower_value, upper_value);
    const second_value = try inner.select(ascending, upper_value, lower_value);
    try inner.storeIndex(first_key, ctx.shared_keys, ctx.local);
    try inner.storeIndex(second_key, ctx.shared_keys, ctx.partner);
    try inner.storeIndex(first_value, ctx.shared_values, ctx.local);
    try inner.storeIndex(second_value, ctx.shared_values, ctx.partner);
}

fn top_k_block_pairs_body_writes_output(inner: anytype, ctx: anytype) !void {
    try ctx.args.param(.dst).store(inner, ctx.key, ctx.local);
    try ctx.args.param(.dst_values).store(inner, ctx.value, ctx.local);
}

fn topKBlockPairsBody(k: anytype, spec: TopKBlockPairs, args: anytype) !void {
    if (!topKBlockPairsInstanceValid(spec)) return error.UnsupportedTopKBlockPairsInstance;
    const shared_keys = try k.sharedBuffer(.i32, spec.threads);
    const shared_values = try k.sharedBuffer(.i32, spec.threads);
    const extent = try k.castIndex(args.param(.extent).raw());
    const local = try k.castIndex(try k.threadId(.x));
    const local_i32 = try k.cast(local, .i32);
    const one = try k.constantIndex(1);
    const last = try k.sub(extent, one);
    const clamped = try k.min(local, last);
    const in_range = try k.compare(.lt, local, extent);
    const loaded_key = try args.param(.keys).load(k, clamped);
    const loaded_value = try args.param(.values).load(k, clamped);
    const padding = try k.constantInt(.i32, std.math.maxInt(i32));
    const key = try k.select(in_range, loaded_key.raw(), padding);
    const payload = try k.select(in_range, loaded_value.raw(), padding);
    try k.storeIndex(key, shared_keys, local);
    try k.storeIndex(payload, shared_values, local);
    try k.barrier(.block);

    var size: u32 = 2;
    while (size <= spec.threads) : (size *= 2) {
        var stride_value: u32 = size / 2;
        while (stride_value > 0) : (stride_value /= 2) {
            const stride_i32 = try k.constantInt(.i32, @as(i32, @intCast(stride_value)));
            const partner_i32 = try k.xor(local_i32, stride_i32);
            const partner = try k.castIndex(partner_i32);
            const writes_pair = try k.compare(.lt, local_i32, partner_i32);
            const direction_bit = try k.constantInt(.i32, @as(i32, @intCast(size)));
            const zero_i32 = try k.constantInt(.i32, 0);
            try k.guardDo(writes_pair, .{
                .shared_keys = shared_keys,
                .shared_values = shared_values,
                .local = local,
                .partner = partner,
                .local_i32 = local_i32,
                .direction_bit = direction_bit,
                .zero_i32 = zero_i32,
            }, top_k_block_pairs_body_writes_pair);
            try k.barrier(.block);
        }
    }

    const top_count = try k.constantIndex(@intCast(spec.k));
    const writes_output = try k.compare(.lt, local, top_count);
    const selected_key = try k.loadIndex(shared_keys, local);
    const selected_value = try k.loadIndex(shared_values, local);
    try k.guardDo(
        writes_output,
        .{ .args = args, .key = selected_key, .value = selected_value, .local = local },
        top_k_block_pairs_body_writes_output,
    );
}

fn bitonicBlockFamilySchedule(instance: BitonicBlock) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn topKBlockFamilySchedule(instance: TopKBlock) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn topKBlockPairsFamilySchedule(instance: TopKBlockPairs) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn bitonicBlockRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_sort_bitonic_block_runtime_i32",
        .parameters = .{
            .dst = kernel.dynamicBuffer(.i32),
            .keys = kernel.dynamicBuffer(.i32),
            .extent = kernel.scalar(.i32),
        },
        .Instance = BitonicBlock,
        .schedule = bitonicBlockFamilySchedule,
        .body = bitonicBlockBody,
    });
}

fn topKBlockRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_sort_top_k_block_runtime_i32",
        .parameters = .{
            .dst = kernel.dynamicBuffer(.i32),
            .keys = kernel.dynamicBuffer(.i32),
            .extent = kernel.scalar(.i32),
        },
        .Instance = TopKBlock,
        .schedule = topKBlockFamilySchedule,
        .body = topKBlockBody,
    });
}

fn topKBlockPairsRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_sort_top_k_block_pairs_runtime_i32",
        .parameters = .{
            .dst = kernel.dynamicBuffer(.i32),
            .dst_values = kernel.dynamicBuffer(.i32),
            .keys = kernel.dynamicBuffer(.i32),
            .values = kernel.dynamicBuffer(.i32),
            .extent = kernel.scalar(.i32),
        },
        .Instance = TopKBlockPairs,
        .schedule = topKBlockPairsFamilySchedule,
        .body = topKBlockPairsBody,
    });
}

fn radix_digit_histogram_body_zero_bin(
    loop_builder: anytype,
    bin: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    try loop_builder.storeIndex(ctx.zero_count, ctx.shared_bins, bin);
    return acc;
}

fn radix_digit_histogram_body_active(inner: anytype, ctx: anytype) !void {
    const key = try ctx.args.param(.keys).load(inner, ctx.element);
    const shifted = try inner.shr(key.raw(), ctx.shift);
    const mask = try inner.constantInt(.i32, radix_digit_bins - 1);
    const masked = try inner.and_(shifted, mask);
    const digit_i32 = try inner.xor(masked, ctx.bias);
    const digit = try inner.castIndex(digit_i32);
    const one = try inner.constantInt(.i32, 1);
    _ = try inner.atomicRmwIndex(.add, one, ctx.shared_bins, digit);
}

fn radix_digit_histogram_body_grid(
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

fn radixDigitHistogramBody(k: anytype, spec: RadixSplit, args: anytype) !void {
    if (!radixSplitInstanceValid(spec)) return error.UnsupportedRadixSplitInstance;
    const shared_bins = try k.sharedBuffer(.i32, radix_digit_bins);
    const zero_count = try k.constantInt(.i32, 0);
    const thread = try k.castIndex(try k.threadId(.x));
    const stride = try k.castIndex(try k.blockDim(.x));
    const bins = try k.constantIndex(radix_digit_bins);

    _ = try k.fold(thread, bins, stride, zero_count, .{
        .shared_bins = shared_bins,
        .zero_count = zero_count,
    }, radix_digit_histogram_body_zero_bin);
    try k.barrier(.block);

    const element = try k.globalId(.x);
    const extent = try k.castIndex(args.param(.extent).raw());
    const active = try k.compare(.lt, element, extent);
    const shift = args.param(.shift).raw();
    const bias = args.param(.bias).raw();
    try k.guardDo(active, .{
        .args = args,
        .element = element,
        .shift = shift,
        .bias = bias,
        .shared_bins = shared_bins,
    }, radix_digit_histogram_body_active);
    try k.barrier(.block);

    const block = try k.blockId(.x);
    const grid = try k.gridDim(.x);
    _ = try k.fold(thread, bins, stride, zero_count, .{
        .args = args,
        .shared_bins = shared_bins,
        .block = block,
        .grid = grid,
    }, radix_digit_histogram_body_grid);
}

fn radixDigitHistogramRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_sort_radix_digit_histogram_runtime_i32",
        .parameters = .{
            .counts = kernel.dynamicBuffer(.f32),
            .keys = kernel.dynamicBuffer(.i32),
            .extent = kernel.scalar(.i32),
            .shift = kernel.scalar(.i32),
            .bias = kernel.scalar(.i32),
        },
        .Instance = RadixSplit,
        .schedule = radixSplitFamilySchedule,
        .body = radixDigitHistogramBody,
    });
}

fn radix_digit_rank_scatter_zero_cell(
    loop_builder: anytype,
    cell: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    try loop_builder.storeIndex(ctx.zero_i32, ctx.shared_counts, cell);
    return acc;
}

fn radix_digit_rank_scatter_record_group(inner: anytype, ctx: anytype) !void {
    try inner.guardDo(ctx.is_rank_zero, .{
        .shared_counts = ctx.shared_counts,
        .warp_cell = ctx.warp_cell,
        .group_count = ctx.group_count,
    }, radix_digit_rank_scatter_write_group_count);
}

fn radix_digit_rank_scatter_write_group_count(write_builder: anytype, write_ctx: anytype) !void {
    try write_builder.storeIndex(
        write_ctx.group_count,
        write_ctx.shared_counts,
        write_ctx.warp_cell,
    );
}

fn radix_digit_rank_scatter_key(inner: anytype, ctx: anytype) !void {
    const cross_warp = try inner.fold(ctx.zero_index, ctx.warp, ctx.one_index, ctx.zero_i32, .{
        .shared_counts = ctx.shared_counts,
        .digit_index = ctx.digit_index,
        .warps_value = ctx.warps_value,
    }, radix_digit_rank_scatter_count_lower_warps);

    const column = try inner.mul(ctx.digit_index, ctx.grid);
    const base_cell = try inner.add(column, ctx.block);
    const base_value = try inner.loadIndex(ctx.args.param(.scanned_counts).raw(), base_cell);
    const base = try inner.cast(base_value, .i32);
    const local = try inner.add(cross_warp, ctx.within_rank);
    const position_i32 = try inner.add(base, local);
    const position = try inner.castIndex(position_i32);
    try ctx.args.param(.dst).store(inner, ctx.key, position);
}

fn radix_digit_rank_scatter_count_lower_warps(
    loop_builder: anytype,
    lower_warp: kernel.Value,
    acc: kernel.Value,
    fold_ctx: anytype,
) !kernel.Value {
    const cell = try loop_builder.add(
        try loop_builder.mul(fold_ctx.digit_index, fold_ctx.warps_value),
        lower_warp,
    );
    const count = try loop_builder.loadIndex(fold_ctx.shared_counts, cell);
    return try loop_builder.add(acc, count);
}

fn radixDigitRankScatterBody(k: anytype, spec: RadixSplit, args: anytype) !void {
    if (!radixSplitInstanceValid(spec)) return error.UnsupportedRadixSplitInstance;
    const warps_per_block = spec.threads / radix_split_warp_size;
    const shared_counts = try k.sharedBuffer(.i32, radix_digit_bins * warps_per_block);
    const zero_i32 = try k.constantInt(.i32, 0);
    const zero_index = try k.constantIndex(0);
    const one_index = try k.constantIndex(1);
    const thread = try k.castIndex(try k.threadId(.x));
    const stride = try k.castIndex(try k.blockDim(.x));
    const cells = try k.constantIndex(radix_digit_bins * warps_per_block);

    _ = try k.fold(thread, cells, stride, zero_i32, .{
        .shared_counts = shared_counts,
        .zero_i32 = zero_i32,
    }, radix_digit_rank_scatter_zero_cell);
    try k.barrier(.block);

    const tid = try k.globalId(.x);
    const extent = try k.castIndex(args.param(.extent).raw());
    const in_range = try k.compare(.lt, tid, extent);
    const last = try k.sub(extent, one_index);
    const clamped = try k.min(tid, last);
    const key = try args.param(.keys).load(k, clamped);
    const shift = args.param(.shift).raw();
    const bias = args.param(.bias).raw();
    const shifted = try k.shr(key.raw(), shift);
    const digit_mask = try k.constantInt(.i32, radix_digit_bins - 1);
    const masked_digit = try k.and_(shifted, digit_mask);
    const digit = try k.xor(masked_digit, bias);

    var same_mask = try k.ballotSync(in_range);
    inline for (0..radix_digit_bits) |bit_index| {
        const bit_constant = try k.constantInt(.i32, @as(i32, 1) << bit_index);
        const bit_value = try k.and_(digit, bit_constant);
        const bit_set = try k.compare(.eq, bit_value, bit_constant);
        const ballot = try k.ballotSync(bit_set);
        const inverted = try k.not(ballot);
        const matching = try k.select(bit_set, ballot, inverted);
        same_mask = try k.and_(same_mask, matching);
    }

    const lane = try k.laneId();
    const lane_i32 = try k.cast(lane, .i32);
    const one_i32 = try k.constantInt(.i32, 1);
    const lane_bit = try k.shl(one_i32, lane_i32);
    const lower_mask = try k.sub(lane_bit, one_i32);
    const below = try k.and_(same_mask, lower_mask);
    const within_rank = try k.popcount(below);
    const group_count = try k.popcount(same_mask);

    const warp = try k.warpId();
    const digit_index = try k.castIndex(digit);
    const warps_value = try k.constantIndex(warps_per_block);
    const warp_cell = try k.add(try k.mul(digit_index, warps_value), warp);
    const is_rank_zero = try k.compare(.eq, within_rank, zero_i32);

    try k.guardDo(in_range, .{
        .shared_counts = shared_counts,
        .warp_cell = warp_cell,
        .group_count = group_count,
        .is_rank_zero = is_rank_zero,
    }, radix_digit_rank_scatter_record_group);
    try k.barrier(.block);

    const block = try k.blockId(.x);
    const grid = try k.gridDim(.x);
    try k.guardDo(in_range, .{
        .args = args,
        .key = key.raw(),
        .digit_index = digit_index,
        .warps_value = warps_value,
        .warp = warp,
        .block = block,
        .grid = grid,
        .within_rank = within_rank,
        .shared_counts = shared_counts,
        .zero_index = zero_index,
        .one_index = one_index,
        .zero_i32 = zero_i32,
    }, radix_digit_rank_scatter_key);
}

fn radix_digit_rank_scatter_pair(inner: anytype, ctx: anytype) !void {
    const cross_warp = try inner.fold(ctx.zero_index, ctx.warp, ctx.one_index, ctx.zero_i32, .{
        .shared_counts = ctx.shared_counts,
        .digit_index = ctx.digit_index,
        .warps_value = ctx.warps_value,
    }, radix_digit_rank_scatter_count_lower_warps);

    const column = try inner.mul(ctx.digit_index, ctx.grid);
    const base_cell = try inner.add(column, ctx.block);
    const base_value = try inner.loadIndex(ctx.args.param(.scanned_counts).raw(), base_cell);
    const base = try inner.cast(base_value, .i32);
    const local = try inner.add(cross_warp, ctx.within_rank);
    const position_i32 = try inner.add(base, local);
    const position = try inner.castIndex(position_i32);
    try ctx.args.param(.dst).store(inner, ctx.key, position);
    try ctx.args.param(.dst_values).store(inner, ctx.payload, position);
}

fn radixDigitRankScatterPairsBody(k: anytype, spec: RadixSplit, args: anytype) !void {
    if (!radixSplitInstanceValid(spec)) return error.UnsupportedRadixSplitInstance;
    const warps_per_block = spec.threads / radix_split_warp_size;
    const shared_counts = try k.sharedBuffer(.i32, radix_digit_bins * warps_per_block);
    const zero_i32 = try k.constantInt(.i32, 0);
    const zero_index = try k.constantIndex(0);
    const one_index = try k.constantIndex(1);
    const thread = try k.castIndex(try k.threadId(.x));
    const stride = try k.castIndex(try k.blockDim(.x));
    const cells = try k.constantIndex(radix_digit_bins * warps_per_block);

    _ = try k.fold(thread, cells, stride, zero_i32, .{
        .shared_counts = shared_counts,
        .zero_i32 = zero_i32,
    }, radix_digit_rank_scatter_zero_cell);
    try k.barrier(.block);

    const tid = try k.globalId(.x);
    const extent = try k.castIndex(args.param(.extent).raw());
    const in_range = try k.compare(.lt, tid, extent);
    const last = try k.sub(extent, one_index);
    const clamped = try k.min(tid, last);
    const key = try args.param(.keys).load(k, clamped);
    const payload = try args.param(.values).load(k, clamped);
    const shift = args.param(.shift).raw();
    const bias = args.param(.bias).raw();
    const shifted = try k.shr(key.raw(), shift);
    const digit_mask = try k.constantInt(.i32, radix_digit_bins - 1);
    const masked_digit = try k.and_(shifted, digit_mask);
    const digit = try k.xor(masked_digit, bias);

    var same_mask = try k.ballotSync(in_range);
    inline for (0..radix_digit_bits) |bit_index| {
        const bit_constant = try k.constantInt(.i32, @as(i32, 1) << bit_index);
        const bit_value = try k.and_(digit, bit_constant);
        const bit_set = try k.compare(.eq, bit_value, bit_constant);
        const ballot = try k.ballotSync(bit_set);
        const inverted = try k.not(ballot);
        const matching = try k.select(bit_set, ballot, inverted);
        same_mask = try k.and_(same_mask, matching);
    }

    const lane = try k.laneId();
    const lane_i32 = try k.cast(lane, .i32);
    const one_i32 = try k.constantInt(.i32, 1);
    const lane_bit = try k.shl(one_i32, lane_i32);
    const lower_mask = try k.sub(lane_bit, one_i32);
    const below = try k.and_(same_mask, lower_mask);
    const within_rank = try k.popcount(below);
    const group_count = try k.popcount(same_mask);

    const warp = try k.warpId();
    const digit_index = try k.castIndex(digit);
    const warps_value = try k.constantIndex(warps_per_block);
    const warp_cell = try k.add(try k.mul(digit_index, warps_value), warp);
    const is_rank_zero = try k.compare(.eq, within_rank, zero_i32);

    try k.guardDo(in_range, .{
        .shared_counts = shared_counts,
        .warp_cell = warp_cell,
        .group_count = group_count,
        .is_rank_zero = is_rank_zero,
    }, radix_digit_rank_scatter_record_group);
    try k.barrier(.block);

    const block = try k.blockId(.x);
    const grid = try k.gridDim(.x);
    try k.guardDo(in_range, .{
        .args = args,
        .key = key.raw(),
        .payload = payload.raw(),
        .digit_index = digit_index,
        .warps_value = warps_value,
        .warp = warp,
        .block = block,
        .grid = grid,
        .within_rank = within_rank,
        .shared_counts = shared_counts,
        .zero_index = zero_index,
        .one_index = one_index,
        .zero_i32 = zero_i32,
    }, radix_digit_rank_scatter_pair);
}

fn radixDigitRankScatterPairsRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_sort_radix_digit_rank_scatter_pairs_runtime_i32",
        .parameters = .{
            .dst = kernel.dynamicBuffer(.i32),
            .dst_values = kernel.dynamicBuffer(.i32),
            .keys = kernel.dynamicBuffer(.i32),
            .values = kernel.dynamicBuffer(.i32),
            .scanned_counts = kernel.dynamicBuffer(.f32),
            .extent = kernel.scalar(.i32),
            .shift = kernel.scalar(.i32),
            .bias = kernel.scalar(.i32),
        },
        .Instance = RadixSplit,
        .schedule = radixSplitFamilySchedule,
        .body = radixDigitRankScatterPairsBody,
    });
}

pub const RadixDigitRankScatterPairsRuntimeFamilyI32 = radixDigitRankScatterPairsRuntimeFamily();

pub fn radixDigitRankScatterPairsFamilyTarget(
    allocator: std.mem.Allocator,
    instance: RadixSplit,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sort.radix_digit_rank_scatter_pairs_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn radixDigitRankScatterPairsFamilyEntryName(
    allocator: std.mem.Allocator,
    instance: RadixSplit,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sort_radix_digit_rank_scatter_pairs_family_{d}_i32",
        .{instance.threads},
    );
}

fn radixDigitRankScatterRuntimeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_sort_radix_digit_rank_scatter_runtime_i32",
        .parameters = .{
            .dst = kernel.dynamicBuffer(.i32),
            .keys = kernel.dynamicBuffer(.i32),
            .scanned_counts = kernel.dynamicBuffer(.f32),
            .extent = kernel.scalar(.i32),
            .shift = kernel.scalar(.i32),
            .bias = kernel.scalar(.i32),
        },
        .Instance = RadixSplit,
        .schedule = radixSplitFamilySchedule,
        .body = radixDigitRankScatterBody,
    });
}

pub const RadixDigitRankScatterRuntimeFamilyI32 = radixDigitRankScatterRuntimeFamily();

pub fn radixDigitRankScatterFamilyTarget(allocator: std.mem.Allocator, instance: RadixSplit) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sort.radix_digit_rank_scatter_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn radixDigitRankScatterFamilyEntryName(
    allocator: std.mem.Allocator,
    instance: RadixSplit,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sort_radix_digit_rank_scatter_family_{d}_i32",
        .{instance.threads},
    );
}

pub const RadixDigitHistogramRuntimeFamilyI32 = radixDigitHistogramRuntimeFamily();

pub fn radixDigitHistogramFamilyTarget(allocator: std.mem.Allocator, instance: RadixSplit) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sort.radix_digit_histogram_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn radixDigitHistogramFamilyEntryName(
    allocator: std.mem.Allocator,
    instance: RadixSplit,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sort_radix_digit_histogram_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn radixDigitSignedPassBias(shift: u32) u32 {
    return if (shift == radix_split_key_bits - radix_digit_bits) radix_digit_bins / 2 else 0;
}

pub fn radixDigitHistogramRuntimeArguments(
    instance: RadixSplit,
    shift: u32,
) ![3]gpu_abi.ScalarArgument {
    if (shift >= radix_split_key_bits) return error.UnsupportedRadixSplitInstance;
    if (shift % radix_digit_bits != 0) return error.UnsupportedRadixSplitInstance;
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.extent) },
        .{ .u32 = shift },
        .{ .u32 = radixDigitSignedPassBias(shift) },
    };
}

pub const RadixSplitFlagsRuntimeFamilyI32 = radixSplitFlagsRuntimeFamily();
pub const RadixSplitScatterRuntimeFamilyI32 = radixSplitScatterRuntimeFamily();
pub const BitonicBlockRuntimeFamilyI32 = bitonicBlockRuntimeFamily();
pub const TopKBlockRuntimeFamilyI32 = topKBlockRuntimeFamily();
pub const TopKBlockPairsRuntimeFamilyI32 = topKBlockPairsRuntimeFamily();

pub fn radixSplitFlagsFamilyTarget(allocator: std.mem.Allocator, instance: RadixSplit) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sort.radix_split_flags_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn radixSplitFlagsFamilyEntryName(allocator: std.mem.Allocator, instance: RadixSplit) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sort_radix_split_flags_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn radixSplitScatterFamilyTarget(allocator: std.mem.Allocator, instance: RadixSplit) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sort.radix_split_scatter_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn radixSplitScatterFamilyEntryName(allocator: std.mem.Allocator, instance: RadixSplit) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sort_radix_split_scatter_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn radixSplitSignedPassPolarity(bit: u32) u32 {
    return if (bit == radix_split_key_bits - 1) 1 else 0;
}

pub fn radixSplitFlagsRuntimeArguments(instance: RadixSplit, bit: u32) ![3]gpu_abi.ScalarArgument {
    if (bit >= radix_split_key_bits) return error.UnsupportedRadixSplitInstance;
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.extent) },
        .{ .u32 = bit },
        .{ .u32 = radixSplitSignedPassPolarity(bit) },
    };
}

pub fn radixSplitScatterRuntimeArguments(instance: RadixSplit) ![1]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.extent) },
    };
}

pub fn bitonicBlockFamilyTarget(allocator: std.mem.Allocator, instance: BitonicBlock) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sort.bitonic_block_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn bitonicBlockFamilyEntryName(allocator: std.mem.Allocator, instance: BitonicBlock) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sort_bitonic_block_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn bitonicBlockRuntimeArguments(instance: BitonicBlock) ![1]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.extent) },
    };
}

pub fn topKBlockFamilyTarget(allocator: std.mem.Allocator, instance: TopKBlock) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sort.top_k_block_family_{d}x{d}_i32",
        .{ instance.threads, instance.k },
    );
}

pub fn topKBlockFamilyEntryName(allocator: std.mem.Allocator, instance: TopKBlock) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sort_top_k_block_family_{d}x{d}_i32",
        .{ instance.threads, instance.k },
    );
}

pub fn topKBlockRuntimeArguments(instance: TopKBlock) ![1]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.extent) },
    };
}

pub fn topKBlockPairsFamilyTarget(allocator: std.mem.Allocator, instance: TopKBlockPairs) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sort.top_k_block_pairs_family_{d}x{d}_i32",
        .{ instance.threads, instance.k },
    );
}

pub fn topKBlockPairsFamilyEntryName(allocator: std.mem.Allocator, instance: TopKBlockPairs) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sort_top_k_block_pairs_family_{d}x{d}_i32",
        .{ instance.threads, instance.k },
    );
}

pub fn topKBlockPairsRuntimeArguments(instance: TopKBlockPairs) ![1]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.extent) },
    };
}

pub fn radixSplitThreadsForExtent(extent: u64) ?u32 {
    if (extent == 0) return null;
    const max_extent = @as(u64, radix_split_max_threads) * radix_split_max_blocks;
    if (extent > max_extent) return null;
    const needed = (extent + radix_split_max_blocks - 1) / radix_split_max_blocks;
    const wide = needed + radix_split_warp_size - 1;
    const rounded: u32 = @intCast((wide / radix_split_warp_size) * radix_split_warp_size);
    return @max(rounded, radix_split_warp_size);
}

fn bitonicBlockScheduleMetadata(
    lifetime_allocator: std.mem.Allocator,
    instance: BitonicBlock,
) !entry.Schedule {
    const bindings = try lifetime_allocator.alloc(entry.ScheduleBinding, 1);
    bindings[0] = .{
        .axis = try std.fmt.allocPrint(lifetime_allocator, "{s}_lane", .{instance.element_axis}),
        .target = .thread_x,
        .extent = instance.threads,
    };
    return .{ .bindings = bindings };
}

pub fn bitonicBlockShapeProfileDimensions(
    instance: BitonicBlock,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.element_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = .{ .min = 1, .max = instance.threads },
        },
    };
}

pub fn topKBlockShapeProfileDimensions(
    instance: TopKBlock,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.element_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = .{ .min = 1, .max = instance.threads },
        },
    };
}

pub fn topKBlockPairsShapeProfileDimensions(
    instance: TopKBlockPairs,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.element_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = .{ .min = 1, .max = instance.threads },
        },
    };
}

fn bitonicBlockLaunch(instance: BitonicBlock) !artifact_product.KernelCallLaunch {
    if (!bitonicBlockInstanceValid(instance)) return error.UnsupportedBitonicBlockInstance;
    return .{ .derived = .{
        .grid = .{
            .{ .fixed = 1 },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

fn topKBlockLaunch(instance: TopKBlock) !artifact_product.KernelCallLaunch {
    if (!topKBlockInstanceValid(instance)) return error.UnsupportedTopKBlockInstance;
    return .{ .derived = .{
        .grid = .{
            .{ .fixed = 1 },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

fn topKBlockPairsLaunch(instance: TopKBlockPairs) !artifact_product.KernelCallLaunch {
    if (!topKBlockPairsInstanceValid(instance)) return error.UnsupportedTopKBlockPairsInstance;
    return .{ .derived = .{
        .grid = .{
            .{ .fixed = 1 },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn createBitonicBlockFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: BitonicBlock,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!bitonicBlockInstanceValid(instance)) return error.UnsupportedBitonicBlockInstance;
    const target = try bitonicBlockFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try bitonicBlockFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try bitonicBlockFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = bitonicBlockShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "bitonic_block",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try BitonicBlockRuntimeFamilyI32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = bitonic_block_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try bitonicBlockLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn createTopKBlockFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: TopKBlock,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!topKBlockInstanceValid(instance)) return error.UnsupportedTopKBlockInstance;
    const target = try topKBlockFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try topKBlockFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try topKBlockFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = topKBlockShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "top_k_block",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try TopKBlockRuntimeFamilyI32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = top_k_block_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try topKBlockLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn createTopKBlockPairsFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: TopKBlockPairs,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!topKBlockPairsInstanceValid(instance)) return error.UnsupportedTopKBlockPairsInstance;
    const target = try topKBlockPairsFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try topKBlockPairsFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try topKBlockPairsFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = topKBlockPairsShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "top_k_block_pairs",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try TopKBlockPairsRuntimeFamilyI32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = top_k_block_pairs_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try topKBlockPairsLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn bitonicBlockFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: BitonicBlock,
) !u64 {
    var family = try bitonicBlockShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn topKBlockFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: TopKBlock) !u64 {
    var family = try topKBlockShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn topKBlockPairsFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: TopKBlockPairs,
) !u64 {
    var family = try topKBlockPairsShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn bitonicBlockShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: BitonicBlock,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "bitonic_block");
    errdefer builder.deinit();
    const elements = try builder.symbol(instance.element_axis);
    const elements_expr = try builder.symbolExpression(elements);
    _ = try builder.tensor("keys", &.{elements_expr});
    _ = try builder.tensor("out", &.{elements_expr});
    try builder.assumeBounds(elements_expr, .{ .min = 1, .max = instance.threads });
    return builder.finish();
}

pub fn topKBlockShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: TopKBlock,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "top_k_block");
    errdefer builder.deinit();
    const elements = try builder.symbol(instance.element_axis);
    const elements_expr = try builder.symbolExpression(elements);
    const top_expr = builder.constantExpression(@intCast(instance.k));
    _ = try builder.tensor("keys", &.{elements_expr});
    _ = try builder.tensor("out", &.{top_expr});
    try builder.assumeBounds(elements_expr, .{ .min = 1, .max = instance.threads });
    return builder.finish();
}

pub fn topKBlockPairsShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: TopKBlockPairs,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "top_k_block_pairs");
    errdefer builder.deinit();
    const elements = try builder.symbol(instance.element_axis);
    const elements_expr = try builder.symbolExpression(elements);
    const top_expr = builder.constantExpression(@intCast(instance.k));
    _ = try builder.tensor("keys", &.{elements_expr});
    _ = try builder.tensor("values", &.{elements_expr});
    _ = try builder.tensor("out_keys", &.{top_expr});
    _ = try builder.tensor("out_values", &.{top_expr});
    try builder.assumeBounds(elements_expr, .{ .min = 1, .max = instance.threads });
    return builder.finish();
}

pub fn bitonicBlockFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: BitonicBlock,
) !entry.OwnedSpecialization {
    if (!bitonicBlockInstanceValid(instance)) return error.UnsupportedBitonicBlockInstance;
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
        .dtype = .i32,
        .operation = .{ .sort = .radix_ascending },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try bitonicBlockScheduleMetadata(lifetime_allocator, instance),
        .structure = bitonic_block_structure_name,
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try bitonicBlockShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn topKBlockFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: TopKBlock,
) !entry.OwnedSpecialization {
    if (!topKBlockInstanceValid(instance)) return error.UnsupportedTopKBlockInstance;
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
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, "k", instance.k);

    owned.value = .{
        .dtype = .i32,
        .operation = .{ .sort = .top_k_smallest },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try bitonicBlockScheduleMetadata(lifetime_allocator, .{
            .extent = instance.extent,
            .threads = instance.threads,
            .element_axis = instance.element_axis,
        }),
        .structure = top_k_block_structure_name,
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try topKBlockShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn topKBlockPairsFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: TopKBlockPairs,
) !entry.OwnedSpecialization {
    if (!topKBlockPairsInstanceValid(instance)) return error.UnsupportedTopKBlockPairsInstance;
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape1D(
        lifetime_allocator,
        instance.element_axis,
        instance.extent,
    );
    inputs[1] = try entry.runtimeShape1D(
        lifetime_allocator,
        instance.element_axis,
        instance.extent,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 2);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, "k", instance.k);
    outputs[1] = try entry.runtimeShape1D(lifetime_allocator, "k", instance.k);

    owned.value = .{
        .dtype = .i32,
        .operation = .{ .sort = .top_k_smallest },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try bitonicBlockScheduleMetadata(lifetime_allocator, .{
            .extent = instance.extent,
            .threads = instance.threads,
            .element_axis = instance.element_axis,
        }),
        .structure = top_k_block_pairs_structure_name,
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try topKBlockPairsShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn bitonicBlockInstanceFromSpecialization(specialization: entry.Specialization) ?BitonicBlock {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .sort = .radix_ascending })) return null;
    if (!specialization.structureIs(bitonic_block_structure_name)) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .i32) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const data = specialization.inputs[0];
    const output = specialization.outputs[0];
    if (data.axes.len != 1 or output.axes.len != 1) return null;
    const extent = data.axes[0].extent;
    if (output.axes[0].extent != extent) return null;
    const launch = specialization.launch orelse return null;
    if (launch.grid[0] != 1 or launch.grid[1] != 1 or launch.grid[2] != 1) return null;
    if (launch.threadgroup[1] != 1 or launch.threadgroup[2] != 1) return null;
    const instance = BitonicBlock{
        .extent = extent,
        .threads = launch.threadgroup[0],
        .element_axis = data.axes[0].name,
    };
    if (!bitonicBlockInstanceValid(instance)) return null;
    return instance;
}

pub fn topKBlockInstanceFromSpecialization(specialization: entry.Specialization) ?TopKBlock {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .sort = .top_k_smallest })) return null;
    if (!specialization.structureIs(top_k_block_structure_name)) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .i32) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const data = specialization.inputs[0];
    const output = specialization.outputs[0];
    if (data.axes.len != 1 or output.axes.len != 1) return null;
    const extent = data.axes[0].extent;
    const top_count = output.axes[0].extent;
    const launch = specialization.launch orelse return null;
    if (launch.grid[0] != 1 or launch.grid[1] != 1 or launch.grid[2] != 1) return null;
    if (launch.threadgroup[1] != 1 or launch.threadgroup[2] != 1) return null;
    const instance = TopKBlock{
        .extent = extent,
        .k = top_count,
        .threads = launch.threadgroup[0],
        .element_axis = data.axes[0].name,
    };
    if (!topKBlockInstanceValid(instance)) return null;
    return instance;
}

pub fn topKBlockPairsInstanceFromSpecialization(
    specialization: entry.Specialization,
) ?TopKBlockPairs {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .sort = .top_k_smallest })) return null;
    if (!specialization.structureIs(top_k_block_pairs_structure_name)) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .i32) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 2) return null;
    if (specialization.reductions.len != 0) return null;
    const keys = specialization.inputs[0];
    const values = specialization.inputs[1];
    const out_keys = specialization.outputs[0];
    const out_values = specialization.outputs[1];
    if (keys.axes.len != 1 or values.axes.len !=
        1 or out_keys.axes.len != 1 or out_values.axes.len != 1) return null;
    const extent = keys.axes[0].extent;
    const top_count = out_keys.axes[0].extent;
    if (values.axes[0].extent != extent) return null;
    if (out_values.axes[0].extent != top_count) return null;
    const launch = specialization.launch orelse return null;
    if (launch.grid[0] != 1 or launch.grid[1] != 1 or launch.grid[2] != 1) return null;
    if (launch.threadgroup[1] != 1 or launch.threadgroup[2] != 1) return null;
    const instance = TopKBlockPairs{
        .extent = extent,
        .k = top_count,
        .threads = launch.threadgroup[0],
        .element_axis = keys.axes[0].name,
    };
    if (!topKBlockPairsInstanceValid(instance)) return null;
    return instance;
}

pub fn radixSplitFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: RadixSplit,
) !entry.OwnedSpecialization {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
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
        .dtype = .i32,
        .operation = .{ .sort = .radix_ascending },
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
    var family = try radixSplitShapeFamily(
        backing_allocator,
        "radix_split",
        &.{ "keys", "out" },
        instance,
    );
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn radixSplitInstanceFromSpecialization(specialization: entry.Specialization) ?RadixSplit {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .sort = .radix_ascending })) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .i32) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const data = specialization.inputs[0];
    const output = specialization.outputs[0];
    if (data.axes.len != 1 or output.axes.len != 1) return null;
    const extent = data.axes[0].extent;
    if (output.axes[0].extent != extent) return null;
    const launch = specialization.launch orelse return null;
    const instance = RadixSplit{
        .extent = extent,
        .threads = launch.threadgroup[0],
        .element_axis = data.axes[0].name,
    };
    if (!radixSplitInstanceValid(instance)) return null;
    if (launch.grid[0] != radixSplitBlockCount(extent, instance.threads)) return null;
    return instance;
}

pub fn radixSplitMaxExtent(instance: RadixSplit) u64 {
    return @as(u64, instance.threads) * radix_split_max_blocks;
}

pub fn radixSplitShapeProfileDimensions(
    instance: RadixSplit,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.element_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = .{ .min = 1, .max = radixSplitMaxExtent(instance) },
        },
    };
}

fn radixSplitLaunch(instance: RadixSplit) !artifact_product.KernelCallLaunch {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = instance.threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

fn radixSplitShapeFamily(
    backing_allocator: std.mem.Allocator,
    comptime family_name: []const u8,
    comptime tensor_names: []const []const u8,
    instance: RadixSplit,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, family_name);
    errdefer builder.deinit();
    const elements = try builder.symbol(instance.element_axis);
    const elements_expr = try builder.symbolExpression(elements);
    inline for (tensor_names) |tensor_name| {
        _ = try builder.tensor(tensor_name, &.{elements_expr});
    }
    try builder.assumeBounds(elements_expr, .{ .min = 1, .max = radixSplitMaxExtent(instance) });
    return builder.finish();
}

pub fn radixSplitFlagsFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: RadixSplit,
) !u64 {
    var family = try radixSplitShapeFamily(
        backing_allocator,
        "radix_split_flags",
        &.{ "keys", "flags" },
        instance,
    );
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn radixSplitScatterFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: RadixSplit,
) !u64 {
    var family = try radixSplitShapeFamily(
        backing_allocator,
        "radix_split_scatter",
        &.{ "keys", "flags", "scanned", "out" },
        instance,
    );
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn createRadixSplitFlagsFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: RadixSplit,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    const target = try radixSplitFlagsFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try radixSplitFlagsFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try radixSplitFlagsFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = radixSplitShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "radix_split_flags",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try RadixSplitFlagsRuntimeFamilyI32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = radix_split_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try radixSplitLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            3
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn createRadixSplitScatterFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: RadixSplit,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    const target = try radixSplitScatterFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try radixSplitScatterFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try radixSplitScatterFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = radixSplitShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "radix_split_scatter",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try RadixSplitScatterRuntimeFamilyI32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = radix_split_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try radixSplitLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub const radix_digit_scan_threads: u32 = 1024;

pub fn createRadixDigitHistogramFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: RadixSplit,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    const target = try radixDigitHistogramFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try radixDigitHistogramFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try radixSplitFlagsFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = radixSplitShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "radix_digit_histogram",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try RadixDigitHistogramRuntimeFamilyI32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = radix_split_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try radixSplitLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            3
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn createRadixDigitRankScatterFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: RadixSplit,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    const target = try radixDigitRankScatterFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try radixDigitRankScatterFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try radixSplitScatterFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = radixSplitShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "radix_digit_rank_scatter",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try RadixDigitRankScatterRuntimeFamilyI32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = radix_split_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try radixSplitLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            3
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

fn radixDigitCountsScan(instance: RadixSplit) scan.DeviceScan {
    const blocks = radixSplitBlockCount(instance.extent, instance.threads);
    return .{
        .extent = radix_digit_bins * blocks,
        .dtype = .f32,
        .mode = .exclusive,
        .threads = radix_digit_scan_threads,
        .element_axis = instance.element_axis,
    };
}

pub const RadixDigitPipelineArtifacts = struct {
    histogram: kernel.OwnedKernelCallArtifact,
    block_scan: kernel.OwnedKernelCallArtifact,
    sums_scan: kernel.OwnedKernelCallArtifact,
    add_base: kernel.OwnedKernelCallArtifact,
    rank_scatter: kernel.OwnedKernelCallArtifact,

    pub fn entries(
        self: *const RadixDigitPipelineArtifacts,
    ) [5]artifact_product.KernelCallArtifact {
        return .{
            self.histogram.entry(),
            self.block_scan.entry(),
            self.sums_scan.entry(),
            self.add_base.entry(),
            self.rank_scatter.entry(),
        };
    }

    pub fn deinit(self: *RadixDigitPipelineArtifacts) void {
        self.histogram.deinit();
        self.block_scan.deinit();
        self.sums_scan.deinit();
        self.add_base.deinit();
        self.rank_scatter.deinit();
        self.* = undefined;
    }
};

pub fn createRadixDigitPipelineArtifacts(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: RadixSplit,
    options: entry.ArtifactOptions,
) !RadixDigitPipelineArtifacts {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    const counts_scan = radixDigitCountsScan(instance);
    const stages = try scan.deviceScanStages(counts_scan);

    var histogram = try createRadixDigitHistogramFamilyArtifact(
        allocator,
        handle,
        instance,
        options,
    );
    errdefer histogram.deinit();
    var block_scan = try scan.createDeviceScanBlockScanFamilyArtifact(
        allocator,
        handle,
        counts_scan,
        options,
    );
    errdefer block_scan.deinit();
    var sums_scan = try scan.createPrefixSumFamilyArtifact(
        allocator,
        handle,
        stages.sums_scan,
        options,
    );
    errdefer sums_scan.deinit();
    var add_base = try scan.createDeviceScanAddBaseFamilyArtifact(
        allocator,
        handle,
        counts_scan,
        options,
    );
    errdefer add_base.deinit();
    const rank_scatter = try createRadixDigitRankScatterFamilyArtifact(
        allocator,
        handle,
        instance,
        options,
    );
    return .{
        .histogram = histogram,
        .block_scan = block_scan,
        .sums_scan = sums_scan,
        .add_base = add_base,
        .rank_scatter = rank_scatter,
    };
}

pub fn radixDigitPipelineTarget(allocator: std.mem.Allocator, instance: RadixSplit) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sort.radix_digit_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn radixDigitPipeline(
    backing_allocator: std.mem.Allocator,
    instance: RadixSplit,
) !artifact_product.OwnedKernelCallPipeline {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    const counts_scan = radixDigitCountsScan(instance);
    const stages = try scan.deviceScanStages(counts_scan);
    var owned = artifact_product.OwnedKernelCallPipeline.init(backing_allocator);
    errdefer owned.deinit();
    const arena = owned.allocator();

    const cells_extent = artifact_product.PipelineScalarDerivation{
        .ceil_div_scaled = .{
            .argument_index = 0,
            .divisor = instance.threads,
            .scale = radix_digit_bins,
        },
    };
    const scan_blocks_extent = artifact_product.PipelineScalarDerivation{
        .ceil_div = .{ .argument_index = 0, .divisor = 64 * instance.threads },
    };

    const intermediates = try arena.alloc(artifact_product.PipelineIntermediate, 4);
    intermediates[0] = .{ .dtype = .f32, .extent = cells_extent };
    intermediates[1] = .{ .dtype = .f32, .extent = scan_blocks_extent };
    intermediates[2] = .{ .dtype = .f32, .extent = scan_blocks_extent };
    intermediates[3] = .{ .dtype = .f32, .extent = cells_extent };

    const pipeline_stages = try arena.alloc(artifact_product.PipelineStage, 5);
    pipeline_stages[0] = .{
        .target = try radixDigitHistogramFamilyTarget(arena, instance),
        .version = radix_split_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 0 }, .{ .operand = 0 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            .{ .forward = 0 }, .{ .forward = 1 }, .{ .forward = 2 },
        }),
    };
    pipeline_stages[1] = .{
        .target = try scan.deviceScanBlockScanFamilyTarget(arena, counts_scan),
        .version = scan.device_scan_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 3 }, .{ .intermediate = 0 }, .{ .intermediate = 1 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            cells_extent,
        }),
    };
    pipeline_stages[2] = .{
        .target = try scan.prefixSumFamilyTarget(arena, stages.sums_scan),
        .version = scan.prefix_sum_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 2 }, .{ .intermediate = 1 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            scan_blocks_extent,
        }),
    };
    pipeline_stages[3] = .{
        .target = try scan.deviceScanAddBaseFamilyTarget(arena, counts_scan),
        .version = scan.device_scan_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 3 }, .{ .intermediate = 2 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            cells_extent,
        }),
    };
    pipeline_stages[4] = .{
        .target = try radixDigitRankScatterFamilyTarget(arena, instance),
        .version = radix_split_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .result = 0 }, .{ .operand = 0 }, .{ .intermediate = 3 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            .{ .forward = 0 }, .{ .forward = 1 }, .{ .forward = 2 },
        }),
    };

    owned.value = .{
        .target = try radixDigitPipelineTarget(arena, instance),
        .version = radix_split_family_version,
        .operand_count = 1,
        .result_count = 1,
        .runtime_scalar_argument_count = 3,
        .intermediates = intermediates,
        .stages = pipeline_stages,
    };
    return owned;
}

pub fn createRadixDigitRankScatterPairsFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: RadixSplit,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    const target = try radixDigitRankScatterPairsFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try radixDigitRankScatterPairsFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try radixSplitScatterFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = radixSplitShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "radix_digit_rank_scatter_pairs",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try RadixDigitRankScatterPairsRuntimeFamilyI32.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = radix_split_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try radixSplitLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            3
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub const RadixDigitPairsPipelineArtifacts = struct {
    histogram: kernel.OwnedKernelCallArtifact,
    block_scan: kernel.OwnedKernelCallArtifact,
    sums_scan: kernel.OwnedKernelCallArtifact,
    add_base: kernel.OwnedKernelCallArtifact,
    rank_scatter_pairs: kernel.OwnedKernelCallArtifact,

    pub fn entries(
        self: *const RadixDigitPairsPipelineArtifacts,
    ) [5]artifact_product.KernelCallArtifact {
        return .{
            self.histogram.entry(),
            self.block_scan.entry(),
            self.sums_scan.entry(),
            self.add_base.entry(),
            self.rank_scatter_pairs.entry(),
        };
    }

    pub fn deinit(self: *RadixDigitPairsPipelineArtifacts) void {
        self.histogram.deinit();
        self.block_scan.deinit();
        self.sums_scan.deinit();
        self.add_base.deinit();
        self.rank_scatter_pairs.deinit();
        self.* = undefined;
    }
};

pub fn createRadixDigitPairsPipelineArtifacts(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: RadixSplit,
    options: entry.ArtifactOptions,
) !RadixDigitPairsPipelineArtifacts {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    const counts_scan = radixDigitCountsScan(instance);
    const stages = try scan.deviceScanStages(counts_scan);

    var histogram = try createRadixDigitHistogramFamilyArtifact(
        allocator,
        handle,
        instance,
        options,
    );
    errdefer histogram.deinit();
    var block_scan = try scan.createDeviceScanBlockScanFamilyArtifact(
        allocator,
        handle,
        counts_scan,
        options,
    );
    errdefer block_scan.deinit();
    var sums_scan = try scan.createPrefixSumFamilyArtifact(
        allocator,
        handle,
        stages.sums_scan,
        options,
    );
    errdefer sums_scan.deinit();
    var add_base = try scan.createDeviceScanAddBaseFamilyArtifact(
        allocator,
        handle,
        counts_scan,
        options,
    );
    errdefer add_base.deinit();
    const rank_scatter_pairs = try createRadixDigitRankScatterPairsFamilyArtifact(
        allocator,
        handle,
        instance,
        options,
    );
    return .{
        .histogram = histogram,
        .block_scan = block_scan,
        .sums_scan = sums_scan,
        .add_base = add_base,
        .rank_scatter_pairs = rank_scatter_pairs,
    };
}

pub fn radixDigitPairsPipelineTarget(allocator: std.mem.Allocator, instance: RadixSplit) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sort.radix_digit_pairs_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn radixDigitPairsPipeline(
    backing_allocator: std.mem.Allocator,
    instance: RadixSplit,
) !artifact_product.OwnedKernelCallPipeline {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    const counts_scan = radixDigitCountsScan(instance);
    const stages = try scan.deviceScanStages(counts_scan);
    var owned = artifact_product.OwnedKernelCallPipeline.init(backing_allocator);
    errdefer owned.deinit();
    const arena = owned.allocator();

    const cells_extent = artifact_product.PipelineScalarDerivation{
        .ceil_div_scaled = .{
            .argument_index = 0,
            .divisor = instance.threads,
            .scale = radix_digit_bins,
        },
    };
    const scan_blocks_extent = artifact_product.PipelineScalarDerivation{
        .ceil_div = .{ .argument_index = 0, .divisor = 64 * instance.threads },
    };

    const intermediates = try arena.alloc(artifact_product.PipelineIntermediate, 4);
    intermediates[0] = .{ .dtype = .f32, .extent = cells_extent };
    intermediates[1] = .{ .dtype = .f32, .extent = scan_blocks_extent };
    intermediates[2] = .{ .dtype = .f32, .extent = scan_blocks_extent };
    intermediates[3] = .{ .dtype = .f32, .extent = cells_extent };

    const pipeline_stages = try arena.alloc(artifact_product.PipelineStage, 5);
    pipeline_stages[0] = .{
        .target = try radixDigitHistogramFamilyTarget(arena, instance),
        .version = radix_split_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 0 }, .{ .operand = 0 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            .{ .forward = 0 }, .{ .forward = 1 }, .{ .forward = 2 },
        }),
    };
    pipeline_stages[1] = .{
        .target = try scan.deviceScanBlockScanFamilyTarget(arena, counts_scan),
        .version = scan.device_scan_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 3 }, .{ .intermediate = 0 }, .{ .intermediate = 1 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            cells_extent,
        }),
    };
    pipeline_stages[2] = .{
        .target = try scan.prefixSumFamilyTarget(arena, stages.sums_scan),
        .version = scan.prefix_sum_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 2 }, .{ .intermediate = 1 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            scan_blocks_extent,
        }),
    };
    pipeline_stages[3] = .{
        .target = try scan.deviceScanAddBaseFamilyTarget(arena, counts_scan),
        .version = scan.device_scan_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 3 }, .{ .intermediate = 2 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            cells_extent,
        }),
    };
    pipeline_stages[4] = .{
        .target = try radixDigitRankScatterPairsFamilyTarget(arena, instance),
        .version = radix_split_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .result = 0 }, .{ .result = 1 }, .{ .operand = 0 }, .{ .operand = 1 },
            .{
                .intermediate = 3,
            },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            .{ .forward = 0 }, .{ .forward = 1 }, .{ .forward = 2 },
        }),
    };

    owned.value = .{
        .target = try radixDigitPairsPipelineTarget(arena, instance),
        .version = radix_split_family_version,
        .operand_count = 2,
        .result_count = 2,
        .runtime_scalar_argument_count = 3,
        .intermediates = intermediates,
        .stages = pipeline_stages,
    };
    return owned;
}

fn radixSplitDeviceScan(instance: RadixSplit) scan.DeviceScan {
    return .{
        .extent = instance.extent,
        .dtype = .f32,
        .mode = .exclusive,
        .threads = instance.threads,
        .element_axis = instance.element_axis,
    };
}

pub const RadixSplitPipelineArtifacts = struct {
    flags: kernel.OwnedKernelCallArtifact,
    block_scan: kernel.OwnedKernelCallArtifact,
    sums_scan: kernel.OwnedKernelCallArtifact,
    add_base: kernel.OwnedKernelCallArtifact,
    scatter: kernel.OwnedKernelCallArtifact,

    pub fn entries(
        self: *const RadixSplitPipelineArtifacts,
    ) [5]artifact_product.KernelCallArtifact {
        return .{
            self.flags.entry(),
            self.block_scan.entry(),
            self.sums_scan.entry(),
            self.add_base.entry(),
            self.scatter.entry(),
        };
    }

    pub fn deinit(self: *RadixSplitPipelineArtifacts) void {
        self.flags.deinit();
        self.block_scan.deinit();
        self.sums_scan.deinit();
        self.add_base.deinit();
        self.scatter.deinit();
        self.* = undefined;
    }
};

pub fn createRadixSplitPipelineArtifacts(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: RadixSplit,
    options: entry.ArtifactOptions,
) !RadixSplitPipelineArtifacts {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    const device_scan = radixSplitDeviceScan(instance);
    const stages = try scan.deviceScanStages(device_scan);

    var flags = try createRadixSplitFlagsFamilyArtifact(allocator, handle, instance, options);
    errdefer flags.deinit();
    var block_scan = try scan.createDeviceScanBlockScanFamilyArtifact(
        allocator,
        handle,
        device_scan,
        options,
    );
    errdefer block_scan.deinit();
    var sums_scan = try scan.createPrefixSumFamilyArtifact(
        allocator,
        handle,
        stages.sums_scan,
        options,
    );
    errdefer sums_scan.deinit();
    var add_base = try scan.createDeviceScanAddBaseFamilyArtifact(
        allocator,
        handle,
        device_scan,
        options,
    );
    errdefer add_base.deinit();
    const scatter = try createRadixSplitScatterFamilyArtifact(allocator, handle, instance, options);
    return .{
        .flags = flags,
        .block_scan = block_scan,
        .sums_scan = sums_scan,
        .add_base = add_base,
        .scatter = scatter,
    };
}

pub fn radixSplitPipelineTarget(allocator: std.mem.Allocator, instance: RadixSplit) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sort.radix_split_family_{d}_i32",
        .{instance.threads},
    );
}

pub fn radixSplitPipeline(
    backing_allocator: std.mem.Allocator,
    instance: RadixSplit,
) !artifact_product.OwnedKernelCallPipeline {
    if (!radixSplitInstanceValid(instance)) return error.UnsupportedRadixSplitInstance;
    const device_scan = radixSplitDeviceScan(instance);
    const stages = try scan.deviceScanStages(device_scan);
    var owned = artifact_product.OwnedKernelCallPipeline.init(backing_allocator);
    errdefer owned.deinit();
    const arena = owned.allocator();

    const block_count_extent = artifact_product.PipelineScalarDerivation{
        .ceil_div = .{ .argument_index = 0, .divisor = instance.threads },
    };
    const element_extent = artifact_product.PipelineScalarDerivation{ .forward = 0 };

    const intermediates = try arena.alloc(artifact_product.PipelineIntermediate, 4);
    intermediates[0] = .{ .dtype = .f32, .extent = element_extent };
    intermediates[1] = .{ .dtype = .f32, .extent = block_count_extent };
    intermediates[2] = .{ .dtype = .f32, .extent = block_count_extent };
    intermediates[3] = .{ .dtype = .f32, .extent = element_extent };

    const pipeline_stages = try arena.alloc(artifact_product.PipelineStage, 5);
    pipeline_stages[0] = .{
        .target = try radixSplitFlagsFamilyTarget(arena, instance),
        .version = radix_split_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 0 }, .{ .operand = 0 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            .{ .forward = 0 }, .{ .forward = 1 }, .{ .forward = 2 },
        }),
    };
    pipeline_stages[1] = .{
        .target = try scan.deviceScanBlockScanFamilyTarget(arena, device_scan),
        .version = scan.device_scan_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 3 }, .{ .intermediate = 0 }, .{ .intermediate = 1 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            .{ .forward = 0 },
        }),
    };
    pipeline_stages[2] = .{
        .target = try scan.prefixSumFamilyTarget(arena, stages.sums_scan),
        .version = scan.prefix_sum_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 2 }, .{ .intermediate = 1 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            block_count_extent,
        }),
    };
    pipeline_stages[3] = .{
        .target = try scan.deviceScanAddBaseFamilyTarget(arena, device_scan),
        .version = scan.device_scan_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .intermediate = 3 }, .{ .intermediate = 2 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            .{ .forward = 0 },
        }),
    };
    pipeline_stages[4] = .{
        .target = try radixSplitScatterFamilyTarget(arena, instance),
        .version = radix_split_family_version,
        .buffers = try arena.dupe(artifact_product.PipelineValueRef, &.{
            .{ .result = 0 }, .{ .operand = 0 }, .{ .intermediate = 0 }, .{ .intermediate = 3 },
        }),
        .scalars = try arena.dupe(artifact_product.PipelineScalarDerivation, &.{
            .{ .forward = 0 },
        }),
    };

    owned.value = .{
        .target = try radixSplitPipelineTarget(arena, instance),
        .version = radix_split_family_version,
        .operand_count = 1,
        .result_count = 1,
        .runtime_scalar_argument_count = 3,
        .intermediates = intermediates,
        .stages = pipeline_stages,
    };
    return owned;
}

pub fn radixSplitPipelineRuntimeArguments(
    instance: RadixSplit,
    bit: u32,
) ![3]gpu_abi.ScalarArgument {
    return radixSplitFlagsRuntimeArguments(instance, bit);
}

const testing = std.testing;

fn runRadixSplitPassOnOracleWithGraphs(
    allocator: std.mem.Allocator,
    instance: RadixSplit,
    bit: u32,
    keys: []i32,
    dst: []i32,
    flags_graph: anytype,
    scatter_graph: anytype,
) !void {
    const extent = keys.len;
    const flags = try allocator.alloc(f32, extent);
    defer allocator.free(flags);
    @memset(flags, -1);

    const blocks: u32 = @intCast(radixSplitBlockCount(instance.extent, instance.threads));
    try flags_graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, flags),
        kernel.argumentBuffer(i32, keys),
        kernel.argumentI32(@intCast(extent)),
        kernel.argumentI32(@intCast(bit)),
        kernel.argumentI32(@intCast(radixSplitSignedPassPolarity(bit))),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    const scanned = try allocator.alloc(f32, extent);
    defer allocator.free(scanned);
    var running: f32 = 0;
    for (flags, scanned) |flag, *value| {
        value.* = running;
        running += flag;
    }

    try scatter_graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst),
        kernel.argumentBuffer(i32, keys),
        kernel.argumentBuffer(f32, flags),
        kernel.argumentBuffer(f32, scanned),
        kernel.argumentI32(@intCast(extent)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });
}

fn expectStableSplit(keys: []const i32, dst: []const i32, bit: u32) !void {
    var expected = try testing.allocator.alloc(i32, keys.len);
    defer testing.allocator.free(expected);
    var count: usize = 0;
    const shift: u5 = @intCast(bit);
    for (keys) |key| {
        if ((key >> shift) & 1 == 0) {
            expected[count] = key;
            count += 1;
        }
    }
    for (keys) |key| {
        if ((key >> shift) & 1 == 1) {
            expected[count] = key;
            count += 1;
        }
    }
    try testing.expectEqualSlices(i32, expected, dst);
}

test "sort radix split flags discriminate runtime bits on one compiled kernel" {
    const allocator = testing.allocator;
    const instance = RadixSplit{ .extent = 8, .threads = 32 };
    var keys = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const flags = try allocator.alloc(f32, keys.len);
    defer allocator.free(flags);

    var graph = try RadixSplitFlagsRuntimeFamilyI32.build(
        allocator,
        RadixSplitFlagsRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer graph.deinit();

    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, flags),
        kernel.argumentBuffer(i32, keys[0..]),
        kernel.argumentI32(8),
        kernel.argumentI32(0),
        kernel.argumentI32(0),
    }, .{ .grid = .{ 1, 1, 1 }, .block = .{ 32, 1, 1 } });
    try testing.expectEqualSlices(f32, &.{ 1, 0, 1, 0, 1, 0, 1, 0 }, flags);

    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, flags),
        kernel.argumentBuffer(i32, keys[0..]),
        kernel.argumentI32(8),
        kernel.argumentI32(2),
        kernel.argumentI32(0),
    }, .{ .grid = .{ 1, 1, 1 }, .block = .{ 32, 1, 1 } });
    try testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1, 0, 0, 0, 0 }, flags);

    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, flags),
        kernel.argumentBuffer(i32, keys[0..]),
        kernel.argumentI32(8),
        kernel.argumentI32(2),
        kernel.argumentI32(1),
    }, .{ .grid = .{ 1, 1, 1 }, .block = .{ 32, 1, 1 } });
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 1, 1, 1, 1 }, flags);
}

test "sort radix split pass partitions stably across blocks" {
    const allocator = testing.allocator;
    const extent: usize = 90;
    const instance = RadixSplit{ .extent = extent, .threads = 32 };

    var keys: [extent]i32 = undefined;
    var seed: u32 = 0x2545f491;
    for (&keys, 0..) |*key, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        key.* = @intCast((seed >> 8) % 1000 * 10 + index % 10);
    }

    var dst = @as([extent]i32, @splat(-1));
    var flags_graph = try RadixSplitFlagsRuntimeFamilyI32.build(
        allocator,
        RadixSplitFlagsRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer flags_graph.deinit();
    var scatter_graph = try RadixSplitScatterRuntimeFamilyI32.build(
        allocator,
        RadixSplitScatterRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer scatter_graph.deinit();

    try runRadixSplitPassOnOracleWithGraphs(
        allocator,
        instance,
        0,
        keys[0..],
        dst[0..],
        &flags_graph,
        &scatter_graph,
    );
    try expectStableSplit(keys[0..], dst[0..], 0);

    var dst_bit5 = @as([extent]i32, @splat(-1));
    try runRadixSplitPassOnOracleWithGraphs(
        allocator,
        instance,
        5,
        keys[0..],
        dst_bit5[0..],
        &flags_graph,
        &scatter_graph,
    );
    try expectStableSplit(keys[0..], dst_bit5[0..], 5);
}

test "sort radix split passes compose into a full sort on the oracle" {
    const allocator = testing.allocator;
    const extent: usize = 70;
    const instance = RadixSplit{ .extent = extent, .threads = 32 };

    var keys: [extent]i32 = undefined;
    var seed: u32 = 0x9e3779b9;
    for (&keys) |*key| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        key.* = @intCast(seed % 100000);
    }

    var current = keys;
    var scratch = @as([extent]i32, @splat(-1));
    var flags_graph = try RadixSplitFlagsRuntimeFamilyI32.build(
        allocator,
        RadixSplitFlagsRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer flags_graph.deinit();
    var scatter_graph = try RadixSplitScatterRuntimeFamilyI32.build(
        allocator,
        RadixSplitScatterRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer scatter_graph.deinit();
    var bit: u32 = 0;
    while (bit < 17) : (bit += 1) {
        try runRadixSplitPassOnOracleWithGraphs(
            allocator,
            instance,
            bit,
            current[0..],
            scratch[0..],
            &flags_graph,
            &scatter_graph,
        );
        current = scratch;
    }

    var expected = keys;
    std.mem.sort(i32, expected[0..], {}, std.sort.asc(i32));
    try testing.expectEqualSlices(i32, expected[0..], current[0..]);
}

test "sort radix split identity and validity" {
    const instance = RadixSplit{ .extent = 5000, .threads = 64 };
    const flags_target = try radixSplitFlagsFamilyTarget(testing.allocator, instance);
    defer testing.allocator.free(flags_target);
    try testing.expectEqualStrings(
        "accy.kernel.sort.radix_split_flags_family_64_i32",
        flags_target,
    );
    const scatter_target = try radixSplitScatterFamilyTarget(testing.allocator, instance);
    defer testing.allocator.free(scatter_target);
    try testing.expectEqualStrings(
        "accy.kernel.sort.radix_split_scatter_family_64_i32",
        scatter_target,
    );

    try testing.expect(radixSplitInstanceValid(.{ .extent = 1024 * 1024, .threads = 1024 }));
    try testing.expect(!radixSplitInstanceValid(.{ .extent = 1024 * 1024 + 1, .threads = 1024 }));
    try testing.expect(!radixSplitInstanceValid(.{ .extent = 0, .threads = 32 }));
    try testing.expect(!radixSplitInstanceValid(.{ .extent = 100, .threads = 48 }));
    try testing.expect(
        !radixSplitInstanceValid(.{ .extent = std.math.maxInt(u64), .threads = 32 }),
    );

    const args = try radixSplitFlagsRuntimeArguments(instance, 31);
    try testing.expectEqual(@as(u32, 5000), args[0].u32);
    try testing.expectEqual(@as(u32, 31), args[1].u32);
    try testing.expectEqual(@as(u32, 1), args[2].u32);
    const low_bit_args = try radixSplitFlagsRuntimeArguments(instance, 7);
    try testing.expectEqual(@as(u32, 0), low_bit_args[2].u32);
    try testing.expectError(
        error.UnsupportedRadixSplitInstance,
        radixSplitFlagsRuntimeArguments(instance, 32),
    );
}

test "sort bitonic block identity and validity" {
    const instance = BitonicBlock{ .extent = 45, .threads = 64 };
    const target = try bitonicBlockFamilyTarget(testing.allocator, instance);
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.sort.bitonic_block_family_64_i32", target);
    const entry_name = try bitonicBlockFamilyEntryName(testing.allocator, instance);
    defer testing.allocator.free(entry_name);
    try testing.expectEqualStrings("accy_kernel_sort_bitonic_block_family_64_i32", entry_name);

    try testing.expect(bitonicBlockInstanceValid(instance));
    try testing.expect(bitonicBlockInstanceValid(.{ .extent = 1024, .threads = 1024 }));
    try testing.expect(!bitonicBlockInstanceValid(.{ .extent = 0, .threads = 32 }));
    try testing.expect(!bitonicBlockInstanceValid(.{ .extent = 33, .threads = 48 }));
    try testing.expect(!bitonicBlockInstanceValid(.{ .extent = 65, .threads = 64 }));
    try testing.expect(!bitonicBlockInstanceValid(.{ .extent = 16, .threads = 16 }));
    try testing.expectEqual(@as(?u32, 32), bitonicBlockThreadsForExtent(1));
    try testing.expectEqual(@as(?u32, 32), bitonicBlockThreadsForExtent(32));
    try testing.expectEqual(@as(?u32, 64), bitonicBlockThreadsForExtent(33));
    try testing.expectEqual(@as(?u32, 1024), bitonicBlockThreadsForExtent(1024));
    try testing.expectEqual(@as(?u32, null), bitonicBlockThreadsForExtent(1025));

    const args = try bitonicBlockRuntimeArguments(instance);
    try testing.expectEqual(@as(u32, 45), args[0].u32);
}

test "sort bitonic block sorts a bounded tile on the oracle" {
    const allocator = testing.allocator;
    const extent: usize = 45;
    const instance = BitonicBlock{ .extent = extent, .threads = 64 };

    var keys: [extent]i32 = undefined;
    for (&keys, 0..) |*key, index| {
        const raw: i32 = @intCast((index * 37 + 11) % 53);
        key.* = if (index % 3 == 0) -raw else raw - 19;
    }
    keys[7] = keys[4];
    keys[13] = std.math.maxInt(i32);
    keys[29] = std.math.minInt(i32);

    var dst = @as([extent]i32, @splat(-7777));
    var graph = try BitonicBlockRuntimeFamilyI32.build(
        allocator,
        BitonicBlockRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentBuffer(i32, keys[0..]),
        kernel.argumentI32(@intCast(extent)),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    var expected = keys;
    std.mem.sort(i32, expected[0..], {}, std.sort.asc(i32));
    try testing.expectEqualSlices(i32, expected[0..], dst[0..]);
}

test "sort bitonic block artifact records runtime family metadata" {
    const allocator = testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = BitonicBlock{ .extent = 45, .threads = 64 };
    var family_artifact = try createBitonicBlockFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer family_artifact.deinit();
    const family_entry = family_artifact.entry();
    try testing.expectEqualStrings(
        "accy.kernel.sort.bitonic_block_family_64_i32",
        family_entry.target,
    );
    try testing.expectEqual(bitonic_block_family_version, family_entry.version);
    try testing.expectEqual(@as(u32, 1), family_entry.runtime_scalar_argument_count);
    try testing.expect(family_entry.shape_family_fingerprint != null);

    var owned = try bitonicBlockFamilySpecialization(allocator, instance);
    defer owned.deinit();
    const recovered = bitonicBlockInstanceFromSpecialization(owned.value) orelse
        return error.TestExpectedBitonicBlockInstance;
    try testing.expectEqual(instance.extent, recovered.extent);
    try testing.expectEqual(instance.threads, recovered.threads);
    try testing.expect(owned.value.structureIs(bitonic_block_structure_name));
}

test "sort top-k block identity and validity" {
    const instance = TopKBlock{ .extent = 45, .k = 8, .threads = 64 };
    const target = try topKBlockFamilyTarget(testing.allocator, instance);
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.sort.top_k_block_family_64x8_i32", target);
    const entry_name = try topKBlockFamilyEntryName(testing.allocator, instance);
    defer testing.allocator.free(entry_name);
    try testing.expectEqualStrings("accy_kernel_sort_top_k_block_family_64x8_i32", entry_name);

    try testing.expect(topKBlockInstanceValid(instance));
    try testing.expect(topKBlockInstanceValid(.{ .extent = 1024, .k = 1024, .threads = 1024 }));
    try testing.expect(!topKBlockInstanceValid(.{ .extent = 0, .k = 1, .threads = 32 }));
    try testing.expect(!topKBlockInstanceValid(.{ .extent = 16, .k = 0, .threads = 32 }));
    try testing.expect(!topKBlockInstanceValid(.{ .extent = 16, .k = 17, .threads = 32 }));
    try testing.expect(!topKBlockInstanceValid(.{ .extent = 65, .k = 8, .threads = 64 }));

    const args = try topKBlockRuntimeArguments(instance);
    try testing.expectEqual(@as(u32, 45), args[0].u32);

    var owned = try topKBlockFamilySpecialization(testing.allocator, instance);
    defer owned.deinit();
    try testing.expect(owned.value.operationIs(.{ .sort = .top_k_smallest }));
    try testing.expect(owned.value.structureIs(top_k_block_structure_name));
    try testing.expect(owned.value.inputHasExtents(0, &.{45}));
    try testing.expect(owned.value.outputHasExtents(0, &.{8}));
    const recovered = topKBlockInstanceFromSpecialization(owned.value) orelse
        return error.TestExpectedTopKBlockInstance;
    try testing.expectEqual(@as(u64, 45), recovered.extent);
    try testing.expectEqual(@as(u64, 8), recovered.k);
    try testing.expectEqual(@as(u32, 64), recovered.threads);

    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var artifact = try createTopKBlockFamilyArtifact(
        testing.allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer artifact.deinit();
    const entry_value = artifact.entry();
    try testing.expectEqualStrings(
        "accy.kernel.sort.top_k_block_family_64x8_i32",
        entry_value.target,
    );
    try testing.expectEqual(top_k_block_family_version, entry_value.version);
    try testing.expectEqual(@as(u32, 1), entry_value.runtime_scalar_argument_count);
}

test "sort top-k block selects the smallest sorted prefix on the oracle" {
    const allocator = testing.allocator;
    const extent: usize = 45;
    const top_count: usize = 8;
    const instance = TopKBlock{ .extent = extent, .k = top_count, .threads = 64 };

    var keys: [extent]i32 = undefined;
    for (&keys, 0..) |*key, index| {
        const raw: i32 = @intCast((index * 41 + 5) % 67);
        key.* = if (index % 4 == 0) -raw else raw - 23;
    }
    keys[7] = keys[4];
    keys[13] = std.math.maxInt(i32);
    keys[29] = std.math.minInt(i32);

    var dst = @as([top_count]i32, @splat(-7777));
    var graph = try TopKBlockRuntimeFamilyI32.build(
        allocator,
        TopKBlockRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentBuffer(i32, keys[0..]),
        kernel.argumentI32(@intCast(extent)),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    var expected = keys;
    std.mem.sort(i32, expected[0..], {}, std.sort.asc(i32));
    try testing.expectEqualSlices(i32, expected[0..top_count], dst[0..]);
}

test "sort top-k block pairs identity and validity" {
    const instance = TopKBlockPairs{ .extent = 45, .k = 8, .threads = 64 };
    const target = try topKBlockPairsFamilyTarget(testing.allocator, instance);
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.sort.top_k_block_pairs_family_64x8_i32", target);
    const entry_name = try topKBlockPairsFamilyEntryName(testing.allocator, instance);
    defer testing.allocator.free(entry_name);
    try testing.expectEqualStrings(
        "accy_kernel_sort_top_k_block_pairs_family_64x8_i32",
        entry_name,
    );

    try testing.expect(topKBlockPairsInstanceValid(instance));
    try testing.expect(
        topKBlockPairsInstanceValid(.{ .extent = 1024, .k = 1024, .threads = 1024 }),
    );
    try testing.expect(!topKBlockPairsInstanceValid(.{ .extent = 0, .k = 1, .threads = 32 }));
    try testing.expect(!topKBlockPairsInstanceValid(.{ .extent = 16, .k = 0, .threads = 32 }));
    try testing.expect(!topKBlockPairsInstanceValid(.{ .extent = 16, .k = 17, .threads = 32 }));
    try testing.expect(!topKBlockPairsInstanceValid(.{ .extent = 65, .k = 8, .threads = 64 }));

    const args = try topKBlockPairsRuntimeArguments(instance);
    try testing.expectEqual(@as(u32, 45), args[0].u32);

    var owned = try topKBlockPairsFamilySpecialization(testing.allocator, instance);
    defer owned.deinit();
    try testing.expect(owned.value.operationIs(.{ .sort = .top_k_smallest }));
    try testing.expect(owned.value.structureIs(top_k_block_pairs_structure_name));
    try testing.expect(owned.value.inputHasExtents(0, &.{45}));
    try testing.expect(owned.value.inputHasExtents(1, &.{45}));
    try testing.expect(owned.value.outputHasExtents(0, &.{8}));
    try testing.expect(owned.value.outputHasExtents(1, &.{8}));
    const recovered = topKBlockPairsInstanceFromSpecialization(owned.value) orelse
        return error.TestExpectedTopKBlockPairsInstance;
    try testing.expectEqual(@as(u64, 45), recovered.extent);
    try testing.expectEqual(@as(u64, 8), recovered.k);
    try testing.expectEqual(@as(u32, 64), recovered.threads);

    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var artifact = try createTopKBlockPairsFamilyArtifact(
        testing.allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer artifact.deinit();
    const entry_value = artifact.entry();
    try testing.expectEqualStrings(
        "accy.kernel.sort.top_k_block_pairs_family_64x8_i32",
        entry_value.target,
    );
    try testing.expectEqual(top_k_block_pairs_family_version, entry_value.version);
    try testing.expectEqual(@as(u32, 1), entry_value.runtime_scalar_argument_count);
}

const TopKOraclePair = struct {
    key: i32,
    value: i32,

    fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
        return lhs.key < rhs.key or (lhs.key == rhs.key and lhs.value < rhs.value);
    }
};

test "sort top-k block pairs selects key payload prefixes on the oracle" {
    const allocator = testing.allocator;
    const extent: usize = 45;
    const top_count: usize = 8;
    const instance = TopKBlockPairs{ .extent = extent, .k = top_count, .threads = 64 };

    var keys: [extent]i32 = undefined;
    var values: [extent]i32 = undefined;
    for (&keys, &values, 0..) |*key, *value, index| {
        const raw: i32 = @intCast((index * 41 + 5) % 23);
        key.* = if (index % 4 == 0) -raw else raw - 11;
        value.* = @intCast(index);
    }
    keys[7] = keys[4];
    keys[13] = keys[4];
    keys[29] = std.math.minInt(i32);

    var dst_keys = @as([top_count]i32, @splat(-7777));
    var dst_values = @as([top_count]i32, @splat(-7777));
    var graph = try TopKBlockPairsRuntimeFamilyI32.build(
        allocator,
        TopKBlockPairsRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst_keys[0..]),
        kernel.argumentBuffer(i32, dst_values[0..]),
        kernel.argumentBuffer(i32, keys[0..]),
        kernel.argumentBuffer(i32, values[0..]),
        kernel.argumentI32(@intCast(extent)),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    var expected: [extent]TopKOraclePair = undefined;
    for (&expected, keys, values) |*pair, key, value| pair.* = .{ .key = key, .value = value };
    std.mem.sort(TopKOraclePair, expected[0..], {}, TopKOraclePair.lessThan);
    for (0..top_count) |index| {
        try testing.expectEqual(expected[index].key, dst_keys[index]);
        try testing.expectEqual(expected[index].value, dst_values[index]);
    }
}

test "sort radix split pipeline descriptor binds the family artifacts" {
    const allocator = testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = RadixSplit{ .extent = 5000, .threads = 64 };

    var artifacts = try createRadixSplitPipelineArtifacts(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer artifacts.deinit();
    const entries = artifacts.entries();
    const registry = artifact_product.KernelCallRegistry{ .entries = entries[0..] };

    var owned = try radixSplitPipeline(allocator, instance);
    defer owned.deinit();
    try testing.expectEqualStrings(
        "accy.kernel.sort.radix_split_family_64_i32",
        owned.value.target,
    );
    try testing.expectEqual(@as(u32, 3), owned.value.runtime_scalar_argument_count);
    try testing.expectEqual(@as(usize, 4), owned.value.intermediates.len);
    try testing.expectEqual(@as(usize, 5), owned.value.stages.len);
    try owned.value.validate(registry, .cuda_ptx);

    try testing.expectError(
        error.UnsupportedRadixSplitInstance,
        radixSplitPipeline(allocator, .{ .extent = 0, .threads = 64 }),
    );
}

test "sort radix split passes sort signed keys on the oracle" {
    const allocator = testing.allocator;
    const extent: usize = 60;
    const instance = RadixSplit{ .extent = extent, .threads = 32 };

    var keys: [extent]i32 = undefined;
    var seed: u32 = 0xc0ffee11;
    for (&keys) |*key| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const magnitude: i32 = @intCast(seed % 50000);
        key.* = if (seed & 1 == 1) -magnitude else magnitude;
    }

    var current = keys;
    var scratch = @as([extent]i32, @splat(-1));
    var flags_graph = try RadixSplitFlagsRuntimeFamilyI32.build(
        allocator,
        RadixSplitFlagsRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer flags_graph.deinit();
    var scatter_graph = try RadixSplitScatterRuntimeFamilyI32.build(
        allocator,
        RadixSplitScatterRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer scatter_graph.deinit();
    var bit: u32 = 0;
    while (bit < radix_split_key_bits) : (bit += 1) {
        try runRadixSplitPassOnOracleWithGraphs(
            allocator,
            instance,
            bit,
            current[0..],
            scratch[0..],
            &flags_graph,
            &scatter_graph,
        );
        current = scratch;
    }

    var expected = keys;
    std.mem.sort(i32, expected[0..], {}, std.sort.asc(i32));
    try testing.expectEqualSlices(i32, expected[0..], current[0..]);
}

test "sort radix digit histogram counts per block in column-major order" {
    const allocator = testing.allocator;
    const extent: usize = 90;
    const instance = RadixSplit{ .extent = extent, .threads = 32 };
    const blocks: u32 = @intCast(radixSplitBlockCount(instance.extent, instance.threads));
    try testing.expectEqual(@as(u32, 3), blocks);

    var keys: [extent]i32 = undefined;
    var seed: u32 = 0x2545f491;
    for (&keys) |*key| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        key.* = @intCast(seed % 100000);
    }

    var graph = try RadixDigitHistogramRuntimeFamilyI32.build(
        allocator,
        RadixDigitHistogramRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer graph.deinit();

    inline for (.{ 0, 4 }) |shift| {
        var counts = @as([(radix_digit_bins * 3)]f32, @splat(-1));
        try graph.runCpuWithLaunch(allocator, &.{
            kernel.argumentBuffer(f32, counts[0..]),
            kernel.argumentBuffer(i32, keys[0..]),
            kernel.argumentI32(@intCast(extent)),
            kernel.argumentI32(shift),
            kernel.argumentI32(0),
        }, .{
            .grid = .{ blocks, 1, 1 },
            .block = .{ instance.threads, 1, 1 },
        });

        var expected = @as([(radix_digit_bins * 3)]f32, @splat(0));
        for (keys, 0..) |key, index| {
            const digit: usize = @intCast((key >> shift) & (radix_digit_bins - 1));
            const block = index / instance.threads;
            expected[digit * 3 + block] += 1;
        }
        try testing.expectEqualSlices(f32, expected[0..], counts[0..]);
    }
}

fn runRadixDigitPassOnOracleWithGraphs(
    allocator: std.mem.Allocator,
    instance: RadixSplit,
    shift: u32,
    keys: []i32,
    dst: []i32,
    histogram_graph: anytype,
    scatter_graph: anytype,
) !void {
    const extent = keys.len;
    const blocks: u32 = @intCast(radixSplitBlockCount(instance.extent, instance.threads));
    const cell_count = radix_digit_bins * blocks;

    const counts = try allocator.alloc(f32, cell_count);
    defer allocator.free(counts);
    @memset(counts, -1);

    try histogram_graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, counts),
        kernel.argumentBuffer(i32, keys),
        kernel.argumentI32(@intCast(extent)),
        kernel.argumentI32(@intCast(shift)),
        kernel.argumentI32(@intCast(radixDigitSignedPassBias(shift))),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    const scanned = try allocator.alloc(f32, cell_count);
    defer allocator.free(scanned);
    var running: f32 = 0;
    for (counts, scanned) |count, *value| {
        value.* = running;
        running += count;
    }

    try scatter_graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst),
        kernel.argumentBuffer(i32, keys),
        kernel.argumentBuffer(f32, scanned),
        kernel.argumentI32(@intCast(extent)),
        kernel.argumentI32(@intCast(shift)),
        kernel.argumentI32(@intCast(radixDigitSignedPassBias(shift))),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });
}

fn expectStableDigitPass(keys: []const i32, dst: []const i32, shift: u32) !void {
    const expected = try testing.allocator.alloc(i32, keys.len);
    defer testing.allocator.free(expected);
    var count: usize = 0;
    const shift_amount: u5 = @intCast(shift);
    var digit: i32 = 0;
    while (digit < radix_digit_bins) : (digit += 1) {
        for (keys) |key| {
            if ((key >> shift_amount) & (radix_digit_bins - 1) == digit) {
                expected[count] = key;
                count += 1;
            }
        }
    }
    try testing.expectEqualSlices(i32, expected, dst);
}

test "sort radix digit pass partitions stably by digit across warps and blocks" {
    const allocator = testing.allocator;
    const extent: usize = 150;
    const instance = RadixSplit{ .extent = extent, .threads = 64 };

    var keys: [extent]i32 = undefined;
    var seed: u32 = 0x2545f491;
    for (&keys, 0..) |*key, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        key.* = @intCast((seed >> 8) % 10000 * 10 + index % 10);
    }

    var dst = @as([extent]i32, @splat(-1));
    var histogram_graph = try RadixDigitHistogramRuntimeFamilyI32.build(
        allocator,
        RadixDigitHistogramRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer histogram_graph.deinit();
    var scatter_graph = try RadixDigitRankScatterRuntimeFamilyI32.build(
        allocator,
        RadixDigitRankScatterRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer scatter_graph.deinit();

    try runRadixDigitPassOnOracleWithGraphs(
        allocator,
        instance,
        0,
        keys[0..],
        dst[0..],
        &histogram_graph,
        &scatter_graph,
    );
    try expectStableDigitPass(keys[0..], dst[0..], 0);

    var dst_high = @as([extent]i32, @splat(-1));
    try runRadixDigitPassOnOracleWithGraphs(
        allocator,
        instance,
        8,
        keys[0..],
        dst_high[0..],
        &histogram_graph,
        &scatter_graph,
    );
    try expectStableDigitPass(keys[0..], dst_high[0..], 8);
}

test "sort radix digit passes compose into a full sort on the oracle" {
    const allocator = testing.allocator;
    const extent: usize = 130;
    const instance = RadixSplit{ .extent = extent, .threads = 32 };

    var keys: [extent]i32 = undefined;
    var seed: u32 = 0x9e3779b9;
    for (&keys) |*key| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        key.* = @intCast(seed % 1000000);
    }

    var current = keys;
    var scratch = @as([extent]i32, @splat(-1));
    var histogram_graph = try RadixDigitHistogramRuntimeFamilyI32.build(
        allocator,
        RadixDigitHistogramRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer histogram_graph.deinit();
    var scatter_graph = try RadixDigitRankScatterRuntimeFamilyI32.build(
        allocator,
        RadixDigitRankScatterRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer scatter_graph.deinit();
    var shift: u32 = 0;
    while (shift < 20) : (shift += radix_digit_bits) {
        try runRadixDigitPassOnOracleWithGraphs(
            allocator,
            instance,
            shift,
            current[0..],
            scratch[0..],
            &histogram_graph,
            &scatter_graph,
        );
        current = scratch;
    }

    var expected = keys;
    std.mem.sort(i32, expected[0..], {}, std.sort.asc(i32));
    try testing.expectEqualSlices(i32, expected[0..], current[0..]);
}

test "sort radix digit pipeline descriptor binds the family artifacts" {
    const allocator = testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = RadixSplit{ .extent = 5000, .threads = 64 };

    var artifacts = try createRadixDigitPipelineArtifacts(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer artifacts.deinit();
    const entries = artifacts.entries();
    const registry = artifact_product.KernelCallRegistry{ .entries = entries[0..] };

    var owned = try radixDigitPipeline(allocator, instance);
    defer owned.deinit();
    try testing.expectEqualStrings(
        "accy.kernel.sort.radix_digit_family_64_i32",
        owned.value.target,
    );
    try testing.expectEqual(@as(u32, 3), owned.value.runtime_scalar_argument_count);
    try testing.expectEqual(@as(usize, 4), owned.value.intermediates.len);
    try testing.expectEqual(@as(usize, 5), owned.value.stages.len);
    try owned.value.validate(registry, .cuda_ptx);

    const args = [_]gpu_abi.ScalarArgument{ .{ .u32 = 5000 }, .{ .u32 = 0 }, .{ .u32 = 0 } };
    try testing.expectEqual(
        @as(u32, 79 * 16),
        try owned.value.intermediates[0].extent.resolveExtent(args[0..]),
    );
    try testing.expectEqual(
        @as(u32, 2),
        try owned.value.intermediates[1].extent.resolveExtent(args[0..]),
    );
}

test "sort tuning resolves structure winners through pipeline targets" {
    const allocator = testing.allocator;
    const instance = RadixSplit{ .extent = 5000, .threads = 64 };
    const device: u64 = 0xfeed_dead_beef_0001;

    var accumulator = tuning.FamilyMeasurementAccumulator.init(allocator);
    defer accumulator.deinit();

    const key = try radixSplitFamilyTuningKey(allocator, device, instance);
    const digit_target = try radixDigitPipelineTarget(allocator, instance);
    defer allocator.free(digit_target);
    const split_target = try radixSplitPipelineTarget(allocator, instance);
    defer allocator.free(split_target);

    try accumulator.append(key, split_target, 6_400_000, 50);
    try accumulator.append(key, digit_target, 1_550_000, 50);

    var winners = try accumulator.selectWinners(
        allocator,
        tuning.family_tuning_default_margin_percent,
    );
    defer winners.deinit();
    try testing.expectEqual(@as(usize, 1), winners.records.len);

    const encoded_artifact = try tuning.encodeFamilyTuningArtifact(allocator, winners.records);
    defer allocator.free(encoded_artifact);
    var decoded = try tuning.decodeFamilyTuningArtifact(allocator, encoded_artifact);
    defer decoded.deinit();

    const reader = tuning.FamilyTuningReader{
        .device_fingerprint = device,
        .table = decoded.table(),
    };
    const resolved = (try resolveRadixSplitStructure(allocator, reader, instance)) orelse {
        return error.TestExpectedSortStructure;
    };
    try testing.expectEqual(RadixSplitResolvedStructure.radix_digit, resolved);

    const other_extent = RadixSplit{ .extent = 9000, .threads = 64 };
    try testing.expectEqual(
        @as(?RadixSplitResolvedStructure, null),
        try resolveRadixSplitStructure(allocator, reader, other_extent),
    );
}

test "sort radix digit passes sort signed keys on the oracle" {
    const allocator = testing.allocator;
    const extent: usize = 96;
    const instance = RadixSplit{ .extent = extent, .threads = 32 };

    var keys: [extent]i32 = undefined;
    var seed: u32 = 0xc0ffee11;
    for (&keys) |*key| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const magnitude: i32 = @intCast(seed % 500000);
        key.* = if (seed & 1 == 1) -magnitude else magnitude;
    }

    var current = keys;
    var scratch = @as([extent]i32, @splat(-1));
    var histogram_graph = try RadixDigitHistogramRuntimeFamilyI32.build(
        allocator,
        RadixDigitHistogramRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer histogram_graph.deinit();
    var scatter_graph = try RadixDigitRankScatterRuntimeFamilyI32.build(
        allocator,
        RadixDigitRankScatterRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer scatter_graph.deinit();
    var shift: u32 = 0;
    while (shift < radix_split_key_bits) : (shift += radix_digit_bits) {
        try runRadixDigitPassOnOracleWithGraphs(
            allocator,
            instance,
            shift,
            current[0..],
            scratch[0..],
            &histogram_graph,
            &scatter_graph,
        );
        current = scratch;
    }

    var expected = keys;
    std.mem.sort(i32, expected[0..], {}, std.sort.asc(i32));
    try testing.expectEqualSlices(i32, expected[0..], current[0..]);
}

test "sort radix digit pairs pipeline descriptor binds the family artifacts" {
    const allocator = testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = RadixSplit{ .extent = 5000, .threads = 64 };

    var artifacts = try createRadixDigitPairsPipelineArtifacts(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer artifacts.deinit();
    const entries = artifacts.entries();
    const registry = artifact_product.KernelCallRegistry{ .entries = entries[0..] };

    var owned = try radixDigitPairsPipeline(allocator, instance);
    defer owned.deinit();
    try testing.expectEqualStrings(
        "accy.kernel.sort.radix_digit_pairs_family_64_i32",
        owned.value.target,
    );
    try testing.expectEqual(@as(u32, 2), owned.value.operand_count);
    try testing.expectEqual(@as(u32, 2), owned.value.result_count);
    try testing.expectEqual(@as(u32, 3), owned.value.runtime_scalar_argument_count);
    try owned.value.validate(registry, .cuda_ptx);
}

test "sort radix digit pairs pass carries payloads stably on the oracle" {
    const allocator = testing.allocator;
    const extent: usize = 96;
    const instance = RadixSplit{ .extent = extent, .threads = 32 };
    const blocks: u32 = @intCast(radixSplitBlockCount(instance.extent, instance.threads));
    const cell_count = radix_digit_bins * blocks;

    var keys: [extent]i32 = undefined;
    var values: [extent]i32 = undefined;
    var seed: u32 = 0xc0ffee11;
    for (&keys, &values, 0..) |*key, *value, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const magnitude: i32 = @intCast(seed % 50000);
        key.* = if (seed & 1 == 1) -magnitude else magnitude;
        value.* = @intCast(index);
    }

    const shift: u32 = 28;
    const counts = try allocator.alloc(f32, cell_count);
    defer allocator.free(counts);
    @memset(counts, -1);
    var histogram_graph = try RadixDigitHistogramRuntimeFamilyI32.build(
        allocator,
        RadixDigitHistogramRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer histogram_graph.deinit();
    try histogram_graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, counts),
        kernel.argumentBuffer(i32, keys[0..]),
        kernel.argumentI32(@intCast(extent)),
        kernel.argumentI32(@intCast(shift)),
        kernel.argumentI32(@intCast(radixDigitSignedPassBias(shift))),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    const scanned = try allocator.alloc(f32, cell_count);
    defer allocator.free(scanned);
    var running: f32 = 0;
    for (counts, scanned) |count, *value| {
        value.* = running;
        running += count;
    }

    var dst = @as([extent]i32, @splat(-1));
    var dst_values = @as([extent]i32, @splat(-1));
    var pairs_graph = try RadixDigitRankScatterPairsRuntimeFamilyI32.build(
        allocator,
        RadixDigitRankScatterPairsRuntimeFamilyI32.Limits.testing,
        instance,
    );
    defer pairs_graph.deinit();
    try pairs_graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentBuffer(i32, dst_values[0..]),
        kernel.argumentBuffer(i32, keys[0..]),
        kernel.argumentBuffer(i32, values[0..]),
        kernel.argumentBuffer(f32, scanned),
        kernel.argumentI32(@intCast(extent)),
        kernel.argumentI32(@intCast(shift)),
        kernel.argumentI32(@intCast(radixDigitSignedPassBias(shift))),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    for (dst, dst_values) |key, original_index| {
        try testing.expectEqual(keys[@intCast(original_index)], key);
    }
    var previous_bucket: i32 = -1;
    for (dst) |key| {
        const shift_amount: u5 = @intCast(shift);
        const digit = ((key >> shift_amount) & (radix_digit_bins - 1)) ^ @as(
            i32,
            @intCast(radixDigitSignedPassBias(shift)),
        );
        try testing.expect(digit >= previous_bucket);
        previous_bucket = digit;
    }
}
