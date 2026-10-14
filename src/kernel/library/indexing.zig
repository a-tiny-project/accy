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

pub const Gather = struct {
    outer: u64 = 1,
    axis_size: u64,
    gathered: u64,
    inner: u64 = 1,
    dtype: DType = .f32,
    index_dtype: DType = .i32,
    threads: u32 = 256,
    outer_axis: []const u8 = "o",
    source_axis: []const u8 = "s",
    gathered_axis: []const u8 = "g",
    inner_axis: []const u8 = "i",

    pub fn total(self: Gather) u64 {
        return self.outer * self.gathered * self.inner;
    }
};

pub const gather_family_version: u32 = 1;
const gather_thread_caps = geometry_mod.ThreadCaps1D{};

pub fn gatherDTypeSupported(dtype: DType) bool {
    return switch (dtype) {
        .f32, .f16 => true,
        else => false,
    };
}

fn gatherSourceIndexValue(
    inner_builder: anytype,
    indices: anytype,
    element: kernel.Value,
    axis_size: kernel.Value,
    gathered: kernel.Value,
    inner_extent: kernel.Value,
) !kernel.Value {
    const gathered_inner = try inner_builder.mul(gathered, inner_extent);
    const outer_coord = try inner_builder.div(element, gathered_inner);
    const outer_consumed = try inner_builder.mul(outer_coord, gathered_inner);
    const rem = try inner_builder.sub(element, outer_consumed);
    const position = try inner_builder.div(rem, inner_extent);
    const position_consumed = try inner_builder.mul(position, inner_extent);
    const within = try inner_builder.sub(rem, position_consumed);

    const loaded = try indices.load(inner_builder, position);
    const zero_i32 = try inner_builder.constantInt(.i32, 0);
    const one_i32 = try inner_builder.constantInt(.i32, 1);
    const axis_size_i32 = try inner_builder.cast(axis_size, .i32);
    const limit_i32 = try inner_builder.sub(axis_size_i32, one_i32);
    const lower_clamped_i32 = try inner_builder.max(loaded.raw(), zero_i32);
    const clamped_i32 = try inner_builder.min(lower_clamped_i32, limit_i32);
    const clamped = try inner_builder.castIndex(clamped_i32);

    const axis_block = try inner_builder.mul(axis_size, inner_extent);
    const outer_offset = try inner_builder.mul(outer_coord, axis_block);
    const gathered_offset = try inner_builder.mul(clamped, inner_extent);
    const partial = try inner_builder.add(outer_offset, gathered_offset);
    return inner_builder.add(partial, within);
}

fn gather_body_each(inner_builder: anytype, index: kernel.Index1D, ctx: anytype) !void {
    const axis_size = try inner_builder.constantIndex(try indexExtent(ctx.spec.axis_size));
    const gathered = try inner_builder.constantIndex(try indexExtent(ctx.spec.gathered));
    const inner_extent = try inner_builder.constantIndex(try indexExtent(ctx.spec.inner));
    const src = try gatherSourceIndexValue(
        inner_builder,
        ctx.args.param(.indices),
        index.index,
        axis_size,
        gathered,
        inner_extent,
    );
    const value = try ctx.args.param(.data).load(inner_builder, src);
    try ctx.args.param(.dst).store(inner_builder, value.raw(), index);
}

fn gatherBody(k: anytype, spec: Gather, args: anytype) !void {
    _ = try k.forEach1D(
        spec.gathered_axis,
        spec.total(),
        .{ .spec = spec, .args = args },
        gather_body_each,
    );
}

fn gather_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const src = try gatherSourceIndexValue(
        inner_builder,
        ctx.args.param(.indices),
        ctx.element,
        ctx.axis_size,
        ctx.gathered,
        ctx.inner_extent,
    );
    const value = try ctx.args.param(.data).load(inner_builder, src);
    try ctx.args.param(.dst).store(inner_builder, value.raw(), ctx.element);
}

fn gatherRuntimeBody(k: anytype, spec: Gather, args: anytype) !void {
    _ = spec;
    const element = try k.globalId(.x);
    const axis_size = try k.castIndex(args.param(.axis_size).raw());
    const gathered = try k.castIndex(args.param(.gathered).raw());
    const inner_extent = try k.castIndex(args.param(.inner).raw());
    const total = try k.castIndex(args.param(.total).raw());
    const active = try k.compare(.lt, element, total);
    try k.guardDo(active, .{
        .args = args,
        .element = element,
        .axis_size = axis_size,
        .gathered = gathered,
        .inner_extent = inner_extent,
    }, gather_runtime_body_active);
}

fn gatherFamilySchedule(instance: Gather) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn gatherFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_indexing_gather_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .data = kernel.dynamicBuffer(dtype),
            .indices = kernel.dynamicBuffer(.i32),
        },
        .Instance = Gather,
        .schedule = gatherFamilySchedule,
        .body = gatherBody,
    });
}

fn gatherRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_indexing_gather_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .data = kernel.dynamicBuffer(dtype),
            .indices = kernel.dynamicBuffer(.i32),
            .outer = kernel.scalar(.i32),
            .axis_size = kernel.scalar(.i32),
            .gathered = kernel.scalar(.i32),
            .inner = kernel.scalar(.i32),
            .total = kernel.scalar(.i32),
        },
        .Instance = Gather,
        .schedule = gatherFamilySchedule,
        .body = gatherRuntimeBody,
    });
}

pub const GatherFamilyF32 = gatherFamily(.f32);
pub const GatherFamilyF16 = gatherFamily(.f16);
pub const GatherRuntimeFamilyF32 = gatherRuntimeFamily(.f32);
pub const GatherRuntimeFamilyF16 = gatherRuntimeFamily(.f16);

pub fn gatherThreadsForTotal(total: u64) u32 {
    return geometry_mod.threadsForExtent(total, gather_thread_caps);
}

pub fn gatherThreadCandidatesForTotal(total: u64) geometry_mod.Thread1DCandidates {
    return geometry_mod.threadCandidatesForExtent(total, gather_thread_caps);
}

