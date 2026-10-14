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
