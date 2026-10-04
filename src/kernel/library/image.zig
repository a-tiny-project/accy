const std = @import("std");
const gpu_abi = @import("gpu_abi");

const artifact_product = @import("../../artifact/model/root.zig");
const shape = @import("../../choir/shape/root.zig");
const entry = @import("entry.zig");
const extent_mod = @import("extent.zig");
const geometry_mod = @import("geometry.zig");
const kernel = @import("../root.zig");

pub const blur_family_version: u32 = 1;
pub const resize_family_version: u32 = 1;
pub const blur_radius_max: u32 = 15;
pub const image_thread_caps = geometry_mod.ThreadCaps{
    .budget = 256,
    .x_max = 64,
    .y_max = 16,
};

pub const Axis = enum {
    horizontal,
    vertical,

    pub fn name(self: Axis) []const u8 {
        return switch (self) {
            .horizontal => "h",
            .vertical => "v",
        };
    }
};

pub const BlurPass = struct {
    radius: u32,
    axis: Axis,
    width: u64 = 1,
    height: u64 = 1,
    threads: entry.Threads2D = .{ .x = 16, .y = 16 },

    pub fn taps(self: BlurPass) u32 {
        return self.radius * 2 + 1;
    }
};

pub const Resize = struct {
    dst_width: u64 = 1,
    dst_height: u64 = 1,
    src_width: u64 = 1,
    src_height: u64 = 1,
    threads: entry.Threads2D = .{ .x = 16, .y = 16 },
};

pub fn imageExtentValid(extent: u64) bool {
    return extent >= 1 and extent <= extent_mod.runtime_extent_max;
}

pub fn imageThreadsForExtents(width: u64, height: u64) entry.Threads2D {
    return geometry_mod.threadsForGrid(.{ .rows = height, .cols = width }, image_thread_caps);
}

pub fn imageThreadCandidatesForExtents(width: u64, height: u64) geometry_mod.ThreadCandidates {
    return geometry_mod.threadCandidatesForGrid(
        .{ .rows = height, .cols = width },
        image_thread_caps,
    );
}

pub fn blurPassInstanceValid(instance: BlurPass) bool {
    if (instance.radius == 0 or instance.radius > blur_radius_max) return false;
    if (!imageExtentValid(instance.width) or !imageExtentValid(instance.height)) return false;
    if (instance.threads.x == 0 or instance.threads.y == 0) return false;
    return true;
}

pub fn resizeInstanceValid(instance: Resize) bool {
    if (!imageExtentValid(instance.dst_width) or !imageExtentValid(instance.dst_height)) {
        return false;
    }
    if (!imageExtentValid(instance.src_width) or !imageExtentValid(instance.src_height)) {
        return false;
    }
    if (instance.threads.x == 0 or instance.threads.y == 0) return false;
    return true;
}

pub fn gaussianWeightsAlloc(allocator: std.mem.Allocator, radius: u32, sigma: f32) ![]f32 {
    if (radius == 0 or radius > blur_radius_max) return error.UnsupportedBlurRadius;
    if (!(sigma > 0)) return error.UnsupportedBlurSigma;
    const taps = radius * 2 + 1;
    const weights = try allocator.alloc(f32, taps);
    errdefer allocator.free(weights);
    _ = try gaussianWeights(weights, radius, sigma);
    return weights;
}

pub fn gaussianWeights(out: []f32, radius: u32, sigma: f32) ![]f32 {
    if (radius == 0 or radius > blur_radius_max) return error.UnsupportedBlurRadius;
    if (!(sigma > 0)) return error.UnsupportedBlurSigma;
    const taps = radius * 2 + 1;
    if (out.len < taps) return error.BufferTooSmall;
    const weights = out[0..taps];
    var total: f32 = 0;
    for (weights, 0..) |*weight, tap| {
        const offset = @as(f32, @floatFromInt(@as(i64, @intCast(tap)) - @as(i64, radius)));
        const value = @exp(-(offset * offset) / (2 * sigma * sigma));
        weight.* = value;
        total += value;
    }
    for (weights) |*weight| weight.* /= total;
    return weights;
}

const Channels = struct {
    r: kernel.Value,
    g: kernel.Value,
    b: kernel.Value,
    a: kernel.Value,
};

fn unpackChannels(inner: anytype, pixel: kernel.Value) !Channels {
    const mask = try inner.constantInt(.u32, 0xff);
    return .{
        .r = try inner.cast(try inner.and_(pixel, mask), .f32),
        .g = try inner.cast(
            try inner.and_(try inner.ushr(pixel, try inner.constantInt(.u32, 8)), mask),
            .f32,
        ),
        .b = try inner.cast(
            try inner.and_(try inner.ushr(pixel, try inner.constantInt(.u32, 16)), mask),
            .f32,
        ),
        .a = try inner.cast(try inner.ushr(pixel, try inner.constantInt(.u32, 24)), .f32),
    };
}

