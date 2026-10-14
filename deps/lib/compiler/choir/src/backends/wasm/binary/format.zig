const std = @import("std");
const binary = @import("root.zig");

pub fn writeHeader(out: anytype) !void {
    try out.writeAll(&.{ 0x00, 0x61, 0x73, 0x6d });
    try out.writeAll(&.{ 0x01, 0x00, 0x00, 0x00 });
}

pub fn writeSectionHeader(out: anytype, section: binary.Section, body_len: usize) !void {
    try out.writeByte(@backingInt(section));
    try writeUleb(out, body_len);
}

pub fn writeName(out: anytype, name: []const u8) !void {
    try writeUleb(out, name.len);
    try out.writeAll(name);
}

pub fn writeValueType(out: anytype, value_type: binary.ValueType) !void {
    try out.writeByte(@backingInt(value_type));
}

pub fn writeF32(out: anytype, value: f32) !void {
    try writeLittleU32(out, @bitCast(value));
}

pub fn writeF64(out: anytype, value: f64) !void {
    try writeLittleU64(out, @bitCast(value));
}

pub fn writeLittleU32(out: anytype, value: u32) !void {
    try out.writeByte(@intCast(value & 0xff));
    try out.writeByte(@intCast((value >> 8) & 0xff));
    try out.writeByte(@intCast((value >> 16) & 0xff));
    try out.writeByte(@intCast((value >> 24) & 0xff));
}

pub fn writeLittleU64(out: anytype, value: u64) !void {
    try writeLittleU32(out, @intCast(value & 0xffff_ffff));
    try writeLittleU32(out, @intCast(value >> 32));
}

pub fn writeUleb(out: anytype, value: anytype) !void {
    var remaining: u64 = @intCast(value);
    while (true) {
        var byte: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        if (remaining != 0) byte |= 0x80;
        try out.writeByte(byte);
        if (remaining == 0) return;
    }
}

pub fn writeSleb(out: anytype, value: i64) !void {
    var remaining = value;
    while (true) {
        var byte: u8 = @intCast(@as(u64, @bitCast(remaining)) & 0x7f);
        remaining >>= 7;
        const sign_bit = (byte & 0x40) != 0;
        const done = (remaining == 0 and !sign_bit) or (remaining == -1 and sign_bit);
        if (!done) byte |= 0x80;
        try out.writeByte(byte);
        if (done) return;
    }
}
