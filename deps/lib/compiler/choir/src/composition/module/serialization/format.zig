const std = @import("std");
const binary = @import("../../../serialization/root.zig").binary;

pub const magic = "CHOIRCMP";
pub const version: u32 = 6;
pub const header_size = magic.len + @sizeOf(u32) + @sizeOf(u64);
pub const checksum_size = @sizeOf(u32);
pub const max_serialized_bytes: usize = 256 * 1024 * 1024;
pub const max_string_bytes: usize = 1024 * 1024;
pub const max_blob_bytes: usize = 256 * 1024 * 1024;
pub const max_collection_entries: usize = 1 << 16;
pub const max_total_entries: usize = 1 << 18;

/// Distinct compiler manifests one module may reference. Fragments are assembled
/// from a handful of toolchains at most, and a stream that needs more is refused
/// rather than served with a table the import store cannot hold.
pub const max_compiler_manifests: usize = 16;

pub const limits = binary.Limits{
    .serialized_bytes = max_serialized_bytes,
    .string_bytes = max_string_bytes,
    .blob_bytes = max_blob_bytes,
    .collection_entries = max_collection_entries,
    .total_entries = max_total_entries,
};

pub const Error = binary.Error || error{
    InvalidMagic,
    UnsupportedVersion,
    TrailingBytes,
    InvalidChecksum,
};

pub const WriteError = binary.WriteError;
pub const Writer = binary.Writer(limits);
pub const Reader = binary.Reader(limits);

pub fn initWriter(allocator: std.mem.Allocator) WriteError!Writer {
    var writer = Writer.init(allocator);
    errdefer writer.deinit();
    try writer.writeRaw(magic);
    try writer.writeInt(u32, version);
    try writer.writeInt(u64, 0);
    return writer;
}

pub fn finishWriter(writer: *Writer) WriteError![]u8 {
    const payload = writer.bytes.items[header_size..];
    const payload_length = std.math.cast(u64, payload.len) orelse return error.LimitExceeded;
    const length_offset = magic.len + @sizeOf(u32);
    std.mem.writeInt(u64, writer.bytes.items[length_offset..][0..@sizeOf(u64)], payload_length, .little);
    try writer.writeInt(u32, checksum(payload));
    return try writer.finish();
}

pub fn checksum(payload: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(payload);
    return crc.final();
}

pub fn readPayload(bytes: []const u8) Error!Reader {
    if (bytes.len > max_serialized_bytes) return error.LimitExceeded;
    if (bytes.len < header_size + checksum_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u32, bytes[magic.len..][0..@sizeOf(u32)], .little) != version) return error.UnsupportedVersion;

    const length_offset = magic.len + @sizeOf(u32);
    const payload_length_u64 = std.mem.readInt(u64, bytes[length_offset..][0..@sizeOf(u64)], .little);
    const payload_length = std.math.cast(usize, payload_length_u64) orelse return error.LimitExceeded;
    const expected_length = std.math.add(usize, header_size, payload_length) catch return error.LimitExceeded;
    const framed_length = std.math.add(usize, expected_length, checksum_size) catch return error.LimitExceeded;
    if (framed_length > max_serialized_bytes) return error.LimitExceeded;
    if (bytes.len < framed_length) return error.Truncated;
    if (bytes.len > framed_length) return error.TrailingBytes;

    const payload = bytes[header_size..expected_length];
    const expected_checksum = std.mem.readInt(u32, bytes[expected_length..][0..checksum_size], .little);
    if (checksum(payload) != expected_checksum) return error.InvalidChecksum;
    return try Reader.init(payload);
}
