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

pub const Window = struct {
    rows: u64,
    cols: u64,
    radius: u32 = 1,
    dtype: DType = .f32,
    accumulation_dtype: DType = .f32,
    threads: entry.Threads2D = .{},
    row_axis: []const u8 = "r",
    col_axis: []const u8 = "c",
    window_axis: []const u8 = "w",

    pub fn side(self: Window) u64 {
        return 2 * @as(u64, self.radius) + 1;
    }

    pub fn taps(self: Window) u64 {
        return self.side() * self.side();
    }

    pub fn paddedRows(self: Window) u64 {
        return self.rows + 2 * @as(u64, self.radius);
    }

    pub fn paddedCols(self: Window) u64 {
        return self.cols + 2 * @as(u64, self.radius);
    }
};

pub const window_family_version: u32 = 1;
pub const window_radius_max: u32 = 3;
const window_thread_caps = geometry_mod.ThreadCaps{
    .budget = 256,
    .x_max = 64,
    .y_max = 16,
};

pub fn windowAccumulationDType(dtype: DType) ?DType {
    return switch (dtype) {
        .f32, .f16 => .f32,
        else => null,
    };
}

pub fn windowRadiusValid(radius: u32) bool {
    return radius >= 1 and radius <= window_radius_max;
}

fn windowAccumulationZero(inner: anytype, spec: Window) !kernel.Value {
    return switch (spec.accumulation_dtype) {
        .f32 => inner.constantFloat(.f32, 0.0),
        .f16 => inner.constantFloat(.f16, 0.0),
        else => error.UnsupportedDType,
    };
}

fn windowAccumulationValue(inner: anytype, spec: Window, value: anytype) !kernel.Value {
    return switch (spec.accumulation_dtype) {
        .f32 => if (comptime @TypeOf(value).scalar_dtype ==
            .f32) value.raw() else (try value.cast(inner, .f32)).raw(),
        .f16 => if (comptime @TypeOf(value).scalar_dtype ==
            .f16) value.raw() else (try value.cast(inner, .f16)).raw(),
        else => error.UnsupportedDType,
    };
}

fn windowOutputValue(inner: anytype, spec: Window, value: kernel.Value) !kernel.Value {
    if (spec.dtype == spec.accumulation_dtype) return value;
    return switch (spec.dtype) {
        .f32 => inner.cast(value, .f32),
        .f16 => inner.cast(value, .f16),
        else => error.UnsupportedDType,
    };
}

pub fn windowCellSum(
    inner: anytype,
    spec: Window,
    src: anytype,
    weights: anytype,
    row: kernel.Value,
    col: kernel.Value,
    padded_cols: kernel.Value,
) !kernel.Value {
    var acc = try windowAccumulationZero(inner, spec);
    const side_extent = spec.side();
    var dr: u64 = 0;
    while (dr < side_extent) : (dr += 1) {
        var dc: u64 = 0;
        while (dc < side_extent) : (dc += 1) {
            const dr_value = try inner.constantIndex(try indexExtent(dr));
            const dc_value = try inner.constantIndex(try indexExtent(dc));
            const tap_value = try inner.constantIndex(try indexExtent(dr * side_extent + dc));
            const src_row = try inner.add(row, dr_value);
            const src_col = try inner.add(col, dc_value);
            const src_row_offset = try inner.mul(src_row, padded_cols);
            const src_index = try inner.add(src_row_offset, src_col);
            const src_value = try src.load(inner, src_index);
            const weight_value = try weights.load(inner, tap_value);
            const src_acc = try windowAccumulationValue(inner, spec, src_value);
            const weight_acc = try windowAccumulationValue(inner, spec, weight_value);
            const product = try inner.mul(src_acc, weight_acc);
            acc = try inner.add(acc, product);
        }
    }
    return acc;
}

fn window_body_each(inner: anytype, index: kernel.Index2D, ctx: anytype) !void {
    const padded_cols = try inner.constantIndex(try indexExtent(ctx.spec.paddedCols()));
    const cols_stride = try inner.constantIndex(try indexExtent(ctx.spec.cols));
    const sum = try windowCellSum(
        inner,
        ctx.spec,
        ctx.args.param(.src),
        ctx.args.param(.weights),
        index.y.index,
        index.x.index,
        padded_cols,
    );
    const out_row_offset = try inner.mul(index.y.index, cols_stride);
    const out_index = try inner.add(out_row_offset, index.x.index);
    try ctx.args.param(.dst).store(inner, try windowOutputValue(inner, ctx.spec, sum), out_index);
}

