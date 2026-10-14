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
