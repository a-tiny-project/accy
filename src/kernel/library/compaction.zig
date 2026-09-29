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

pub const Filter = struct {
    extent: u64,
    dtype: DType = .f32,
    predicate: entry.CompactionPredicate = .nonzero,
    threads: u32 = 256,
    element_axis: []const u8 = "n",
    segment_axis: []const u8 = "b",

    pub fn segments(self: Filter) u64 {
        return ceilDiv(self.extent, self.threads);
    }

    pub fn padded(self: Filter) u64 {
        return self.extent + self.segments();
    }
};

pub fn filterPredicateName(predicate: entry.CompactionPredicate) []const u8 {
    return switch (predicate) {
        .nonzero => "nonzero",
        .greater_than => "greater",
    };
}

pub const filter_family_version: u32 = 1;
pub const filter_warp_size: u32 = 32;
pub const filter_max_threads: u32 = 1024;

pub fn filterDTypeSupported(dtype: DType) bool {
    return switch (dtype) {
        .f32, .i32 => true,
        else => false,
    };
}

pub fn filterInstanceValid(instance: Filter) bool {
    if (!filterDTypeSupported(instance.dtype)) return false;
    if (instance.extent == 0) return false;
    if (instance.threads == 0 or instance.threads > filter_max_threads) return false;
    return instance.threads % filter_warp_size == 0;
}