fn windowBody(k: anytype, spec: Window, args: anytype) !void {
    _ = try k.forEach2D(.{
        .x = kernel.logical.axis(spec.col_axis, spec.cols),
        .y = kernel.logical.axis(spec.row_axis, spec.rows),
    }, .{ .spec = spec, .args = args }, window_body_each);
}

fn window_runtime_body_row_active(inner: anytype, ctx: anytype) !void {
    const col_active = try inner.compare(.lt, ctx.col, ctx.cols_extent);
    try inner.guardDo(col_active, ctx, window_runtime_body_col_active);
}

fn window_runtime_body_col_active(active_inner: anytype, active_ctx: anytype) !void {
    const sum = try windowCellSum(
        active_inner,
        active_ctx.spec,
        active_ctx.args.param(.src),
        active_ctx.args.param(.weights),
        active_ctx.row,
        active_ctx.col,
        active_ctx.padded_cols,
    );
    const out_row_offset = try active_inner.mul(active_ctx.row, active_ctx.cols_extent);
    const out_index = try active_inner.add(out_row_offset, active_ctx.col);
    try active_ctx.args.param(.dst).store(
        active_inner,
        try windowOutputValue(active_inner, active_ctx.spec, sum),
        out_index,
    );
}

fn windowRuntimeBody(k: anytype, spec: Window, args: anytype) !void {
    const row = try k.globalId(.y);
    const col = try k.globalId(.x);
    const rows_extent = try k.castIndex(args.param(.rows).raw());
    const cols_extent = try k.castIndex(args.param(.cols).raw());
    const halo = try k.constantIndex(try indexExtent(2 * @as(u64, spec.radius)));
    const padded_cols = try k.add(cols_extent, halo);
    const row_active = try k.compare(.lt, row, rows_extent);
    try k.guardDo(row_active, .{
        .args = args,
        .spec = spec,
        .row = row,
        .col = col,
        .cols_extent = cols_extent,
        .padded_cols = padded_cols,
    }, window_runtime_body_row_active);
}

fn windowFamilySchedule(instance: Window) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{
        .x = instance.threads.x,
        .y = instance.threads.y,
    });
}

fn windowFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_stencil_window_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .src = kernel.dynamicBuffer(dtype),
            .weights = kernel.dynamicBuffer(dtype),
        },
        .Instance = Window,
        .schedule = windowFamilySchedule,
        .body = windowBody,
    });
}

fn windowRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_stencil_window_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .src = kernel.dynamicBuffer(dtype),
            .weights = kernel.dynamicBuffer(dtype),
            .rows = kernel.scalar(.i32),
            .cols = kernel.scalar(.i32),
        },
        .Instance = Window,
        .schedule = windowFamilySchedule,
        .body = windowRuntimeBody,
    });
}

pub const WindowFamilyF32 = windowFamily(.f32);
pub const WindowFamilyF16 = windowFamily(.f16);
pub const WindowRuntimeFamilyF32 = windowRuntimeFamily(.f32);
pub const WindowRuntimeFamilyF16 = windowRuntimeFamily(.f16);

pub fn windowThreadsForExtents(rows: u64, cols: u64) entry.Threads2D {
    return geometry_mod.threadsForGrid(.{ .rows = rows, .cols = cols }, window_thread_caps);
}

pub fn windowThreadCandidatesForExtents(rows: u64, cols: u64) geometry_mod.ThreadCandidates {
    return geometry_mod.threadCandidatesForGrid(
        .{ .rows = rows, .cols = cols },
        window_thread_caps,
    );
}

pub fn windowInstanceTarget(allocator: std.mem.Allocator, instance: Window) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.stencil.window{d}x{d}_r{d}_{d}x{d}_{s}",
        .{
            instance.rows,
            instance.cols,
            instance.radius,
            instance.threads.x,
            instance.threads.y,
            instance.dtype.name(),
        },
    );
}

pub fn windowInstanceEntryName(allocator: std.mem.Allocator, instance: Window) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_stencil_window{d}x{d}_r{d}_{d}x{d}_{s}",
        .{
            instance.rows,
            instance.cols,
            instance.radius,
            instance.threads.x,
            instance.threads.y,
            instance.dtype.name(),
        },
    );
}

