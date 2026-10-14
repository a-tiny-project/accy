const std = @import("std");
const bfloat = @import("bfloat.zig");

pub fn mulRound(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    requireFloat(D.Lane, "mulRound");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = roundEvenScalar(D.Lane, a[index] * b[index]);
    }
    return result;
}

pub fn mulByPow2(comptime D: type, a: D.Vector, exponents: anytype) D.Vector {
    requireFloat(D.Lane, "mulByPow2");
    validateSameLanes(D, @TypeOf(exponents));
    if (comptime @typeInfo(sourceLane(@TypeOf(exponents))) != .int) {
        @compileError("mulByPow2 requires integer exponents");
    }
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = std.math.ldexp(a[index], exponentI32(exponents[index]));
    }
    return result;
}

pub fn mulByFloorPow2(comptime D: type, a: D.Vector, exponents: D.Vector) D.Vector {
    requireFloat(D.Lane, "mulByFloorPow2");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        const exponent = exponents[index];
        if (std.math.isNan(exponent) or exponent == std.math.inf(D.Lane)) {
            result[index] = a[index] * exponent;
        } else if (exponent == -std.math.inf(D.Lane)) {
            result[index] = a[index] * @as(D.Lane, 0);
        } else {
            result[index] = std.math.ldexp(a[index], floatExponentI32(@floor(exponent)));
        }
    }
    return result;
}

pub fn mulHigh(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    requireInteger(D.Lane, "mulHigh");
    const bits = @bitSizeOf(D.Lane);
    const WideSigned = @Int(.signed, bits * 2);
    const WideUnsigned = @Int(.unsigned, bits * 2);
    const Unsigned = @Int(.unsigned, bits);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        const high: Unsigned = if (@typeInfo(D.Lane).int.signedness == .signed) blk: {
            const product = @as(WideSigned, a[index]) * @as(WideSigned, b[index]);
            const product_bits: WideUnsigned = @bitCast(product);
            break :blk @truncate(product_bits >> bits);
        } else blk: {
            const product = @as(WideUnsigned, a[index]) * @as(WideUnsigned, b[index]);
            break :blk @truncate(product >> bits);
        };
        result[index] = @bitCast(high);
    }
    return result;
}

pub fn mulFixedPoint15(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    if (comptime D.Lane != i16) @compileError("mulFixedPoint15 requires i16 lanes");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        const rounded = (@as(i32, a[index]) * @as(i32, b[index]) + 0x4000) >> 15;
        result[index] = @intCast(std.math.clamp(rounded, std.math.minInt(i16), std.math.maxInt(i16)));
    }
    return result;
}

pub fn mulEven(comptime D: type, a: D.Vector, b: D.Vector) D.repartition(wideLane(D.Lane)).Vector {
    return mulParity(D, a, b, 0);
}

pub fn mulOdd(comptime D: type, a: D.Vector, b: D.Vector) D.repartition(wideLane(D.Lane)).Vector {
    return mulParity(D, a, b, 1);
}

pub fn widenMulPairwiseAdd(comptime DW: type, a: anytype, b: @TypeOf(a)) DW.Vector {
    validatePairwiseWide(DW, @TypeOf(a));
    var result: DW.Vector = undefined;
    inline for (0..DW.lane_count) |index| {
        const first = productLane(DW.Lane, a[index * 2], b[index * 2]);
        const second = productLane(DW.Lane, a[index * 2 + 1], b[index * 2 + 1]);
        result[index] = addLane(DW.Lane, first, second);
    }
    return result;
}

pub fn maskedWidenMulPairwiseAdd(
    comptime DW: type,
    mask: DW.Mask,
    a: anytype,
    b: @TypeOf(a),
) DW.Vector {
    return @select(
        DW.Lane,
        mask,
        widenMulPairwiseAdd(DW, a, b),
        @as(DW.Vector, @splat(0)),
    );
}

pub fn satWidenMulPairwiseAdd(comptime DW: type, a: anytype, b: anytype) DW.Vector {
    if (comptime DW.Lane != i16 or sourceLane(@TypeOf(a)) != u8 or sourceLane(@TypeOf(b)) != i8 or
        sourceLaneCount(@TypeOf(a)) != DW.lane_count * 2 or
        sourceLaneCount(@TypeOf(b)) != DW.lane_count * 2)
    {
        @compileError("satWidenMulPairwiseAdd requires paired u8 and i8 sources with i16 output");
    }
    var result: DW.Vector = undefined;
    inline for (0..DW.lane_count) |index| {
        const sum = @as(i32, a[index * 2]) * @as(i32, b[index * 2]) +
            @as(i32, a[index * 2 + 1]) * @as(i32, b[index * 2 + 1]);
        result[index] = @intCast(std.math.clamp(sum, std.math.minInt(i16), std.math.maxInt(i16)));
    }
    return result;
}