fn ceilDiv(numerator: u64, denominator: u64) u64 {
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

pub fn filterBlocksExpectedF32(data: []const f32, threads: u32, dst: []f32) void {
    const segment_count = ceilDiv(data.len, threads);
    for (0..segment_count) |segment| {
        const begin = segment * threads;
        const end = @min(begin + threads, data.len);
        var survivors: usize = 0;
        for (data[begin..end]) |value| {
            if (value != 0.0) {
                dst[begin + survivors] = value;
                survivors += 1;
            }
        }
        dst[data.len + segment] = @floatFromInt(survivors);
    }
}

pub fn filterBlocksExpectedI32(data: []const i32, threads: u32, dst: []i32) void {
    const segment_count = ceilDiv(data.len, threads);
    for (0..segment_count) |segment| {
        const begin = segment * threads;
        const end = @min(begin + threads, data.len);
        var survivors: usize = 0;
        for (data[begin..end]) |value| {
            if (value != 0) {
                dst[begin + survivors] = value;
                survivors += 1;
            }
        }
        dst[data.len + segment] = @intCast(survivors);
    }
}

pub fn filterBlocksGreaterExpectedF32(data: []const f32, threads: u32, threshold: f32, dst: []f32) void {
    const segment_count = ceilDiv(data.len, threads);
    for (0..segment_count) |segment| {
        const begin = segment * threads;
        const end = @min(begin + threads, data.len);
        var survivors: usize = 0;
        for (data[begin..end]) |value| {
            if (value > threshold) {
                dst[begin + survivors] = value;
                survivors += 1;
            }
        }
        dst[data.len + segment] = @floatFromInt(survivors);
    }
}

pub fn filterBlocksGreaterExpectedI32(data: []const i32, threads: u32, threshold: i32, dst: []i32) void {
    const segment_count = ceilDiv(data.len, threads);
    for (0..segment_count) |segment| {
        const begin = segment * threads;
        const end = @min(begin + threads, data.len);
        var survivors: usize = 0;
        for (data[begin..end]) |value| {
            if (value > threshold) {
                dst[begin + survivors] = value;
                survivors += 1;
            }
        }
        dst[data.len + segment] = @intCast(survivors);
    }
}

fn predicateFlag(
    k: anytype,
    comptime dtype: DType,
    comptime predicate: entry.CompactionPredicate,
    args: anytype,
    element: kernel.Value,
) !kernel.Value {
    const survives = switch (predicate) {
        .nonzero => switch (dtype) {
            .f32 => try k.compare(.ne, element, try k.constantFloat(.f32, 0.0)),
            .i32 => try k.compare(.ne, element, try k.constantInt(.i32, 0)),
            else => @compileError("filter kernels support dtype .f32 or .i32"),
        },
        .greater_than => try k.compare(.gt, element, args.param(.threshold).raw()),
    };
    const one = try k.constantInt(.i32, 1);
    const zero = try k.constantInt(.i32, 0);
    return k.select(survives, one, zero);
}

fn zeroElement(k: anytype, comptime dtype: DType) !kernel.Value {
    return switch (dtype) {
        .f32 => k.constantFloat(.f32, 0.0),
        .i32 => k.constantInt(.i32, 0),
        else => @compileError("filter kernels support dtype .f32 or .i32"),
    };
}

fn filter_scan_core_seeds_zero(inner: anytype, ctx: anytype) !void {
    try inner.storeIndex(ctx.zero_flag, ctx.warp_sums, ctx.local);
}

fn filter_scan_core_is_last_lane(inner: anytype, ctx: anytype) !void {
    try inner.storeIndex(ctx.scanned, ctx.warp_sums, ctx.warp);
}

fn filter_scan_core_is_first_warp(inner: anytype, ctx: anytype) !void {
    const warp_sum = try inner.loadIndex(ctx.warp_sums, ctx.lane);
    const warp_scan = try inner.warpScan(.add, .inclusive, warp_sum);
    try inner.storeIndex(warp_scan, ctx.warp_sums, ctx.lane);
}

fn filter_scan_core_survives(inner: anytype, ctx: anytype) !void {
    try ctx.args.param(.dst).store(inner, ctx.element, ctx.destination);
}

fn filter_scan_core_is_last_thread(inner: anytype, ctx: anytype) !void {
    try ctx.args.param(.dst).store(inner, ctx.count_value, ctx.count_slot);
}

fn filterScanCore(
    k: anytype,
    comptime dtype: DType,
    comptime predicate: entry.CompactionPredicate,
    args: anytype,
    extent: kernel.Value,
) !void {
    const tid = try k.globalId(.x);
    const local = try k.threadId(.x);
    const block = try k.blockId(.x);
    const block_threads = try k.blockDim(.x);
    const lane = try k.laneId();
    const warp = try k.warpId();
    const zero = try k.constantIndex(0);
    const one = try k.constantIndex(1);

    const in_range = try k.compare(.lt, tid, extent);
    const extent_minus_one = try k.sub(extent, one);
    const clamped_tid = try k.min(tid, extent_minus_one);
    const loaded = try args.param(.data).load(k, clamped_tid);
    const element = try k.select(in_range, loaded.raw(), try zeroElement(k, dtype));

    const live = try predicateFlag(k, dtype, predicate, args, element);
    const flag = try k.select(in_range, live, try k.constantInt(.i32, 0));

    const scanned = try k.warpScan(.add, .inclusive, flag);

    const warp_sums = try k.sharedBuffer(.i32, filter_warp_size);
    const lane_limit = try k.constantIndex(filter_warp_size - 1);
    const warp_count_value = try k.constantIndex(filter_warp_size);

    const seeds_zero = try k.compare(.lt, local, warp_count_value);
    try k.guardDo(seeds_zero, .{ .warp_sums = warp_sums, .local = local, .zero_flag = try k.constantInt(.i32, 0) }, filter_scan_core_seeds_zero);
    try k.barrier(.block);

    const is_last_lane = try k.compare(.eq, lane, lane_limit);
    try k.guardDo(is_last_lane, .{ .warp_sums = warp_sums, .warp = warp, .scanned = scanned }, filter_scan_core_is_last_lane);
    try k.barrier(.block);

    const is_first_warp = try k.compare(.eq, warp, zero);
    try k.guardDo(is_first_warp, .{ .warp_sums = warp_sums, .lane = lane }, filter_scan_core_is_first_warp);
    try k.barrier(.block);

    const has_base = try k.compare(.gt, warp, zero);
    const warp_minus_one = try k.sub(warp, one);
    const base_index = try k.select(has_base, warp_minus_one, zero);
    const base_loaded = try k.loadIndex(warp_sums, base_index);
    const base = try k.select(has_base, base_loaded, try k.constantInt(.i32, 0));
    const inclusive = try k.add(scanned, base);

    const segment_base = try k.mul(block, block_threads);
    const survives = try k.compare(.gt, flag, try k.constantInt(.i32, 0));
    const offset = try k.castIndex(try k.sub(inclusive, try k.constantInt(.i32, 1)));
    const destination = try k.add(segment_base, offset);
    try k.guardDo(survives, .{ .args = args, .element = element, .destination = destination }, filter_scan_core_survives);

    const block_threads_minus_one = try k.sub(block_threads, one);
    const is_last_thread = try k.compare(.eq, local, block_threads_minus_one);
    const count_value = switch (dtype) {
        .f32 => try k.cast(inclusive, .f32),
        .i32 => inclusive,
        else => @compileError("filter kernels support dtype .f32 or .i32"),
    };
    const count_slot = try k.add(extent, block);
    try k.guardDo(is_last_thread, .{ .args = args, .count_value = count_value, .count_slot = count_slot }, filter_scan_core_is_last_thread);
}

fn filterBody(
    k: anytype,
    comptime dtype: DType,
    comptime predicate: entry.CompactionPredicate,
    spec: Filter,
    args: anytype,
) !void {
    if (!filterInstanceValid(spec)) return error.UnsupportedFilterInstance;
    const extent = try k.constantIndex(try indexExtent(spec.extent));
    try filterScanCore(k, dtype, predicate, args, extent);
}

fn filterRuntimeBody(
    k: anytype,
    comptime dtype: DType,
    comptime predicate: entry.CompactionPredicate,
    spec: Filter,
    args: anytype,
) !void {
    if (!filterInstanceValid(spec)) return error.UnsupportedFilterInstance;
    const extent = try k.castIndex(args.param(.extent).raw());
    try filterScanCore(k, dtype, predicate, args, extent);
}

fn filterFamilySchedule(instance: Filter) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn filter_runtime_family_body_f32(k: anytype, spec: Filter, args: anytype) !void {
    try filterRuntimeBody(k, .f32, .nonzero, spec, args);
}

fn filter_runtime_family_body_i32(k: anytype, spec: Filter, args: anytype) !void {
    try filterRuntimeBody(k, .i32, .nonzero, spec, args);
}

fn filterRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_compaction_filter_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .data = kernel.dynamicBuffer(dtype),
            .extent = kernel.scalar(.i32),
        },
        .Instance = Filter,
        .schedule = filterFamilySchedule,
        .body = switch (dtype) {
            .f32 => filter_runtime_family_body_f32,
            .i32 => filter_runtime_family_body_i32,
            else => @compileError("runtime filter supports dtype .f32 or .i32"),
        },
    });
}