pub fn windowFamilyTarget(allocator: std.mem.Allocator, instance: Window) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.stencil.window_family_r{d}_{d}x{d}_{s}",
        .{ instance.radius, instance.threads.x, instance.threads.y, instance.dtype.name() },
    );
}

pub fn windowFamilyEntryName(allocator: std.mem.Allocator, instance: Window) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_stencil_window_family_r{d}_{d}x{d}_{s}",
        .{ instance.radius, instance.threads.x, instance.threads.y, instance.dtype.name() },
    );
}

pub fn windowTuningExtents(instance: Window) [3]u64 {
    return .{ instance.rows, instance.cols, instance.radius };
}

pub fn windowTuningOperation(instance: Window) entry.Operation {
    _ = instance;
    return .{ .stencil = .window };
}

pub fn windowFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: Window,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try windowFamilyFingerprint(backing_allocator, instance);
    const extents = windowTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(windowTuningOperation(instance)),
        instance.dtype,
        window_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn windowRuntimeArguments(instance: Window) ![2]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.rows) },
        .{ .u32 = try runtimeExtentArgument(instance.cols) },
    };
}

pub fn windowShapeProfileDimensions(
    instance: Window,
) [2]artifact_product.KernelCallShapeProfileDimension {
    const bounds = windowRuntimeExtentBounds();
    return .{
        .{
            .name = instance.row_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = bounds,
        },
        .{
            .name = instance.col_axis,
            .runtime_scalar_argument_index = 1,
            .bounds = bounds,
        },
    };
}

fn windowRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

fn windowDerivedLaunch(instance: Window) !artifact_product.KernelCallLaunch {
    if (instance.threads.x == 0 or instance.threads.y == 0) {
        return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    }
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 1, .divisor = instance.threads.x } },
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = instance.threads.y } },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads.x, instance.threads.y, 1 },
    } };
}

