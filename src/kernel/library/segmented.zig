const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");

const artifact_product = @import("../../artifact/model/root.zig");
const shape = @import("../../choir/shape/root.zig");
const entry = @import("entry.zig");
const extent_mod = @import("extent.zig");
const geometry_mod = @import("geometry.zig");
const kernel = @import("../root.zig");
const tuning = @import("tuning.zig");

const DType = gpu_abi.DType;
const indexExtent = extent_mod.indexExtent;
const runtimeExtentArgument = extent_mod.runtimeExtentArgument;

pub const SegmentSumGranularity = enum {
    thread,
    warp,

    pub fn name(self: SegmentSumGranularity) []const u8 {
        return switch (self) {
            .thread => "thread",
            .warp => "warp",
        };
    }
};

pub const SegmentSum = struct {
    segments: u64,
    total: u64,
    dtype: DType = .f32,
    accumulation_dtype: DType = .f32,
    granularity: SegmentSumGranularity = .thread,
    threads: u32 = 256,
    segment_axis: []const u8 = "s",
    element_axis: []const u8 = "e",

    pub fn launchExtent(self: SegmentSum) u64 {
        return switch (self.granularity) {
            .thread => self.segments,
            .warp => self.segments * segment_sum_warp_size,
        };
    }
};

pub const segment_sum_family_version: u32 = 1;
pub const segment_sum_warp_size: u32 = 32;
const segment_sum_thread_caps = geometry_mod.ThreadCaps1D{};

pub fn segmentSumGranularityValid(granularity: SegmentSumGranularity, threads: u32) bool {
    return switch (granularity) {
        .thread => threads != 0,
        .warp => threads != 0 and threads % segment_sum_warp_size == 0,
    };
}

pub fn segmentSumDTypeSupported(dtype: DType) bool {
    return switch (dtype) {
        .f32, .f16 => true,
        else => false,
    };
}

pub fn segmentSumAccumulationDType(dtype: DType) ?DType {
    return switch (dtype) {
        .f32, .f16 => .f32,
        else => null,
    };
}

fn segmentSumAccumulationZero(inner_builder: anytype, spec: SegmentSum) !kernel.Value {
    return switch (spec.accumulation_dtype) {
        .f32 => inner_builder.constantFloat(.f32, 0.0),
        .f16 => inner_builder.constantFloat(.f16, 0.0),
        else => error.UnsupportedDType,
    };
}

fn segmentSumAccumulationValue(inner_builder: anytype, spec: SegmentSum, value: anytype) !kernel.Value {
    return switch (spec.accumulation_dtype) {
        .f32 => if (comptime @TypeOf(value).scalar_dtype == .f32) value.raw() else (try value.cast(inner_builder, .f32)).raw(),
        .f16 => if (comptime @TypeOf(value).scalar_dtype == .f16) value.raw() else (try value.cast(inner_builder, .f16)).raw(),
        else => error.UnsupportedDType,
    };
}

fn segmentSumOutputValue(inner_builder: anytype, spec: SegmentSum, value: kernel.Value) !kernel.Value {
    if (spec.dtype == spec.accumulation_dtype) return value;
    return switch (spec.dtype) {
        .f32 => inner_builder.cast(value, .f32),
        .f16 => inner_builder.cast(value, .f16),
        else => error.UnsupportedDType,
    };
}

fn segmentOffsetIndex(inner_builder: anytype, loaded: anytype, total: kernel.Value) !kernel.Value {
    const zero_i32 = try inner_builder.constantInt(.i32, 0);
    const max_i32_index = try inner_builder.constantIndex(std.math.maxInt(i32));
    const total_limit = try inner_builder.min(total, max_i32_index);
    const total_i32 = try inner_builder.cast(total_limit, .i32);
    const lower = try inner_builder.max(loaded.raw(), zero_i32);
    const clamped = try inner_builder.min(lower, total_i32);
    return inner_builder.castIndex(clamped);
}