pub fn gatherInstanceTarget(allocator: std.mem.Allocator, instance: Gather) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.indexing.gather{d}x{d}x{d}x{d}_{d}_{s}",
        .{
            instance.outer,
            instance.axis_size,
            instance.gathered,
            instance.inner,
            instance.threads,
            instance.dtype.name(),
        },
    );
}

pub fn gatherInstanceEntryName(allocator: std.mem.Allocator, instance: Gather) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_indexing_gather{d}x{d}x{d}x{d}_{d}_{s}",
        .{
            instance.outer,
            instance.axis_size,
            instance.gathered,
            instance.inner,
            instance.threads,
            instance.dtype.name(),
        },
    );
}

pub fn gatherFamilyTarget(allocator: std.mem.Allocator, instance: Gather) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.indexing.gather_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

pub fn gatherFamilyEntryName(allocator: std.mem.Allocator, instance: Gather) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_indexing_gather_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

pub fn gatherTuningExtents(instance: Gather) [4]u64 {
    return .{ instance.outer, instance.axis_size, instance.gathered, instance.inner };
}

pub fn gatherTuningOperation(instance: Gather) entry.Operation {
    _ = instance;
    return .{ .indexing = .gather };
}

pub fn gatherFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: Gather,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try gatherFamilyFingerprint(backing_allocator, instance);
    const extents = gatherTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(gatherTuningOperation(instance)),
        instance.dtype,
        gather_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn resolveGatherSchedule(
    backing_allocator: std.mem.Allocator,
    reader: tuning.FamilyTuningReader,
    instance: Gather,
) !?u32 {
    const key = try gatherFamilyTuningKey(backing_allocator, reader.device_fingerprint, instance);
    const record = reader.table.find(key) orelse return null;
    const thread_candidates = gatherThreadCandidatesForTotal(instance.total());
    for (thread_candidates.slice()) |threads| {
        var candidate = instance;
        candidate.threads = threads;
        const target = try gatherFamilyTarget(backing_allocator, candidate);
        defer backing_allocator.free(target);
        if (std.mem.eql(u8, target, record.target)) return threads;
    }
    return null;
}

pub fn gatherRuntimeArguments(instance: Gather) ![5]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.outer) },
        .{ .u32 = try runtimeExtentArgument(instance.axis_size) },
        .{ .u32 = try runtimeExtentArgument(instance.gathered) },
        .{ .u32 = try runtimeExtentArgument(instance.inner) },
        .{ .u32 = try runtimeExtentArgument(instance.total()) },
    };
}

pub fn gatherShapeProfileDimensions(
    instance: Gather,
) [5]artifact_product.KernelCallShapeProfileDimension {
    const bounds = gatherRuntimeExtentBounds();
    return .{
        .{ .name = instance.outer_axis, .runtime_scalar_argument_index = 0, .bounds = bounds },
        .{ .name = instance.source_axis, .runtime_scalar_argument_index = 1, .bounds = bounds },
        .{ .name = instance.gathered_axis, .runtime_scalar_argument_index = 2, .bounds = bounds },
        .{ .name = instance.inner_axis, .runtime_scalar_argument_index = 3, .bounds = bounds },
        .{ .name = "e", .runtime_scalar_argument_index = 4, .bounds = bounds },
    };
}

fn gatherRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

fn gatherDerivedLaunch(instance: Gather) !artifact_product.KernelCallLaunch {
    if (instance.threads == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 4, .divisor = instance.threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn createGatherFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: Gather,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try gatherFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try gatherFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try gatherFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = gatherShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "gather",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try GatherRuntimeFamilyF32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .f16 => try GatherRuntimeFamilyF16.buildNamed(
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
        .version = gather_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try gatherDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            5
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn gatherFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: Gather) !u64 {
    var family = try gatherShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn gatherShapeFamily(backing_allocator: std.mem.Allocator, instance: Gather) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "gather");
    errdefer builder.deinit();

    const outer = try builder.symbol(instance.outer_axis);
    const source = try builder.symbol(instance.source_axis);
    const gathered = try builder.symbol(instance.gathered_axis);
    const inner = try builder.symbol(instance.inner_axis);

    const outer_expr = try builder.symbolExpression(outer);
    const source_expr = try builder.symbolExpression(source);
    const gathered_expr = try builder.symbolExpression(gathered);
    const inner_expr = try builder.symbolExpression(inner);

    _ = try builder.tensor("data", &.{ outer_expr, source_expr, inner_expr });
    _ = try builder.tensor("indices", &.{gathered_expr});
    _ = try builder.tensor("out", &.{ outer_expr, gathered_expr, inner_expr });
    try builder.assumeBounds(outer_expr, gatherRuntimeExtentBounds());
    try builder.assumeBounds(source_expr, gatherRuntimeExtentBounds());
    try builder.assumeBounds(gathered_expr, gatherRuntimeExtentBounds());
    try builder.assumeBounds(inner_expr, gatherRuntimeExtentBounds());

    return builder.finish();
}

pub fn gatherFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: Gather,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.outer_axis,
        instance.outer,
        instance.source_axis,
        instance.axis_size,
        instance.inner_axis,
        instance.inner,
    );
    inputs[1] = try entry.runtimeShape1D(
        lifetime_allocator,
        instance.gathered_axis,
        instance.gathered,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.outer_axis,
        instance.outer,
        instance.gathered_axis,
        instance.gathered,
        instance.inner_axis,
        instance.inner,
    );

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .indexing = .gather },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            "e",
            instance.total(),
            instance.threads,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try gatherShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn gatherInstanceFromSpecialization(specialization: entry.Specialization) ?Gather {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .indexing = .gather })) return null;
    const dtype = specialization.dtype orelse return null;
    if (!gatherDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const data = specialization.inputs[0];
    const indices = specialization.inputs[1];
    const output = specialization.outputs[0];
    if (data.axes.len != 3 or indices.axes.len != 1 or output.axes.len != 3) return null;
    const outer = data.axes[0].extent;
    const axis_size = data.axes[1].extent;
    const inner = data.axes[2].extent;
    const gathered = indices.axes[0].extent;
    if (output.axes[0].extent !=
        outer or output.axes[1].extent != gathered or output.axes[2].extent != inner) return null;
    if (!std.mem.eql(u8, data.axes[0].name, output.axes[0].name)) return null;
    if (!std.mem.eql(u8, indices.axes[0].name, output.axes[1].name)) return null;
    if (!std.mem.eql(u8, data.axes[2].name, output.axes[2].name)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    return .{
        .outer = outer,
        .axis_size = axis_size,
        .gathered = gathered,
        .inner = inner,
        .dtype = dtype,
        .threads = launch.threadgroup[0],
        .outer_axis = data.axes[0].name,
        .source_axis = data.axes[1].name,
        .gathered_axis = indices.axes[0].name,
        .inner_axis = data.axes[2].name,
    };
}

fn gatherSpecialization(comptime spec: Gather) entry.Specialization {
    return .{
        .dtype = spec.dtype,
        .operation = .{ .indexing = .gather },
        .inputs = &.{
            entry.shape3D(
                spec.outer_axis,
                spec.outer,
                spec.source_axis,
                spec.axis_size,
                spec.inner_axis,
                spec.inner,
            ),
            entry.shape1D(spec.gathered_axis, spec.gathered),
        },
        .outputs = &.{entry.shape3D(
            spec.outer_axis,
            spec.outer,
            spec.gathered_axis,
            spec.gathered,
            spec.inner_axis,
            spec.inner,
        )},
        .launch = entry.launch1D(ceilDivComptime(spec.total(), spec.threads), spec.threads),
        .schedule = entry.threadBlocks1D("e", spec.total(), spec.threads),
    };
}

fn ceilDivComptime(comptime numerator: u64, comptime denominator: u32) u32 {
    return @intCast(numerator / denominator + @as(u64, @intFromBool(numerator % denominator != 0)));
}

fn gatherProgram(comptime spec: Gather) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            try gatherBody(k, spec, args);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_indexing_gather{}x{}x{}x{}_{}_{s}",
            .{
                spec.outer,
                spec.axis_size,
                spec.gathered,
                spec.inner,
                spec.threads,
                spec.dtype.name(),
            },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(spec.dtype),
            .data = kernel.dynamicBuffer(spec.dtype),
            .indices = kernel.dynamicBuffer(.i32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

pub fn gatherF32(comptime spec: Gather) type {
    return entry.Entry(gatherProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.indexing.gather{}x{}x{}x{}_{}_{s}",
            .{
                spec.outer,
                spec.axis_size,
                spec.gathered,
                spec.inner,
                spec.threads,
                spec.dtype.name(),
            },
        ),
        .layer = .logical,
        .category = .indexing,
        .specialization = gatherSpecialization(spec),
    });
}

