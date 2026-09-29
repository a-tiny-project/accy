const builtin = @import("builtin");
const std = @import("std");

pub fn rotateLeft(
    comptime D: type,
    comptime amount: usize,
    value: D.Vector,
) D.Vector {
    validate(D);
    validateAmount(D, amount);
    const amounts: UnsignedVector(D) = @splat(amount);
    return rotateLeftBits(D, value, amounts);
}

pub fn rotateRight(
    comptime D: type,
    comptime amount: usize,
    value: D.Vector,
) D.Vector {
    validate(D);
    validateAmount(D, amount);
    const amounts: UnsignedVector(D) = @splat(amount);
    return rotateRightBits(D, value, amounts);
}

pub fn rotateLeftSame(comptime D: type, value: D.Vector, amount: i32) D.Vector {
    validate(D);
    const normalized: UnsignedLane(D) = @intCast(@mod(amount, @bitSizeOf(D.Lane)));
    return rotateLeftBits(D, value, @splat(normalized));
}

pub fn rotateRightSame(comptime D: type, value: D.Vector, amount: i32) D.Vector {
    validate(D);
    const normalized: UnsignedLane(D) = @intCast(@mod(amount, @bitSizeOf(D.Lane)));
    return rotateRightBits(D, value, @splat(normalized));
}

pub fn rol(comptime D: type, value: D.Vector, amounts: D.Vector) D.Vector {
    validate(D);
    const raw: UnsignedVector(D) = @bitCast(amounts);
    return rotateLeftBits(D, value, raw);
}

pub fn ror(comptime D: type, value: D.Vector, amounts: D.Vector) D.Vector {
    validate(D);
    const raw: UnsignedVector(D) = @bitCast(amounts);
    return rotateRightBits(D, value, raw);
}

pub fn multiRotateRight(
    comptime D: type,
    value: D.Vector,
    indices: D.repartition(u8).Vector,
) D.Vector {
    validate(D);
    if (@bitSizeOf(D.Lane) != 64) @compileError("multiRotateRight requires 64-bit lanes");
    const bits: @Vector(D.lane_count, u64) = @bitCast(value);
    const index_lanes: [D.lane_count * 8]u8 = indices;
    var result: @Vector(D.lane_count, u64) = @splat(0);
    inline for (0..D.lane_count) |lane_index| {
        var lane: u64 = 0;
        inline for (0..8) |byte_index| {
            const amount = index_lanes[lane_index * 8 + byte_index] & 63;
            const byte: u8 = @truncate(std.math.rotr(u64, bits[lane_index], amount));
            const destination = if (builtin.cpu.arch.endian() == .little)
                byte_index
            else
                byte_index ^ 7;
            lane |= @as(u64, byte) << @intCast(destination * 8);
        }
        result[lane_index] = lane;
    }
    return @bitCast(result);
}

fn rotateLeftBits(
    comptime D: type,
    value: D.Vector,
    raw_amounts: UnsignedVector(D),
) D.Vector {
    const bits: UnsignedVector(D) = @bitCast(value);
    const zero: UnsignedVector(D) = @splat(0);
    const left: AmountVector(D) = @truncate(raw_amounts);
    const right: AmountVector(D) = @truncate(zero -% raw_amounts);
    return @bitCast((bits << left) | (bits >> right));
}

fn rotateRightBits(
    comptime D: type,
    value: D.Vector,
    raw_amounts: UnsignedVector(D),
) D.Vector {
    const bits: UnsignedVector(D) = @bitCast(value);
    const zero: UnsignedVector(D) = @splat(0);
    const right: AmountVector(D) = @truncate(raw_amounts);
    const left: AmountVector(D) = @truncate(zero -% raw_amounts);
    return @bitCast((bits >> right) | (bits << left));
}

fn UnsignedLane(comptime D: type) type {
    return @Int(.unsigned, @bitSizeOf(D.Lane));
}

fn UnsignedVector(comptime D: type) type {
    return @Vector(D.lane_count, UnsignedLane(D));
}

fn AmountVector(comptime D: type) type {
    return @Vector(D.lane_count, std.math.Log2Int(UnsignedLane(D)));
}

fn validate(comptime D: type) void {
    if (@typeInfo(D.Lane) != .int) @compileError("rotations require integer lanes");
}

fn validateAmount(comptime D: type, comptime amount: usize) void {
    if (amount >= @bitSizeOf(D.Lane)) @compileError("rotation amount exceeds lane width");
}

fn verifyLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const U = @Int(.unsigned, @bitSizeOf(T));
    const UV = @Vector(4, U);
    const raw: UV = .{ 0, 1, @as(U, 1) << (@bitSizeOf(T) - 1), std.math.maxInt(U) };
    const value: D.Vector = @bitCast(raw);
    try std.testing.expect(@reduce(.And, rotateRight(D, 1, rotateLeft(D, 1, value)) == value));
    try std.testing.expect(@reduce(.And, rotateRightSame(D, rotateLeftSame(D, value, -3), -3) == value));
}

test "Highway rotations instantiate every integer lane type" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64 }) |T| {
        try verifyLaneType(T);
    }
}

test "Highway fixed rotations wrap every shifted bit" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u8, 4);
    const value: D.Vector = .{ 0x01, 0x80, 0x55, 0x81 };
    try std.testing.expect(@reduce(.And, rotateLeft(D, 1, value) ==
        @as(D.Vector, .{ 0x02, 0x01, 0xaa, 0x03 })));
    try std.testing.expect(@reduce(.And, rotateRight(D, 1, value) ==
        @as(D.Vector, .{ 0x80, 0x40, 0xaa, 0xc0 })));
    try std.testing.expect(@reduce(.And, rotateLeft(D, 0, value) == value));
}

test "Highway variable rotations mask signed amounts" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i16, 4);
    const U = simd.FixedTag(u16, 4);
    const value: D.Vector = @bitCast(@as(U.Vector, .{ 1, 0x8000, 0x1234, 0x55aa }));
    const amounts: D.Vector = .{ 0, 1, -4, 17 };
    const round_trip = ror(D, rol(D, value, amounts), amounts);
    try std.testing.expect(@reduce(.And, round_trip == value));
    try std.testing.expect(@reduce(.And, rotateLeftSame(D, value, -1) == rotateRight(D, 1, value)));
}

test "Highway multi rotate composes bytes within each u64 lane" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u64, 2);
    const DI = D.repartition(u8);
    const value: D.Vector = .{ 0x0102_0304_0506_0708, 0x1020_3040_5060_7080 };
    const indices: DI.Vector = .{
        0,  8,  16, 24, 32, 40, 48, 56,
        56, 48, 40, 32, 24, 16, 8,  0,
    };
    const expected: D.Vector = if (builtin.cpu.arch.endian() == .little)
        .{ value[0], @byteSwap(value[1]) }
    else
        .{ @byteSwap(value[0]), value[1] };
    try std.testing.expect(@reduce(.And, multiRotateRight(D, value, indices) == expected));
}