fn packChannel(inner: anytype, value: kernel.Value) !kernel.Value {
    const zero = try inner.constantFloat(.f32, 0);
    const limit = try inner.constantFloat(.f32, 255);
    const half = try inner.constantFloat(.f32, 0.5);
    const rounded = try inner.floor(try inner.add(value, half));
    const clamped = try inner.min(try inner.max(rounded, zero), limit);
    return inner.cast(clamped, .u32);
}

fn packChannels(inner: anytype, channels: Channels) !kernel.Value {
    const r = try packChannel(inner, channels.r);
    const g = try packChannel(inner, channels.g);
    const b = try packChannel(inner, channels.b);
    const a = try packChannel(inner, channels.a);
    return inner.or_(
        try inner.or_(r, try inner.shl(g, try inner.constantInt(.u32, 8))),
        try inner.or_(
            try inner.shl(b, try inner.constantInt(.u32, 16)),
            try inner.shl(a, try inner.constantInt(.u32, 24)),
        ),
    );
}

fn blur_pass_body_active(inner: anytype, ctx: anytype) !void {
    const zero_i32 = try inner.constantInt(.i32, 0);
    const axis_extent = switch (ctx.spec.axis) {
        .horizontal => ctx.width,
        .vertical => ctx.height,
    };
    const axis_base = switch (ctx.spec.axis) {
        .horizontal => ctx.col,
        .vertical => ctx.row,
    };
    const axis_last = try inner.sub(
        try inner.cast(axis_extent, .i32),
        try inner.constantInt(.i32, 1),
    );
    const base_i32 = try inner.cast(axis_base, .i32);

    var acc = Channels{
        .r = try inner.constantFloat(.f32, 0),
        .g = try inner.constantFloat(.f32, 0),
        .b = try inner.constantFloat(.f32, 0),
        .a = try inner.constantFloat(.f32, 0),
    };
    const tap_count = ctx.spec.taps();
    var tap: u32 = 0;
    while (tap < tap_count) : (tap += 1) {
        const offset = @as(i64, tap) - @as(i64, ctx.spec.radius);
        const offset_value = try inner.constantInt(.i32, offset);
        const sample_raw = try inner.add(base_i32, offset_value);
        const sample_clamped = try inner.min(try inner.max(sample_raw, zero_i32), axis_last);
        const sample_index = try inner.castIndex(sample_clamped);
        const pixel_index = switch (ctx.spec.axis) {
            .horizontal => try inner.add(try inner.mul(ctx.row, ctx.width), sample_index),
            .vertical => try inner.add(try inner.mul(sample_index, ctx.width), ctx.col),
        };
        const pixel = (try ctx.args.param(.src).load(inner, pixel_index)).raw();
        const weight = (try ctx.args.param(
            .weights,
        ).load(inner, try inner.constantIndex(tap))).raw();
        const channels = try unpackChannels(inner, pixel);
        acc = .{
            .r = try inner.fma(channels.r, weight, acc.r),
            .g = try inner.fma(channels.g, weight, acc.g),
            .b = try inner.fma(channels.b, weight, acc.b),
            .a = try inner.fma(channels.a, weight, acc.a),
        };
    }
    const out_index = try inner.add(try inner.mul(ctx.row, ctx.width), ctx.col);
    try ctx.args.param(.dst).store(inner, try packChannels(inner, acc), out_index);
}

fn blurPassBody(k: anytype, spec: BlurPass, args: anytype) !void {
    if (!blurPassInstanceValid(spec)) return error.UnsupportedBlurPassInstance;
    const col = try k.globalId(.x);
    const row = try k.globalId(.y);
    const width = try k.castIndex(args.param(.width).raw());
    const height = try k.castIndex(args.param(.height).raw());
    const col_active = try k.compare(.lt, col, width);
    const row_active = try k.compare(.lt, row, height);
    const active = try k.and_(col_active, row_active);
    try k.guardDo(active, .{
        .args = args,
        .spec = spec,
        .col = col,
        .row = row,
        .width = width,
        .height = height,
    }, blur_pass_body_active);
}

fn blurPassSchedule(instance: BlurPass) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{
        .x = instance.threads.x,
        .y = instance.threads.y,
    });
}

fn blurPassFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_image_blur_pass_rgba8",
        .parameters = .{
            .dst = kernel.dynamicBuffer(.u32),
            .src = kernel.dynamicBuffer(.u32),
            .weights = kernel.dynamicBuffer(.f32),
            .width = kernel.scalar(.i32),
            .height = kernel.scalar(.i32),
        },
        .Instance = BlurPass,
        .schedule = blurPassSchedule,
        .body = blurPassBody,
    });
}

