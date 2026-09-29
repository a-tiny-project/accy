const std = @import("std");
const size_class = @import("../../root.zig").class;
const model = @import("../root.zig").model;

const Alignment = std.mem.Alignment;
const Class = model.Class;

pub fn classFor(len: usize, requested_alignment: Alignment) ?Class {
    if (requested_alignment.toByteUnits() > size_class.min_alignment) return null;
    if (len <= model.max_small_cached_size or len > model.max_medium_cached_size) return null;
    const class_size = std.mem.alignForward(usize, len, model.medium_class_step);
    if (class_size < model.min_medium_cached_size or class_size > model.max_medium_cached_size) return null;
    return .{
        .index = (class_size - model.min_medium_cached_size) / model.medium_class_step,
        .size = class_size,
    };
}

pub fn backingSize(class: Class) usize {
    return backingSizeForClassSize(class.size);
}

pub fn classForIndex(index: usize) Class {
    return .{
        .index = index,
        .size = sizeForIndex(index),
    };
}

pub fn sizeForIndex(index: usize) usize {
    return model.min_medium_cached_size + index * model.medium_class_step;
}

pub fn backingSizeForClassSize(class_size: usize) usize {
    return class_size + model.header_size;
}

test "medium cache classes cover Barnes page-run sizes" {
    try std.testing.expect(classFor(model.max_small_cached_size, .@"1") == null);
    try std.testing.expectEqual(
        @as(usize, 320 * 1024),
        classFor(model.max_small_cached_size + 1, .@"1").?.size,
    );
    try std.testing.expectEqual(
        @as(usize, 448 * 1024),
        classFor(400 * 1024, .@"1").?.size,
    );
    try std.testing.expectEqual(
        @as(usize, 512 * 1024),
        classFor(model.max_medium_cached_size, .@"1").?.size,
    );
    try std.testing.expect(classFor(model.max_medium_cached_size + 1, .@"1") == null);
    try std.testing.expect(classFor(400 * 1024, .fromByteUnits(32)) == null);
}
