const std = @import("std");
const size_class = @import("../root.zig").class;
const model = @import("model.zig");

const Alignment = std.mem.Alignment;
const Class = model.Class;

pub fn classFor(len: usize, requested_alignment: Alignment) ?Class {
    if (requested_alignment.toByteUnits() > size_class.min_alignment) return null;
    if (len > size_class.max_small_size and len <= model.max_small_cached_size) {
        const class_size = std.mem.alignForward(usize, len, model.class_step);
        if (class_size < model.min_cached_size or class_size > model.max_small_cached_size) return null;
        return .{
            .index = (class_size - model.min_cached_size) / model.class_step,
            .size = class_size,
        };
    }
    if (len >= model.min_huge_cached_size and len <= model.max_cached_size) {
        const class_size = std.mem.alignForward(usize, len, model.huge_class_step);
        if (class_size < model.min_huge_cached_size or class_size > model.max_cached_size) return null;
        return .{
            .index = model.small_class_count + (class_size - model.min_huge_cached_size) / model.huge_class_step,
            .size = class_size,
        };
    }
    return null;
}

pub fn classForIndex(index: usize) Class {
    return .{
        .index = index,
        .size = sizeForIndex(index),
    };
}

pub fn backingSize(class: Class) usize {
    return backingSizeForClassSize(class.size);
}

pub fn sizeForIndex(index: usize) usize {
    if (index >= model.small_class_count) {
        return model.min_huge_cached_size + (index - model.small_class_count) * model.huge_class_step;
    }
    return model.min_cached_size + index * model.class_step;
}

pub fn backingSizeForClassSize(class_size: usize) usize {
    return class_size + model.header_size;
}

test "large cache leaves medium page-run sizes to medium policy" {
    try std.testing.expect(classFor(model.max_small_cached_size, .@"1") != null);
    try std.testing.expect(classFor(model.max_small_cached_size + 1, .@"1") == null);
    try std.testing.expect(classFor(400 * 1024, .@"1") == null);
    try std.testing.expect(classFor(model.max_medium_cached_size, .@"1") == null);
}
