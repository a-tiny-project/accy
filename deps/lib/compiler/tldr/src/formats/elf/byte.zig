const std = @import("std");

pub fn copyInto(buffer: []u8, offset: usize, bytes: []const u8) void {
    if (bytes.len == 0) return;
    @memcpy(buffer[offset .. offset + bytes.len], bytes);
}

pub fn elfSymbolInfo(binding: anytype, kind: anytype) u8 {
    return (@as(u8, binding) << 4) | @as(u8, kind);
}

pub fn hashU64(seed: u64, value: u64) u64 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return std.hash.Wyhash.hash(seed, &bytes);
}

pub fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

pub fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

pub fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

pub fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

pub fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

pub fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
}
