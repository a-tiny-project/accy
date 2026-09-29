const std = @import("std");
const model = @import("root.zig").model;

/// Linux PIPE_BUF is 4096. Each frame is one writev, never a buffered flush
/// or a continuation after a short write. Other inherited writers can appear
/// between frames, including in the middle of their own large writes.
pub const atomic_bytes = 4096;
pub const payload_bytes = 1024;
pub const header_bytes = 128;
pub const prefix = "@@tiny.compiled-binding-frame/v1 ";

pub fn frameBytesMax() usize {
    return header_bytes + 2 * payload_bytes;
}

pub fn frameCountMax() usize {
    return std.math.divCeil(usize, model.locatorBytesMax(), payload_bytes) catch unreachable;
}

pub fn transportBytesMax() usize {
    return 2 * model.locatorBytesMax() + header_bytes * frameCountMax();
}

/// The locator/announcement JSON wire is unchanged. Its bytes are hex-framed
/// with a full-message SHA256, byte offset and total length for bounded
/// reassembly. A leading LF protects each frame from another writer's prefix;
/// no other writer can insert bytes inside a successful atomic pipe frame.
pub fn write(io: std.Io, file: std.Io.File, announcement: []const u8) !void {
    if (@import("builtin").os.tag != .linux) return error.UnsupportedCompilerBindingTransport;
    if (announcement.len == 0 or announcement.len > model.locatorBytesMax()) return error.CompilerBindingLocatorTooLarge;
    const kind = (try file.stat(io)).kind;
    if (kind != .named_pipe and kind != .file) return error.UnsupportedCompilerBindingTransport;
    const digest = model.digest(announcement);
    var offset: usize = 0;
    var buffer: [frameBytesMax()]u8 = undefined;
    while (offset < announcement.len) {
        const count = @min(payload_bytes, announcement.len - offset);
        const bytes = try frame(&buffer, digest, offset, announcement.len, announcement[offset..][0..count]);
        const written = try file.writeStreaming(io, &.{}, &.{bytes}, 1);
        if (written != bytes.len) return error.CompilerBindingPartialFrame;
        offset += count;
    }
}

pub fn frame(buffer: []u8, digest: [64]u8, offset: usize, total: usize, payload: []const u8) ![]const u8 {
    if (total == 0 or total > model.locatorBytesMax() or offset >= total or
        offset % payload_bytes != 0 or payload.len != @min(payload_bytes, total - offset))
    {
        return error.InvalidCompilerBindingFrame;
    }
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("\n{s}{s} {d} {d} ", .{ prefix, &digest, offset, total });
    const alphabet = "0123456789abcdef";
    for (payload) |byte| {
        try writer.writeByte(alphabet[byte >> 4]);
        try writer.writeByte(alphabet[byte & 15]);
    }
    try writer.writeByte('\n');
    std.debug.assert(writer.buffered().len <= frameBytesMax());
    std.debug.assert(frameBytesMax() <= atomic_bytes);
    return writer.buffered();
}