fn filter_greater_runtime_family_body_f32(k: anytype, spec: Filter, args: anytype) !void {
    try filterRuntimeBody(k, .f32, .greater_than, spec, args);
}

fn filter_greater_runtime_family_body_i32(k: anytype, spec: Filter, args: anytype) !void {
    try filterRuntimeBody(k, .i32, .greater_than, spec, args);
}

fn filterGreaterRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_compaction_filter_greater_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .data = kernel.dynamicBuffer(dtype),
            .extent = kernel.scalar(.i32),
            .threshold = kernel.scalar(dtype),
        },
        .Instance = Filter,
        .schedule = filterFamilySchedule,
        .body = switch (dtype) {
            .f32 => filter_greater_runtime_family_body_f32,
            .i32 => filter_greater_runtime_family_body_i32,
            else => @compileError("runtime greater-than filter supports dtype .f32 or .i32"),
        },
    });
}

pub const FilterRuntimeFamilyF32 = filterRuntimeFamily(.f32);
pub const FilterRuntimeFamilyI32 = filterRuntimeFamily(.i32);
pub const FilterGreaterRuntimeFamilyF32 = filterGreaterRuntimeFamily(.f32);
pub const FilterGreaterRuntimeFamilyI32 = filterGreaterRuntimeFamily(.i32);

pub fn filterThreadsForExtent(extent: u64) u32 {
    if (extent >= 256) return 256;
    const wide: u64 = extent + filter_warp_size - 1;
    const rounded: u32 = @intCast((wide / filter_warp_size) * filter_warp_size);
    return @max(rounded, filter_warp_size);
}