pub const BlurPassFamilyRgba8 = blurPassFamily();

fn resize_body_active(inner: anytype, ctx: anytype) !void {
    const sample_x = try sampleAxis(
        inner,
        ctx.col,
        ctx.args.param(.scale_x).raw(),
        ctx.args.param(.src_last_x).raw(),
    );
    const sample_y = try sampleAxis(
        inner,
        ctx.row,
        ctx.args.param(.scale_y).raw(),
        ctx.args.param(.src_last_y).raw(),
    );
    const src_width_index = try inner.castIndex(ctx.args.param(.src_width).raw());

    const row0_base = try inner.mul(sample_y.lo, src_width_index);
    const row1_base = try inner.mul(sample_y.hi, src_width_index);
    const p00 = try unpackChannels(
        inner,
        (try ctx.args.param(.src).load(inner, try inner.add(row0_base, sample_x.lo))).raw(),
    );
    const p01 = try unpackChannels(
        inner,
        (try ctx.args.param(.src).load(inner, try inner.add(row0_base, sample_x.hi))).raw(),
    );
    const p10 = try unpackChannels(
        inner,
        (try ctx.args.param(.src).load(inner, try inner.add(row1_base, sample_x.lo))).raw(),
    );
    const p11 = try unpackChannels(
        inner,
        (try ctx.args.param(.src).load(inner, try inner.add(row1_base, sample_x.hi))).raw(),
    );

    const top = try lerpChannels(inner, p00, p01, sample_x.frac);
    const bottom = try lerpChannels(inner, p10, p11, sample_x.frac);
    const blended = try lerpChannels(inner, top, bottom, sample_y.frac);

    const out_index = try inner.add(try inner.mul(ctx.row, ctx.dst_width), ctx.col);
    try ctx.args.param(.dst).store(inner, try packChannels(inner, blended), out_index);
}

fn resizeBody(k: anytype, spec: Resize, args: anytype) !void {
    if (!resizeInstanceValid(spec)) return error.UnsupportedResizeInstance;
    const col = try k.globalId(.x);
    const row = try k.globalId(.y);
    const dst_width = try k.castIndex(args.param(.dst_width).raw());
    const dst_height = try k.castIndex(args.param(.dst_height).raw());
    const col_active = try k.compare(.lt, col, dst_width);
    const row_active = try k.compare(.lt, row, dst_height);
    const active = try k.and_(col_active, row_active);
    try k.guardDo(active, .{
        .args = args,
        .col = col,
        .row = row,
        .dst_width = dst_width,
    }, resize_body_active);
}

const AxisSample = struct {
    lo: kernel.Value,
    hi: kernel.Value,
    frac: kernel.Value,
};

fn sampleAxis(
    inner: anytype,
    dst_index: kernel.Value,
    scale: kernel.Value,
    last: kernel.Value,
) !AxisSample {
    const zero = try inner.constantFloat(.f32, 0);
    const half = try inner.constantFloat(.f32, 0.5);
    const one = try inner.constantFloat(.f32, 1);
    const negative_half = try inner.constantFloat(.f32, -0.5);
    const centered = try inner.fma(try inner.add(
        try inner.cast(try inner.cast(dst_index, .u32), .f32),
        half,
    ), scale, negative_half);
    const clamped = try inner.min(try inner.max(centered, zero), last);
    const lo_f = try inner.floor(clamped);
    const frac = try inner.sub(clamped, lo_f);
    const lo_u32 = try inner.cast(lo_f, .u32);
    const lo = try inner.castIndex(lo_u32);
    const hi_f = try inner.min(try inner.add(lo_f, one), last);
    const hi = try inner.castIndex(try inner.cast(hi_f, .u32));
    return .{ .lo = lo, .hi = hi, .frac = frac };
}

fn lerpChannels(inner: anytype, from: Channels, to: Channels, t: kernel.Value) !Channels {
    return .{
        .r = try lerp(inner, from.r, to.r, t),
        .g = try lerp(inner, from.g, to.g, t),
        .b = try lerp(inner, from.b, to.b, t),
        .a = try lerp(inner, from.a, to.a, t),
    };
}

fn lerp(inner: anytype, from: kernel.Value, to: kernel.Value, t: kernel.Value) !kernel.Value {
    return inner.fma(try inner.sub(to, from), t, from);
}

fn resizeSchedule(instance: Resize) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{
        .x = instance.threads.x,
        .y = instance.threads.y,
    });
}

