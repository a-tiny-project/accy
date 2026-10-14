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