pub const Gather8F32 = gatherF32(.{ .axis_size = 8, .gathered = 8, .threads = 8 });

pub const Scatter = struct {
    outer: u64 = 1,
    axis_size: u64,
    updates: u64,
    inner: u64 = 1,
    dtype: DType = .f32,
    index_dtype: DType = .i32,
    threads: u32 = 256,
    outer_axis: []const u8 = "o",
    source_axis: []const u8 = "s",
    update_axis: []const u8 = "u",
    inner_axis: []const u8 = "i",

    pub fn total(self: Scatter) u64 {
        return self.outer * self.axis_size * self.inner;
    }
};

pub const scatter_family_version: u32 = 1;
const scatter_thread_caps = geometry_mod.ThreadCaps1D{};

pub fn scatterDTypeSupported(dtype: DType) bool {
    return switch (dtype) {
        .f32, .f16 => true,
        else => false,
    };
}

fn scatter_output_value_apply(
    fold_builder: anytype,
    update_position: kernel.Value,
    current: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    const loaded = try ctx.args.param(.indices).load(fold_builder, update_position);
    const index_value = try fold_builder.castIndex(loaded.raw());
    const matches = try fold_builder.compare(.eq, index_value, ctx.axis_coord);
    const update_offset = try fold_builder.mul(update_position, ctx.inner_extent);
    const update_partial = try fold_builder.add(ctx.update_base, update_offset);
    const update_index = try fold_builder.add(update_partial, ctx.within);
    const candidate = try ctx.args.param(.updates).load(fold_builder, update_index);
    return fold_builder.select(matches, candidate.raw(), current);
}

fn scatterOutputValue(
    inner_builder: anytype,
    args: anytype,
    element: kernel.Value,
    axis_size: kernel.Value,
    update_count: kernel.Value,
    inner_extent: kernel.Value,
) !kernel.Value {
    const axis_block = try inner_builder.mul(axis_size, inner_extent);
    const outer_coord = try inner_builder.div(element, axis_block);
    const outer_consumed = try inner_builder.mul(outer_coord, axis_block);
    const axis_rem = try inner_builder.sub(element, outer_consumed);
    const axis_coord = try inner_builder.div(axis_rem, inner_extent);
    const axis_consumed = try inner_builder.mul(axis_coord, inner_extent);
    const within = try inner_builder.sub(axis_rem, axis_consumed);

    const update_block = try inner_builder.mul(update_count, inner_extent);
    const update_base = try inner_builder.mul(outer_coord, update_block);

    const zero = try inner_builder.constantIndex(0);
    const one = try inner_builder.constantIndex(1);
    const initial = try args.param(.data).load(inner_builder, element);

    return inner_builder.fold(zero, update_count, one, initial.raw(), .{
        .args = args,
        .axis_coord = axis_coord,
        .within = within,
        .update_base = update_base,
        .inner_extent = inner_extent,
    }, scatter_output_value_apply);
}

fn scatter_body_each(inner_builder: anytype, index: kernel.Index1D, ctx: anytype) !void {
    const axis_size = try inner_builder.constantIndex(try indexExtent(ctx.spec.axis_size));
    const update_count = try inner_builder.constantIndex(try indexExtent(ctx.spec.updates));
    const inner_extent = try inner_builder.constantIndex(try indexExtent(ctx.spec.inner));
    const value = try scatterOutputValue(
        inner_builder,
        ctx.args,
        index.index,
        axis_size,
        update_count,
        inner_extent,
    );
    try ctx.args.param(.dst).store(inner_builder, value, index);
}

fn scatterBody(k: anytype, spec: Scatter, args: anytype) !void {
    _ = try k.forEach1D(
        spec.source_axis,
        spec.total(),
        .{ .spec = spec, .args = args },
        scatter_body_each,
    );
}

