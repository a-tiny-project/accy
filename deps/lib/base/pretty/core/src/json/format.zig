const std = @import("std");

pub const Style = enum {
    minified,
    indent_2,
};

pub fn stringifyOptions(style: Style) std.json.Stringify.Options {
    return switch (style) {
        .minified => .{},
        .indent_2 => .{ .whitespace = .indent_2 },
    };
}

pub fn writeMinified(writer: anytype, value: anytype) !void {
    try std.json.Stringify.value(value, stringifyOptions(.minified), writer);
}

pub fn writeMinifiedLine(writer: anytype, value: anytype) !void {
    try writeMinified(writer, value);
    try writer.writeByte('\n');
}

pub fn renderMinifiedAlloc(
    allocator: std.mem.Allocator,
    value: anytype,
) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    writeMinified(&out.writer, value) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

pub fn renderMinifiedLineAlloc(
    allocator: std.mem.Allocator,
    value: anytype,
) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    writeMinifiedLine(&out.writer, value) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

pub fn writeIndented(writer: anytype, value: anytype) !void {
    try std.json.Stringify.value(value, stringifyOptions(.indent_2), writer);
}

pub fn renderIndentedAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeIndented(&out.writer, value);
    return try out.toOwnedSlice();
}
