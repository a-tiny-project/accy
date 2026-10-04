const std = @import("std");

pub fn appendFmt(
    buf: []u8,
    pos: usize,
    comptime fmt: []const u8,
    args: anytype,
) !usize {
    const slice = try std.fmt.bufPrint(buf[pos..], fmt, args);
    return pos + slice.len;
}

pub fn intPayload(buf: []u8, value: anytype) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value});
}

test "format.appendFmt appends and advances position" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;

    var pos: usize = 0;
    pos = try appendFmt(buf[0..], pos, "hello", .{});
    pos = try appendFmt(buf[0..], pos, " {s} {d}", .{ "world", 42 });

    try testing.expectEqualStrings("hello world 42", buf[0..pos]);
}

test "format.intPayload formats integers" {
    const testing = std.testing;
    var buf: [16]u8 = undefined;

    const payload = try intPayload(buf[0..], 12345);
    try testing.expectEqualStrings("12345", payload);
}

test "format.appendFmt errors on small buffer" {
    const testing = std.testing;
    var buf: [4]u8 = undefined;

    try testing.expectError(error.NoSpaceLeft, appendFmt(buf[0..], 0, "hello", .{}));
}

test "format.intPayload errors on small buffer" {
    const testing = std.testing;
    var buf: [2]u8 = undefined;

    try testing.expectError(error.NoSpaceLeft, intPayload(buf[0..], 123));
}