fn scatter_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const value = try scatterOutputValue(
        inner_builder,
        ctx.args,
        ctx.element,
        ctx.axis_size,
        ctx.update_count,
        ctx.inner_extent,
    );
    try ctx.args.param(.dst).store(inner_builder, value, ctx.element);
}

fn scatterRuntimeBody(k: anytype, spec: Scatter, args: anytype) !void {
    _ = spec;
    const element = try k.globalId(.x);
    const axis_size = try k.castIndex(args.param(.axis_size).raw());
    const update_count = try k.castIndex(args.param(.update_count).raw());
    const inner_extent = try k.castIndex(args.param(.inner).raw());
    const total = try k.castIndex(args.param(.total).raw());
    const active = try k.compare(.lt, element, total);
    try k.guardDo(active, .{
        .args = args,
        .element = element,
        .axis_size = axis_size,
        .update_count = update_count,
        .inner_extent = inner_extent,
    }, scatter_runtime_body_active);
}

fn scatterFamilySchedule(instance: Scatter) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn scatterFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_indexing_scatter_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .data = kernel.dynamicBuffer(dtype),
            .indices = kernel.dynamicBuffer(.i32),
            .updates = kernel.dynamicBuffer(dtype),
        },
        .Instance = Scatter,
        .schedule = scatterFamilySchedule,
        .body = scatterBody,
    });
}

fn scatterRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_indexing_scatter_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .data = kernel.dynamicBuffer(dtype),
            .indices = kernel.dynamicBuffer(.i32),
            .updates = kernel.dynamicBuffer(dtype),
            .outer = kernel.scalar(.i32),
            .axis_size = kernel.scalar(.i32),
            .update_count = kernel.scalar(.i32),
            .inner = kernel.scalar(.i32),
            .total = kernel.scalar(.i32),
        },
        .Instance = Scatter,
        .schedule = scatterFamilySchedule,
        .body = scatterRuntimeBody,
    });
}

pub const ScatterFamilyF32 = scatterFamily(.f32);
pub const ScatterFamilyF16 = scatterFamily(.f16);
pub const ScatterRuntimeFamilyF32 = scatterRuntimeFamily(.f32);
pub const ScatterRuntimeFamilyF16 = scatterRuntimeFamily(.f16);

pub fn scatterThreadsForTotal(total: u64) u32 {
    return geometry_mod.threadsForExtent(total, scatter_thread_caps);
}

pub fn scatterThreadCandidatesForTotal(total: u64) geometry_mod.Thread1DCandidates {
    return geometry_mod.threadCandidatesForExtent(total, scatter_thread_caps);
}

pub fn scatterAddThreadsForTotal(total: u64) u32 {
    return geometry_mod.threadsForExtent(total, scatter_thread_caps);
}

pub fn scatterAddThreadCandidatesForTotal(total: u64) geometry_mod.Thread1DCandidates {
    return geometry_mod.threadCandidatesForExtent(total, scatter_thread_caps);
}

pub fn scatterInstanceTarget(allocator: std.mem.Allocator, instance: Scatter) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.indexing.scatter{d}x{d}x{d}x{d}_{d}_{s}",
        .{
            instance.outer,
            instance.axis_size,
            instance.updates,
            instance.inner,
            instance.threads,
            instance.dtype.name(),
        },
    );
}

pub fn scatterInstanceEntryName(allocator: std.mem.Allocator, instance: Scatter) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_indexing_scatter{d}x{d}x{d}x{d}_{d}_{s}",
        .{
            instance.outer,
            instance.axis_size,
            instance.updates,
            instance.inner,
            instance.threads,
            instance.dtype.name(),
        },
    );
}

pub fn scatterFamilyTarget(allocator: std.mem.Allocator, instance: Scatter) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.indexing.scatter_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

pub fn scatterFamilyEntryName(allocator: std.mem.Allocator, instance: Scatter) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_indexing_scatter_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

pub fn scatterTuningExtents(instance: Scatter) [4]u64 {
    return .{ instance.outer, instance.axis_size, instance.updates, instance.inner };
}

pub fn scatterTuningOperation(instance: Scatter) entry.Operation {
    _ = instance;
    return .{ .indexing = .scatter };
}

pub fn scatterFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: Scatter,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try scatterFamilyFingerprint(backing_allocator, instance);
    const extents = scatterTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(scatterTuningOperation(instance)),
        instance.dtype,
        scatter_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn resolveScatterSchedule(
    backing_allocator: std.mem.Allocator,
    reader: tuning.FamilyTuningReader,
    instance: Scatter,
) !?u32 {
    const key = try scatterFamilyTuningKey(backing_allocator, reader.device_fingerprint, instance);
    const record = reader.table.find(key) orelse return null;
    const thread_candidates = scatterThreadCandidatesForTotal(instance.total());
    for (thread_candidates.slice()) |threads| {
        var candidate = instance;
        candidate.threads = threads;
        const target = try scatterFamilyTarget(backing_allocator, candidate);
        defer backing_allocator.free(target);
        if (std.mem.eql(u8, target, record.target)) return threads;
    }
    return null;
}

pub fn scatterRuntimeArguments(instance: Scatter) ![5]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.outer) },
        .{ .u32 = try runtimeExtentArgument(instance.axis_size) },
        .{ .u32 = try runtimeExtentArgument(instance.updates) },
        .{ .u32 = try runtimeExtentArgument(instance.inner) },
        .{ .u32 = try runtimeExtentArgument(instance.total()) },
    };
}

pub fn scatterShapeProfileDimensions(
    instance: Scatter,
) [5]artifact_product.KernelCallShapeProfileDimension {
    const bounds = scatterRuntimeExtentBounds();
    return .{
        .{ .name = instance.outer_axis, .runtime_scalar_argument_index = 0, .bounds = bounds },
        .{ .name = instance.source_axis, .runtime_scalar_argument_index = 1, .bounds = bounds },
        .{ .name = instance.update_axis, .runtime_scalar_argument_index = 2, .bounds = bounds },
        .{ .name = instance.inner_axis, .runtime_scalar_argument_index = 3, .bounds = bounds },
        .{ .name = "e", .runtime_scalar_argument_index = 4, .bounds = bounds },
    };
}

