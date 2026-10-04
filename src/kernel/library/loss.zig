const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");

const artifact_product = @import("../../artifact/model/root.zig");
const shape = @import("../../choir/shape/root.zig");
const entry = @import("entry.zig");
const extent_mod = @import("extent.zig");
const geometry_mod = @import("geometry.zig");
const kernel = @import("../root.zig");

const DType = gpu_abi.DType;
const runtimeExtentArgument = extent_mod.runtimeExtentArgument;

const loss_thread_caps = geometry_mod.ThreadCaps1D{};

pub const RowSparseCrossEntropy = struct {
    rows: u64,
    classes: u64,
    dtype: DType = .f32,
    threads: u32 = 256,
    row_axis: []const u8 = "r",
    class_axis: []const u8 = "c",

    pub fn total(self: RowSparseCrossEntropy) u64 {
        return self.rows;
    }
};

pub const row_sparse_cross_entropy_family_version: u32 = 1;

pub fn rowSparseCrossEntropyDTypeSupported(dtype: DType) bool {
    return dtype == .f32;
}

pub fn rowSparseCrossEntropyInstanceValid(instance: RowSparseCrossEntropy) bool {
    if (!rowSparseCrossEntropyDTypeSupported(instance.dtype)) return false;
    if (instance.rows == 0 or instance.classes == 0) return false;
    return instance.threads != 0;
}

pub fn rowSparseCrossEntropyThreadsForRows(rows: u64) u32 {
    return geometry_mod.threadsForExtent(rows, loss_thread_caps);
}

pub fn rowSparseCrossEntropyThreadCandidatesForRows(rows: u64) geometry_mod.Thread1DCandidates {
    return geometry_mod.threadCandidatesForExtent(rows, loss_thread_caps);
}

pub fn rowSparseCrossEntropyFamilyTarget(
    allocator: std.mem.Allocator,
    instance: RowSparseCrossEntropy,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.loss.row_sparse_cross_entropy_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

pub fn rowSparseCrossEntropyFamilyEntryName(
    allocator: std.mem.Allocator,
    instance: RowSparseCrossEntropy,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_loss_row_sparse_cross_entropy_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

pub fn rowSparseCrossEntropyRuntimeArguments(
    instance: RowSparseCrossEntropy,
) ![2]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.rows) },
        .{ .u32 = try runtimeExtentArgument(instance.classes) },
    };
}

pub fn rowSparseCrossEntropyShapeProfileDimensions(
    instance: RowSparseCrossEntropy,
) [2]artifact_product.KernelCallShapeProfileDimension {
    const bounds = lossRuntimeExtentBounds();
    return .{
        .{ .name = instance.row_axis, .runtime_scalar_argument_index = 0, .bounds = bounds },
        .{ .name = instance.class_axis, .runtime_scalar_argument_index = 1, .bounds = bounds },
    };
}

fn lossRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

fn rowSparseCrossEntropyDerivedLaunch(
    instance: RowSparseCrossEntropy,
) !artifact_product.KernelCallLaunch {
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

pub fn rowSparseCrossEntropyShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: RowSparseCrossEntropy,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "row_sparse_cross_entropy");
    errdefer builder.deinit();

    const row = try builder.symbol(instance.row_axis);
    const class = try builder.symbol(instance.class_axis);
    const row_expr = try builder.symbolExpression(row);
    const class_expr = try builder.symbolExpression(class);

    _ = try builder.tensor("logits", &.{ row_expr, class_expr });
    _ = try builder.tensor("targets", &.{row_expr});
    _ = try builder.tensor("losses", &.{row_expr});
    try builder.assumeBounds(row_expr, lossRuntimeExtentBounds());
    try builder.assumeBounds(class_expr, lossRuntimeExtentBounds());
    return builder.finish();
}

pub fn rowSparseCrossEntropyFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: RowSparseCrossEntropy,
) !u64 {
    var family = try rowSparseCrossEntropyShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn rowSparseCrossEntropyFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: RowSparseCrossEntropy,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape2D(
        lifetime_allocator,
        instance.row_axis,
        instance.rows,
        instance.class_axis,
        instance.classes,
    );
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, instance.row_axis, instance.rows);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.row_axis, instance.rows);

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .loss = .row_sparse_cross_entropy },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.row_axis,
            instance.rows,
            instance.threads,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try rowSparseCrossEntropyShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn rowSparseCrossEntropyInstanceFromSpecialization(
    specialization: entry.Specialization,
) ?RowSparseCrossEntropy {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .loss = .row_sparse_cross_entropy })) return null;
    const dtype = specialization.dtype orelse return null;
    if (!rowSparseCrossEntropyDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const logits = specialization.inputs[0];
    const targets = specialization.inputs[1];
    const losses = specialization.outputs[0];
    if (logits.axes.len != 2 or targets.axes.len != 1 or losses.axes.len != 1) return null;
    const rows = logits.axes[0].extent;
    const classes = logits.axes[1].extent;
    if (targets.axes[0].extent != rows or losses.axes[0].extent != rows) return null;
    if (!std.mem.eql(u8, logits.axes[0].name, targets.axes[0].name)) return null;
    if (!std.mem.eql(u8, logits.axes[0].name, losses.axes[0].name)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    return .{
        .rows = rows,
        .classes = classes,
        .dtype = dtype,
        .threads = launch.threadgroup[0],
        .row_axis = logits.axes[0].name,
        .class_axis = logits.axes[1].name,
    };
}

fn rowSparseCrossEntropyFamilySchedule(
    instance: RowSparseCrossEntropy,
) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn row_sparse_cross_entropy_runtime_body_active(b: anytype, ctx: anytype) !void {
    const classes_extent = try b.castIndex(ctx.args.param(.classes).raw());
    const row_base = try b.mul(ctx.row, classes_extent);
    const one_index = try b.constantIndex(1);

    const first_logit = (try ctx.args.param(.logits).load(b, row_base)).raw();
    const row_max = try b.fold(one_index, classes_extent, one_index, first_logit, .{
        .args = ctx.args,
        .row_base = row_base,
    }, row_sparse_cross_entropy_runtime_body_row_max);

    const zero_index = try b.constantIndex(0);
    const zero_value = try b.constantFloat(ctx.dtype, 0.0);
    const exp_sum = try b.fold(zero_index, classes_extent, one_index, zero_value, .{
        .args = ctx.args,
        .row_base = row_base,
        .row_max = row_max,
    }, row_sparse_cross_entropy_runtime_body_exp_sum);

    const target = try b.castIndex((try ctx.args.param(.targets).load(b, ctx.row)).raw());
    const non_negative = try b.compare(.ge, target, zero_index);
    const in_range = try b.compare(.lt, target, classes_extent);
    const valid = try b.and_(non_negative, in_range);
    const clamped = try b.select(valid, target, zero_index);
    const target_logit = (try ctx.args.param(.logits).load(b, try b.add(row_base, clamped))).raw();
    const target_shifted = try b.select(valid, try b.sub(target_logit, row_max), zero_value);

    const loss = try b.sub(try b.log(exp_sum), target_shifted);
    try ctx.args.param(.losses).store(b, loss, ctx.row);
}

fn row_sparse_cross_entropy_runtime_body_row_max(
    fb: anytype,
    class_index: kernel.Value,
    acc: kernel.Value,
    fold_ctx: anytype,
) !kernel.Value {
    const position = try fb.add(fold_ctx.row_base, class_index);
    const value = (try fold_ctx.args.param(.logits).load(fb, position)).raw();
    return fb.max(acc, value);
}

fn row_sparse_cross_entropy_runtime_body_exp_sum(
    fb: anytype,
    class_index: kernel.Value,
    acc: kernel.Value,
    fold_ctx: anytype,
) !kernel.Value {
    const position = try fb.add(fold_ctx.row_base, class_index);
    const value = (try fold_ctx.args.param(.logits).load(fb, position)).raw();
    const shifted = try fb.sub(value, fold_ctx.row_max);
    return fb.add(acc, try fb.exp(shifted));
}

fn rowSparseCrossEntropyRuntimeBody(k: anytype, spec: RowSparseCrossEntropy, args: anytype) !void {
    const row = try k.globalId(.x);
    const rows_extent = try k.castIndex(args.param(.rows).raw());
    const active = try k.compare(.lt, row, rows_extent);
    try k.guardDo(active, .{
        .args = args,
        .row = row,
        .dtype = spec.dtype,
    }, row_sparse_cross_entropy_runtime_body_active);
}

fn rowSparseCrossEntropyRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_loss_row_sparse_cross_entropy_runtime_{s}",
            .{dtype.name()},
        ),
        .parameters = .{
            .losses = kernel.dynamicBuffer(dtype),
            .logits = kernel.dynamicBuffer(dtype),
            .targets = kernel.dynamicBuffer(.i32),
            .rows = kernel.scalar(.i32),
            .classes = kernel.scalar(.i32),
        },
        .Instance = RowSparseCrossEntropy,
        .schedule = rowSparseCrossEntropyFamilySchedule,
        .body = rowSparseCrossEntropyRuntimeBody,
    });
}

pub const RowSparseCrossEntropyRuntimeFamilyF32 = rowSparseCrossEntropyRuntimeFamily(.f32);

pub fn createRowSparseCrossEntropyFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: RowSparseCrossEntropy,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!rowSparseCrossEntropyInstanceValid(instance)) return error.InvalidKernelLibraryEntry;
    const target = try rowSparseCrossEntropyFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try rowSparseCrossEntropyFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try rowSparseCrossEntropyFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = rowSparseCrossEntropyShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "row_sparse_cross_entropy",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try RowSparseCrossEntropyRuntimeFamilyF32.buildNamed(
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
        .version = row_sparse_cross_entropy_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try rowSparseCrossEntropyDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            2
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn hostRowSparseCrossEntropy(
    rows: usize,
    classes: usize,
    logits: []const f32,
    targets: []const i32,
    losses: []f32,
) void {
    for (0..rows) |row| {
        const row_logits = logits[row * classes ..][0..classes];
        var row_max = row_logits[0];
        for (row_logits) |value| row_max = @max(row_max, value);
        var exp_sum: f32 = 0;
        for (row_logits) |value| exp_sum += @exp(value - row_max);
        const target = targets[row];
        const target_shifted = if (target >= 0 and target < classes)
            row_logits[@intCast(target)] - row_max
        else
            0;
        losses[row] = @log(exp_sum) - target_shifted;
    }
}
