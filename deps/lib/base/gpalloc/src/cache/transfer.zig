const std = @import("std");
const size_class = @import("../root.zig").class;

pub const capacity: u16 = 2048;
pub const target_bytes: usize = 2 * 1024 * 1024;

pub fn classLimit(class_index: usize) u16 {
    const class_size = size_class.size(class_index);
    const by_bytes = @max(@as(usize, 1), target_bytes / class_size);
    return @intCast(@min(capacity, by_bytes));
}

test "transfer class limits match byte and slot caps" {
    for (size_class.sizes, 0..) |class_size, class_index| {
        const by_bytes = @max(@as(usize, 1), target_bytes / class_size);
        const expected: u16 = @intCast(@min(capacity, by_bytes));
        try std.testing.expectEqual(expected, classLimit(class_index));
    }
}
