const std = @import("std");
const support = @import("support.zig");

const coordinate = support.coordinate;
const cursorShapeValue = support.cursorShapeValue;

test "seat coordinates clamp non-finite and out-of-range values" {
    try std.testing.expectEqual(@as(i32, 2), coordinate(1.6));
    try std.testing.expectEqual(@as(i32, 0), coordinate(std.math.nan(f64)));
    try std.testing.expectEqual(@as(i32, 0), coordinate(std.math.inf(f64)));
}

test "cursor shapes map to protocol shape values" {
    try std.testing.expectEqual(@as(u32, 1), cursorShapeValue(.default));
    try std.testing.expectEqual(@as(u32, 29), cursorShapeValue(.resize_nwse));
}