fn resizeFamily() type {
    return kernel.logical.Family(.{
        .name = "accy_kernel_image_resize_bilinear_rgba8",
        .parameters = .{
            .dst = kernel.dynamicBuffer(.u32),
            .src = kernel.dynamicBuffer(.u32),
            .dst_width = kernel.scalar(.i32),
            .dst_height = kernel.scalar(.i32),
            .src_width = kernel.scalar(.i32),
            .scale_x = kernel.scalar(.f32),
            .scale_y = kernel.scalar(.f32),
            .src_last_x = kernel.scalar(.f32),
            .src_last_y = kernel.scalar(.f32),
        },
        .Instance = Resize,
        .schedule = resizeSchedule,
        .body = resizeBody,
    });
}

pub const ResizeBilinearFamilyRgba8 = resizeFamily();

pub fn blurPassFamilyTarget(allocator: std.mem.Allocator, instance: BlurPass) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "image_blur_pass_family_r{d}{s}_{d}x{d}_rgba8",
        .{ instance.radius, instance.axis.name(), instance.threads.x, instance.threads.y },
    );
}

pub fn blurPassFamilyEntryName(allocator: std.mem.Allocator, instance: BlurPass) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_image_blur_pass_r{d}{s}_rgba8",
        .{ instance.radius, instance.axis.name() },
    );
}

pub fn resizeFamilyTarget(allocator: std.mem.Allocator, instance: Resize) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "image_resize_bilinear_family_{d}x{d}_rgba8",
        .{ instance.threads.x, instance.threads.y },
    );
}

pub fn resizeFamilyEntryName(allocator: std.mem.Allocator, instance: Resize) ![]u8 {
    _ = instance;
    return allocator.dupe(u8, "accy_image_resize_bilinear_rgba8");
}

pub fn blurPassRuntimeArguments(width: u32, height: u32) ![2]gpu_abi.ScalarArgument {
    if (width == 0 or height == 0) return error.UnsupportedImageExtent;
    if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) {
        return error.UnsupportedImageExtent;
    }
    return .{
        .{ .i32 = @intCast(width) },
        .{ .i32 = @intCast(height) },
    };
}

pub fn resizeScale(src_extent: u32, dst_extent: u32) f32 {
    return @as(f32, @floatFromInt(src_extent)) / @as(f32, @floatFromInt(dst_extent));
}

pub fn resizeRuntimeArguments(
    dst_width: u32,
    dst_height: u32,
    src_width: u32,
    src_height: u32,
) ![7]gpu_abi.ScalarArgument {
    if (dst_width == 0 or dst_height == 0 or src_width == 0 or src_height == 0) {
        return error.UnsupportedImageExtent;
    }
    if (dst_width > std.math.maxInt(i32) or dst_height > std.math.maxInt(i32)) {
        return error.UnsupportedImageExtent;
    }
    if (src_width > std.math.maxInt(i32) or src_height > std.math.maxInt(i32)) {
        return error.UnsupportedImageExtent;
    }
    return .{
        .{ .i32 = @intCast(dst_width) },
        .{ .i32 = @intCast(dst_height) },
        .{ .i32 = @intCast(src_width) },
        .{ .f32 = resizeScale(src_width, dst_width) },
        .{ .f32 = resizeScale(src_height, dst_height) },
        .{ .f32 = @floatFromInt(src_width - 1) },
        .{ .f32 = @floatFromInt(src_height - 1) },
    };
}

pub fn imageLaunchGeometry(
    instance_threads: entry.Threads2D,
    width: u32,
    height: u32,
) gpu_abi.LaunchGeometry {
    return .{
        .grid = .{
            (width + instance_threads.x - 1) / instance_threads.x,
            (height + instance_threads.y - 1) / instance_threads.y,
            1,
        },
        .threadgroup = .{ instance_threads.x, instance_threads.y, 1 },
    };
}

pub fn blurPassAxisParameter(axis: Axis) u64 {
    return switch (axis) {
        .horizontal => 0,
        .vertical => 1,
    };
}

pub fn blurPassShapeProfileDimensions(
    instance: BlurPass,
) [2]artifact_product.KernelCallShapeProfileDimension {
    _ = instance;
    const bounds = imageRuntimeExtentBounds();
    return .{
        .{
            .name = "x",
            .runtime_scalar_argument_index = 0,
            .bounds = bounds,
        },
        .{
            .name = "y",
            .runtime_scalar_argument_index = 1,
            .bounds = bounds,
        },
    };
}

pub fn resizeShapeProfileDimensions(
    instance: Resize,
) [3]artifact_product.KernelCallShapeProfileDimension {
    _ = instance;
    const bounds = imageRuntimeExtentBounds();
    return .{
        .{
            .name = "dst_x",
            .runtime_scalar_argument_index = 0,
            .bounds = bounds,
        },
        .{
            .name = "dst_y",
            .runtime_scalar_argument_index = 1,
            .bounds = bounds,
        },
        .{
            .name = "src_x",
            .runtime_scalar_argument_index = 2,
            .bounds = bounds,
        },
    };
}