pub const FilterThreadCandidates = struct {
    count: usize = 0,
    items: [6]u32 = @as([6]u32, @splat(0)),

    pub fn slice(self: *const FilterThreadCandidates) []const u32 {
        return self.items[0..self.count];
    }
};

pub fn filterThreadCandidatesForExtent(extent: u64) FilterThreadCandidates {
    var result = FilterThreadCandidates{};
    if (extent == 0) return result;
    const base = filterThreadsForExtent(extent);
    result.items[result.count] = base;
    result.count += 1;
    var threads: u32 = filter_warp_size;
    while (threads <= filter_max_threads) : (threads *= 2) {
        if (threads == base) continue;
        if (result.count >= result.items.len) break;
        result.items[result.count] = threads;
        result.count += 1;
    }
    return result;
}

pub fn filterInstanceTarget(allocator: std.mem.Allocator, instance: Filter) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.compaction.filter{d}_{d}_{s}",
        .{ instance.extent, instance.threads, instance.dtype.name() },
    );
}

pub fn filterInstanceEntryName(allocator: std.mem.Allocator, instance: Filter) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_compaction_filter{d}_{d}_{s}",
        .{ instance.extent, instance.threads, instance.dtype.name() },
    );
}

pub fn filterFamilyTarget(allocator: std.mem.Allocator, instance: Filter) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.compaction.filter_family_{s}_{d}_{s}",
        .{ filterPredicateName(instance.predicate), instance.threads, instance.dtype.name() },
    );
}

pub fn filterFamilyEntryName(allocator: std.mem.Allocator, instance: Filter) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_compaction_filter_family_{s}_{d}_{s}",
        .{ filterPredicateName(instance.predicate), instance.threads, instance.dtype.name() },
    );
}

pub fn filterTuningExtents(instance: Filter) [1]u64 {
    return .{instance.extent};
}

pub fn filterTuningOperation(instance: Filter) entry.Operation {
    return .{ .compaction = .{ .blocks = instance.predicate } };
}

pub fn filterFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: Filter,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try filterFamilyFingerprint(backing_allocator, instance);
    const extents = filterTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(filterTuningOperation(instance)),
        instance.dtype,
        filter_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn filterRuntimeArguments(instance: Filter) ![1]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.extent) },
    };
}

pub fn filterGreaterRuntimeArguments(
    instance: Filter,
    threshold: gpu_abi.ScalarArgument,
) ![2]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.extent) },
        threshold,
    };
}

pub fn filterRuntimeScalarArgumentCount(instance: Filter) u32 {
    return switch (instance.predicate) {
        .nonzero => 1,
        .greater_than => 2,
    };
}

fn filterRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

pub fn filterShapeProfileDimensions(instance: Filter) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{ .name = instance.element_axis, .runtime_scalar_argument_index = 0, .bounds = filterRuntimeExtentBounds() },
    };
}

fn filterDerivedLaunch(instance: Filter) !artifact_product.KernelCallLaunch {
    if (instance.threads == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = instance.threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn createFilterFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: Filter,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try filterFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try filterFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try filterFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = filterShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "filter",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.predicate) {
        .nonzero => switch (instance.dtype) {
            .f32 => try FilterRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
            .i32 => try FilterRuntimeFamilyI32.buildNamed(allocator, options.limits, entry_name, instance),
            else => return error.UnsupportedDType,
        },
        .greater_than => switch (instance.dtype) {
            .f32 => try FilterGreaterRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
            .i32 => try FilterGreaterRuntimeFamilyI32.buildNamed(allocator, options.limits, entry_name, instance),
            else => return error.UnsupportedDType,
        },
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = filter_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try filterDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            filterRuntimeScalarArgumentCount(instance)
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn filterFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: Filter) !u64 {
    var family = try filterShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn filterShapeFamily(backing_allocator: std.mem.Allocator, instance: Filter) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "filter");
    errdefer builder.deinit();

    const element = try builder.symbol(instance.element_axis);
    const segment = try builder.symbol(instance.segment_axis);
    const element_expr = try builder.symbolExpression(element);
    const segment_expr = try builder.symbolExpression(segment);

    const padded_expr = try builder.addExpression(element_expr, segment_expr);
    _ = try builder.tensor("data", &.{element_expr});
    _ = try builder.tensor("out", &.{padded_expr});
    try builder.assumeBounds(element_expr, filterRuntimeExtentBounds());
    try builder.assumeBounds(segment_expr, filterRuntimeExtentBounds());

    return builder.finish();
}

