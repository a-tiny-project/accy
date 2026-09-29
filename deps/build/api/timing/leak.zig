const std = @import("std");

test "leaks std testing allocator allocation" {
    _ = try std.testing.allocator.alloc(u8, 1);
}