fn imageRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

fn imageDerivedLaunch(threads: entry.Threads2D) !artifact_product.KernelCallLaunch {
    if (threads.x == 0 or threads.y == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = threads.x } },
            .{ .runtime_u32_ceil_div = .{ .argument_index = 1, .divisor = threads.y } },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ threads.x, threads.y, 1 },
    } };
}

pub fn blurPassShapeFamily(backing_allocator: std.mem.Allocator, instance: BlurPass) !shape.Family {
    if (!blurPassInstanceValid(instance)) return error.UnsupportedBlurPassInstance;
    var builder = try shape.Builder.init(backing_allocator, "image_blur_pass");
    errdefer builder.deinit();

    const y = try builder.symbol("y");
    const x = try builder.symbol("x");
    const y_expr = try builder.symbolExpression(y);
    const x_expr = try builder.symbolExpression(x);
    const taps_expr = builder.constantExpression(@intCast(instance.taps()));

    _ = try builder.tensor("src", &.{ y_expr, x_expr });
    _ = try builder.tensor("weights", &.{taps_expr});
    _ = try builder.tensor("out", &.{ y_expr, x_expr });
    try builder.assumeBounds(y_expr, imageRuntimeExtentBounds());
    try builder.assumeBounds(x_expr, imageRuntimeExtentBounds());

    return builder.finish();
}

pub fn resizeShapeFamily(backing_allocator: std.mem.Allocator, instance: Resize) !shape.Family {
    if (!resizeInstanceValid(instance)) return error.UnsupportedResizeInstance;
    var builder = try shape.Builder.init(backing_allocator, "image_resize_bilinear");
    errdefer builder.deinit();

    const dst_y = try builder.symbol("dst_y");
    const dst_x = try builder.symbol("dst_x");
    const src_y = try builder.symbol("src_y");
    const src_x = try builder.symbol("src_x");
    const dst_y_expr = try builder.symbolExpression(dst_y);
    const dst_x_expr = try builder.symbolExpression(dst_x);
    const src_y_expr = try builder.symbolExpression(src_y);
    const src_x_expr = try builder.symbolExpression(src_x);

    _ = try builder.tensor("src", &.{ src_y_expr, src_x_expr });
    _ = try builder.tensor("out", &.{ dst_y_expr, dst_x_expr });
    try builder.assumeBounds(dst_y_expr, imageRuntimeExtentBounds());
    try builder.assumeBounds(dst_x_expr, imageRuntimeExtentBounds());
    try builder.assumeBounds(src_y_expr, imageRuntimeExtentBounds());
    try builder.assumeBounds(src_x_expr, imageRuntimeExtentBounds());

    return builder.finish();
}