pub fn filterFamilySpecialization(backing_allocator: std.mem.Allocator, instance: Filter) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 1);
    inputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.element_axis, instance.extent);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.segment_axis, instance.padded());

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .compaction = .{ .blocks = instance.predicate } },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(lifetime_allocator, "e", instance.extent, instance.threads),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try filterShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn filterInstanceFromSpecialization(specialization: entry.Specialization) ?Filter {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const operation = specialization.operation orelse return null;
    const predicate = switch (operation) {
        .compaction => |compaction_operation| switch (compaction_operation) {
            .blocks => |predicate| predicate,
        },
        else => return null,
    };
    const dtype = specialization.dtype orelse return null;
    if (!filterDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const data = specialization.inputs[0];
    const packed_output = specialization.outputs[0];
    if (data.axes.len != 1 or packed_output.axes.len != 1) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const instance = Filter{
        .extent = data.axes[0].extent,
        .dtype = dtype,
        .predicate = predicate,
        .threads = launch.threadgroup[0],
        .element_axis = data.axes[0].name,
        .segment_axis = packed_output.axes[0].name,
    };
    if (!filterInstanceValid(instance)) return null;
    if (packed_output.axes[0].extent != instance.padded()) return null;
    return instance;
}

fn ceilDivComptime(comptime numerator: u64, comptime denominator: u32) u32 {
    return @intCast(numerator / denominator + @as(u64, @intFromBool(numerator % denominator != 0)));
}

fn filterSpecialization(comptime spec: Filter) entry.Specialization {
    return .{
        .dtype = spec.dtype,
        .operation = .{ .compaction = .{ .blocks = spec.predicate } },
        .inputs = &.{entry.shape1D(spec.element_axis, spec.extent)},
        .outputs = &.{entry.shape1D(spec.segment_axis, spec.padded())},
        .launch = entry.launch1D(ceilDivComptime(spec.extent, spec.threads), spec.threads),
        .schedule = entry.threadBlocks1D("e", spec.extent, spec.threads),
    };
}

fn filterProgram(comptime spec: Filter) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            try filterBody(k, spec.dtype, spec.predicate, spec, args);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_compaction_filter{}_{}_{s}",
            .{ spec.extent, spec.threads, spec.dtype.name() },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(spec.dtype),
            .data = kernel.dynamicBuffer(spec.dtype),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

pub fn filterEntry(comptime spec: Filter) type {
    return entry.Entry(filterProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.compaction.filter{}_{}_{s}",
            .{ spec.extent, spec.threads, spec.dtype.name() },
        ),
        .layer = .logical,
        .category = .compaction,
        .specialization = filterSpecialization(spec),
    });
}

pub const Filter8F32 = filterEntry(.{ .extent = 8, .threads = 32 });

test "compaction filter entry compacts one block on CPU" {
    const allocator = std.testing.allocator;
    var data = [_]f32{ 0.0, 3.5, 0.0, -1.25, 2.0, 0.0, 0.0, 7.0 };
    var dst = @as([9]f32, @splat(-99.0));

    const ProgramType = filterProgram(.{ .extent = 8, .threads = 32 });
    var graph = try ProgramType.build(allocator, ProgramType.Limits.testing);
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, data[0..]),
    }, .{
        .grid = .{ 1, 1, 1 },
        .block = .{ 32, 1, 1 },
    });

    try std.testing.expectEqual(@as(f32, 4.0), dst[8]);
    try std.testing.expectEqualSlices(f32, &.{ 3.5, -1.25, 2.0, 7.0 }, dst[0..4]);
    for (dst[4..8]) |value| try std.testing.expectEqual(@as(f32, -99.0), value);
}

