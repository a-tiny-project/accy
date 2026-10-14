const std = @import("std");
const artifact = @import("../root.zig");

pub const format = @import("format.zig");
pub const metadata = @import("metadata.zig");
pub const option = @import("option.zig");
pub const linkage = @import("linkage.zig");
pub const payload = @import("payload.zig");
pub const verification = @import("verification.zig");

pub const magic = format.magic;
pub const format_version = format.version;
pub const SerializeError = format.WriteError;
pub const DeserializeError = format.Error || std.mem.Allocator.Error;

pub fn serialize(allocator: std.mem.Allocator, value: *const artifact.Artifact) SerializeError![]u8 {
    var writer = format.Writer.init(allocator);
    errdefer writer.deinit();
    try writer.writeRaw(format.magic);
    try writer.writeInt(u32, format.version);
    try metadata.write(&writer, value.metadata);
    try option.write(&writer, value.options);
    try linkage.write(&writer, value.linkage);
    try payload.write(&writer, value.payload);
    try verification.write(&writer, value.verification);
    return try writer.finish();
}

pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) DeserializeError!artifact.Artifact {
    var reader = try format.Reader.init(bytes);
    if (!std.mem.eql(u8, try reader.readRaw(format.magic.len), format.magic)) return error.InvalidMagic;
    if (try reader.readInt(u32) != format.version) return error.UnsupportedVersion;

    var decoded_metadata = try metadata.read(allocator, &reader);
    defer decoded_metadata.deinit();
    var value = try artifact.Artifact.init(allocator, decoded_metadata.value);
    errdefer value.deinit();
    try option.readInto(&reader, &value.options);
    try linkage.readInto(&reader, &value.linkage);
    try payload.readInto(&reader, &value.payload);
    try verification.readInto(&reader, allocator, &value.verification);
    if (!reader.atEnd()) return error.TrailingBytes;
    return value;
}
