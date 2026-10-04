const std = @import("std");
const escape = @import("escape.zig");
const format = @import("format.zig");

/// An open object scope on one `Writer`.
/// Nested scopes share the writer and must end before their parent continues.
pub const Object = struct {
    writer: *Writer,

    pub fn field(self: Object, name: []const u8, value: anytype) !void {
        try self.writer.objectField(name);
        try self.writer.write(value);
    }

    pub fn fields(self: Object, values: anytype) !void {
        const info = switch (@typeInfo(@TypeOf(values))) {
            .@"struct" => |value| value,
            else => @compileError("JSON object fields require a named struct"),
        };
        if (info.is_tuple) {
            @compileError("JSON object fields require a named struct");
        }
        inline for (info.field_names) |name| {
            try self.field(name, @field(values, name));
        }
    }

    pub fn fieldParts(
        self: Object,
        name_parts: []const []const u8,
        value: anytype,
    ) !void {
        try self.writer.objectFieldParts(name_parts);
        try self.writer.write(value);
    }

    pub fn formattedField(
        self: Object,
        comptime capacity: usize,
        comptime fmt: []const u8,
        args: anytype,
        value: anytype,
    ) !void {
        var buffer: [capacity]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, fmt, args);
        try self.field(name, value);
    }

    pub fn object(self: Object, name: []const u8) !Object {
        try self.writer.objectField(name);
        return try self.writer.object();
    }

    pub fn formattedObject(
        self: Object,
        comptime capacity: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) !Object {
        var buffer: [capacity]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, fmt, args);
        return try self.object(name);
    }

    pub fn array(self: Object, name: []const u8) !Array {
        try self.writer.objectField(name);
        return try self.writer.array();
    }

    pub fn formattedArray(
        self: Object,
        comptime capacity: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) !Array {
        var buffer: [capacity]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, fmt, args);
        return try self.array(name);
    }

    pub fn stringParts(
        self: Object,
        name: []const u8,
        parts: []const []const u8,
    ) !void {
        try self.writer.objectField(name);
        try self.writer.stringParts(parts);
    }

    pub fn byteString(self: Object, name: []const u8, bytes: []const u8) !void {
        try self.writer.objectField(name);
        try self.writer.byteString(bytes);
    }

    pub fn hexString(self: Object, name: []const u8, bytes: []const u8) !void {
        try self.writer.objectField(name);
        try self.writer.hexString(bytes);
    }

    pub fn base64String(self: Object, name: []const u8, bytes: []const u8) !void {
        try self.writer.objectField(name);
        try self.writer.base64String(bytes);
    }

    pub fn formattedString(
        self: Object,
        name: []const u8,
        comptime capacity: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.writer.objectField(name);
        try self.writer.formattedString(capacity, fmt, args);
    }

    pub fn raw(self: Object, name: []const u8, value: []const u8) !void {
        try self.writer.objectField(name);
        try self.writer.raw(value);
    }

    pub fn print(
        self: Object,
        name: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.writer.objectField(name);
        try self.writer.print(fmt, args);
    }

    pub fn end(self: Object) !void {
        try self.writer.endObject();
    }

    pub fn endLine(self: Object) !void {
        try self.end();
        try self.writer.newline();
    }
};

/// An open array scope on one `Writer`.
/// Nested scopes share the writer and must end before their parent continues.
pub const Array = struct {
    writer: *Writer,

    pub fn element(self: Array, value: anytype) !void {
        try self.writer.write(value);
    }

    pub fn object(self: Array) !Object {
        return try self.writer.object();
    }

    pub fn array(self: Array) !Array {
        return try self.writer.array();
    }

    pub fn stringParts(self: Array, parts: []const []const u8) !void {
        try self.writer.stringParts(parts);
    }

    pub fn byteString(self: Array, bytes: []const u8) !void {
        try self.writer.byteString(bytes);
    }

    pub fn hexString(self: Array, bytes: []const u8) !void {
        try self.writer.hexString(bytes);
    }

    pub fn base64String(self: Array, bytes: []const u8) !void {
        try self.writer.base64String(bytes);
    }

    pub fn formattedString(
        self: Array,
        comptime capacity: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.writer.formattedString(capacity, fmt, args);
    }

    pub fn raw(self: Array, value: []const u8) !void {
        try self.writer.raw(value);
    }

    pub fn print(self: Array, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
    }

    pub fn end(self: Array) !void {
        try self.writer.endArray();
    }

    pub fn endLine(self: Array) !void {
        try self.end();
        try self.writer.newline();
    }
};