fn segment_sum_value_apply(fold_builder: anytype, element: kernel.Value, current: kernel.Value, ctx: anytype) !kernel.Value {
    const value = try ctx.args.param(.data).load(fold_builder, element);
    const value_acc = try segmentSumAccumulationValue(fold_builder, ctx.spec, value);
    return fold_builder.add(current, value_acc);
}

fn segmentSumValue(
    inner_builder: anytype,
    spec: SegmentSum,
    args: anytype,
    segment: kernel.Value,
    total: kernel.Value,
) !kernel.Value {
    const one = try inner_builder.constantIndex(1);
    const next = try inner_builder.add(segment, one);
    const begin_loaded = try args.param(.offsets).load(inner_builder, segment);
    const end_loaded = try args.param(.offsets).load(inner_builder, next);
    const end_clamped = try segmentOffsetIndex(inner_builder, end_loaded, total);
    const begin_offset = try segmentOffsetIndex(inner_builder, begin_loaded, total);
    const begin_clamped = try inner_builder.min(begin_offset, end_clamped);

    const acc_zero = try segmentSumAccumulationZero(inner_builder, spec);
    return inner_builder.fold(begin_clamped, end_clamped, one, acc_zero, .{
        .spec = spec,
        .args = args,
    }, segment_sum_value_apply);
}

fn segment_sum_warp_value_apply(fold_builder: anytype, element: kernel.Value, current: kernel.Value, ctx: anytype) !kernel.Value {
    const value = try ctx.args.param(.data).load(fold_builder, element);
    const value_acc = try segmentSumAccumulationValue(fold_builder, ctx.spec, value);
    return fold_builder.add(current, value_acc);
}

fn segmentSumWarpValue(
    inner_builder: anytype,
    spec: SegmentSum,
    args: anytype,
    segment: kernel.Value,
    lane: kernel.Value,
    total: kernel.Value,
) !kernel.Value {
    const one = try inner_builder.constantIndex(1);
    const next = try inner_builder.add(segment, one);
    const begin_loaded = try args.param(.offsets).load(inner_builder, segment);
    const end_loaded = try args.param(.offsets).load(inner_builder, next);
    const end_clamped = try segmentOffsetIndex(inner_builder, end_loaded, total);
    const begin_offset = try segmentOffsetIndex(inner_builder, begin_loaded, total);
    const begin_clamped = try inner_builder.min(begin_offset, end_clamped);
    const lane_begin = try inner_builder.add(begin_clamped, lane);
    const stride = try inner_builder.constantIndex(segment_sum_warp_size);

    const acc_zero = try segmentSumAccumulationZero(inner_builder, spec);
    const partial = try inner_builder.fold(lane_begin, end_clamped, stride, acc_zero, .{
        .spec = spec,
        .args = args,
    }, segment_sum_warp_value_apply);
    return inner_builder.warpReduce(.add, partial);
}

fn segment_sum_body_each(inner_builder: anytype, index: kernel.Index1D, ctx: anytype) !void {
    const total = try inner_builder.constantIndex(try indexExtent(ctx.spec.total));
    const sum = try segmentSumValue(inner_builder, ctx.spec, ctx.args, index.index, total);
    const output = try segmentSumOutputValue(inner_builder, ctx.spec, sum);
    try ctx.args.param(.dst).store(inner_builder, output, index);
}

fn segmentSumBody(k: anytype, spec: SegmentSum, args: anytype) !void {
    if (spec.granularity != .thread) return error.UnsupportedGranularity;
    _ = try k.forEach1D(spec.segment_axis, spec.segments, .{ .spec = spec, .args = args }, segment_sum_body_each);
}

fn segmentSumRuntimeBody(k: anytype, spec: SegmentSum, args: anytype) !void {
    return switch (spec.granularity) {
        .thread => segmentSumThreadRuntimeBody(k, spec, args),
        .warp => segmentSumWarpRuntimeBody(k, spec, args),
    };
}

fn segment_sum_thread_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const sum = try segmentSumValue(inner_builder, ctx.spec, ctx.args, ctx.segment, ctx.total);
    const output = try segmentSumOutputValue(inner_builder, ctx.spec, sum);
    try ctx.args.param(.dst).store(inner_builder, output, ctx.segment);
}