pub fn blurPassFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: BlurPass) !u64 {
    var family = try blurPassShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn resizeFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: Resize) !u64 {
    var family = try resizeShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn blurPassFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: BlurPass,
) !entry.OwnedSpecialization {
    if (!blurPassInstanceValid(instance)) return error.UnsupportedBlurPassInstance;
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape2D(
        lifetime_allocator,
        "y",
        instance.height,
        "x",
        instance.width,
    );
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, "tap", instance.taps());

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape2D(
        lifetime_allocator,
        "y",
        instance.height,
        "x",
        instance.width,
    );

    const reductions = try lifetime_allocator.alloc(entry.Reduction, 1);
    reductions[0] = try entry.runtimeReduction(
        lifetime_allocator,
        "blur_tap",
        .weighted_sum,
        try entry.runtimeShape1D(lifetime_allocator, "tap", instance.taps()),
    );

    const static_parameters = try lifetime_allocator.alloc(entry.StaticParameter, 2);
    static_parameters[0] = try entry.runtimeStaticParameter(
        lifetime_allocator,
        "radius",
        instance.radius,
    );
    static_parameters[1] = try entry.runtimeStaticParameter(
        lifetime_allocator,
        "axis",
        blurPassAxisParameter(instance.axis),
    );

    owned.value = .{
        .dtype = .u32,
        .accumulation_dtype = .f32,
        .operation = .{ .image = .blur_pass },
        .inputs = inputs,
        .outputs = outputs,
        .reductions = reductions,
        .static_parameters = static_parameters,
        .schedule = try entry.runtimeThreadBlocks2D(
            lifetime_allocator,
            "x",
            instance.width,
            "y",
            instance.height,
            instance.threads.x,
            instance.threads.y,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try blurPassShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn resizeFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: Resize,
) !entry.OwnedSpecialization {
    if (!resizeInstanceValid(instance)) return error.UnsupportedResizeInstance;
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 1);
    inputs[0] = try entry.runtimeShape2D(
        lifetime_allocator,
        "src_y",
        instance.src_height,
        "src_x",
        instance.src_width,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape2D(
        lifetime_allocator,
        "dst_y",
        instance.dst_height,
        "dst_x",
        instance.dst_width,
    );

    owned.value = .{
        .dtype = .u32,
        .accumulation_dtype = .f32,
        .operation = .{ .image = .resize_bilinear },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks2D(
            lifetime_allocator,
            "dst_x",
            instance.dst_width,
            "dst_y",
            instance.dst_height,
            instance.threads.x,
            instance.threads.y,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try resizeShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn blurPassInstanceFromSpecialization(specialization: entry.Specialization) ?BlurPass {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .image = .blur_pass })) return null;
    if (specialization.dtype != .u32 or specialization.accumulation_dtype != .f32) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 1 or specialization.static_parameters.len != 2) {
        return null;
    }

    const src = specialization.inputs[0];
    const weights = specialization.inputs[1];
    const output = specialization.outputs[0];
    const reduction = specialization.reductions[0];
    if (src.axes.len != 2 or weights.axes.len != 1 or output.axes.len != 2) return null;
    if (reduction.shape.axes.len != 1) return null;
    if (!std.mem.eql(u8, src.axes[0].name, output.axes[0].name)) return null;
    if (!std.mem.eql(u8, src.axes[1].name, output.axes[1].name)) return null;
    if (!std.mem.eql(u8, reduction.name, "blur_tap")) return null;
    if (reduction.operator != .weighted_sum) return null;
    if (!std.mem.eql(u8, reduction.shape.axes[0].name, weights.axes[0].name)) return null;

    const radius_value = specialization.staticParameterValue("radius") orelse return null;
    const axis_value = specialization.staticParameterValue("axis") orelse return null;
    const radius = std.math.cast(u32, radius_value) orelse return null;
    const axis: Axis = switch (axis_value) {
        0 => .horizontal,
        1 => .vertical,
        else => return null,
    };
    const taps = 2 * @as(u64, radius) + 1;
    if (weights.axes[0].extent != taps or reduction.shape.axes[0].extent != taps) return null;
    if (!src.matchesExtents(&.{ output.axes[0].extent, output.axes[1].extent })) return null;

    const launch = specialization.launch orelse return null;
    const instance = BlurPass{
        .radius = radius,
        .axis = axis,
        .width = output.axes[1].extent,
        .height = output.axes[0].extent,
        .threads = .{ .x = launch.threadgroup[0], .y = launch.threadgroup[1] },
    };
    if (!blurPassInstanceValid(instance)) return null;
    return instance;
}

pub fn resizeInstanceFromSpecialization(specialization: entry.Specialization) ?Resize {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .image = .resize_bilinear })) return null;
    if (specialization.dtype != .u32 or specialization.accumulation_dtype != .f32) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0 or specialization.static_parameters.len != 0) {
        return null;
    }

    const src = specialization.inputs[0];
    const output = specialization.outputs[0];
    if (src.axes.len != 2 or output.axes.len != 2) return null;

    const launch = specialization.launch orelse return null;
    const instance = Resize{
        .dst_width = output.axes[1].extent,
        .dst_height = output.axes[0].extent,
        .src_width = src.axes[1].extent,
        .src_height = src.axes[0].extent,
        .threads = .{ .x = launch.threadgroup[0], .y = launch.threadgroup[1] },
    };
    if (!resizeInstanceValid(instance)) return null;
    return instance;
}