/// Streams one JSON value at a time without intermediate string allocations.
/// `newline` resets completed top-level state so the same writer can emit JSONL.
pub const Writer = struct {
    stringify: std.json.Stringify,

    pub fn init(writer: *std.Io.Writer, style: format.Style) Writer {
        return .{ .stringify = .{
            .writer = writer,
            .options = format.stringifyOptions(style),
        } };
    }

    pub fn beginObject(self: *Writer) !void {
        try self.stringify.beginObject();
    }

    pub fn object(self: *Writer) !Object {
        try self.beginObject();
        return .{ .writer = self };
    }

    pub fn endObject(self: *Writer) !void {
        try self.stringify.endObject();
    }

    pub fn objectField(self: *Writer, name: []const u8) !void {
        try self.stringify.objectField(name);
    }

    fn objectFieldParts(self: *Writer, parts: []const []const u8) !void {
        try self.stringify.beginObjectFieldRaw();
        try escape.writeStringParts(self.stringify.writer, parts);
        self.stringify.endObjectFieldRaw();
    }

    pub fn beginArray(self: *Writer) !void {
        try self.stringify.beginArray();
    }

    pub fn array(self: *Writer) !Array {
        try self.beginArray();
        return .{ .writer = self };
    }

    pub fn endArray(self: *Writer) !void {
        try self.stringify.endArray();
    }

    pub fn write(self: *Writer, value: anytype) !void {
        try self.stringify.write(value);
    }

    pub fn stringParts(self: *Writer, parts: []const []const u8) !void {
        const raw_writer = try self.beginRaw();
        try escape.writeStringParts(raw_writer, parts);
        self.endRaw();
    }

    pub fn byteString(self: *Writer, bytes: []const u8) !void {
        const raw_writer = try self.beginRaw();
        try escape.writeByteString(raw_writer, bytes);
        self.endRaw();
    }

    pub fn hexString(self: *Writer, bytes: []const u8) !void {
        const hex = "0123456789abcdef";
        const raw_writer = try self.beginRaw();
        try raw_writer.writeByte('"');
        for (bytes) |byte| {
            try raw_writer.writeByte(hex[byte >> 4]);
            try raw_writer.writeByte(hex[byte & 0x0f]);
        }
        try raw_writer.writeByte('"');
        self.endRaw();
    }

    pub fn base64String(self: *Writer, bytes: []const u8) !void {
        const raw_writer = try self.beginRaw();
        try raw_writer.writeByte('"');
        try std.base64.standard.Encoder.encodeWriter(raw_writer, bytes);
        try raw_writer.writeByte('"');
        self.endRaw();
    }

    pub fn formattedString(
        self: *Writer,
        comptime capacity: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        if (capacity == 0) @compileError("formatted JSON string capacity must be positive");
        var buffer: [capacity]u8 = undefined;
        try self.write(try std.fmt.bufPrint(&buffer, fmt, args));
    }

    pub fn raw(self: *Writer, value: []const u8) !void {
        try self.stringify.beginWriteRaw();
        try self.stringify.writer.writeAll(value);
        self.stringify.endWriteRaw();
    }

    pub fn beginRaw(self: *Writer) !*std.Io.Writer {
        try self.stringify.beginWriteRaw();
        return self.stringify.writer;
    }

    pub fn endRaw(self: *Writer) void {
        self.stringify.endWriteRaw();
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.stringify.print(fmt, args);
    }

    pub fn newline(self: *Writer) !void {
        try self.stringify.writer.writeByte('\n');
        if (self.stringify.indent_level != 0) return;
        if (self.stringify.next_punctuation != .comma) return;
        self.stringify = .{
            .writer = self.stringify.writer,
            .options = self.stringify.options,
        };
    }
};

test "Writer streams one JSON document per JSONL line" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    const first = try writer.object();
    try first.field("line", @as(u8, 1));
    try first.endLine();
    const second = try writer.object();
    try second.field("line", @as(u8, 2));
    try second.endLine();
    try std.testing.expectEqualStrings(
        "{\"line\":1}\n{\"line\":2}\n",
        out.written(),
    );
}

test "Writer keeps document state across a newline inside a value" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    const root = try writer.object();
    const nested = try root.object("nested");
    try nested.field("kept", true);
    try nested.endLine();
    try root.field("after", @as(u8, 7));
    try root.endLine();
    try std.testing.expectEqualStrings(
        "{\"nested\":{\"kept\":true}\n,\"after\":7}\n",
        out.written(),
    );
}

test "Writer streams minified machine JSON" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    try writer.beginObject();
    try writer.objectField("event");
    try writer.write("sample");
    try writer.objectField("values");
    try writer.beginArray();
    try writer.write(@as(u8, 1));
    try writer.write(@as(u8, 2));
    try writer.endArray();
    try writer.endObject();
    try std.testing.expectEqualStrings("{\"event\":\"sample\",\"values\":[1,2]}", out.written());
}

test "Writer prints raw formatted JSON values" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    try writer.beginObject();
    try writer.objectField("checksum");
    try writer.print("{s}", .{"201123673782136532013988583703766643259"});
    try writer.endObject();
    try std.testing.expectEqualStrings("{\"checksum\":201123673782136532013988583703766643259}", out.written());
}

