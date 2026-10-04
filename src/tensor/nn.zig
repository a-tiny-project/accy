const std = @import("std");

const trace = @import("trace/root.zig");
const types = @import("type/root.zig");

pub fn embedding(table: trace.Value, ids: trace.Value, comptime axis: anytype) !trace.Value {
    return embeddingNamed(table, ids, comptime trace.builder.nameOf(axis));
}

pub fn embeddingNamed(table: trace.Value, ids: trace.Value, axis_name: []const u8) !trace.Value {
    return table.builder.gatherNamed(table, ids, axis_name);
}

pub fn sparseCrossEntropy(
    logits: trace.Value,
    targets: trace.Value,
    comptime class_axis: anytype,
) !trace.Value {
    return sparseCrossEntropyNamed(logits, targets, comptime trace.builder.nameOf(class_axis));
}

pub fn sparseCrossEntropyNamed(
    logits: trace.Value,
    targets: trace.Value,
    class_axis_name: []const u8,
) !trace.Value {
    if (!logits.ty.dtype.isFloat()) return error.DTypeMismatch;
    if (targets.ty.dtype != .i32) return error.DTypeMismatch;

    const builder = logits.builder;
    const allocator = builder.arena.allocator();
    const class_axis = types.findDim(logits.ty.dims, class_axis_name) orelse
        return error.AxisNotFound;
    const class_axes = [_]i64{@intCast(class_axis)};
    const target_dims = try types.removeAxes(allocator, logits.ty.dims, &class_axes);
    if (targets.ty.rank() != target_dims.len) return error.ShapeMismatch;

    const ordered_targets = try builder.alignTo(targets, target_dims);
    return builder.sparseCrossEntropyOp(logits, ordered_targets, @intCast(class_axis));
}

pub fn sparseCrossEntropyMean(
    logits: trace.Value,
    targets: trace.Value,
    comptime class_axis: anytype,
) !trace.Value {
    return sparseCrossEntropyMeanNamed(logits, targets, comptime trace.builder.nameOf(class_axis));
}

pub fn sparseCrossEntropyMeanNamed(
    logits: trace.Value,
    targets: trace.Value,
    class_axis_name: []const u8,
) !trace.Value {
    const losses = try sparseCrossEntropyNamed(logits, targets, class_axis_name);
    if (losses.ty.rank() == 0) return losses;
    const allocator = logits.builder.arena.allocator();
    const axes = try allocator.alloc([]const u8, losses.ty.rank());
    for (losses.ty.dims, axes) |dim, *slot| {
        slot.* = dim.name;
    }
    return logits.builder.meanNamed(losses, axes);
}

test "tensor nn embedding gathers a table by ids" {
    var builder = try trace.Builder.init(std.testing.allocator, "nn_embedding");
    defer builder.deinit();

    const table = try builder.input(.f32, .{ .vocab = 32, .channel = 8 });
    const ids = try builder.input(.i32, .{ .batch = 2, .token = 5 });
    const out = try embedding(table, ids, .vocab);

    try types.expectExtents(&.{ 2, 5, 8 }, out.ty);
    try std.testing.expectEqualStrings("batch", out.ty.dims[0].name);
    try std.testing.expectEqualStrings("token", out.ty.dims[1].name);
    try std.testing.expectEqualStrings("channel", out.ty.dims[2].name);
}

test "tensor nn sparse cross entropy returns target-shaped losses" {
    var builder = try trace.Builder.init(std.testing.allocator, "nn_sparse_cross_entropy");
    defer builder.deinit();

    const logits = try builder.input(.f32, .{ .token = 5, .vocab = 32 });
    const targets = try builder.input(.i32, .{ .token = 5 });
    const losses = try sparseCrossEntropy(logits, targets, .vocab);
    const mean = try sparseCrossEntropyMean(logits, targets, .vocab);

    try types.expectExtents(&.{5}, losses.ty);
    try std.testing.expectEqualStrings("token", losses.ty.dims[0].name);
    try types.expectExtents(&.{}, mean.ty);
}