pub fn createWindowFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: Window,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!windowRadiusValid(instance.radius)) return error.StencilRadiusOutOfRange;
    const target = try windowFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try windowFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try windowFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = windowShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "stencil_window",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try WindowRuntimeFamilyF32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .f16 => try WindowRuntimeFamilyF16.buildNamed(
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
        .version = window_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try windowDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            2
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn windowFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: Window) !u64 {
    var family = try windowShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn windowShapeFamily(backing_allocator: std.mem.Allocator, instance: Window) !shape.Family {
    if (!windowRadiusValid(instance.radius)) return error.StencilRadiusOutOfRange;
    var builder = try shape.Builder.init(backing_allocator, "stencil_window");
    errdefer builder.deinit();

    const rows = try builder.symbol(instance.row_axis);
    const cols = try builder.symbol(instance.col_axis);

    const rows_expr = try builder.symbolExpression(rows);
    const cols_expr = try builder.symbolExpression(cols);
    const halo_expr = builder.constantExpression(@intCast(2 * @as(u64, instance.radius)));
    const padded_rows_expr = try builder.addExpression(rows_expr, halo_expr);
    const padded_cols_expr = try builder.addExpression(cols_expr, halo_expr);
    const taps_expr = builder.constantExpression(try indexExtent(instance.taps()));

    _ = try builder.tensor("src", &.{ padded_rows_expr, padded_cols_expr });
    _ = try builder.tensor("weights", &.{taps_expr});
    _ = try builder.tensor("out", &.{ rows_expr, cols_expr });
    try builder.assumeBounds(rows_expr, windowRuntimeExtentBounds());
    try builder.assumeBounds(cols_expr, windowRuntimeExtentBounds());

    return builder.finish();
}

pub fn windowFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: Window,
) !entry.OwnedSpecialization {
    if (!windowRadiusValid(instance.radius)) return error.StencilRadiusOutOfRange;
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape2D(
        lifetime_allocator,
        instance.row_axis,
        instance.paddedRows(),
        instance.col_axis,
        instance.paddedCols(),
    );
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, instance.window_axis, instance.taps());

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape2D(
        lifetime_allocator,
        instance.row_axis,
        instance.rows,
        instance.col_axis,
        instance.cols,
    );

    const reductions = try lifetime_allocator.alloc(entry.Reduction, 1);
    reductions[0] = try entry.runtimeReduction(
        lifetime_allocator,
        "window",
        .weighted_sum,
        try entry.runtimeShape1D(lifetime_allocator, instance.window_axis, instance.taps()),
    );

    owned.value = .{
        .dtype = instance.dtype,
        .accumulation_dtype = instance.accumulation_dtype,
        .operation = .{ .stencil = .window },
        .inputs = inputs,
        .outputs = outputs,
        .reductions = reductions,
        .schedule = try entry.runtimeThreadBlocks2D(
            lifetime_allocator,
            instance.col_axis,
            instance.cols,
            instance.row_axis,
            instance.rows,
            instance.threads.x,
            instance.threads.y,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try windowShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn windowInstanceFromSpecialization(specialization: entry.Specialization) ?Window {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .stencil = .window })) return null;
    const dtype = specialization.dtype orelse return null;
    const accumulation_dtype = specialization.accumulation_dtype orelse return null;
    if (windowAccumulationDType(dtype) != accumulation_dtype) return null;
    if (specialization.inputs.len !=
        2 or specialization.outputs.len != 1 or specialization.reductions.len != 1) return null;
    const src = specialization.inputs[0];
    const weights = specialization.inputs[1];
    const output = specialization.outputs[0];
    const reduction = specialization.reductions[0];
    if (src.axes.len != 2 or weights.axes.len != 1 or output.axes.len != 2) return null;
    if (reduction.shape.axes.len != 1) return null;
    const rows = output.axes[0].extent;
    const cols = output.axes[1].extent;
    if (src.axes[0].extent <= rows or src.axes[1].extent <= cols) return null;
    const row_halo = src.axes[0].extent - rows;
    const col_halo = src.axes[1].extent - cols;
    if (row_halo != col_halo or row_halo % 2 != 0) return null;
    const radius: u32 = @intCast(row_halo / 2);
    if (!windowRadiusValid(radius)) return null;
    const side = 2 * @as(u64, radius) + 1;
    if (weights.axes[0].extent != side * side) return null;
    if (!std.mem.eql(u8, src.axes[0].name, output.axes[0].name)) return null;
    if (!std.mem.eql(u8, src.axes[1].name, output.axes[1].name)) return null;
    if (!std.mem.eql(u8, reduction.name, "window")) return null;
    if (reduction.operator != .weighted_sum) return null;
    if (reduction.shape.axes[0].extent != side * side) return null;
    if (!std.mem.eql(u8, reduction.shape.axes[0].name, weights.axes[0].name)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0 or launch.threadgroup[1] == 0) return null;
    return .{
        .rows = rows,
        .cols = cols,
        .radius = radius,
        .dtype = dtype,
        .accumulation_dtype = accumulation_dtype,
        .threads = .{ .x = launch.threadgroup[0], .y = launch.threadgroup[1] },
        .row_axis = output.axes[0].name,
        .col_axis = output.axes[1].name,
        .window_axis = weights.axes[0].name,
    };
}

fn windowSpecialization(comptime spec: Window) entry.Specialization {
    return .{
        .dtype = spec.dtype,
        .accumulation_dtype = spec.accumulation_dtype,
        .operation = .{ .stencil = .window },
        .inputs = &.{
            entry.shape2D(spec.row_axis, spec.paddedRows(), spec.col_axis, spec.paddedCols()),
            entry.shape1D(spec.window_axis, spec.taps()),
        },
        .outputs = &.{entry.shape2D(spec.row_axis, spec.rows, spec.col_axis, spec.cols)},
        .reductions = &.{
            entry.reduction("window", .weighted_sum, entry.shape1D(spec.window_axis, spec.taps())),
        },
        .launch = entry.launch2D(spec.cols, spec.rows, spec.threads.x, spec.threads.y),
        .schedule = entry.threadBlocks2D(
            spec.col_axis,
            spec.cols,
            spec.row_axis,
            spec.rows,
            spec.threads.x,
            spec.threads.y,
        ),
    };
}

fn windowProgram(comptime spec: Window) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            try windowBody(k, spec, args);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_stencil_window{}x{}_r{}_{}x{}_{s}",
            .{
                spec.rows,
                spec.cols,
                spec.radius,
                spec.threads.x,
                spec.threads.y,
                spec.dtype.name(),
            },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(spec.dtype),
            .src = kernel.dynamicBuffer(spec.dtype),
            .weights = kernel.dynamicBuffer(spec.dtype),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{
        .x = spec.threads.x,
        .y = spec.threads.y,
    }));
}