fn segmentSumThreadRuntimeBody(k: anytype, spec: SegmentSum, args: anytype) !void {
    const segment = try k.globalId(.x);
    const segments_extent = try k.castIndex(args.param(.segments).raw());
    const total = try k.castIndex(args.param(.total).raw());
    const active = try k.compare(.lt, segment, segments_extent);
    try k.guardDo(active, .{
        .spec = spec,
        .args = args,
        .segment = segment,
        .total = total,
    }, segment_sum_thread_runtime_body_active);
}

fn segment_sum_warp_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const sum = try segmentSumWarpValue(inner_builder, ctx.spec, ctx.args, ctx.segment, ctx.lane, ctx.total);
    const zero = try inner_builder.constantIndex(0);
    const writer = try inner_builder.compare(.eq, ctx.lane, zero);
    try inner_builder.guardDo(writer, .{
        .spec = ctx.spec,
        .args = ctx.args,
        .segment = ctx.segment,
        .sum = sum,
    }, segment_sum_warp_runtime_body_writer);
}

fn segment_sum_warp_runtime_body_writer(writer_builder: anytype, writer_ctx: anytype) !void {
    const output = try segmentSumOutputValue(writer_builder, writer_ctx.spec, writer_ctx.sum);
    try writer_ctx.args.param(.dst).store(writer_builder, output, writer_ctx.segment);
}

fn segmentSumWarpRuntimeBody(k: anytype, spec: SegmentSum, args: anytype) !void {
    if (!segmentSumGranularityValid(.warp, spec.threads)) return error.UnsupportedGranularity;
    const element_thread = try k.globalId(.x);
    const lane = try k.laneId();
    const warp_size = try k.constantIndex(segment_sum_warp_size);
    const segment = try k.div(element_thread, warp_size);
    const segments_extent = try k.castIndex(args.param(.segments).raw());
    const total = try k.castIndex(args.param(.total).raw());
    const active = try k.compare(.lt, segment, segments_extent);
    try k.guardDo(active, .{
        .spec = spec,
        .args = args,
        .segment = segment,
        .lane = lane,
        .total = total,
    }, segment_sum_warp_runtime_body_active);
}

fn segmentSumFamilySchedule(instance: SegmentSum) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn segmentSumFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_segmented_segment_sum_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .data = kernel.dynamicBuffer(dtype),
            .offsets = kernel.dynamicBuffer(.i32),
        },
        .Instance = SegmentSum,
        .schedule = segmentSumFamilySchedule,
        .body = segmentSumBody,
    });
}

fn segmentSumRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_segmented_segment_sum_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .data = kernel.dynamicBuffer(dtype),
            .offsets = kernel.dynamicBuffer(.i32),
            .segments = kernel.scalar(.i32),
            .total = kernel.scalar(.i32),
        },
        .Instance = SegmentSum,
        .schedule = segmentSumFamilySchedule,
        .body = segmentSumRuntimeBody,
    });
}

pub const SegmentSumFamilyF32 = segmentSumFamily(.f32);
pub const SegmentSumFamilyF16 = segmentSumFamily(.f16);
pub const SegmentSumRuntimeFamilyF32 = segmentSumRuntimeFamily(.f32);
pub const SegmentSumRuntimeFamilyF16 = segmentSumRuntimeFamily(.f16);

pub fn segmentSumThreadsForSegments(segments: u64) u32 {
    return geometry_mod.threadsForExtent(segments, segment_sum_thread_caps);
}

pub fn segmentSumThreadCandidatesForSegments(segments: u64) geometry_mod.Thread1DCandidates {
    return geometry_mod.threadCandidatesForExtent(segments, segment_sum_thread_caps);
}

pub fn segmentSumInstanceTarget(allocator: std.mem.Allocator, instance: SegmentSum) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.segmented.segment_sum{d}x{d}_{s}_{d}_{s}",
        .{ instance.segments, instance.total, instance.granularity.name(), instance.threads, instance.dtype.name() },
    );
}