test "compaction filter runtime family compacts segments with tail" {
    const allocator = std.testing.allocator;
    const compiled = Filter{ .extent = 1, .threads = 32 };
    const runtime = Filter{ .extent = 70, .threads = 32 };

    var graph = try FilterRuntimeFamilyF32.build(allocator, FilterRuntimeFamilyF32.Limits.testing, compiled);
    defer graph.deinit();

    var data: [70]f32 = undefined;
    var seed: u32 = 0x2545f491;
    for (&data, 0..) |*value, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        value.* = if (seed % 3 == 0) 0.0 else @floatFromInt(index + 1);
    }

    var dst = @as([73]f32, @splat(-1.0));

    const launch_value = try entry.runtimeLaunch1D(runtime.extent, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, data[0..]),
        kernel.argumentI32(@intCast(runtime.extent)),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    var expected_dst = @as([73]f32, @splat(-1.0));
    filterBlocksExpectedF32(data[0..], runtime.threads, expected_dst[0..]);

    try std.testing.expectEqualSlices(f32, expected_dst[70..], dst[70..]);
    for (0..3) |segment| {
        const begin = segment * 32;
        const survivors: usize = @intFromFloat(expected_dst[70 + segment]);
        try std.testing.expectEqualSlices(f32, expected_dst[begin .. begin + survivors], dst[begin .. begin + survivors]);
    }
}

test "compaction filter runtime family compacts i32 data" {
    const allocator = std.testing.allocator;
    const compiled = Filter{ .extent = 1, .dtype = .i32, .threads = 32 };
    const runtime = Filter{ .extent = 40, .dtype = .i32, .threads = 32 };

    var graph = try FilterRuntimeFamilyI32.build(allocator, FilterRuntimeFamilyI32.Limits.testing, compiled);
    defer graph.deinit();

    var data: [40]i32 = undefined;
    for (&data, 0..) |*value, index| value.* = if (index % 2 == 0) 0 else @intCast(index);

    var dst = @as([42]i32, @splat(-1));

    const launch_value = try entry.runtimeLaunch1D(runtime.extent, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentBuffer(i32, data[0..]),
        kernel.argumentI32(@intCast(runtime.extent)),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    var expected_dst = @as([42]i32, @splat(-1));
    filterBlocksExpectedI32(data[0..], runtime.threads, expected_dst[0..]);

    try std.testing.expectEqualSlices(i32, expected_dst[40..], dst[40..]);
    for (0..2) |segment| {
        const begin = segment * 32;
        const survivors: usize = @intCast(expected_dst[40 + segment]);
        try std.testing.expectEqualSlices(i32, expected_dst[begin .. begin + survivors], dst[begin .. begin + survivors]);
    }
}

test "compaction filter greater runtime family keeps survivors above the threshold" {
    const allocator = std.testing.allocator;
    const compiled = Filter{ .extent = 1, .predicate = .greater_than, .threads = 32 };
    const runtime = Filter{ .extent = 70, .predicate = .greater_than, .threads = 32 };

    var graph = try FilterGreaterRuntimeFamilyF32.build(allocator, FilterGreaterRuntimeFamilyF32.Limits.testing, compiled);
    defer graph.deinit();

    var data: [70]f32 = undefined;
    var seed: u32 = 0x2545f491;
    for (&data, 0..) |*value, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const magnitude: f32 = @floatFromInt(index + 1);
        value.* = if (seed % 2 == 0) -magnitude else magnitude;
    }

    const threshold: f32 = 20.0;
    var dst = @as([73]f32, @splat(-999.0));

    const launch_value = try entry.runtimeLaunch1D(runtime.extent, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, data[0..]),
        kernel.argumentI32(@intCast(runtime.extent)),
        kernel.argumentF32(threshold),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    var expected_dst = @as([73]f32, @splat(-999.0));
    filterBlocksGreaterExpectedF32(data[0..], runtime.threads, threshold, expected_dst[0..]);

    try std.testing.expectEqualSlices(f32, expected_dst[70..], dst[70..]);
    for (0..3) |segment| {
        const begin = segment * 32;
        const survivors: usize = @intFromFloat(expected_dst[70 + segment]);
        for (dst[begin .. begin + survivors]) |value| try std.testing.expect(value > threshold);
        try std.testing.expectEqualSlices(f32, expected_dst[begin .. begin + survivors], dst[begin .. begin + survivors]);
    }
}