pub fn windowF32(comptime spec: Window) type {
    if (!windowRadiusValid(spec.radius)) {
        @compileError("kernel library stencil window radius out of range");
    }
    return entry.Entry(windowProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.stencil.window{}x{}_r{}_{}x{}_{s}",
            .{
                spec.rows,
                spec.cols,
                spec.radius,
                spec.threads.x,
                spec.threads.y,
                spec.dtype.name(),
            },
        ),
        .layer = .logical,
        .category = .stencil,
        .specialization = windowSpecialization(spec),
    });
}

pub const Window2x3R1F32 = windowF32(
    .{ .rows = 2, .cols = 3, .radius = 1, .threads = .{ .x = 3, .y = 2 } },
);

fn stencilFamilyTuningTestCapabilities(device_id: u32) gpu.BackendCapabilities {
    return .{ .identity = .{
        .backend = .cuda,
        .family = .nvidia_cuda,
        .name = "stencil-family-tuning-test-device",
        .vendor_id = 0x10de,
        .device_id = device_id,
    } };
}

fn testPaddedInput(comptime count: usize) [count]f32 {
    var values: [count]f32 = undefined;
    for (&values, 0..) |*value, index| value.* = @floatFromInt(index);
    return values;
}

test "stencil window entry runs on CPU" {
    var src = testPaddedInput(20);
    var identity_weights = [_]f32{ 0, 0, 0, 0, 1, 0, 0, 0, 0 };
    var dst = @as([6]f32, @splat(0.0));

    try Window2x3R1F32.runCpu(std.testing.allocator, Window2x3R1F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentBuffer(f32, identity_weights[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 6.0, 7.0, 8.0, 11.0, 12.0, 13.0 }, dst[0..]);

    var mixed_weights = [_]f32{ 1, 0, 0, 0, 2, 0, 0, 0, 3 };
    var mixed_dst = @as([6]f32, @splat(0.0));
    try Window2x3R1F32.runCpu(std.testing.allocator, Window2x3R1F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, mixed_dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentBuffer(f32, mixed_weights[0..]),
    });
    try std.testing.expectEqualSlices(
        f32,
        &.{ 48.0, 54.0, 60.0, 78.0, 84.0, 90.0 },
        mixed_dst[0..],
    );
}

test "stencil window runtime family executes explicit runtime extents" {
    const allocator = std.testing.allocator;
    const compiled = Window{ .rows = 1, .cols = 1, .radius = 1, .threads = .{ .x = 4, .y = 2 } };
    const runtime = Window{ .rows = 2, .cols = 3, .radius = 1, .threads = compiled.threads };

    var graph = try WindowRuntimeFamilyF32.build(
        allocator,
        WindowRuntimeFamilyF32.Limits.testing,
        compiled,
    );
    defer graph.deinit();

    var src = testPaddedInput(20);
    var weights = [_]f32{ 1, 0, 0, 0, 2, 0, 0, 0, 3 };
    var dst = @as([6]f32, @splat(0.0));

    const launch_value = try entry.runtimeLaunch2D(
        runtime.cols,
        runtime.rows,
        runtime.threads.x,
        runtime.threads.y,
    );
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentBuffer(f32, weights[0..]),
        kernel.argumentI32(@intCast(runtime.rows)),
        kernel.argumentI32(@intCast(runtime.cols)),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });
    try std.testing.expectEqualSlices(f32, &.{ 48.0, 54.0, 60.0, 78.0, 84.0, 90.0 }, dst[0..]);
}

test "stencil window thread candidates stay legal for output grids" {
    const candidates = windowThreadCandidatesForExtents(17, 17);
    try std.testing.expect(candidates.count > 1);
    for (candidates.slice(), 0..) |candidate, index| {
        try std.testing.expect(candidate.x != 0);
        try std.testing.expect(candidate.y != 0);
        try std.testing.expect(candidate.x * candidate.y <= window_thread_caps.budget);
        for (candidates.slice()[0..index]) |previous| {
            try std.testing.expect(!geometry_mod.threadCandidatesEqual(previous, candidate));
        }
    }
    try std.testing.expect(
        geometry_mod.threadCandidatesEqual(candidates.items[0], windowThreadsForExtents(17, 17)),
    );
}