pub fn segmentSumInstanceEntryName(allocator: std.mem.Allocator, instance: SegmentSum) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_segmented_segment_sum{d}x{d}_{s}_{d}_{s}",
        .{ instance.segments, instance.total, instance.granularity.name(), instance.threads, instance.dtype.name() },
    );
}

pub fn segmentSumFamilyTarget(allocator: std.mem.Allocator, instance: SegmentSum) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.segmented.segment_sum_family_{s}_{d}_{s}",
        .{ instance.granularity.name(), instance.threads, instance.dtype.name() },
    );
}

pub fn segmentSumFamilyEntryName(allocator: std.mem.Allocator, instance: SegmentSum) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_segmented_segment_sum_family_{s}_{d}_{s}",
        .{ instance.granularity.name(), instance.threads, instance.dtype.name() },
    );
}

pub fn segmentSumTuningExtents(instance: SegmentSum) [2]u64 {
    return .{ instance.segments, instance.total };
}

pub fn segmentSumTuningOperation(instance: SegmentSum) entry.Operation {
    _ = instance;
    return .{ .segmented = .segment_sum };
}

pub fn segmentSumFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: SegmentSum,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try segmentSumFamilyFingerprint(backing_allocator, instance);
    const extents = segmentSumTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(segmentSumTuningOperation(instance)),
        instance.dtype,
        segment_sum_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn segmentSumRuntimeArguments(instance: SegmentSum) ![2]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.segments) },
        .{ .u32 = try runtimeExtentArgument(instance.total) },
    };
}

pub fn segmentSumShapeProfileDimensions(instance: SegmentSum) [2]artifact_product.KernelCallShapeProfileDimension {
    const bounds = segmentSumRuntimeExtentBounds();
    return .{
        .{ .name = instance.segment_axis, .runtime_scalar_argument_index = 0, .bounds = bounds },
        .{ .name = instance.element_axis, .runtime_scalar_argument_index = 1, .bounds = bounds },
    };
}

fn segmentSumRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

fn segmentSumDerivedLaunch(instance: SegmentSum) !artifact_product.KernelCallLaunch {
    if (instance.threads == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    if (!segmentSumGranularityValid(instance.granularity, instance.threads)) return error.UnsupportedGranularity;
    const divisor = switch (instance.granularity) {
        .thread => instance.threads,
        .warp => instance.threads / segment_sum_warp_size,
    };
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = divisor } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn createSegmentSumFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: SegmentSum,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try segmentSumFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try segmentSumFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try segmentSumFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = segmentSumShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "segment_sum",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try SegmentSumRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .f16 => try SegmentSumRuntimeFamilyF16.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = segment_sum_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try segmentSumDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 2 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn segmentSumFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: SegmentSum) !u64 {
    var family = try segmentSumShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn segmentSumShapeFamily(backing_allocator: std.mem.Allocator, instance: SegmentSum) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "segment_sum");
    errdefer builder.deinit();

    const segments = try builder.symbol(instance.segment_axis);
    const elements = try builder.symbol(instance.element_axis);

    const segments_expr = try builder.symbolExpression(segments);
    const elements_expr = try builder.symbolExpression(elements);
    const one_expr = builder.constantExpression(1);
    const offsets_expr = try builder.addExpression(segments_expr, one_expr);

    _ = try builder.tensor("data", &.{elements_expr});
    _ = try builder.tensor("offsets", &.{offsets_expr});
    _ = try builder.tensor("out", &.{segments_expr});
    try builder.assumeBounds(segments_expr, segmentSumRuntimeExtentBounds());
    try builder.assumeBounds(elements_expr, segmentSumRuntimeExtentBounds());

    return builder.finish();
}

pub fn segmentSumFamilySpecialization(backing_allocator: std.mem.Allocator, instance: SegmentSum) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.element_axis, instance.total);
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, instance.segment_axis, instance.segments + 1);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.segment_axis, instance.segments);

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .segmented = .segment_sum },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(lifetime_allocator, instance.segment_axis, instance.launchExtent(), instance.threads),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try segmentSumShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

