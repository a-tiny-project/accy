const std = @import("std");

pub fn bitNot(comptime D: type, value: D.Vector) D.Vector {
    const UVector = unsignedVector(D);
    const bits: UVector = @bitCast(value);
    return @bitCast(~bits);
}

pub fn bitAnd(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    const UVector = unsignedVector(D);
    const a_bits: UVector = @bitCast(a);
    const b_bits: UVector = @bitCast(b);
    return @bitCast(a_bits & b_bits);
}

pub fn andNot(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return bitAnd(D, bitNot(D, a), b);
}

pub fn bitOr(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    const UVector = unsignedVector(D);
    const a_bits: UVector = @bitCast(a);
    const b_bits: UVector = @bitCast(b);
    return @bitCast(a_bits | b_bits);
}

pub fn bitXor(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    const UVector = unsignedVector(D);
    const a_bits: UVector = @bitCast(a);
    const b_bits: UVector = @bitCast(b);
    return @bitCast(a_bits ^ b_bits);
}

pub fn or3(comptime D: type, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return bitOr(D, a, bitOr(D, b, c));
}

pub fn xor3(comptime D: type, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return bitXor(D, a, bitXor(D, b, c));
}

pub fn orAnd(comptime D: type, o: D.Vector, a: D.Vector, b: D.Vector) D.Vector {
    return bitOr(D, o, bitAnd(D, a, b));
}

pub fn xorAndNot(comptime D: type, x: D.Vector, a: D.Vector, b: D.Vector) D.Vector {
    return bitXor(D, x, andNot(D, a, b));
}

pub fn andXor(comptime D: type, a: D.Vector, x: D.Vector, y: D.Vector) D.Vector {
    return bitAnd(D, a, bitXor(D, x, y));
}

pub fn maskedOrOr(
    comptime D: type,
    inactive: D.Vector,
    mask: D.Mask,
    a: D.Vector,
    b: D.Vector,
) D.Vector {
    return @select(D.Lane, mask, bitOr(D, a, b), inactive);
}

pub fn maskedOr(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedOrOr(D, @splat(0), mask, a, b);
}

pub fn maskedXorOr(
    comptime D: type,
    inactive: D.Vector,
    mask: D.Mask,
    a: D.Vector,
    b: D.Vector,
) D.Vector {
    return @select(D.Lane, mask, bitXor(D, a, b), inactive);
}

pub fn maskedXor(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedXorOr(D, @splat(0), mask, a, b);
}

pub fn testBit(comptime D: type, value: D.Vector, bit: D.Vector) D.Mask {
    if (comptime @typeInfo(D.Lane) != .int) {
        @compileError("testBit requires integer lanes");
    }
    return bitAnd(D, value, bit) == bit;
}

pub fn allBitsZero(comptime D: type, value: D.Vector) bool {
    const UVector = unsignedVector(D);
    const bits: UVector = @bitCast(value);
    return !@reduce(.Or, bits != @as(UVector, @splat(0)));
}

pub fn allBitsOne(comptime D: type, value: D.Vector) bool {
    const UVector = unsignedVector(D);
    const bits: UVector = @bitCast(value);
    return !@reduce(.Or, bits != @as(UVector, @splat(~@as(unsignedLane(D.Lane), 0))));
}

fn unsignedVector(comptime D: type) type {
    return @Vector(D.lane_count, unsignedLane(D.Lane));
}

fn unsignedLane(comptime T: type) type {
    return @Int(.unsigned, @bitSizeOf(T));
}

test "logical operations match Highway truth tables" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u32, 4);
    const zero: D.Vector = @splat(0);
    const value: D.Vector = .{ 0, 1, 2, 3 };
    try std.testing.expect(@reduce(.And, bitAnd(D, value, value) == value));
    try std.testing.expect(@reduce(.And, bitXor(D, value, value) == zero));
    try std.testing.expect(@reduce(.And, bitOr(D, value, zero) == value));
    try std.testing.expect(allBitsZero(D, bitAnd(D, value, bitNot(D, value))));
    try std.testing.expect(allBitsOne(D, bitOr(D, value, bitNot(D, value))));
}

test "logical operations preserve floating-point bit patterns" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f32, 4);
    const U = simd.FixedTag(u32, 4);
    const value: D.Vector = @bitCast(@as(U.Vector, .{ 0, 1, 0x8000_0000, 0x7f80_0000 }));
    const twice = bitXor(D, value, value);
    try std.testing.expect(allBitsZero(D, twice));
    const inverted: U.Vector = @bitCast(bitNot(D, value));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), inverted[0]);
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), inverted[2]);
}

test "Highway ternary and masked logical operations match scalar bit formulas" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u8, 4);
    const a: D.Vector = .{ 0x0f, 0xf0, 0xaa, 0x55 };
    const b: D.Vector = .{ 0x33, 0x33, 0xcc, 0xcc };
    const c: D.Vector = .{ 0x55, 0xaa, 0x0f, 0xf0 };
    try std.testing.expect(@reduce(.And, xorAndNot(D, a, b, c) == (a ^ (~b & c))));
    try std.testing.expect(@reduce(.And, andXor(D, a, b, c) == (a & (b ^ c))));
    const mask: D.Mask = .{ true, false, false, true };
    try std.testing.expect(@reduce(.And, maskedOrOr(D, @splat(7), mask, a, b) ==
        @as(D.Vector, .{ 0x3f, 7, 7, 0xdd })));
    try std.testing.expect(@reduce(.And, maskedXor(D, mask, a, b) ==
        @as(D.Vector, .{ 0x3c, 0, 0, 0x99 })));
}
