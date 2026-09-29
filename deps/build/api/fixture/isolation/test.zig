const std = @import("std");

test "compiler manifest isolation preserves aliases and separates native and compiler options" {
    const results = @import("isolated_compilers");
    try std.testing.expectEqualSlices(u8, results.first, results.repeated);
    try std.testing.expectEqual(0, results.native.len);
    if (results.first.len == 0) return error.SkipZigTest;
    try std.testing.expectEqual(32, results.first.len);
    try std.testing.expectEqual(32, results.changed.len);
    try std.testing.expect(!std.mem.eql(u8, results.first, results.changed));
}
