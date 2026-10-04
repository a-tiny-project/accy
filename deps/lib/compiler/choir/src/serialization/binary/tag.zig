const std = @import("std");

pub fn encodeTag(value: anytype) error{LimitExceeded}!u8 {
    return std.math.cast(u8, @backingInt(value)) orelse error.LimitExceeded;
}

pub fn decodeTag(comptime T: type, value: u8) error{InvalidTag}!T {
    return std.enums.fromInt(T, value) orelse error.InvalidTag;
}
