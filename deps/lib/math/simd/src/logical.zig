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
