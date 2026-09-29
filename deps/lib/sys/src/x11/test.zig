const std = @import("std");
const subject = @import("root.zig");

const display = subject.display;

test {
    std.testing.refAllDecls(subject);
}

test "display target resolves to the connection socket path" {
    var buffer: [64]u8 = undefined;
    const target = try display.parse(":0");
    const path = try target.socketPath(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/.X11-unix/X"));
}
