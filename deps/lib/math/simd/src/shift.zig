const std = @import("std");

pub fn shiftLeft(
    comptime D: type,
    comptime amount: usize,
    value: D.Vector,
) D.Vector {
    validate(D);
    validateAmount(D, amount);
    const bits: UnsignedVector(D) = @bitCast(value);
    return @bitCast(bits << sameAmount(D, amount));
}

pub fn shiftRight(
    comptime D: type,
    comptime amount: usize,
    value: D.Vector,
) D.Vector {
    validate(D);
    validateAmount(D, amount);
    return value >> sameAmount(D, amount);
}

pub fn shiftLeftSame(comptime D: type, value: D.Vector, amount: usize) D.Vector {
    validate(D);
    std.debug.assert(amount < @bitSizeOf(D.Lane));
    const bits: UnsignedVector(D) = @bitCast(value);
    return @bitCast(bits << sameAmount(D, amount));
}

pub fn shiftRightSame(comptime D: type, value: D.Vector, amount: usize) D.Vector {
    validate(D);
    std.debug.assert(amount < @bitSizeOf(D.Lane));
    return value >> sameAmount(D, amount);
}

pub fn shl(comptime D: type, value: D.Vector, amounts: D.Vector) D.Vector {
    validate(D);
    const bits: UnsignedVector(D) = @bitCast(value);
    return @bitCast(bits << laneAmounts(D, amounts));
}

pub fn shr(comptime D: type, value: D.Vector, amounts: D.Vector) D.Vector {
    validate(D);
    return value >> laneAmounts(D, amounts);
}

pub fn averageRound(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    validate(D);
    return (a | b) -% ((a ^ b) >> sameAmount(D, 1));
}

pub fn roundingShiftRight(
    comptime D: type,
    comptime amount: usize,
    value: D.Vector,
) D.Vector {
    validateAmount(D, amount);
    if (amount == 0) return value;
    return averageRound(D, shiftRight(D, amount - 1, value), @splat(0));
}

pub fn roundingShiftRightSame(
    comptime D: type,
    value: D.Vector,
    amount: usize,
) D.Vector {
    std.debug.assert(amount < @bitSizeOf(D.Lane));
    if (amount == 0) return value;
    return averageRound(D, shiftRightSame(D, value, amount - 1), @splat(0));
}

pub fn roundingShr(comptime D: type, value: D.Vector, amounts: D.Vector) D.Vector {
    validate(D);
    const U = UnsignedVector(D);
    const raw: U = @bitCast(amounts);
    const zero: U = @splat(0);
    const one: U = @splat(1);
    const scaled_amounts: U = @select(UnsignedLane(D), raw == zero, zero, raw -% one);
    const scaled = shr(D, value, @bitCast(scaled_amounts));
    const other = @select(D.Lane, raw == zero, scaled, @as(D.Vector, @splat(0)));
    return averageRound(D, scaled, other);
}

pub fn maskedShiftLeftOr(
    comptime D: type,
    comptime amount: usize,
    no: D.Vector,
    mask: D.Mask,
    value: D.Vector,
) D.Vector {
    return @select(D.Lane, mask, shiftLeft(D, amount, value), no);
}

pub fn maskedShiftLeft(
    comptime D: type,
    comptime amount: usize,
    mask: D.Mask,
    value: D.Vector,
) D.Vector {
    return maskedShiftLeftOr(D, amount, @splat(0), mask, value);
}

pub fn maskedShiftRightOr(
    comptime D: type,
    comptime amount: usize,
    no: D.Vector,
    mask: D.Mask,
    value: D.Vector,
) D.Vector {
    return @select(D.Lane, mask, shiftRight(D, amount, value), no);
}

pub fn maskedShiftRight(
    comptime D: type,
    comptime amount: usize,
    mask: D.Mask,
    value: D.Vector,
) D.Vector {
    return maskedShiftRightOr(D, amount, @splat(0), mask, value);
}

pub fn maskedShlOr(
    comptime D: type,
    no: D.Vector,
    mask: D.Mask,
    value: D.Vector,
    amounts: D.Vector,
) D.Vector {
    return @select(D.Lane, mask, shl(D, value, amounts), no);
}

pub fn maskedShl(
    comptime D: type,
    mask: D.Mask,
    value: D.Vector,
    amounts: D.Vector,
) D.Vector {
    return maskedShlOr(D, @splat(0), mask, value, amounts);
}

pub fn maskedShrOr(
    comptime D: type,
    no: D.Vector,
    mask: D.Mask,
    value: D.Vector,
    amounts: D.Vector,
) D.Vector {
    return @select(D.Lane, mask, shr(D, value, amounts), no);
}

pub fn maskedShr(
    comptime D: type,
    mask: D.Mask,
    value: D.Vector,
    amounts: D.Vector,
) D.Vector {
    return maskedShrOr(D, @splat(0), mask, value, amounts);
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

fn sameAmount(comptime D: type, amount: usize) AmountVector(D) {
    return @splat(@intCast(amount));
}

fn laneAmounts(comptime D: type, amounts: D.Vector) AmountVector(D) {
    const raw: UnsignedVector(D) = @bitCast(amounts);
    return @truncate(raw);
}

fn validate(comptime D: type) void {
    if (@typeInfo(D.Lane) != .int) @compileError("shifts require integer lanes");
}

fn validateAmount(comptime D: type, comptime amount: usize) void {
    validate(D);
    if (amount >= @bitSizeOf(D.Lane)) @compileError("shift amount exceeds lane width");
}

fn verifyLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const U = @Int(.unsigned, @bitSizeOf(T));
    const UV = @Vector(4, U);
    const raw: UV = .{ 0, 1, @as(U, 1) << (@bitSizeOf(T) - 1), std.math.maxInt(U) };
    const value: D.Vector = @bitCast(raw);
    const amounts: D.Vector = @splat(@as(T, 1));
    try std.testing.expect(@reduce(.And, shiftLeft(D, 1, value) == shl(D, value, amounts)));
    try std.testing.expect(@reduce(.And, shiftRight(D, 1, value) == shr(D, value, amounts)));
    try std.testing.expect(@reduce(.And, shiftLeftSame(D, value, 1) == shiftLeft(D, 1, value)));
    try std.testing.expect(@reduce(.And, shiftRightSame(D, value, 1) == shiftRight(D, 1, value)));
    try std.testing.expect(@reduce(.And, roundingShiftRight(D, 0, value) == value));
}