pub fn createBlurPassFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: BlurPass,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!blurPassInstanceValid(instance)) return error.UnsupportedBlurPassInstance;
    const target = try blurPassFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try blurPassFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try blurPassFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = blurPassShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "image_blur_pass",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try BlurPassFamilyRgba8.buildNamed(allocator, options.limits, entry_name, instance);
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = blur_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try imageDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            2
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn createResizeFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: Resize,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!resizeInstanceValid(instance)) return error.UnsupportedResizeInstance;
    const target = try resizeFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try resizeFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try resizeFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = resizeShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "image_resize_bilinear",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try ResizeBilinearFamilyRgba8.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = resize_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try imageDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            7
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn referenceBlurPass(
    dst: []u32,
    src: []const u32,
    weights: []const f32,
    width: u32,
    height: u32,
    axis: Axis,
) void {
    const radius: i64 = @intCast((weights.len - 1) / 2);
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            var acc = [4]f32{ 0, 0, 0, 0 };
            for (weights, 0..) |weight, tap| {
                const offset = @as(i64, @intCast(tap)) - radius;
                const base: i64 = switch (axis) {
                    .horizontal => @as(i64, col),
                    .vertical => @as(i64, row),
                };
                const extent: i64 = switch (axis) {
                    .horizontal => @as(i64, width),
                    .vertical => @as(i64, height),
                };
                const sample = std.math.clamp(base + offset, 0, extent - 1);
                const index: usize = switch (axis) {
                    .horizontal => @as(usize, row) * width + @as(usize, @intCast(sample)),
                    .vertical => @as(usize, @intCast(sample)) * width + col,
                };
                const pixel = src[index];
                acc[0] = @mulAdd(f32, @floatFromInt(pixel & 0xff), weight, acc[0]);
                acc[1] = @mulAdd(f32, @floatFromInt((pixel >> 8) & 0xff), weight, acc[1]);
                acc[2] = @mulAdd(f32, @floatFromInt((pixel >> 16) & 0xff), weight, acc[2]);
                acc[3] = @mulAdd(f32, @floatFromInt(pixel >> 24), weight, acc[3]);
            }
            dst[@as(usize, row) * width + col] = packReferenceChannels(acc);
        }
    }
}

pub fn referenceResizeBilinear(
    dst: []u32,
    src: []const u32,
    dst_width: u32,
    dst_height: u32,
    src_width: u32,
    src_height: u32,
) void {
    var row: u32 = 0;
    while (row < dst_height) : (row += 1) {
        var col: u32 = 0;
        while (col < dst_width) : (col += 1) {
            const sx = referenceSampleAxis(col, dst_width, src_width);
            const sy = referenceSampleAxis(row, dst_height, src_height);
            const p00 = referenceUnpack(src[sy.lo * src_width + sx.lo]);
            const p01 = referenceUnpack(src[sy.lo * src_width + sx.hi]);
            const p10 = referenceUnpack(src[sy.hi * src_width + sx.lo]);
            const p11 = referenceUnpack(src[sy.hi * src_width + sx.hi]);
            var blended: [4]f32 = undefined;
            for (0..4) |channel| {
                const top = @mulAdd(f32, p01[channel] - p00[channel], sx.frac, p00[channel]);
                const bottom = @mulAdd(f32, p11[channel] - p10[channel], sx.frac, p10[channel]);
                blended[channel] = @mulAdd(f32, bottom - top, sy.frac, top);
            }
            dst[@as(usize, row) * dst_width + col] = packReferenceChannels(blended);
        }
    }
}

const ReferenceAxisSample = struct {
    lo: usize,
    hi: usize,
    frac: f32,
};

fn referenceSampleAxis(dst_index: u32, dst_extent: u32, src_extent: u32) ReferenceAxisSample {
    const scale = resizeScale(src_extent, dst_extent);
    const centered = @mulAdd(f32, @as(f32, @floatFromInt(dst_index)) + 0.5, scale, -0.5);
    const last = @as(f32, @floatFromInt(src_extent)) - 1;
    const clamped = @max(@as(f32, 0), @min(centered, last));
    const lo_f = @floor(clamped);
    const hi_f = @min(lo_f + 1, last);
    return .{
        .lo = @intFromFloat(lo_f),
        .hi = @intFromFloat(hi_f),
        .frac = clamped - lo_f,
    };
}

fn referenceUnpack(pixel: u32) [4]f32 {
    return .{
        @floatFromInt(pixel & 0xff),
        @floatFromInt((pixel >> 8) & 0xff),
        @floatFromInt((pixel >> 16) & 0xff),
        @floatFromInt(pixel >> 24),
    };
}

fn packReferenceChannels(channels: [4]f32) u32 {
    var packed_pixel: u32 = 0;
    for (channels, 0..) |value, channel| {
        const rounded = @floor(value + 0.5);
        const clamped = @max(@as(f32, 0), @min(rounded, 255));
        packed_pixel |= @as(u32, @intFromFloat(clamped)) << @intCast(channel * 8);
    }
    return packed_pixel;
}

const testing = std.testing;

fn testPixel(seed: usize) u32 {
    var value: u32 = @truncate(seed *% 2654435761);
    value ^= value >> 13;
    value *%= 0x5bd1e995;
    value ^= value >> 15;
    return value;
}

test "gaussian weights normalize and peak at the center" {
    const weights = try gaussianWeightsAlloc(testing.allocator, 3, 1.4);
    defer testing.allocator.free(weights);
    try testing.expectEqual(@as(usize, 7), weights.len);
    var total: f32 = 0;
    for (weights) |weight| total += weight;
    try testing.expectApproxEqAbs(@as(f32, 1), total, 0.0001);
    for (weights) |weight| try testing.expect(weight <= weights[3]);
}

