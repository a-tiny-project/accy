const std = @import("std");
const root = @import("../../../root.zig");

const model = root.model;

pub fn checkedU64(value: i128) model.Error!u64 {
    if (value < 0 or value > std.math.maxInt(u64)) return error.RelocationOverflow;
    return @intCast(value);
}

pub fn checkedX8664U64(value: i128) model.Error!u64 {
    if (value < std.math.minInt(i64) or value > std.math.maxInt(u64)) return error.RelocationOverflow;
    if (value < 0) return @bitCast(@as(i64, @intCast(value)));
    return @intCast(value);
}

pub fn checkedU32(value: i128) model.Error!u32 {
    if (value < 0 or value > std.math.maxInt(u32)) return error.RelocationOverflow;
    return @intCast(value);
}

pub fn checkedX8664U16(value: i128) model.Error!u16 {
    if (value < std.math.minInt(i16) or value > std.math.maxInt(u16)) return error.RelocationOverflow;
    return @bitCast(@as(i16, @truncate(value)));
}

pub fn checkedX8664U8(value: i128) model.Error!u8 {
    if (value < std.math.minInt(i8) or value > std.math.maxInt(u8)) return error.RelocationOverflow;
    return @bitCast(@as(i8, @truncate(value)));
}

pub fn checkedI64(value: i128) model.Error!i64 {
    if (value < std.math.minInt(i64) or value > std.math.maxInt(i64)) return error.RelocationOverflow;
    return @intCast(value);
}

pub fn checkedI32(value: i128) model.Error!i32 {
    if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return error.RelocationOverflow;
    return @intCast(value);
}

pub fn checkedI16(value: i128) model.Error!i16 {
    if (value < std.math.minInt(i16) or value > std.math.maxInt(i16)) return error.RelocationOverflow;
    return @intCast(value);
}

pub fn checkedI8(value: i128) model.Error!i8 {
    if (value < std.math.minInt(i8) or value > std.math.maxInt(i8)) return error.RelocationOverflow;
    return @intCast(value);
}