fn scatterRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

fn scatterDerivedLaunch(instance: Scatter) !artifact_product.KernelCallLaunch {
    if (instance.threads == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 4, .divisor = instance.threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn createScatterFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: Scatter,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try scatterFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try scatterFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try scatterFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = scatterShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "scatter",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try ScatterRuntimeFamilyF32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .f16 => try ScatterRuntimeFamilyF16.buildNamed(
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
        .version = scatter_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try scatterDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            5
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn scatterFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: Scatter) !u64 {
    var family = try scatterShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn scatterShapeFamily(backing_allocator: std.mem.Allocator, instance: Scatter) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "scatter");
    errdefer builder.deinit();

    const outer = try builder.symbol(instance.outer_axis);
    const source = try builder.symbol(instance.source_axis);
    const update = try builder.symbol(instance.update_axis);
    const inner = try builder.symbol(instance.inner_axis);

    const outer_expr = try builder.symbolExpression(outer);
    const source_expr = try builder.symbolExpression(source);
    const update_expr = try builder.symbolExpression(update);
    const inner_expr = try builder.symbolExpression(inner);

    _ = try builder.tensor("data", &.{ outer_expr, source_expr, inner_expr });
    _ = try builder.tensor("indices", &.{update_expr});
    _ = try builder.tensor("updates", &.{ outer_expr, update_expr, inner_expr });
    _ = try builder.tensor("out", &.{ outer_expr, source_expr, inner_expr });
    try builder.assumeBounds(outer_expr, scatterRuntimeExtentBounds());
    try builder.assumeBounds(source_expr, scatterRuntimeExtentBounds());
    try builder.assumeBounds(update_expr, scatterRuntimeExtentBounds());
    try builder.assumeBounds(inner_expr, scatterRuntimeExtentBounds());

    return builder.finish();
}

pub fn scatterFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: Scatter,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 3);
    inputs[0] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.outer_axis,
        instance.outer,
        instance.source_axis,
        instance.axis_size,
        instance.inner_axis,
        instance.inner,
    );
    inputs[1] = try entry.runtimeShape1D(
        lifetime_allocator,
        instance.update_axis,
        instance.updates,
    );
    inputs[2] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.outer_axis,
        instance.outer,
        instance.update_axis,
        instance.updates,
        instance.inner_axis,
        instance.inner,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.outer_axis,
        instance.outer,
        instance.source_axis,
        instance.axis_size,
        instance.inner_axis,
        instance.inner,
    );

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .indexing = .scatter },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            "e",
            instance.total(),
            instance.threads,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try scatterShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn scatterInstanceFromSpecialization(specialization: entry.Specialization) ?Scatter {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .indexing = .scatter })) return null;
    const dtype = specialization.dtype orelse return null;
    if (!scatterDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 3 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const data = specialization.inputs[0];
    const indices = specialization.inputs[1];
    const update_values = specialization.inputs[2];
    const output = specialization.outputs[0];
    if (data.axes.len != 3 or indices.axes.len !=
        1 or update_values.axes.len != 3 or output.axes.len != 3) return null;
    const outer = data.axes[0].extent;
    const axis_size = data.axes[1].extent;
    const inner = data.axes[2].extent;
    const updates = indices.axes[0].extent;
    if (update_values.axes[0].extent != outer or update_values.axes[1].extent !=
        updates or update_values.axes[2].extent != inner) return null;
    if (output.axes[0].extent !=
        outer or output.axes[1].extent != axis_size or output.axes[2].extent != inner) return null;
    if (!std.mem.eql(u8, data.axes[1].name, output.axes[1].name)) return null;
    if (!std.mem.eql(u8, indices.axes[0].name, update_values.axes[1].name)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    return .{
        .outer = outer,
        .axis_size = axis_size,
        .updates = updates,
        .inner = inner,
        .dtype = dtype,
        .threads = launch.threadgroup[0],
        .outer_axis = data.axes[0].name,
        .source_axis = data.axes[1].name,
        .update_axis = indices.axes[0].name,
        .inner_axis = data.axes[2].name,
    };
}

fn scatterSpecialization(comptime spec: Scatter) entry.Specialization {
    return .{
        .dtype = spec.dtype,
        .operation = .{ .indexing = .scatter },
        .inputs = &.{
            entry.shape3D(
                spec.outer_axis,
                spec.outer,
                spec.source_axis,
                spec.axis_size,
                spec.inner_axis,
                spec.inner,
            ),
            entry.shape1D(spec.update_axis, spec.updates),
            entry.shape3D(
                spec.outer_axis,
                spec.outer,
                spec.update_axis,
                spec.updates,
                spec.inner_axis,
                spec.inner,
            ),
        },
        .outputs = &.{entry.shape3D(
            spec.outer_axis,
            spec.outer,
            spec.source_axis,
            spec.axis_size,
            spec.inner_axis,
            spec.inner,
        )},
        .launch = entry.launch1D(ceilDivComptime(spec.total(), spec.threads), spec.threads),
        .schedule = entry.threadBlocks1D("e", spec.total(), spec.threads),
    };
}

fn scatterProgram(comptime spec: Scatter) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            try scatterBody(k, spec, args);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_indexing_scatter{}x{}x{}x{}_{}_{s}",
            .{
                spec.outer,
                spec.axis_size,
                spec.updates,
                spec.inner,
                spec.threads,
                spec.dtype.name(),
            },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(spec.dtype),
            .data = kernel.dynamicBuffer(spec.dtype),
            .indices = kernel.dynamicBuffer(.i32),
            .updates = kernel.dynamicBuffer(spec.dtype),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

pub fn scatterF32(comptime spec: Scatter) type {
    return entry.Entry(scatterProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.indexing.scatter{}x{}x{}x{}_{}_{s}",
            .{
                spec.outer,
                spec.axis_size,
                spec.updates,
                spec.inner,
                spec.threads,
                spec.dtype.name(),
            },
        ),
        .layer = .logical,
        .category = .indexing,
        .specialization = scatterSpecialization(spec),
    });
}

