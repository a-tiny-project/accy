const std = @import("std");

pub const Divisor = ScalarDivisor(u32);
pub const Divisor64 = ScalarDivisor(u64);

pub fn ScalarDivisor(comptime T: type) type {
    requireUnsigned(T);
    if (T != u32 and T != u64) {
        @compileError("Highway scalar divisors require u32 or u64");
    }
    return struct {
        params: DivisorParamsU(T),

        const Self = @This();

        pub fn init(divisor: T) Self {
            return .{ .params = computeDivisorParams(T, divisor) };
        }

        pub fn getDivisor(self: Self) T {
            return self.params.divisor;
        }

        pub fn divide(self: Self, dividend: T) T {
            return intDivScalar(T, dividend, self.params);
        }

        pub fn remainder(self: Self, dividend: T) T {
            return dividend - self.divide(dividend) * self.params.divisor;
        }
    };
}

pub fn DivisorParamsU(comptime T: type) type {
    requireUnsigned(T);
    const M = Multiplier(T);
    return struct {
        multiplier: M,
        shift2: u8,
        is_pow2: bool,
        pow2_shift: u8,
        divisor: T,
    };
}

pub fn DivisorParamsS(comptime T: type) type {
    requireSigned(T);
    const M = Multiplier(T);
    return struct {
        multiplier: M,
        shift: u8,
        divisor: T,
        dsign: T,
        is_pow2: bool,
        is_neg_one: bool,
        pow2_shift: u8,
    };
}

pub fn DivisorParams(comptime T: type) type {
    requireInteger(T);
    return if (isSigned(T)) DivisorParamsS(T) else DivisorParamsU(T);
}

pub fn computeDivisorParams(comptime T: type, divisor: T) DivisorParams(T) {
    std.debug.assert(divisor != 0);
    return if (comptime isSigned(T))
        computeSignedParams(T, divisor)
    else
        computeUnsignedParams(T, divisor);
}

pub fn intDiv(comptime D: type, dividend: D.Vector, params: DivisorParams(D.Lane)) D.Vector {
    requireInteger(D.Lane);
    std.debug.assert(params.divisor != 0);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = intDivScalar(D.Lane, dividend[index], params);
    }
    return result;
}

pub fn intDivFloor(comptime D: type, dividend: D.Vector, params: DivisorParams(D.Lane)) D.Vector {
    requireInteger(D.Lane);
    std.debug.assert(params.divisor != 0);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = intDivFloorScalar(D.Lane, dividend[index], params);
    }
    return result;
}

pub fn divideByScalar(comptime D: type, dividend: D.Vector, divisor: D.Lane) D.Vector {
    return intDiv(D, dividend, computeDivisorParams(D.Lane, divisor));
}

pub fn floorDivideByScalar(comptime D: type, dividend: D.Vector, divisor: D.Lane) D.Vector {
    return intDivFloor(D, dividend, computeDivisorParams(D.Lane, divisor));
}

pub fn divideArrayByScalar(comptime T: type, array: []T, divisor: T) void {
    requireInteger(T);
    std.debug.assert(divisor != 0);
    const params = computeDivisorParams(T, divisor);
    for (array) |*value| value.* = intDivScalar(T, value.*, params);
}

pub fn floorDivideArrayByScalar(comptime T: type, array: []T, divisor: T) void {
    requireInteger(T);
    std.debug.assert(divisor != 0);
    const params = computeDivisorParams(T, divisor);
    for (array) |*value| value.* = intDivFloorScalar(T, value.*, params);
}

pub fn div128HighBy(high: u64, divisor: u64) u64 {
    std.debug.assert(divisor != 0);
    std.debug.assert(high < divisor);
    return @intCast((@as(u128, high) << 64) / divisor);
}

