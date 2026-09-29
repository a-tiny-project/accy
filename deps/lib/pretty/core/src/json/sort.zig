const std = @import("std");
const escape = @import("escape.zig");
const scalar = @import("scalar.zig");

const Entry = struct {
    key: []const u8,
    value: *const std.json.Value,
};

pub fn writeSortedMinified(writer: anytype, allocator: std.mem.Allocator, value: std.json.Value) !void {
    switch (value) {
        .null => try scalar.writeNull(writer),
        .bool => |inner| try scalar.writeBool(writer, inner),
        .integer => |inner| try scalar.writeInt(writer, inner),
        .float => |inner| try writer.print("{d}", .{inner}),
        .number_string => |inner| try scalar.writeNumberString(writer, inner),
        .string => |inner| try escape.writeString(writer, inner),
        .array => |inner| {
            try writer.writeByte('[');
            for (inner.items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeSortedMinified(writer, allocator, item);
            }
            try writer.writeByte(']');
        },
        .object => |inner| {
            var entries: std.ArrayList(Entry) = .empty;
            defer entries.deinit(allocator);
            var iterator = inner.iterator();
            while (iterator.next()) |entry| {
                try entries.append(allocator, .{
                    .key = entry.key_ptr.*,
                    .value = entry.value_ptr,
                });
            }
            std.sort.insertion(Entry, entries.items, {}, lessEntry);
            try writer.writeByte('{');
            for (entries.items, 0..) |entry, index| {
                if (index != 0) try writer.writeByte(',');
                try escape.writeString(writer, entry.key);
                try writer.writeByte(':');
                try writeSortedMinified(writer, allocator, entry.value.*);
            }
            try writer.writeByte('}');
        },
    }
}

pub fn renderSortedMinifiedAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeSortedMinified(&out.writer, allocator, value);
    return try out.toOwnedSlice();
}

fn lessEntry(_: void, lhs: Entry, rhs: Entry) bool {
    return std.mem.lessThan(u8, lhs.key, rhs.key);
}

test "writeSortedMinified serializes compact JSON with lexical object keys" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"z\":1,\"a\":{\"b\":2,\"a\":1},\"list\":[{\"d\":4,\"c\":3}]}", .{});
    defer parsed.deinit();

    const rendered = try renderSortedMinifiedAlloc(allocator, parsed.value);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("{\"a\":{\"a\":1,\"b\":2},\"list\":[{\"c\":3,\"d\":4}],\"z\":1}", rendered);
}