test "compaction filter greater runtime family filters i32 data" {
    const allocator = std.testing.allocator;
    const compiled = Filter{ .extent = 1, .dtype = .i32, .predicate = .greater_than, .threads = 32 };
    const runtime = Filter{ .extent = 40, .dtype = .i32, .predicate = .greater_than, .threads = 32 };

    var graph = try FilterGreaterRuntimeFamilyI32.build(allocator, FilterGreaterRuntimeFamilyI32.Limits.testing, compiled);
    defer graph.deinit();

    var data: [40]i32 = undefined;
    for (&data, 0..) |*value, index| {
        const magnitude: i32 = @intCast(index);
        value.* = if (index % 3 == 0) -magnitude else magnitude;
    }

    const threshold: i32 = 11;
    var dst = @as([42]i32, @splat(-999));

    const launch_value = try entry.runtimeLaunch1D(runtime.extent, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(i32, dst[0..]),
        kernel.argumentBuffer(i32, data[0..]),
        kernel.argumentI32(@intCast(runtime.extent)),
        kernel.argumentI32(threshold),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });

    var expected_dst = @as([42]i32, @splat(-999));
    filterBlocksGreaterExpectedI32(data[0..], runtime.threads, threshold, expected_dst[0..]);

    try std.testing.expectEqualSlices(i32, expected_dst[40..], dst[40..]);
    for (0..2) |segment| {
        const begin = segment * 32;
        const survivors: usize = @intCast(expected_dst[40 + segment]);
        try std.testing.expectEqualSlices(i32, expected_dst[begin .. begin + survivors], dst[begin .. begin + survivors]);
    }
}

test "compaction filter family instance identity matches fixed entry strings" {
    const instance = Filter{ .extent = 8, .threads = 32 };

    const target = try filterInstanceTarget(std.testing.allocator, instance);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings(Filter8F32.target, target);

    const entry_name = try filterInstanceEntryName(std.testing.allocator, instance);
    defer std.testing.allocator.free(entry_name);
    try std.testing.expectEqualStrings(Filter8F32.name, entry_name);

    try std.testing.expectEqual(Filter8F32.version, filter_family_version);

    const fresh = Filter{ .extent = 1 << 20, .threads = 128, .dtype = .i32 };
    const family_target = try filterFamilyTarget(std.testing.allocator, fresh);
    defer std.testing.allocator.free(family_target);
    try std.testing.expectEqualStrings("accy.kernel.compaction.filter_family_nonzero_128_i32", family_target);
}

test "compaction filter family tuning keys discriminate predicates" {
    const allocator = std.testing.allocator;
    const device = tuning.deviceFingerprint(.{ .identity = .{
        .backend = .cuda,
        .family = .nvidia_cuda,
        .name = "compaction-family-tuning-test-device",
        .vendor_id = 0x10de,
        .device_id = 0x2684,
    } });

    const nonzero = Filter{ .extent = 4096, .predicate = .nonzero };
    const greater = Filter{ .extent = 4096, .predicate = .greater_than };
    const nonzero_key = try filterFamilyTuningKey(allocator, device, nonzero);
    const greater_key = try filterFamilyTuningKey(allocator, device, greater);
    try std.testing.expect(!nonzero_key.eql(greater_key));
    try std.testing.expectEqual(nonzero_key.family_fingerprint, greater_key.family_fingerprint);
    try std.testing.expect(nonzero_key.operation_fingerprint != greater_key.operation_fingerprint);

    const other_dtype = try filterFamilyTuningKey(allocator, device, .{ .extent = 4096, .dtype = .i32 });
    try std.testing.expect(!nonzero_key.eql(other_dtype));

    const repeat_key = try filterFamilyTuningKey(allocator, device, nonzero);
    try std.testing.expect(nonzero_key.eql(repeat_key));
}

