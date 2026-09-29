const std = @import("std");

test "validation runner initializes and tears down test resources without a deadline" {
    const bytes = try std.testing.allocator.dupe(u8, "validation runner");
    defer std.testing.allocator.free(bytes);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = "result", .data = bytes });
    var buffer: [32]u8 = undefined;
    const contents = try directory.dir.readFile(std.testing.io, "result", &buffer);
    try std.testing.expectEqualStrings("validation runner", contents);
}