fn ceilDivExtent(extent: u64, divisor: u32) u64 {
    return (extent + divisor - 1) / divisor;
}

fn launchMatches1D(launch: entry.Launch, extent: u64, threadgroup: u32) bool {
    if (threadgroup == 0) return false;
    if (@as(u64, threadgroup) > extent) return false;
    const expected_grid = ceilDivExtent(extent, threadgroup);
    return @as(u64, launch.grid[0]) == expected_grid and
        launch.grid[1] == 1 and launch.grid[2] == 1 and
        launch.threadgroup[1] == 1 and launch.threadgroup[2] == 1;
}

pub fn segmentSumGranularityFromLaunch(launch: entry.Launch, segments: u64) ?SegmentSumGranularity {
    const threadgroup = launch.threadgroup[0];
    if (launchMatches1D(launch, segments, threadgroup)) return .thread;
    if (threadgroup % segment_sum_warp_size == 0 and
        launchMatches1D(launch, segments * segment_sum_warp_size, threadgroup))
    {
        return .warp;
    }
    return null;
}

pub fn segmentSumInstanceFromSpecialization(specialization: entry.Specialization) ?SegmentSum {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .segmented = .segment_sum })) return null;
    const dtype = specialization.dtype orelse return null;
    if (!segmentSumDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const data = specialization.inputs[0];
    const offsets = specialization.inputs[1];
    const output = specialization.outputs[0];
    if (data.axes.len != 1 or offsets.axes.len != 1 or output.axes.len != 1) return null;
    const total = data.axes[0].extent;
    const segments = output.axes[0].extent;
    if (offsets.axes[0].extent != segments + 1) return null;
    if (!std.mem.eql(u8, offsets.axes[0].name, output.axes[0].name)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const granularity = segmentSumGranularityFromLaunch(launch, segments) orelse return null;
    return .{
        .segments = segments,
        .total = total,
        .dtype = dtype,
        .granularity = granularity,
        .threads = launch.threadgroup[0],
        .segment_axis = output.axes[0].name,
        .element_axis = data.axes[0].name,
    };
}

fn segmentSumSpecialization(comptime spec: SegmentSum) entry.Specialization {
    return .{
        .dtype = spec.dtype,
        .operation = .{ .segmented = .segment_sum },
        .inputs = &.{
            entry.shape1D(spec.element_axis, spec.total),
            entry.shape1D(spec.segment_axis, spec.segments + 1),
        },
        .outputs = &.{entry.shape1D(spec.segment_axis, spec.segments)},
        .launch = entry.launch1D(ceilDivComptime(spec.segments, spec.threads), spec.threads),
        .schedule = entry.threadBlocks1D(spec.segment_axis, spec.segments, spec.threads),
    };
}

fn ceilDivComptime(comptime numerator: u64, comptime denominator: u32) u32 {
    return @intCast(numerator / denominator + @as(u64, @intFromBool(numerator % denominator != 0)));
}

fn segmentSumProgram(comptime spec: SegmentSum) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            try segmentSumBody(k, spec, args);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_segmented_segment_sum{}x{}_{s}_{}_{s}",
            .{ spec.segments, spec.total, spec.granularity.name(), spec.threads, spec.dtype.name() },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(spec.dtype),
            .data = kernel.dynamicBuffer(spec.dtype),
            .offsets = kernel.dynamicBuffer(.i32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

pub fn segmentSumF32(comptime spec: SegmentSum) type {
    return entry.Entry(segmentSumProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.segmented.segment_sum{}x{}_{s}_{}_{s}",
            .{ spec.segments, spec.total, spec.granularity.name(), spec.threads, spec.dtype.name() },
        ),
        .layer = .logical,
        .category = .segmented,
        .specialization = segmentSumSpecialization(spec),
    });
}

pub const SegmentSum4F32 = segmentSumF32(.{ .segments = 4, .total = 16, .threads = 4 });