test "compaction filter family artifact carries runtime launch contract" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = Filter{ .extent = 4096, .threads = 128 };

    var family_artifact = try createFilterFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();

    const family_entry = family_artifact.entry();
    try std.testing.expectEqualStrings("accy.kernel.compaction.filter_family_nonzero_128_f32", family_entry.target);
    try std.testing.expectEqualStrings("accy_kernel_compaction_filter_family_nonzero_128_f32", family_entry.entry_name);
    try std.testing.expectEqual(@as(u32, 3), family_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 1), family_entry.runtime_scalar_argument_count);
    try std.testing.expect(family_entry.required_dtypes.contains(.f32));
    try std.testing.expect(family_entry.shape_family_fingerprint != null);
    const profile = family_entry.shape_profile orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("filter", profile.name);
    switch (family_entry.launch) {
        .derived => |launch| {
            try std.testing.expectEqual(@as(u32, 128), launch.threadgroup[0]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |term| {
                    try std.testing.expectEqual(@as(usize, 0), term.argument_index);
                    try std.testing.expectEqual(@as(u32, 128), term.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
        },
        else => return error.TestExpectedDerivedLaunch,
    }
}

test "compaction filter instance round-trips through specialization" {
    const instance = Filter{ .extent = 1000, .threads = 64, .dtype = .i32 };
    var owned = try filterFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();

    const recovered = filterInstanceFromSpecialization(owned.value) orelse return error.TestExpectedFilterInstance;
    try std.testing.expectEqual(instance.extent, recovered.extent);
    try std.testing.expectEqual(instance.dtype, recovered.dtype);
    try std.testing.expectEqual(instance.predicate, recovered.predicate);
    try std.testing.expectEqual(instance.threads, recovered.threads);
    try std.testing.expectEqual(@as(u64, 16), recovered.segments());

    try std.testing.expectEqual(@as(?Filter, null), filterInstanceFromSpecialization(.{}));
}

test "compaction filter greater instance keeps its predicate through identity and specialization" {
    const instance = Filter{ .extent = 4096, .predicate = .greater_than, .threads = 128 };

    const family_target = try filterFamilyTarget(std.testing.allocator, instance);
    defer std.testing.allocator.free(family_target);
    try std.testing.expectEqualStrings("accy.kernel.compaction.filter_family_greater_128_f32", family_target);

    const family_entry_name = try filterFamilyEntryName(std.testing.allocator, instance);
    defer std.testing.allocator.free(family_entry_name);
    try std.testing.expectEqualStrings("accy_kernel_compaction_filter_family_greater_128_f32", family_entry_name);

    try std.testing.expectEqual(@as(u32, 2), filterRuntimeScalarArgumentCount(instance));
    try std.testing.expectEqual(@as(u32, 1), filterRuntimeScalarArgumentCount(.{ .extent = 4096 }));

    var owned = try filterFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const recovered = filterInstanceFromSpecialization(owned.value) orelse return error.TestExpectedFilterInstance;
    try std.testing.expectEqual(entry.CompactionPredicate.greater_than, recovered.predicate);

    const arguments = try filterGreaterRuntimeArguments(instance, .{ .f32 = 0.5 });
    try std.testing.expectEqual(@as(u32, 4096), arguments[0].u32);
    try std.testing.expectEqual(@as(f32, 0.5), arguments[1].f32);
}

test "compaction filter greater family artifact requires two runtime scalars" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = Filter{ .extent = 4096, .predicate = .greater_than, .threads = 128 };

    var family_artifact = try createFilterFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();

    const family_entry = family_artifact.entry();
    try std.testing.expectEqualStrings("accy.kernel.compaction.filter_family_greater_128_f32", family_entry.target);
    try std.testing.expectEqual(@as(u32, 4), family_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 2), family_entry.runtime_scalar_argument_count);
}

test "compaction filter thread candidates stay bounded and lead with the default" {
    const candidates = filterThreadCandidatesForExtent(100_000);
    try std.testing.expect(candidates.count > 2);
    try std.testing.expectEqual(filterThreadsForExtent(100_000), candidates.items[0]);
    for (candidates.slice(), 0..) |candidate, index| {
        try std.testing.expect(candidate != 0);
        try std.testing.expect(candidate % filter_warp_size == 0);
        for (candidates.slice()[0..index]) |previous| try std.testing.expect(previous != candidate);
    }
}