fn computeUnsignedParams(comptime T: type, divisor: T) DivisorParamsU(T) {
    if (std.math.isPowerOfTwo(divisor)) {
        return .{
            .multiplier = 1,
            .shift2 = 0,
            .is_pow2 = true,
            .pow2_shift = @intCast(@ctz(divisor)),
            .divisor = divisor,
        };
    }

    const bits = @bitSizeOf(T);
    const l: usize = @as(usize, std.math.log2_int(T, divisor - 1)) + 1;
    const wide_divisor: u128 = divisor;
    const numerator = ((@as(u128, 1) << @intCast(l)) - wide_divisor) << @intCast(bits);
    const multiplier: Multiplier(T) = @intCast(numerator / wide_divisor + 1);
    return .{
        .multiplier = multiplier,
        .shift2 = @intCast(l - 1),
        .is_pow2 = false,
        .pow2_shift = 0,
        .divisor = divisor,
    };
}

fn computeSignedParams(comptime T: type, divisor: T) DivisorParamsS(T) {
    const U = @Int(.unsigned, @bitSizeOf(T));
    const raw: U = @bitCast(divisor);
    const abs_divisor: U = if (divisor < 0) 0 -% raw else raw;
    const dsign: T = if (divisor < 0) -1 else 0;
    if (std.math.isPowerOfTwo(abs_divisor)) {
        return .{
            .multiplier = 1,
            .shift = 0,
            .divisor = divisor,
            .dsign = dsign,
            .is_pow2 = true,
            .is_neg_one = divisor == -1,
            .pow2_shift = @intCast(@ctz(abs_divisor)),
        };
    }

    const bits = @bitSizeOf(T);
    const shift: usize = std.math.log2_int(U, abs_divisor - 1);
    const wide_multiplier = (@as(u128, 1) << @intCast(bits + shift)) / abs_divisor + 1;
    const low: U = @truncate(wide_multiplier);
    const signed_low: T = @bitCast(low);
    return .{
        .multiplier = @intCast(signed_low),
        .shift = @intCast(shift),
        .divisor = divisor,
        .dsign = dsign,
        .is_pow2 = false,
        .is_neg_one = divisor == -1,
        .pow2_shift = 0,
    };
}

fn intDivScalar(comptime T: type, dividend: T, params: DivisorParams(T)) T {
    if (comptime isSigned(T)) return intDivSignedScalar(T, dividend, params);
    if (params.is_pow2) return dividend >> @intCast(params.pow2_shift);
    const W = Product(T);
    const product: W = @as(W, dividend) * @as(W, params.multiplier);
    const high: T = @intCast(product >> @intCast(@bitSizeOf(T)));
    const sum = high + ((dividend - high) >> 1);
    return sum >> @intCast(params.shift2);
}

fn intDivSignedScalar(comptime T: type, dividend: T, params: DivisorParamsS(T)) T {
    const U = @Int(.unsigned, @bitSizeOf(T));
    if (params.is_pow2) {
        if (params.pow2_shift == 0) return (dividend ^ params.dsign) -% params.dsign;
        const mask_bits = (@as(U, 1) << @intCast(params.pow2_shift)) - 1;
        const mask: T = @bitCast(mask_bits);
        const sign = dividend >> @intCast(@bitSizeOf(T) - 1);
        const bias = sign & mask;
        const quotient = (dividend +% bias) >> @intCast(params.pow2_shift);
        return (quotient ^ params.dsign) -% params.dsign;
    }

    const W = Product(T);
    const product: W = @as(W, dividend) * @as(W, params.multiplier);
    const high: T = @intCast(product >> @intCast(@bitSizeOf(T)));
    var quotient = dividend +% high;
    quotient >>= @intCast(params.shift);
    quotient -%= dividend >> @intCast(@bitSizeOf(T) - 1);
    return (quotient ^ params.dsign) -% params.dsign;
}

fn intDivFloorScalar(comptime T: type, dividend: T, params: DivisorParams(T)) T {
    if (comptime !isSigned(T)) return intDivScalar(T, dividend, params);
    if (params.is_neg_one and dividend == std.math.minInt(T)) return 0;
    const quotient = intDivScalar(T, dividend, params);
    const remainder_nonzero = quotient *% params.divisor != dividend;
    const adjust: T = if (remainder_nonzero and (dividend < 0) != (params.divisor < 0)) 1 else 0;
    return quotient - adjust;
}

fn Multiplier(comptime T: type) type {
    const info = @typeInfo(T).int;
    const bits = if (info.bits < 32) info.bits * 2 else info.bits;
    return @Int(info.signedness, bits);
}