test "segmented segment sum entry runs on CPU with ragged segments" {
    var data: [16]f32 = undefined;
    for (&data, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    var offsets = [_]i32{ 0, 3, 3, 10, 16 };
    var dst = @as([4]f32, @splat(0));

    try SegmentSum4F32.runCpu(std.testing.allocator, SegmentSum4F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, data[0..]),
        kernel.argumentBuffer(i32, offsets[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 6, 0, 49, 81 }, dst[0..]);
}

test "segmented segment sum clamps out-of-range offsets" {
    var data = [_]f32{ 1, 2, 4, 8 };
    var offsets = [_]i32{ -2, 2, 9, 4 };
    var dst = @as([3]f32, @splat(0));

    const Entry3 = segmentSumF32(.{ .segments = 3, .total = 4, .threads = 3 });
    try Entry3.runCpu(std.testing.allocator, Entry3.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, data[0..]),
        kernel.argumentBuffer(i32, offsets[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 3, 12, 0 }, dst[0..]);
}

test "segmented segment sum runtime family executes explicit runtime extents" {
    const allocator = std.testing.allocator;
    const compiled = SegmentSum{ .segments = 1, .total = 1, .threads = 4 };
    const runtime = SegmentSum{ .segments = 3, .total = 12, .threads = 4 };

    var graph = try SegmentSumRuntimeFamilyF32.build(allocator, SegmentSumRuntimeFamilyF32.Limits.testing, compiled);
    defer graph.deinit();

    var data: [12]f32 = undefined;
    for (&data, 0..) |*value, index| value.* = @floatFromInt(index);
    var offsets = [_]i32{ 0, 5, 5, 12 };
    var dst = @as([3]f32, @splat(0));

    var expected = [_]f32{ 0, 0, 0 };
    for (0..3) |segment| {
        const begin: usize = @intCast(offsets[segment]);
        const end: usize = @intCast(offsets[segment + 1]);
        for (begin..end) |element| expected[segment] += data[element];
    }

    const launch_value = try entry.runtimeLaunch1D(runtime.segments, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, data[0..]),
        kernel.argumentBuffer(i32, offsets[0..]),
        kernel.argumentI32(@intCast(runtime.segments)),
        kernel.argumentI32(@intCast(runtime.total)),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);
}

test "segmented segment sum warp runtime family matches the thread oracle" {
    const allocator = std.testing.allocator;
    const compiled = SegmentSum{ .segments = 1, .total = 1, .granularity = .warp, .threads = 32 };
    const runtime = SegmentSum{ .segments = 3, .total = 80, .granularity = .warp, .threads = 32 };

    var graph = try SegmentSumRuntimeFamilyF32.build(allocator, SegmentSumRuntimeFamilyF32.Limits.testing, compiled);
    defer graph.deinit();

    var data: [80]f32 = undefined;
    for (&data, 0..) |*value, index| value.* = @floatFromInt(index);
    var offsets = [_]i32{ 0, 50, 50, 80 };
    var dst = @as([3]f32, @splat(0));

    var expected = [_]f32{ 0, 0, 0 };
    for (0..3) |segment| {
        const begin: usize = @intCast(offsets[segment]);
        const end: usize = @intCast(offsets[segment + 1]);
        for (begin..end) |element| expected[segment] += data[element];
    }

    const launch_value = try entry.runtimeLaunch1D(runtime.launchExtent(), runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, data[0..]),
        kernel.argumentBuffer(i32, offsets[0..]),
        kernel.argumentI32(@intCast(runtime.segments)),
        kernel.argumentI32(@intCast(runtime.total)),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);
}

test "segmented segment sum warp identity carries the granularity" {
    const instance = SegmentSum{ .segments = 1024, .total = 1_000_000, .granularity = .warp, .threads = 128 };

    const family_target = try segmentSumFamilyTarget(std.testing.allocator, instance);
    defer std.testing.allocator.free(family_target);
    try std.testing.expectEqualStrings("accy.kernel.segmented.segment_sum_family_warp_128_f32", family_target);

    const family_entry = try segmentSumFamilyEntryName(std.testing.allocator, instance);
    defer std.testing.allocator.free(family_entry);
    try std.testing.expectEqualStrings("accy_kernel_segmented_segment_sum_family_warp_128_f32", family_entry);
}

