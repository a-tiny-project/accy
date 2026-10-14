const std = @import("std");

const accy = @import("../../../../root.zig");
const artifact = @import("../../../../artifact/model/root.zig");
const library = @import("../../root.zig");
const model = @import("model.zig");

const extent = library.extent;
const shape = accy.choir.shape;
const Histogram = model.Histogram;

pub fn histogramShapeFamily(
    backing_allocator: std.mem.Allocator,
    instance: Histogram,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "histogram");
    errdefer builder.deinit();

    const bin = try builder.symbol(instance.bin_axis);
    const element = try builder.symbol(instance.element_axis);
    const bin_expr = try builder.symbolExpression(bin);
    const element_expr = try builder.symbolExpression(element);

    _ = try builder.tensor("dst", &.{bin_expr});
    _ = try builder.tensor("data", &.{element_expr});
    try builder.assumeBounds(bin_expr, histogramRuntimeExtentBounds());
    try builder.assumeBounds(element_expr, histogramRuntimeExtentBounds());

    return builder.finish();
}

pub fn histogramRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent.runtime_extent_max };
}

pub fn histogramFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: Histogram) !u64 {
    var family = try histogramShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn histogramShapeProfileDimensions(
    instance: Histogram,
) [2]artifact.KernelCallShapeProfileDimension {
    const bounds = histogramRuntimeExtentBounds();
    return .{
        .{ .name = instance.bin_axis, .runtime_scalar_argument_index = 0, .bounds = bounds },
        .{ .name = instance.element_axis, .runtime_scalar_argument_index = 1, .bounds = bounds },
    };
}