fn Product(comptime T: type) type {
    const info = @typeInfo(T).int;
    return @Int(info.signedness, info.bits * 2);
}

fn isSigned(comptime T: type) bool {
    return @typeInfo(T).int.signedness == .signed;
}

fn requireInteger(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => |info| if (info.bits != 8 and info.bits != 16 and info.bits != 32 and info.bits != 64) {
            @compileError("integer division requires 8/16/32/64-bit integer lanes");
        },
        else => @compileError("integer division requires integer lanes"),
    }
}

fn requireUnsigned(comptime T: type) void {
    requireInteger(T);
    if (isSigned(T)) @compileError("unsigned divisor parameters require unsigned integers");
}

fn requireSigned(comptime T: type) void {
    requireInteger(T);
    if (!isSigned(T)) @compileError("signed divisor parameters require signed integers");
}

test "Highway integer divisor parameters retain special cases" {
    const unsigned_three = computeDivisorParams(u8, 3);
    try std.testing.expectEqual(@as(u16, 86), unsigned_three.multiplier);
    try std.testing.expectEqual(@as(u8, 1), unsigned_three.shift2);
    try std.testing.expect(!unsigned_three.is_pow2);

    const u16_params = computeDivisorParams(u16, 16);
    try std.testing.expect(u16_params.is_pow2);
    try std.testing.expectEqual(@as(u8, 4), u16_params.pow2_shift);

    const s3 = computeDivisorParams(i8, 3);
    try std.testing.expectEqual(@as(i16, -85), s3.multiplier);
    try std.testing.expectEqual(@as(u8, 1), s3.shift);
    try std.testing.expectEqual(@as(i8, 0), s3.dsign);

    const neg = computeDivisorParams(i32, -1);
    try std.testing.expect(neg.is_pow2);
    try std.testing.expect(neg.is_neg_one);
    try std.testing.expectEqual(@as(i32, -1), neg.dsign);
}

test "Highway integer division covers every lane width and signed edge" {
    const simd = @import("root.zig");
    inline for (.{ u8, u16, u32, u64 }) |T| {
        const D = simd.FixedTag(T, 8);
        const values: D.Vector = .{ 0, 1, 2, 3, 7, 31, std.math.maxInt(T) - 1, std.math.maxInt(T) };
        const result = divideByScalar(D, values, 7);
        inline for (0..D.lane_count) |index| {
            try std.testing.expectEqual(values[index] / 7, result[index]);
        }
    }

    inline for (.{ i8, i16, i32, i64 }) |T| {
        const D = simd.FixedTag(T, 8);
        const values: D.Vector = .{ std.math.minInt(T), -31, -8, -1, 0, 1, 8, std.math.maxInt(T) };
        const trunc_result = divideByScalar(D, values, -7);
        const floor_result = floorDivideByScalar(D, values, -7);
        inline for (0..D.lane_count) |index| {
            try std.testing.expectEqual(@divTrunc(values[index], @as(T, -7)), trunc_result[index]);
            const quotient = @divTrunc(values[index], @as(T, -7));
            const remainder = @rem(values[index], @as(T, -7));
            const expected_floor = quotient - @as(T, if (remainder != 0 and values[index] >= 0) 1 else 0);
            try std.testing.expectEqual(expected_floor, floor_result[index]);
        }
        const by_neg_one = divideByScalar(D, @as(D.Vector, @splat(std.math.minInt(T))), -1);
        try std.testing.expectEqual(std.math.minInt(T), by_neg_one[0]);
        const floor_neg_one = floorDivideByScalar(D, @as(D.Vector, @splat(std.math.minInt(T))), -1);
        try std.testing.expectEqual(@as(T, 0), floor_neg_one[0]);
    }
}