test "stencil window family instance identity matches fixed entry strings" {
    const instance = Window{ .rows = 2, .cols = 3, .radius = 1, .threads = .{ .x = 3, .y = 2 } };

    const target = try windowInstanceTarget(std.testing.allocator, instance);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings(Window2x3R1F32.target, target);

    const entry_name = try windowInstanceEntryName(std.testing.allocator, instance);
    defer std.testing.allocator.free(entry_name);
    try std.testing.expectEqualStrings(Window2x3R1F32.name, entry_name);

    try std.testing.expectEqual(Window2x3R1F32.version, window_family_version);

    const fresh = Window{ .rows = 64, .cols = 96, .radius = 2, .threads = .{ .x = 8, .y = 4 } };
    const fresh_target = try windowInstanceTarget(std.testing.allocator, fresh);
    defer std.testing.allocator.free(fresh_target);
    try std.testing.expectEqualStrings("accy.kernel.stencil.window64x96_r2_8x4_f32", fresh_target);

    const family_target = try windowFamilyTarget(std.testing.allocator, fresh);
    defer std.testing.allocator.free(family_target);
    try std.testing.expectEqualStrings(
        "accy.kernel.stencil.window_family_r2_8x4_f32",
        family_target,
    );

    const family_entry = try windowFamilyEntryName(std.testing.allocator, fresh);
    defer std.testing.allocator.free(family_entry);
    try std.testing.expectEqualStrings(
        "accy_kernel_stencil_window_family_r2_8x4_f32",
        family_entry,
    );

    const fresh_f16 = Window{
        .rows = 64,
        .cols = 96,
        .radius = 2,
        .dtype = .f16,
        .threads = .{ .x = 8, .y = 4 },
    };
    const family_f16_target = try windowFamilyTarget(std.testing.allocator, fresh_f16);
    defer std.testing.allocator.free(family_f16_target);
    try std.testing.expectEqualStrings(
        "accy.kernel.stencil.window_family_r2_8x4_f16",
        family_f16_target,
    );
}

test "stencil window family tuning keys discriminate dtype radius and device" {
    const allocator = std.testing.allocator;
    const device = tuning.deviceFingerprint(stencilFamilyTuningTestCapabilities(0x2684));

    const base = try windowFamilyTuningKey(allocator, device, .{ .rows = 8, .cols = 8 });
    const half = try windowFamilyTuningKey(
        allocator,
        device,
        .{ .rows = 8, .cols = 8, .dtype = .f16, .accumulation_dtype = .f32 },
    );
    try std.testing.expect(!base.eql(half));
    try std.testing.expectEqual(base.family_fingerprint, half.family_fingerprint);
    try std.testing.expectEqual(base.operation_fingerprint, half.operation_fingerprint);

    const wider = try windowFamilyTuningKey(
        allocator,
        device,
        .{ .rows = 8, .cols = 8, .radius = 2 },
    );
    try std.testing.expect(!base.eql(wider));
    try std.testing.expect(base.family_fingerprint != wider.family_fingerprint);
    try std.testing.expectEqual(base.operation_fingerprint, wider.operation_fingerprint);

    const other_device = try windowFamilyTuningKey(
        allocator,
        tuning.deviceFingerprint(stencilFamilyTuningTestCapabilities(0x1b80)),
        .{ .rows = 8, .cols = 8 },
    );
    try std.testing.expect(!base.eql(other_device));
    try std.testing.expectEqual(base.family_fingerprint, other_device.family_fingerprint);
    try std.testing.expectEqual(base.operation_fingerprint, other_device.operation_fingerprint);
}