test "Writer inserts raw values and string parts" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    try writer.beginObject();
    try writer.objectField("metadata");
    try writer.raw("{\"count\":2}");
    try writer.objectField("ref");
    try writer.stringParts(&.{ "forum:", "post\"id", "#", "reply\nid" });
    try writer.endObject();
    try std.testing.expectEqualStrings("{\"metadata\":{\"count\":2},\"ref\":\"forum:post\\\"id#reply\\nid\"}", out.written());
}

test "Writer streams arbitrary byte strings through every container" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    const root = try writer.object();
    try root.byteString("payload", "quote\"\n\x80");
    const values = try root.array("values");
    try values.byteString("\x01\xff");
    try values.end();
    try root.end();
    try std.testing.expectEqualStrings(
        "{\"payload\":\"quote\\\"\\n\\u0080\",\"values\":[\"\\u0001\\u00ff\"]}",
        out.written(),
    );
}

test "Writer streams byte slices as lowercase hexadecimal strings" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    const root = try writer.object();
    try root.hexString("payload", &.{ 0x00, 0x7f, 0xa5, 0xff });
    const values = try root.array("values");
    try values.hexString(&.{ 0x12, 0x34 });
    try values.end();
    try root.end();
    try std.testing.expectEqualStrings(
        "{\"payload\":\"007fa5ff\",\"values\":[\"1234\"]}",
        out.written(),
    );
}

test "Writer streams byte slices as base64 strings" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    const root = try writer.object();
    try root.base64String("payload", &.{ 0x00, 0xfb, 0xff });
    const values = try root.array("values");
    try values.base64String("tiny");
    try values.end();
    try root.end();
    try std.testing.expectEqualStrings(
        "{\"payload\":\"APv/\",\"values\":[\"dGlueQ==\"]}",
        out.written(),
    );
}

test "Writer formats bounded string values without allocating" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    const root = try writer.object();
    try root.formattedString("timepoint", 54, "{d}:{d}:{d}", .{ 7, 1, 42 });
    const values = try root.array("values");
    try values.formattedString(8, "item-{d}", .{3});
    try values.end();
    try root.end();
    try std.testing.expectEqualStrings(
        "{\"timepoint\":\"7:1:42\",\"values\":[\"item-3\"]}",
        out.written(),
    );
}

test "Writer composes large nested records through object and array scopes" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    const root = try writer.object();
    try root.field("schema", "sample/v1");
    const run = try root.object("run");
    try run.field("id", @as(u32, 42));
    try run.stringParts("ref", &.{ "run:", "a\"b" });
    const samples = try run.array("samples");
    const first = try samples.object();
    try first.field("ok", true);
    try first.print("ratio", "{d:.2}", .{@as(f64, 0.5)});
    try first.end();
    try samples.raw("null");
    try samples.end();
    try run.end();
    try root.endLine();
    try std.testing.expectEqualStrings(
        "{\"schema\":\"sample/v1\",\"run\":{\"id\":42,\"ref\":\"run:a\\\"b\"," ++
            "\"samples\":[{\"ok\":true,\"ratio\":0.50},null]}}\n",
        out.written(),
    );
}

test "Object writes named struct fields in declaration order" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    const root = try writer.object();
    try root.fields(.{
        .status = "ready",
        .count = @as(u8, 2),
        .label = "quoted\"\n",
    });
    try root.end();
    try std.testing.expectEqualStrings(
        "{\"status\":\"ready\",\"count\":2,\"label\":\"quoted\\\"\\n\"}",
        out.written(),
    );
}

test "Object formats and escapes field names without allocation" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .minified);
    const root = try writer.object();
    try root.formattedField(32, "field-\"{d}", .{1}, true);
    const child = try root.formattedObject(32, "object-\"{d}", .{2});
    try child.field("ok", true);
    try child.end();
    const values = try root.formattedArray(32, "array-\"{d}", .{3});
    try values.element(@as(u8, 7));
    try values.end();
    try root.end();
    try std.testing.expectEqualStrings(
        "{\"field-\\\"1\":true,\"object-\\\"2\":{\"ok\":true},\"array-\\\"3\":[7]}",
        out.written(),
    );
}

test "Writer scope formatting indents nested records" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var writer = Writer.init(&out.writer, .indent_2);
    const root = try writer.object();
    try root.field("status", "ok");
    try root.fieldParts(&.{ "mean_", "ns", "_per_", "source\"op" }, 30);
    const values = try root.array("values");
    try values.element(@as(u8, 1));
    try values.element(@as(u8, 2));
    try values.end();
    try root.end();
    try std.testing.expectEqualStrings(
        "{\n  \"status\": \"ok\",\n  \"mean_ns_per_source\\\"op\": 30," ++
            "\n  \"values\": [\n    1,\n    2\n  ]\n}",
        out.written(),
    );
}