pub const Scatter8F32 = scatterF32(.{ .axis_size = 8, .updates = 4, .threads = 8 });

pub const ScatterAddVariant = enum {
    direct,
    shared_bins,
};

pub const ScatterAdd = struct {
    outer: u64 = 1,
    axis_size: u64,
    updates: u64,
    inner: u64 = 1,
    dtype: DType = .i32,
    variant: ScatterAddVariant = .direct,
    threads: u32 = 256,
    outer_axis: []const u8 = "o",
    source_axis: []const u8 = "s",
    update_axis: []const u8 = "u",
    inner_axis: []const u8 = "i",

    pub fn total(self: ScatterAdd) u64 {
        return self.outer * self.updates * self.inner;
    }
};

pub const scatter_add_shared_bins_cap: u64 = 4096;

pub const scatter_add_family_version: u32 = 3;

pub const ScatterAddResolvedSchedule = struct {
    variant: ScatterAddVariant,
    threads: u32,
};

pub fn scatterAddDTypeSupported(dtype: DType) bool {
    return switch (dtype) {
        .i32, .f32 => true,
        else => false,
    };
}

pub fn scatterAddInstanceValid(instance: ScatterAdd) bool {
    if (!scatterAddDTypeSupported(instance.dtype)) return false;
    if (instance.outer == 0 or instance.axis_size == 0 or
        instance.updates == 0 or instance.inner == 0) return false;
    if (instance.variant == .shared_bins and
        (instance.axis_size > scatter_add_shared_bins_cap or
            instance.outer != 1 or instance.inner != 1))
    {
        return false;
    }
    return instance.threads != 0;
}

pub fn scatterAddFamilyTarget(allocator: std.mem.Allocator, instance: ScatterAdd) ![]u8 {
    return switch (instance.variant) {
        .direct => std.fmt.allocPrint(
            allocator,
            "accy.kernel.indexing.scatter_add_family_{d}_{s}",
            .{ instance.threads, instance.dtype.name() },
        ),
        .shared_bins => std.fmt.allocPrint(
            allocator,
            "accy.kernel.indexing.scatter_add_family_shared{d}_{d}_{s}",
            .{ instance.axis_size, instance.threads, instance.dtype.name() },
        ),
    };
}

pub fn scatterAddFamilyEntryName(allocator: std.mem.Allocator, instance: ScatterAdd) ![]u8 {
    return switch (instance.variant) {
        .direct => std.fmt.allocPrint(
            allocator,
            "accy_kernel_indexing_scatter_add_family_{d}_{s}",
            .{ instance.threads, instance.dtype.name() },
        ),
        .shared_bins => std.fmt.allocPrint(
            allocator,
            "accy_kernel_indexing_scatter_add_family_shared{d}_{d}_{s}",
            .{ instance.axis_size, instance.threads, instance.dtype.name() },
        ),
    };
}

pub fn scatterAddTuningExtents(instance: ScatterAdd) [4]u64 {
    return .{ instance.outer, instance.axis_size, instance.updates, instance.inner };
}

pub fn scatterAddTuningOperation(instance: ScatterAdd) entry.Operation {
    _ = instance;
    return .{ .indexing = .scatter_add };
}

pub fn scatterAddFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: ScatterAdd,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try scatterAddFamilyFingerprint(backing_allocator, instance);
    const extents = scatterAddTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(scatterAddTuningOperation(instance)),
        instance.dtype,
        scatter_add_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn resolveScatterAddSchedule(
    backing_allocator: std.mem.Allocator,
    reader: tuning.FamilyTuningReader,
    instance: ScatterAdd,
) !?ScatterAddResolvedSchedule {
    const key = try scatterAddFamilyTuningKey(
        backing_allocator,
        reader.device_fingerprint,
        instance,
    );
    const record = reader.table.find(key) orelse return null;
    const thread_candidates = scatterAddThreadCandidatesForTotal(instance.total());
    const variants = [_]ScatterAddVariant{ .direct, .shared_bins };
    for (variants) |variant| {
        for (thread_candidates.slice()) |threads| {
            var candidate = instance;
            candidate.variant = variant;
            candidate.threads = threads;
            if (!scatterAddInstanceValid(candidate)) continue;
            const target = try scatterAddFamilyTarget(backing_allocator, candidate);
            defer backing_allocator.free(target);
            if (std.mem.eql(u8, target, record.target)) {
                return .{ .variant = variant, .threads = threads };
            }
        }
    }
    return null;
}

pub fn scatterAddRuntimeArguments(instance: ScatterAdd) ![5]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.outer) },
        .{ .u32 = try runtimeExtentArgument(instance.axis_size) },
        .{ .u32 = try runtimeExtentArgument(instance.updates) },
        .{ .u32 = try runtimeExtentArgument(instance.inner) },
        .{ .u32 = try runtimeExtentArgument(instance.total()) },
    };
}

pub fn scatterAddShapeProfileDimensions(
    instance: ScatterAdd,
) [5]artifact_product.KernelCallShapeProfileDimension {
    const bounds = scatterRuntimeExtentBounds();
    return .{
        .{ .name = instance.outer_axis, .runtime_scalar_argument_index = 0, .bounds = bounds },
        .{ .name = instance.source_axis, .runtime_scalar_argument_index = 1, .bounds = bounds },
        .{ .name = instance.update_axis, .runtime_scalar_argument_index = 2, .bounds = bounds },
        .{ .name = instance.inner_axis, .runtime_scalar_argument_index = 3, .bounds = bounds },
        .{ .name = "e", .runtime_scalar_argument_index = 4, .bounds = bounds },
    };
}