test "Highway precomputed division covers power two and maximal divisors" {
    const simd = @import("root.zig");
    inline for (.{ u8, u16, u32, u64 }) |T| {
        const D = simd.FixedTag(T, 8);
        const dividends: D.Vector = .{ 0, 1, 2, 3, 7, 31, std.math.maxInt(T) - 1, std.math.maxInt(T) };
        const divisors = [_]T{ 1, 2, 3, 16, std.math.maxInt(T) };
        for (divisors) |divisor| {
            const result = intDiv(D, dividends, computeDivisorParams(T, divisor));
            inline for (0..D.lane_count) |index| {
                try std.testing.expectEqual(dividends[index] / divisor, result[index]);
            }
        }
    }

    inline for (.{ i8, i16, i32, i64 }) |T| {
        const D = simd.FixedTag(T, 8);
        const dividends: D.Vector = .{ std.math.minInt(T), -31, -8, -1, 0, 1, 8, std.math.maxInt(T) };
        const divisors = [_]T{ std.math.minInt(T), -16, -3, -1, 1, 2, 7, std.math.maxInt(T) };
        for (divisors) |divisor| {
            const params = computeDivisorParams(T, divisor);
            const trunc_result = intDiv(D, dividends, params);
            const floor_result = intDivFloor(D, dividends, params);
            inline for (0..D.lane_count) |index| {
                const dividend = dividends[index];
                if (dividend == std.math.minInt(T) and divisor == -1) {
                    try std.testing.expectEqual(std.math.minInt(T), trunc_result[index]);
                    try std.testing.expectEqual(@as(T, 0), floor_result[index]);
                } else {
                    const quotient = @divTrunc(dividend, divisor);
                    const remainder = @rem(dividend, divisor);
                    const adjust: T = if (remainder != 0 and (dividend < 0) != (divisor < 0)) 1 else 0;
                    try std.testing.expectEqual(quotient, trunc_result[index]);
                    try std.testing.expectEqual(quotient - adjust, floor_result[index]);
                }
            }
        }
    }
}

test "Highway array division handles tails without allocation" {
    var trunc_values = [_]i32{ -10, -9, -1, 0, 1, 9, 10 };
    divideArrayByScalar(i32, &trunc_values, 3);
    try std.testing.expectEqualSlices(i32, &.{ -3, -3, 0, 0, 0, 3, 3 }, &trunc_values);

    var floor_values = [_]i32{ -10, -9, -1, 0, 1, 9, 10 };
    floorDivideArrayByScalar(i32, &floor_values, 3);
    try std.testing.expectEqualSlices(i32, &.{ -4, -3, -1, 0, 0, 3, 3 }, &floor_values);
}

test "Highway scalar divisors match exhaustive small and boundary quadrants" {
    inline for (.{ u32, u64 }) |T| try verifyScalarDivisor(T);
}

fn verifyScalarDivisor(comptime T: type) !void {
    const Scalar = ScalarDivisor(T);
    for (1..256) |divisor_value| {
        const divisor: T = @intCast(divisor_value);
        const scalar = Scalar.init(divisor);
        try std.testing.expectEqual(divisor, scalar.getDivisor());
        for (0..256) |dividend_value| {
            try expectScalarDivision(T, scalar, @intCast(dividend_value));
        }
        for (0..256) |offset| {
            try expectScalarDivision(T, scalar, std.math.maxInt(T) - @as(T, @intCast(offset)));
        }
    }
    for (0..256) |divisor_offset| {
        const divisor = std.math.maxInt(T) - @as(T, @intCast(divisor_offset));
        const scalar = Scalar.init(divisor);
        for (0..256) |dividend_value| {
            try expectScalarDivision(T, scalar, @intCast(dividend_value));
        }
        for (0..256) |dividend_offset| {
            try expectScalarDivision(
                T,
                scalar,
                std.math.maxInt(T) - @as(T, @intCast(dividend_offset)),
            );
        }
    }
}

fn expectScalarDivision(
    comptime T: type,
    scalar: ScalarDivisor(T),
    dividend: T,
) !void {
    try std.testing.expectEqual(dividend / scalar.getDivisor(), scalar.divide(dividend));
    try std.testing.expectEqual(dividend % scalar.getDivisor(), scalar.remainder(dividend));
}

test "Highway 128 by 64 helper returns the low fitting quotient" {
    try std.testing.expectEqual(@as(u64, 0x5555555555555555), div128HighBy(1, 3));
    try std.testing.expectEqual(@as(u64, 1) << 63, div128HighBy(@as(u64, 1) << 62, @as(u64, 1) << 63));
    try std.testing.expectEqual(@as(u64, 1), div128HighBy(1, std.math.maxInt(u64)));
}
