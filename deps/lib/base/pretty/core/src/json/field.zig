const std = @import("std");
const escape = @import("escape.zig");
const scalar = @import("scalar.zig");

pub const Field = struct {
    first: bool = false,
};

pub fn writeFieldName(writer: anytype, name: []const u8, field: Field) !void {
    if (!field.first) try writer.writeByte(',');
    try escape.writeString(writer, name);
    try writer.writeByte(':');
}

pub fn writeFieldString(writer: anytype, name: []const u8, value: []const u8, field: Field) !void {
    try writeFieldName(writer, name, field);
    try escape.writeString(writer, value);
}

pub fn writeFieldOptionalString(writer: anytype, name: []const u8, value: ?[]const u8, field: Field) !void {
    try writeFieldName(writer, name, field);
    if (value) |inner| try escape.writeString(writer, inner) else try scalar.writeNull(writer);
}

pub fn writeFieldBool(writer: anytype, name: []const u8, value: bool, field: Field) !void {
    try writeFieldName(writer, name, field);
    try scalar.writeBool(writer, value);
}

pub fn writeFieldInt(writer: anytype, name: []const u8, value: anytype, field: Field) !void {
    try writeFieldName(writer, name, field);
    try scalar.writeInt(writer, value);
}

pub fn writeFieldRaw(writer: anytype, name: []const u8, raw_json: []const u8, field: Field) !void {
    try writeFieldName(writer, name, field);
    try writer.writeAll(raw_json);
}