test "segmented segment sum warp derived launch divides segments by warps per block" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = SegmentSum{ .segments = 1000, .total = 65536, .granularity = .warp, .threads = 128 };

    var family_artifact = try createSegmentSumFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();

    const family_entry = family_artifact.entry();
    try std.testing.expectEqualStrings("accy.kernel.segmented.segment_sum_family_warp_128_f32", family_entry.target);
    switch (family_entry.launch) {
        .derived => |launch| {
            try std.testing.expectEqual(@as(u32, 128), launch.threadgroup[0]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |term| {
                    try std.testing.expectEqual(@as(usize, 0), term.argument_index);
                    try std.testing.expectEqual(@as(u32, 4), term.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
        },
        else => return error.TestExpectedDerivedLaunch,
    }
}

test "segmented segment sum warp instance round-trips through specialization" {
    const instance = SegmentSum{ .segments = 100, .total = 4096, .granularity = .warp, .threads = 64 };
    var owned = try segmentSumFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();

    const recovered = segmentSumInstanceFromSpecialization(owned.value) orelse return error.TestExpectedSegmentSumInstance;
    try std.testing.expectEqual(SegmentSumGranularity.warp, recovered.granularity);
    try std.testing.expectEqual(instance.segments, recovered.segments);
    try std.testing.expectEqual(instance.total, recovered.total);
    try std.testing.expectEqual(instance.threads, recovered.threads);
}

test "segmented segment sum granularity recovery separates single-segment launches" {
    const thread_instance = SegmentSum{ .segments = 1, .total = 8, .threads = 1 };
    var thread_owned = try segmentSumFamilySpecialization(std.testing.allocator, thread_instance);
    defer thread_owned.deinit();
    const thread_recovered = segmentSumInstanceFromSpecialization(thread_owned.value) orelse return error.TestExpectedSegmentSumInstance;
    try std.testing.expectEqual(SegmentSumGranularity.thread, thread_recovered.granularity);

    const warp_instance = SegmentSum{ .segments = 1, .total = 8, .granularity = .warp, .threads = 32 };
    var warp_owned = try segmentSumFamilySpecialization(std.testing.allocator, warp_instance);
    defer warp_owned.deinit();
    const warp_recovered = segmentSumInstanceFromSpecialization(warp_owned.value) orelse return error.TestExpectedSegmentSumInstance;
    try std.testing.expectEqual(SegmentSumGranularity.warp, warp_recovered.granularity);
}

test "segmented segment sum family instance identity matches fixed entry strings" {
    const instance = SegmentSum{ .segments = 4, .total = 16, .threads = 4 };

    const target = try segmentSumInstanceTarget(std.testing.allocator, instance);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings(SegmentSum4F32.target, target);

    const entry_name = try segmentSumInstanceEntryName(std.testing.allocator, instance);
    defer std.testing.allocator.free(entry_name);
    try std.testing.expectEqualStrings(SegmentSum4F32.name, entry_name);

    try std.testing.expectEqual(SegmentSum4F32.version, segment_sum_family_version);

    const fresh = SegmentSum{ .segments = 1024, .total = 1_000_000, .threads = 128 };
    const family_target = try segmentSumFamilyTarget(std.testing.allocator, fresh);
    defer std.testing.allocator.free(family_target);
    try std.testing.expectEqualStrings("accy.kernel.segmented.segment_sum_family_thread_128_f32", family_target);

    const family_entry = try segmentSumFamilyEntryName(std.testing.allocator, fresh);
    defer std.testing.allocator.free(family_entry);
    try std.testing.expectEqualStrings("accy_kernel_segmented_segment_sum_family_thread_128_f32", family_entry);
}

test "segmented segment sum family tuning keys group candidate granularity" {
    const allocator = std.testing.allocator;
    const device = tuning.deviceFingerprint(.{ .identity = .{
        .backend = .cuda,
        .family = .nvidia_cuda,
        .name = "segmented-family-tuning-test-device",
        .vendor_id = 0x10de,
        .device_id = 0x2684,
    } });

    const thread = SegmentSum{ .segments = 64, .total = 4096, .granularity = .thread, .threads = 128 };
    const warp = SegmentSum{ .segments = 64, .total = 4096, .granularity = .warp, .threads = 128 };
    const thread_key = try segmentSumFamilyTuningKey(allocator, device, thread);
    const warp_key = try segmentSumFamilyTuningKey(allocator, device, warp);
    try std.testing.expect(thread_key.eql(warp_key));

    const other_extent = try segmentSumFamilyTuningKey(allocator, device, .{ .segments = 32, .total = 4096 });
    try std.testing.expect(!thread_key.eql(other_extent));

    const other_device = try segmentSumFamilyTuningKey(
        allocator,
        tuning.deviceFingerprint(.{ .identity = .{
            .backend = .cuda,
            .family = .nvidia_cuda,
            .name = "other-segmented-family-tuning-test-device",
            .vendor_id = 0x10de,
            .device_id = 0x1b80,
        } }),
        thread,
    );
    try std.testing.expect(!thread_key.eql(other_device));
    try std.testing.expectEqual(thread_key.family_fingerprint, other_device.family_fingerprint);
    try std.testing.expectEqual(thread_key.operation_fingerprint, other_device.operation_fingerprint);
}

test "segmented segment sum family artifact carries runtime launch contract" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = SegmentSum{ .segments = 4, .total = 16, .threads = 4 };

    var family_artifact = try createSegmentSumFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();

    const family_entry = family_artifact.entry();
    try std.testing.expectEqualStrings("accy.kernel.segmented.segment_sum_family_thread_4_f32", family_entry.target);
    try std.testing.expectEqualStrings("accy_kernel_segmented_segment_sum_family_thread_4_f32", family_entry.entry_name);
    try std.testing.expectEqual(@as(u32, 5), family_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 2), family_entry.runtime_scalar_argument_count);
    try std.testing.expect(family_entry.required_dtypes.contains(.f32));
    try std.testing.expect(family_entry.required_dtypes.contains(.i32));
    try std.testing.expect(family_entry.shape_family_fingerprint != null);
    const profile = family_entry.shape_profile orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("segment_sum", profile.name);
    try std.testing.expectEqual(@as(usize, 2), profile.dimensions.len);
    switch (family_entry.launch) {
        .derived => |launch| {
            try std.testing.expectEqual(@as(u32, 4), launch.threadgroup[0]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |term| {
                    try std.testing.expectEqual(@as(usize, 0), term.argument_index);
                    try std.testing.expectEqual(@as(u32, 4), term.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
        },
        else => return error.TestExpectedDerivedLaunch,
    }
}

test "segmented segment sum instance round-trips through specialization" {
    const instance = SegmentSum{ .segments = 100, .total = 4096, .threads = 32 };
    var owned = try segmentSumFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();

    const recovered = segmentSumInstanceFromSpecialization(owned.value) orelse return error.TestExpectedSegmentSumInstance;
    try std.testing.expectEqual(instance.segments, recovered.segments);
    try std.testing.expectEqual(instance.total, recovered.total);
    try std.testing.expectEqual(instance.dtype, recovered.dtype);
    try std.testing.expectEqual(instance.threads, recovered.threads);

    try std.testing.expectEqual(@as(?SegmentSum, null), segmentSumInstanceFromSpecialization(.{}));
}

test "segmented segment sum thread candidates stay bounded and lead with the default" {
    const candidates = segmentSumThreadCandidatesForSegments(50_000);
    try std.testing.expect(candidates.count > 2);
    try std.testing.expectEqual(segmentSumThreadsForSegments(50_000), candidates.items[0]);
    for (candidates.slice(), 0..) |candidate, index| {
        try std.testing.expect(candidate != 0);
        for (candidates.slice()[0..index]) |previous| try std.testing.expect(previous != candidate);
    }
}
