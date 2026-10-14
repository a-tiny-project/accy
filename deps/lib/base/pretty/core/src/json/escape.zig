const std = @import("std");

pub fn writeString(writer: anytype, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

pub fn writeStringParts(writer: anytype, parts: []const []const u8) !void {
    for (parts) |part| {
        if (!std.unicode.utf8ValidateSlice(part)) return error.InvalidUtf8;
    }
    try writer.writeByte('"');
    for (parts) |part| try writeStringContent(writer, part);
    try writer.writeByte('"');
}

pub fn writeByteString(writer: anytype, value: []const u8) !void {
    const hex = "0123456789abcdef";
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\x08' => try writer.writeAll("\\b"),
            '\x0c' => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
            else => try writer.writeAll(&[_]u8{
                '\\',
                'u',
                '0',
                '0',
                hex[byte >> 4],
                hex[byte & 0x0f],
            }),
        }
    }
    try writer.writeByte('"');
}

pub fn stringAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn writeStringContent(writer: anytype, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    try writer.print("\\u{x:0>4}", .{byte});
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
}