test "blur pass family matches the reference on the interpreter" {
    const allocator = testing.allocator;
    const width: u32 = 13;
    const height: u32 = 7;
    const pixel_count = @as(usize, width) * height;

    const src = try allocator.alloc(u32, pixel_count);
    defer allocator.free(src);
    for (src, 0..) |*pixel, index| pixel.* = testPixel(index);

    const weights = try gaussianWeightsAlloc(allocator, 2, 1.1);
    defer allocator.free(weights);

    inline for (.{ Axis.horizontal, Axis.vertical }) |axis| {
        const instance = BlurPass{ .radius = 2, .axis = axis, .threads = .{ .x = 8, .y = 4 } };
        const expected = try allocator.alloc(u32, pixel_count);
        defer allocator.free(expected);
        referenceBlurPass(expected, src, weights, width, height, axis);

        const actual = try allocator.alloc(u32, pixel_count);
        defer allocator.free(actual);
        @memset(actual, 0);

        var graph = try BlurPassFamilyRgba8.build(
            allocator,
            BlurPassFamilyRgba8.Limits.testing,
            instance,
        );
        defer graph.deinit();
        const geometry = imageLaunchGeometry(instance.threads, width, height);
        try graph.runCpuWithLaunch(allocator, &.{
            kernel.argumentBuffer(u32, actual),
            kernel.argumentBuffer(u32, @constCast(src)),
            kernel.argumentBuffer(f32, @constCast(weights)),
            kernel.argumentI32(@intCast(width)),
            kernel.argumentI32(@intCast(height)),
        }, .{
            .grid = geometry.grid,
            .block = geometry.threadgroup,
        });

        try testing.expectEqualSlices(u32, expected, actual);
    }
}

test "resize bilinear family matches the reference on the interpreter" {
    const allocator = testing.allocator;
    const src_width: u32 = 12;
    const src_height: u32 = 9;
    const dst_width: u32 = 7;
    const dst_height: u32 = 5;

    const src = try allocator.alloc(u32, @as(usize, src_width) * src_height);
    defer allocator.free(src);
    for (src, 0..) |*pixel, index| pixel.* = testPixel(index +% 17);

    const expected = try allocator.alloc(u32, @as(usize, dst_width) * dst_height);
    defer allocator.free(expected);
    referenceResizeBilinear(expected, src, dst_width, dst_height, src_width, src_height);

    const actual = try allocator.alloc(u32, @as(usize, dst_width) * dst_height);
    defer allocator.free(actual);
    @memset(actual, 0);

    const instance = Resize{ .threads = .{ .x = 8, .y = 4 } };
    var graph = try ResizeBilinearFamilyRgba8.build(
        allocator,
        ResizeBilinearFamilyRgba8.Limits.testing,
        instance,
    );
    defer graph.deinit();
    const geometry = imageLaunchGeometry(instance.threads, dst_width, dst_height);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(u32, actual),
        kernel.argumentBuffer(u32, @constCast(src)),
        kernel.argumentI32(@intCast(dst_width)),
        kernel.argumentI32(@intCast(dst_height)),
        kernel.argumentI32(@intCast(src_width)),
        kernel.argumentF32(resizeScale(src_width, dst_width)),
        kernel.argumentF32(resizeScale(src_height, dst_height)),
        kernel.argumentF32(@floatFromInt(src_width - 1)),
        kernel.argumentF32(@floatFromInt(src_height - 1)),
    }, .{
        .grid = geometry.grid,
        .block = geometry.threadgroup,
    });

    try testing.expectEqualSlices(u32, expected, actual);
}

test "upscale resize keeps corner pixels exact" {
    const allocator = testing.allocator;
    const src = [_]u32{ 0xff000011, 0xff000022, 0xff000033, 0xff000044 };
    const dst = try allocator.alloc(u32, 16);
    defer allocator.free(dst);
    referenceResizeBilinear(dst, src[0..], 4, 4, 2, 2);
    try testing.expectEqual(src[0], dst[0]);
    try testing.expectEqual(src[1], dst[3]);
    try testing.expectEqual(src[2], dst[12]);
    try testing.expectEqual(src[3], dst[15]);
}

test "blur instance validation bounds radius and threads" {
    try testing.expect(blurPassInstanceValid(.{ .radius = 1, .axis = .horizontal }));
    try testing.expect(!blurPassInstanceValid(.{ .radius = 0, .axis = .horizontal }));
    try testing.expect(
        !blurPassInstanceValid(.{ .radius = blur_radius_max + 1, .axis = .vertical }),
    );
    try testing.expect(
        !blurPassInstanceValid(.{ .radius = 2, .axis = .vertical, .threads = .{ .x = 0, .y = 4 } }),
    );
}