test "stencil window family artifact carries runtime launch contract" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = Window{ .rows = 2, .cols = 3, .radius = 1, .threads = .{ .x = 3, .y = 2 } };

    var family_artifact = try createWindowFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer family_artifact.deinit();
    var fixed_artifact = try Window2x3R1F32.createKernelCallArtifact(allocator, state.handle(), .{
        .limits = Window2x3R1F32.Limits.testing,
    });
    defer fixed_artifact.deinit();

    const family_entry = family_artifact.entry();
    const fixed_entry = fixed_artifact.entry();
    try std.testing.expect(!std.mem.eql(u8, fixed_entry.target, family_entry.target));
    try std.testing.expectEqual(fixed_entry.version, family_entry.version);
    try std.testing.expectEqual(fixed_entry.format, family_entry.format);
    try std.testing.expectEqualStrings(
        "accy.kernel.stencil.window_family_r1_3x2_f32",
        family_entry.target,
    );
    try std.testing.expectEqualStrings(
        "accy_kernel_stencil_window_family_r1_3x2_f32",
        family_entry.entry_name,
    );
    try std.testing.expectEqual(@as(u32, 5), family_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 2), family_entry.runtime_scalar_argument_count);
    try std.testing.expect(family_entry.required_dtypes.contains(.i32));
    try std.testing.expect(fixed_entry.shape_family_fingerprint == null);
    try std.testing.expect(family_entry.shape_family_fingerprint != null);
    const profile = family_entry.shape_profile orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("stencil_window", profile.name);
    try std.testing.expectEqual(family_entry.shape_family_fingerprint.?, profile.fingerprint);
    try std.testing.expectEqual(@as(usize, 2), profile.dimensions.len);
    const rows_dimension = profile.runtimeScalarDimension(0) orelse
        return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("r", rows_dimension.name);
    try std.testing.expectEqual(
        @as(?u64, extent_mod.runtime_extent_max),
        rows_dimension.bounds.max,
    );
    switch (family_entry.launch) {
        .derived => |launch| {
            try std.testing.expectEqual(@as(u32, 3), launch.threadgroup[0]);
            try std.testing.expectEqual(@as(u32, 2), launch.threadgroup[1]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |term| {
                    try std.testing.expectEqual(@as(usize, 1), term.argument_index);
                    try std.testing.expectEqual(@as(u32, 3), term.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
            switch (launch.grid[1]) {
                .runtime_u32_ceil_div => |term| {
                    try std.testing.expectEqual(@as(usize, 0), term.argument_index);
                    try std.testing.expectEqual(@as(u32, 2), term.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
        },
        else => return error.TestExpectedDerivedLaunch,
    }
}

test "stencil window family records fixed-entry specialization metadata" {
    const instance = Window{ .rows = 2, .cols = 3, .radius = 1, .threads = .{ .x = 3, .y = 2 } };
    var owned = try windowFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const specialization = owned.value;

    try std.testing.expect(specialization.operationIs(.{ .stencil = .window }));
    try std.testing.expectEqual(Window2x3R1F32.specialization.dtype, specialization.dtype);
    try std.testing.expect(specialization.inputHasExtents(0, &.{ 4, 5 }));
    try std.testing.expect(specialization.inputHasExtents(1, &.{9}));
    try std.testing.expect(specialization.outputHasExtents(0, &.{ 2, 3 }));
    try std.testing.expect(specialization.reductionMatches(0, .{
        .name = "window",
        .operator = .weighted_sum,
        .extents = &.{9},
    }));
    try std.testing.expect(specialization.scheduleMatchesLaunch());
    try std.testing.expect(specialization.shape_family != null);
}

test "stencil window instance round-trips through specialization" {
    const instance = Window{ .rows = 6, .cols = 9, .radius = 2, .threads = .{ .x = 9, .y = 6 } };
    var owned = try windowFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();

    const recovered = windowInstanceFromSpecialization(owned.value) orelse
        return error.TestExpectedWindowInstance;
    try std.testing.expectEqual(instance.rows, recovered.rows);
    try std.testing.expectEqual(instance.cols, recovered.cols);
    try std.testing.expectEqual(instance.radius, recovered.radius);
    try std.testing.expectEqual(instance.dtype, recovered.dtype);
    try std.testing.expectEqual(instance.accumulation_dtype, recovered.accumulation_dtype);
    try std.testing.expectEqual(instance.threads.x, recovered.threads.x);
    try std.testing.expectEqual(instance.threads.y, recovered.threads.y);

    try std.testing.expectEqual(@as(?Window, null), windowInstanceFromSpecialization(.{}));
}

test "stencil window family rejects out-of-range radii" {
    const oversized = Window{
        .rows = 4,
        .cols = 4,
        .radius = window_radius_max + 1,
        .threads = .{ .x = 4, .y = 4 },
    };
    try std.testing.expectError(
        error.StencilRadiusOutOfRange,
        windowFamilySpecialization(std.testing.allocator, oversized),
    );
    try std.testing.expectError(
        error.StencilRadiusOutOfRange,
        windowShapeFamily(std.testing.allocator, oversized),
    );

    const zero_radius = Window{ .rows = 4, .cols = 4, .radius = 0, .threads = .{ .x = 4, .y = 4 } };
    try std.testing.expectError(
        error.StencilRadiusOutOfRange,
        windowFamilySpecialization(std.testing.allocator, zero_radius),
    );
}