pub fn satWidenMulPairwiseAccumulate(
    comptime DW: type,
    a: anytype,
    b: @TypeOf(a),
    sum: DW.Vector,
) DW.Vector {
    if (comptime DW.Lane != i32 or sourceLane(@TypeOf(a)) != i16 or
        sourceLaneCount(@TypeOf(a)) != DW.lane_count * 2)
    {
        @compileError("satWidenMulPairwiseAccumulate requires paired i16 sources with i32 output");
    }
    var result: DW.Vector = undefined;
    inline for (0..DW.lane_count) |index| {
        const value = @as(i64, sum[index]) +
            @as(i64, a[index * 2]) * @as(i64, b[index * 2]) +
            @as(i64, a[index * 2 + 1]) * @as(i64, b[index * 2 + 1]);
        result[index] = @intCast(std.math.clamp(
            value,
            @as(i64, std.math.minInt(i32)),
            @as(i64, std.math.maxInt(i32)),
        ));
    }
    return result;
}

pub fn satWidenMulAccumFixedPoint(
    comptime DW: type,
    a: anytype,
    b: @TypeOf(a),
    sum: DW.Vector,
) DW.Vector {
    if (comptime DW.Lane != i32 or sourceLane(@TypeOf(a)) != i16 or
        sourceLaneCount(@TypeOf(a)) != DW.lane_count)
    {
        @compileError("satWidenMulAccumFixedPoint requires same-lane-count i16 sources with i32 output");
    }
    var result: DW.Vector = undefined;
    inline for (0..DW.lane_count) |index| {
        const value = @as(i64, sum[index]) +
            @as(i64, a[index]) * @as(i64, b[index]) * 2;
        result[index] = @intCast(std.math.clamp(
            value,
            @as(i64, std.math.minInt(i32)),
            @as(i64, std.math.maxInt(i32)),
        ));
    }
    return result;
}

pub fn reorderWidenMulAccumulate(
    comptime DW: type,
    a: anytype,
    b: @TypeOf(a),
    sum0: DW.Vector,
    sum1: *DW.Vector,
) DW.Vector {
    validatePairwiseWide(DW, @TypeOf(a));
    var result = sum0;
    inline for (0..DW.lane_count) |index| {
        result[index] = addLane(DW.Lane, result[index], productLane(
            DW.Lane,
            a[index * 2],
            b[index * 2],
        ));
        sum1[index] = addLane(DW.Lane, sum1[index], productLane(
            DW.Lane,
            a[index * 2 + 1],
            b[index * 2 + 1],
        ));
    }
    return result;
}

pub fn rearrangeToOddPlusEven(comptime D: type, sum0: D.Vector, sum1: D.Vector) D.Vector {
    return if (@typeInfo(D.Lane) == .int) sum0 +% sum1 else sum0 + sum1;
}

pub fn sumOfMulQuadAccumulate(
    comptime DW: type,
    a: anytype,
    b: anytype,
    sum: DW.Vector,
) DW.Vector {
    if (comptime sourceLaneCount(@TypeOf(a)) != DW.lane_count * 4 or
        sourceLaneCount(@TypeOf(b)) != DW.lane_count * 4)
    {
        @compileError("sumOfMulQuadAccumulate requires four source lanes per output lane");
    }
    var result = sum;
    inline for (0..DW.lane_count) |index| {
        inline for (0..4) |offset| {
            result[index] = addLane(DW.Lane, result[index], productLane(
                DW.Lane,
                a[index * 4 + offset],
                b[index * 4 + offset],
            ));
        }
    }
    return result;
}

pub fn widenMulAccumulate(
    comptime DW: type,
    a: anytype,
    b: @TypeOf(a),
    low: DW.Vector,
    high: *DW.Vector,
) DW.Vector {
    validatePairwiseWide(DW, @TypeOf(a));
    var result = low;
    inline for (0..DW.lane_count) |index| {
        result[index] = addLane(DW.Lane, result[index], productLane(
            DW.Lane,
            a[index],
            b[index],
        ));
        high[index] = addLane(DW.Lane, high[index], productLane(
            DW.Lane,
            a[DW.lane_count + index],
            b[DW.lane_count + index],
        ));
    }
    return result;
}

pub fn maskedMulFixedPoint15(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return @select(D.Lane, mask, mulFixedPoint15(D, a, b), @as(D.Vector, @splat(0)));
}

