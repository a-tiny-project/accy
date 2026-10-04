const std = @import("std");
const gpu_abi = @import("gpu_abi");

const accy = @import("../../../../../root.zig");
const library = @import("../../../root.zig");
const family = @import("../root.zig");

const entry = library.entry;
const kernel = accy.kernel;
const Histogram = family.Histogram;
const HistogramBinningPolicy = family.HistogramBinningPolicy;
const DType = gpu_abi.DType;

fn histogramFamilySchedule(instance: Histogram) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn histogramBinIndex(
    b: anytype,
    value: kernel.Value,
    lo: kernel.Value,
    width: kernel.Value,
) !kernel.Value {
    const offset = try b.sub(value, lo);
    const ratio = try b.div(offset, width);
    const bin_i32 = try b.cast(ratio, .i32);
    return b.castIndex(bin_i32);
}

fn histogramUpperBound(
    b: anytype,
    bins: kernel.Value,
    lo: kernel.Value,
    width: kernel.Value,
    policy: HistogramBinningPolicy,
) !kernel.Value {
    return switch (policy) {
        .lower_inclusive_upper_exclusive => {
            const bins_f32 = try b.cast(bins, .f32);
            const span = try b.mul(bins_f32, width);
            return b.add(lo, span);
        },
    };
}

fn histogramAccumulate(b: anytype, ctx: anytype, target: kernel.Value) !void {
    const one = try b.constantInt(.i32, 1);
    _ = try b.atomicRmwIndex(.add, one, ctx.dst, target);
}

fn histogram_element_body_in_low(inner: anytype, low_ctx: anytype) !void {
    const width = low_ctx.args.param(.width).raw();
    const upper = try histogramUpperBound(inner, low_ctx.bins, low_ctx.lo, width, low_ctx.binning);
    const in_high = try inner.compare(.lt, low_ctx.value, upper);
    try inner.guardDo(in_high, .{
        .args = low_ctx.args,
        .value = low_ctx.value,
        .lo = low_ctx.lo,
        .width = width,
        .bins = low_ctx.bins,
        .dst = low_ctx.dst,
    }, histogram_element_body_in_high);
}

fn histogram_element_body_in_high(range_builder: anytype, range_ctx: anytype) !void {
    const target = try histogramBinIndex(
        range_builder,
        range_ctx.value,
        range_ctx.lo,
        range_ctx.width,
    );
    const in_range = try range_builder.compare(.lt, target, range_ctx.bins);
    try range_builder.guardDo(in_range, .{
        .dst = range_ctx.dst,
        .target = target,
    }, histogram_element_body_in_range);
}

fn histogram_element_body_in_range(atomic_builder: anytype, atomic_ctx: anytype) !void {
    try histogramAccumulate(atomic_builder, atomic_ctx, atomic_ctx.target);
}

fn histogramElementBody(b: anytype, ctx: anytype) !void {
    const loaded = try ctx.args.param(.data).load(b, ctx.element);
    const value = loaded.raw();
    const lo = ctx.args.param(.lo).raw();
    const in_low = try b.compare(.ge, value, lo);
    try b.guardDo(in_low, .{
        .args = ctx.args,
        .value = value,
        .lo = lo,
        .bins = ctx.bins,
        .dst = ctx.dst,
        .binning = ctx.binning,
    }, histogram_element_body_in_low);
}

fn histogram_runtime_body_accumulate(guard_builder: anytype, ctx: anytype) !void {
    try histogramElementBody(guard_builder, ctx);
}

fn histogramDirectRuntimeBody(k: anytype, spec: Histogram, args: anytype) !void {
    const element = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const bins = try k.castIndex(args.param(.bins).raw());
    const active = try k.compare(.lt, element, count);
    try k.guardDo(active, .{
        .args = args,
        .element = element,
        .bins = bins,
        .dst = args.param(.dst).raw(),
        .binning = spec.binning,
    }, histogram_runtime_body_accumulate);
}

fn histogram_shared_runtime_body_zero_bin(
    loop_builder: anytype,
    bin: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    try loop_builder.storeIndex(ctx.zero_count, ctx.shared_bins, bin);
    return acc;
}

fn histogram_shared_runtime_body_merge(
    loop_builder: anytype,
    bin: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    const partial = try loop_builder.loadIndex(ctx.shared_bins, bin);
    _ = try loop_builder.atomicRmwIndex(.add, partial, ctx.args.param(.dst).raw(), bin);
    return acc;
}

