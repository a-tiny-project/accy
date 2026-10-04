const std = @import("std");

pub fn signBit(comptime D: type) D.Vector {
    const U = UnsignedLane(D);
    const mask: U = @as(U, 1) << (@bitSizeOf(D.Lane) - 1);
    return @bitCast(@as(UnsignedVector(D), @splat(mask)));
}

pub fn copySign(comptime D: type, magnitude: D.Vector, sign: D.Vector) D.Vector {
    validateFloat(D);
    const mask: UnsignedVector(D) = @bitCast(signBit(D));
    const magnitude_bits: UnsignedVector(D) = @bitCast(magnitude);
    const sign_bits: UnsignedVector(D) = @bitCast(sign);
    return @bitCast((magnitude_bits & ~mask) | (sign_bits & mask));
}

pub fn copySignToAbs(comptime D: type, absolute: D.Vector, sign: D.Vector) D.Vector {
    validateFloat(D);
    const mask: UnsignedVector(D) = @bitCast(signBit(D));
    const absolute_bits: UnsignedVector(D) = @bitCast(absolute);
    const sign_bits: UnsignedVector(D) = @bitCast(sign);
    return @bitCast(absolute_bits | (sign_bits & mask));
}

pub fn broadcastSignBit(comptime D: type, value: D.Vector) D.Vector {
    if (@typeInfo(D.Lane) != .int or
        @typeInfo(D.Lane).int.signedness != .signed)
    {
        @compileError("broadcastSignBit requires signed integer lanes");
    }
    const Amount = @Vector(D.lane_count, std.math.Log2Int(UnsignedLane(D)));
    const amount: Amount = @splat(@bitSizeOf(D.Lane) - 1);
    return value >> amount;
}

fn UnsignedLane(comptime D: type) type {
    return @Int(.unsigned, @bitSizeOf(D.Lane));
}

fn UnsignedVector(comptime D: type) type {
    return @Vector(D.lane_count, UnsignedLane(D));
}

fn validateFloat(comptime D: type) void {
    if (@typeInfo(D.Lane) != .float) @compileError("copySign requires floating-point lanes");
}

fn verifyBroadcast(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const value: D.Vector = .{ 0, 1, -1, std.math.minInt(T) };
    try std.testing.expect(@reduce(.And, broadcastSignBit(D, value) ==
        @as(D.Vector, .{ 0, 0, -1, -1 })));
}

fn verifyCopySign(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const U = @Int(.unsigned, @bitSizeOf(T));
    const UV = @Vector(4, U);
    const sign_mask: U = @as(U, 1) << (@bitSizeOf(T) - 1);
    const one_bits: U = @bitCast(@as(T, 1));
    const signs: D.Vector = @bitCast(@as(UV, .{ 0, sign_mask, sign_mask, 0 }));
    const magnitude: D.Vector = @splat(1);
    const expected: UV = .{ one_bits, one_bits | sign_mask, one_bits | sign_mask, one_bits };
    try std.testing.expect(@reduce(.And, @as(UV, @bitCast(copySign(D, magnitude, signs))) == expected));
    try std.testing.expect(@reduce(.And, @as(UV, @bitCast(copySignToAbs(D, magnitude, signs))) == expected));
}
