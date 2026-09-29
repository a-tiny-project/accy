const std = @import("std");

pub const ParseError = error{
    MissingDisplay,
    RemoteDisplayUnsupported,
    InvalidDisplay,
};

pub const Target = struct {
    display: u32,
    screen: u32,

    pub fn socketPath(self: Target, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "/tmp/.X11-unix/X{d}", .{self.display});
    }
};

pub fn parse(value: ?[]const u8) ParseError!Target {
    const raw = value orelse return error.MissingDisplay;
    if (raw.len == 0) return error.MissingDisplay;

    var rest = raw;
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
        const host = rest[0..colon];
        if (host.len != 0 and !std.mem.eql(u8, host, "unix")) {
            return error.RemoteDisplayUnsupported;
        }
        rest = rest[colon + 1 ..];
    } else {
        return error.InvalidDisplay;
    }

    var display_part = rest;
    var screen_part: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
        display_part = rest[0..dot];
        screen_part = rest[dot + 1 ..];
    }

    const display = std.fmt.parseInt(u32, display_part, 10) catch return error.InvalidDisplay;
    const screen = if (screen_part.len == 0)
        0
    else
        std.fmt.parseInt(u32, screen_part, 10) catch return error.InvalidDisplay;

    return .{ .display = display, .screen = screen };
}

test "parse accepts local display forms" {
    try std.testing.expectEqual(Target{ .display = 0, .screen = 0 }, try parse(":0"));
    try std.testing.expectEqual(Target{ .display = 1, .screen = 0 }, try parse(":1"));
    try std.testing.expectEqual(Target{ .display = 0, .screen = 2 }, try parse(":0.2"));
    try std.testing.expectEqual(Target{ .display = 10, .screen = 0 }, try parse("unix:10"));
}

test "parse rejects remote and malformed displays" {
    try std.testing.expectError(error.MissingDisplay, parse(null));
    try std.testing.expectError(error.MissingDisplay, parse(""));
    try std.testing.expectError(error.RemoteDisplayUnsupported, parse("remote.host:0"));
    try std.testing.expectError(error.InvalidDisplay, parse("0"));
    try std.testing.expectError(error.InvalidDisplay, parse(":zero"));
}

test "socket path names the abstract unix socket" {
    var buffer: [64]u8 = undefined;
    const target = try parse(":1");
    try std.testing.expectEqualStrings("/tmp/.X11-unix/X1", try target.socketPath(&buffer));
}