fn scatterAddDerivedLaunch(instance: ScatterAdd) !artifact_product.KernelCallLaunch {
    if (instance.threads == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 4, .divisor = instance.threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn scatterAddShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: ScatterAdd,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "scatter_add");
    errdefer builder.deinit();

    const outer = try builder.symbol(instance.outer_axis);
    const source = try builder.symbol(instance.source_axis);
    const update = try builder.symbol(instance.update_axis);
    const inner = try builder.symbol(instance.inner_axis);
    const outer_expr = try builder.symbolExpression(outer);
    const source_expr = try builder.symbolExpression(source);
    const update_expr = try builder.symbolExpression(update);
    const inner_expr = try builder.symbolExpression(inner);

    _ = try builder.tensor("dst", &.{ outer_expr, source_expr, inner_expr });
    _ = try builder.tensor("indices", &.{update_expr});
    _ = try builder.tensor("updates", &.{ outer_expr, update_expr, inner_expr });
    _ = try builder.tensor("out", &.{ outer_expr, source_expr, inner_expr });
    try builder.assumeBounds(outer_expr, scatterRuntimeExtentBounds());
    try builder.assumeBounds(source_expr, scatterRuntimeExtentBounds());
    try builder.assumeBounds(update_expr, scatterRuntimeExtentBounds());
    try builder.assumeBounds(inner_expr, scatterRuntimeExtentBounds());

    return builder.finish();
}