fn histogramSharedRuntimeBody(k: anytype, spec: Histogram, args: anytype) !void {
    const shared_bins = try k.sharedBuffer(.i32, spec.bins);
    const zero_count = try k.constantInt(.i32, 0);
    const thread = try k.castIndex(try k.threadId(.x));
    const stride = try k.castIndex(try k.blockDim(.x));
    const bins = try k.castIndex(args.param(.bins).raw());

    _ = try k.fold(thread, bins, stride, zero_count, .{
        .shared_bins = shared_bins,
        .zero_count = zero_count,
    }, histogram_shared_runtime_body_zero_bin);
    try k.barrier(.block);

    const element = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const active = try k.compare(.lt, element, count);
    try k.guardDo(active, .{
        .args = args,
        .element = element,
        .bins = bins,
        .dst = shared_bins,
        .binning = spec.binning,
    }, histogram_runtime_body_accumulate);
    try k.barrier(.block);

    _ = try k.fold(thread, bins, stride, zero_count, .{
        .args = args,
        .shared_bins = shared_bins,
    }, histogram_shared_runtime_body_merge);
}

fn histogramRuntimeBody(k: anytype, spec: Histogram, args: anytype) !void {
    switch (spec.variant) {
        .direct => try histogramDirectRuntimeBody(k, spec, args),
        .shared_bins => try histogramSharedRuntimeBody(k, spec, args),
    }
}

fn histogramRuntimeFamily(comptime data_dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_histogram_runtime_{s}", .{data_dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.i32),
            .data = kernel.dynamicBuffer(data_dtype),
            .bins = kernel.scalar(.i32),
            .count = kernel.scalar(.i32),
            .lo = kernel.scalar(.f32),
            .width = kernel.scalar(.f32),
        },
        .Instance = Histogram,
        .schedule = histogramFamilySchedule,
        .body = histogramRuntimeBody,
    });
}

pub const HistogramRuntimeFamilyF32 = histogramRuntimeFamily(.f32);

test "histogram runtime family bins values exactly on the oracle" {
    const allocator = std.testing.allocator;
    const compiled = Histogram{ .bins = 8, .count = 1, .variant = .shared_bins, .threads = 8 };
    const runtime = Histogram{
        .bins = 8,
        .count = 20,
        .lo = 0,
        .width = 0.5,
        .variant = .shared_bins,
        .threads = 8,
    };

    var graph = try HistogramRuntimeFamilyF32.build(
        allocator,
        HistogramRuntimeFamilyF32.Limits.testing,
        compiled,
    );
    defer graph.deinit();

    var dst = @as([8]i32, @splat(0));
    var data: [20]f32 = undefined;
    for (&data, 0..) |*value, element| {
        value.* = -0.4 + @as(f32, @floatFromInt(element)) * 0.25;
    }

    var expected = @as([8]i32, @splat(0));
    for (data) |value| {
        if (family.histogramBinForValue(runtime, value)) |bin| expected[bin] += 1;
    }

    const launch_value = try entry.runtimeLaunch1D(runtime.count, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentBuffer(f32, data[0..]),
        kernel.argumentI32(@intCast(runtime.bins)),
        kernel.argumentI32(@intCast(runtime.count)),
        .{ .scalar = .{ .f32 = runtime.lo } },
        .{ .scalar = .{ .f32 = runtime.width } },
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });
    try std.testing.expectEqualSlices(i32, expected[0..], dst[0..]);
}

test "histogram binning policy drops closed upper edge" {
    const allocator = std.testing.allocator;
    const instance = Histogram{
        .bins = 4,
        .count = 6,
        .lo = 1.0,
        .width = 0.5,
        .variant = .direct,
        .threads = 4,
    };
    var graph = try HistogramRuntimeFamilyF32.build(
        allocator,
        HistogramRuntimeFamilyF32.Limits.testing,
        instance,
    );
    defer graph.deinit();

    var dst = @as([4]i32, @splat(0));
    var data = [_]f32{ 0.99, 1.0, 1.49, 1.5, 2.99, 3.0 };
    var expected = @as([4]i32, @splat(0));
    for (data) |value| {
        if (family.histogramBinForValue(instance, value)) |bin| expected[bin] += 1;
    }

    const launch_value = try entry.runtimeLaunch1D(instance.count, instance.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentBuffer(f32, data[0..]),
        kernel.argumentI32(@intCast(instance.bins)),
        kernel.argumentI32(@intCast(instance.count)),
        .{ .scalar = .{ .f32 = instance.lo } },
        .{ .scalar = .{ .f32 = instance.width } },
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });
    try std.testing.expectEqualSlices(i32, expected[0..], dst[0..]);
    try std.testing.expectEqual(@as(i32, 1), dst[3]);
}
