const std = @import("std");
const stabilizer = @import("stabilizer");

const default_shuffle_slots = stabilizer.default_shuffle_slots;
const default_region_size = stabilizer.default_region_size;
const code_alignment = stabilizer.code_alignment;
const stack_alignment = stabilizer.stack_alignment;
const rerandomize_interval_ms = stabilizer.rerandomize_interval_ms;

const Reference = stabilizer.Reference;
const sizeClass = stabilizer.sizeClass;

test "defaults match upstream stabilizer runtime constants" {
    try std.testing.expectEqual(Reference.data_shuffle, default_shuffle_slots);
    try std.testing.expectEqual(Reference.code_shuffle, default_shuffle_slots);
    try std.testing.expectEqual(Reference.data_size, default_region_size);
    try std.testing.expectEqual(Reference.code_size, default_region_size);
    try std.testing.expectEqual(Reference.code_align, code_alignment);
    try std.testing.expectEqual(Reference.stack_align, stack_alignment);
    try std.testing.expectEqual(Reference.interval_ms, rerandomize_interval_ms);
    try std.testing.expect((stabilizer.HeapConfig{}).pointer_validation);
}

test "size classes are powers of two" {
    try std.testing.expectEqual(@as(usize, 16), try sizeClass(1, 16));
    try std.testing.expectEqual(@as(usize, 16), try sizeClass(16, 16));
    try std.testing.expectEqual(@as(usize, 32), try sizeClass(17, 16));
}