pub fn scatterAddFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: ScatterAdd,
) !u64 {
    var family = try scatterAddShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn scatterAddFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: ScatterAdd,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 3);
    inputs[0] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.outer_axis,
        instance.outer,
        instance.source_axis,
        instance.axis_size,
        instance.inner_axis,
        instance.inner,
    );
    inputs[1] = try entry.runtimeShape1D(
        lifetime_allocator,
        instance.update_axis,
        instance.updates,
    );
    inputs[2] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.outer_axis,
        instance.outer,
        instance.update_axis,
        instance.updates,
        instance.inner_axis,
        instance.inner,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape3D(
        lifetime_allocator,
        instance.outer_axis,
        instance.outer,
        instance.source_axis,
        instance.axis_size,
        instance.inner_axis,
        instance.inner,
    );

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .indexing = .scatter_add },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            "e",
            instance.total(),
            instance.threads,
        ),
        .structure = @tagName(instance.variant),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try scatterAddShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn scatterAddInstanceFromSpecialization(specialization: entry.Specialization) ?ScatterAdd {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .indexing = .scatter_add })) return null;
    const dtype = specialization.dtype orelse return null;
    if (!scatterAddDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 3 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const seed = specialization.inputs[0];
    const indices = specialization.inputs[1];
    const update_values = specialization.inputs[2];
    const output = specialization.outputs[0];
    if (seed.axes.len != 3 or indices.axes.len !=
        1 or update_values.axes.len != 3 or output.axes.len != 3) return null;
    const outer = seed.axes[0].extent;
    const axis_size = seed.axes[1].extent;
    const inner = seed.axes[2].extent;
    const updates = indices.axes[0].extent;
    if (update_values.axes[0].extent != outer or update_values.axes[1].extent !=
        updates or update_values.axes[2].extent != inner) return null;
    if (output.axes[0].extent !=
        outer or output.axes[1].extent != axis_size or output.axes[2].extent != inner) return null;
    if (!std.mem.eql(u8, seed.axes[0].name, output.axes[0].name)) return null;
    if (!std.mem.eql(u8, seed.axes[1].name, output.axes[1].name)) return null;
    if (!std.mem.eql(u8, seed.axes[2].name, output.axes[2].name)) return null;
    if (!std.mem.eql(u8, indices.axes[0].name, update_values.axes[1].name)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const variant: ScatterAddVariant = if (specialization.structure) |structure| blk: {
        if (std.mem.eql(u8, structure, "direct")) break :blk .direct;
        if (std.mem.eql(u8, structure, "shared_bins")) break :blk .shared_bins;
        return null;
    } else .direct;
    return .{
        .outer = outer,
        .axis_size = axis_size,
        .updates = updates,
        .inner = inner,
        .dtype = dtype,
        .variant = variant,
        .threads = launch.threadgroup[0],
        .outer_axis = seed.axes[0].name,
        .source_axis = seed.axes[1].name,
        .update_axis = indices.axes[0].name,
        .inner_axis = seed.axes[2].name,
    };
}

fn scatterAddFamilySchedule(instance: ScatterAdd) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn scatter_add_direct_runtime_body_active(guard_builder: anytype, ctx: anytype) !void {
    const axis_size = try guard_builder.castIndex(ctx.args.param(.axis_size).raw());
    const update_block = try guard_builder.mul(ctx.update_count, ctx.inner_extent);
    const outer = try guard_builder.div(ctx.element, update_block);
    const outer_consumed = try guard_builder.mul(outer, update_block);
    const rem = try guard_builder.sub(ctx.element, outer_consumed);
    const update_position = try guard_builder.div(rem, ctx.inner_extent);
    const update_consumed = try guard_builder.mul(update_position, ctx.inner_extent);
    const within = try guard_builder.sub(rem, update_consumed);
    const loaded = try ctx.args.param(.indices).load(guard_builder, update_position);
    const target = try guard_builder.castIndex(loaded.raw());
    const zero = try guard_builder.constantIndex(0);
    const non_negative = try guard_builder.compare(.ge, target, zero);
    try guard_builder.guardDo(non_negative, .{
        .args = ctx.args,
        .element = ctx.element,
        .outer = outer,
        .target = target,
        .axis_size = axis_size,
        .inner_extent = ctx.inner_extent,
        .within = within,
    }, scatter_add_direct_runtime_body_non_negative);
}

fn scatter_add_direct_runtime_body_non_negative(range_builder: anytype, range_ctx: anytype) !void {
    const in_range = try range_builder.compare(.lt, range_ctx.target, range_ctx.axis_size);
    try range_builder.guardDo(in_range, .{
        .args = range_ctx.args,
        .element = range_ctx.element,
        .outer = range_ctx.outer,
        .target = range_ctx.target,
        .axis_size = range_ctx.axis_size,
        .inner_extent = range_ctx.inner_extent,
        .within = range_ctx.within,
    }, scatter_add_direct_runtime_body_in_range);
}

fn scatter_add_direct_runtime_body_in_range(atomic_builder: anytype, atomic_ctx: anytype) !void {
    const axis_block = try atomic_builder.mul(atomic_ctx.axis_size, atomic_ctx.inner_extent);
    const outer_offset = try atomic_builder.mul(atomic_ctx.outer, axis_block);
    const target_offset = try atomic_builder.mul(atomic_ctx.target, atomic_ctx.inner_extent);
    const partial = try atomic_builder.add(outer_offset, target_offset);
    const dst_index = try atomic_builder.add(partial, atomic_ctx.within);
    const value = try atomic_ctx.args.param(.updates).load(atomic_builder, atomic_ctx.element);
    _ = try atomic_ctx.args.param(.dst).atomicRmw(atomic_builder, .add, value, dst_index);
}

fn scatterAddDirectRuntimeBody(k: anytype, spec: ScatterAdd, args: anytype) !void {
    _ = spec;
    const element = try k.globalId(.x);
    const total = try k.castIndex(args.param(.total).raw());
    const update_count = try k.castIndex(args.param(.update_count).raw());
    const inner_extent = try k.castIndex(args.param(.inner).raw());
    const active = try k.compare(.lt, element, total);
    try k.guardDo(active, .{
        .args = args,
        .element = element,
        .update_count = update_count,
        .inner_extent = inner_extent,
    }, scatter_add_direct_runtime_body_active);
}

fn scatterAddRuntimeBody(k: anytype, spec: ScatterAdd, args: anytype) !void {
    switch (spec.variant) {
        .direct => try scatterAddDirectRuntimeBody(k, spec, args),
        .shared_bins => try scatterAddSharedRuntimeBody(k, spec, args),
    }
}

fn scatter_add_shared_runtime_body_zero_bin(
    loop_builder: anytype,
    bin: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    try loop_builder.storeIndex(ctx.zero_value, ctx.bins, bin);
    return acc;
}

fn scatter_add_shared_runtime_body_active(guard_builder: anytype, ctx: anytype) !void {
    const loaded = try ctx.args.param(.indices).load(guard_builder, ctx.update);
    const target = try guard_builder.castIndex(loaded.raw());
    const zero = try guard_builder.constantIndex(0);
    const non_negative = try guard_builder.compare(.ge, target, zero);
    try guard_builder.guardDo(non_negative, .{
        .args = ctx.args,
        .update = ctx.update,
        .target = target,
        .axis_size = ctx.axis_size,
        .bins = ctx.bins,
    }, scatter_add_shared_runtime_body_non_negative);
}

fn scatter_add_shared_runtime_body_non_negative(range_builder: anytype, range_ctx: anytype) !void {
    const in_range = try range_builder.compare(.lt, range_ctx.target, range_ctx.axis_size);
    try range_builder.guardDo(in_range, .{
        .args = range_ctx.args,
        .update = range_ctx.update,
        .target = range_ctx.target,
        .bins = range_ctx.bins,
    }, scatter_add_shared_runtime_body_in_range);
}

fn scatter_add_shared_runtime_body_in_range(atomic_builder: anytype, atomic_ctx: anytype) !void {
    const value = try atomic_ctx.args.param(.updates).load(atomic_builder, atomic_ctx.update);
    _ = try atomic_builder.atomicRmwIndex(.add, value.raw(), atomic_ctx.bins, atomic_ctx.target);
}

fn scatter_add_shared_runtime_body_value(
    loop_builder: anytype,
    bin: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    const partial = try loop_builder.loadIndex(ctx.bins, bin);
    _ = try loop_builder.atomicRmwIndex(.add, partial, ctx.args.param(.dst).raw(), bin);
    return acc;
}

fn scatterAddSharedRuntimeBody(k: anytype, spec: ScatterAdd, args: anytype) !void {
    const bins = try k.sharedBuffer(spec.dtype, spec.axis_size);
    const zero_value = switch (spec.dtype) {
        .i32 => try k.constantInt(.i32, 0),
        .f32 => try k.constantFloat(.f32, 0),
        else => return error.UnsupportedDType,
    };
    const thread = try k.castIndex(try k.threadId(.x));
    const stride = try k.castIndex(try k.blockDim(.x));
    const axis_size = try k.castIndex(args.param(.axis_size).raw());

    _ = try k.fold(thread, axis_size, stride, zero_value, .{
        .bins = bins,
        .zero_value = zero_value,
    }, scatter_add_shared_runtime_body_zero_bin);
    try k.barrier(.block);

    const update = try k.globalId(.x);
    const update_count = try k.castIndex(args.param(.update_count).raw());
    const active = try k.compare(.lt, update, update_count);
    try k.guardDo(active, .{
        .args = args,
        .update = update,
        .bins = bins,
        .axis_size = axis_size,
    }, scatter_add_shared_runtime_body_active);
    try k.barrier(.block);

    _ = try k.fold(thread, axis_size, stride, zero_value, .{
        .args = args,
        .bins = bins,
    }, scatter_add_shared_runtime_body_value);
}

fn scatterAddRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_indexing_scatter_add_runtime_{s}",
            .{dtype.name()},
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .src = kernel.dynamicBuffer(dtype),
            .indices = kernel.dynamicBuffer(.i32),
            .updates = kernel.dynamicBuffer(dtype),
            .outer = kernel.scalar(.i32),
            .axis_size = kernel.scalar(.i32),
            .update_count = kernel.scalar(.i32),
            .inner = kernel.scalar(.i32),
            .total = kernel.scalar(.i32),
        },
        .Instance = ScatterAdd,
        .schedule = scatterAddFamilySchedule,
        .body = scatterAddRuntimeBody,
    });
}

pub const ScatterAddRuntimeFamilyI32 = scatterAddRuntimeFamily(.i32);
pub const ScatterAddRuntimeFamilyF32 = scatterAddRuntimeFamily(.f32);

pub fn createScatterAddFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: ScatterAdd,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!scatterAddInstanceValid(instance)) return error.InvalidKernelLibraryEntry;
    const target = try scatterAddFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try scatterAddFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try scatterAddFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = scatterAddShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "scatter_add",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .i32 => try ScatterAddRuntimeFamilyI32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .f32 => try ScatterAddRuntimeFamilyF32.buildNamed(
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
        .version = scatter_add_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try scatterAddDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            5
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

fn indexingFamilyTuningTestCapabilities() gpu.BackendCapabilities {
    return .{ .identity = .{
        .backend = .cuda,
        .family = .nvidia_cuda,
        .name = "indexing-family-tuning-test-device",
        .vendor_id = 0x10de,
        .device_id = 0x2684,
    } };
}
