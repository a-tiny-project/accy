const std = @import("std");
const root = @import("root.zig");

test "keysym modules compose through the native API" {
    const a = root.fromName("A").?;
    try std.testing.expectEqual(@as(root.Keysym, @fromBackingInt(@intCast(0x0041))), a);
    try std.testing.expectEqual(@as(?u21, 'A'), root.codepoint(a));
    try std.testing.expectEqual(@as(root.Keysym, @fromBackingInt(@intCast(0x0061))), root.lower(a));
    try std.testing.expect(!root.isModifier(a));
}