fn mulParity(comptime D: type, a: D.Vector, b: D.Vector, comptime parity: usize) D.repartition(wideLane(D.Lane)).Vector {
    requireInteger(D.Lane, "mulEven/mulOdd");
    const Wide = wideLane(D.Lane);
    const DW = D.repartition(Wide);
    var result: DW.Vector = undefined;
    if (@bitSizeOf(D.Lane) < 64) {
        inline for (0..DW.lane_count) |index| {
            result[index] = productLane(Wide, a[index * 2 + parity], b[index * 2 + parity]);
        }
        return result;
    }
    if (comptime D.lane_count & 1 != 0) @compileError("64-bit parity multiplication requires lane pairs");
    const U128 = u128;
    const I128 = i128;
    inline for (0..D.lane_count / 2) |index| {
        const source = index * 2 + parity;
        const product_bits: U128 = if (@typeInfo(D.Lane).int.signedness == .signed)
            @bitCast(@as(I128, a[source]) * @as(I128, b[source]))
        else
            @as(U128, a[source]) * @as(U128, b[source]);
        const low: u64 = @truncate(product_bits);
        const high: u64 = @truncate(product_bits >> 64);
        result[index * 2] = @bitCast(low);
        result[index * 2 + 1] = @bitCast(high);
    }
    return result;
}

fn productLane(comptime T: type, a: anytype, b: @TypeOf(a)) T {
    if (comptime T == f32 and @TypeOf(a) == u16) {
        return bfloat.f32FromBits(a) * bfloat.f32FromBits(b);
    }
    return switch (@typeInfo(T)) {
        .int => @as(T, @intCast(a)) *% @as(T, @intCast(b)),
        .float => @as(T, @floatCast(a)) * @as(T, @floatCast(b)),
        else => unreachable,
    };
}

fn addLane(comptime T: type, a: T, b: T) T {
    return if (@typeInfo(T) == .int) a +% b else a + b;
}

fn wideLane(comptime T: type) type {
    return switch (T) {
        u8 => u16,
        i8 => i16,
        u16 => u32,
        i16 => i32,
        u32 => u64,
        i32 => i64,
        u64 => u64,
        i64 => i64,
        f16 => f32,
        f32 => f64,
        else => @compileError("lane has no Highway wide representation"),
    };
}

fn roundEvenScalar(comptime T: type, value: T) T {
    const rounded = @round(value);
    const tie = @abs(value - @trunc(value)) == @as(T, 0.5);
    const half = rounded / @as(T, 2);
    if (tie and @trunc(half) != half) {
        return rounded - if (value < 0) @as(T, -1) else @as(T, 1);
    }
    return rounded;
}

fn exponentI32(value: anytype) i32 {
    const T = @TypeOf(value);
    if (@typeInfo(T).int.signedness == .signed) {
        if (value < std.math.minInt(i32)) return std.math.minInt(i32);
        if (value > std.math.maxInt(i32)) return std.math.maxInt(i32);
        return @intCast(value);
    }
    if (value > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(value);
}

fn floatExponentI32(value: anytype) i32 {
    if (value <= @as(@TypeOf(value), @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    if (value >= @as(@TypeOf(value), @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(value);
}

fn validatePairwiseWide(comptime DW: type, comptime V: type) void {
    if (comptime DW.Lane == f32 and sourceLane(V) == u16 and
        sourceLaneCount(V) == DW.lane_count * 2)
    {
        return;
    }
    if (comptime sourceLaneCount(V) != DW.lane_count * 2 or wideLane(sourceLane(V)) != DW.Lane) {
        @compileError("widening pair operation requires twice as many narrow source lanes");
    }
}

fn validateSameLanes(comptime D: type, comptime V: type) void {
    if (comptime sourceLaneCount(V) != D.lane_count) @compileError("vectors require equal lane counts");
}

fn sourceLane(comptime V: type) type {
    return switch (@typeInfo(V)) {
        .vector => |info| info.child,
        else => @compileError("operation requires vector sources"),
    };
}

fn sourceLaneCount(comptime V: type) usize {
    return switch (@typeInfo(V)) {
        .vector => |info| info.len,
        else => @compileError("operation requires vector sources"),
    };
}

fn requireInteger(comptime T: type, comptime operation: []const u8) void {
    if (comptime @typeInfo(T) != .int) @compileError(operation ++ " requires integer lanes");
}

fn requireFloat(comptime T: type, comptime operation: []const u8) void {
    if (comptime @typeInfo(T) != .float) @compileError(operation ++ " requires floating-point lanes");
}
