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
