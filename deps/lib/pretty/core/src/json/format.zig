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

test "writeMinified serializes byte-stable machine JSON" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"name\":\"alpha\",\"items\":[1,true,null]}", .{});
    defer parsed.deinit();

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeMinified(&out.writer, parsed.value);
    try std.testing.expectEqualStrings("{\"name\":\"alpha\",\"items\":[1,true,null]}", out.written());

    const rendered = try renderMinifiedAlloc(allocator, .{ .status = "ok", .count = @as(u8, 2) });
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"count\":2}", rendered);
}

test "writeMinifiedLine serializes independent escaped JSONL records" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try writeMinifiedLine(&out.writer, .{ .event = "first\"\n", .count = @as(u8, 1) });
    try writeMinifiedLine(&out.writer, .{ .event = "second", .count = @as(u8, 2) });

    try std.testing.expectEqualStrings(
        "{\"event\":\"first\\\"\\n\",\"count\":1}\n" ++
            "{\"event\":\"second\",\"count\":2}\n",
        out.written(),
    );

    const rendered = try renderMinifiedLineAlloc(
        std.testing.allocator,
        .{ .event = "owned", .count = @as(u8, 3) },
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{\"event\":\"owned\",\"count\":3}\n",
        rendered,
    );
}

test "allocated renders expose allocator failures" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        renderMinifiedAlloc(failing.allocator(), .{ .status = "ok" }),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        renderMinifiedLineAlloc(failing.allocator(), .{ .status = "ok" }),
    );
}

test "writeIndented serializes two-space machine JSON" {
    const allocator = std.testing.allocator;
    const rendered = try renderIndentedAlloc(allocator, .{ .status = "ok", .count = @as(u8, 2) });
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{\n  \"status\": \"ok\",\n  \"count\": 2\n}",
        rendered,
    );
}
