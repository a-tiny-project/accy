const std = @import("std");

pub fn add(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return if (comptime isInteger(D.Lane)) a +% b else a + b;
}

pub fn sub(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return if (comptime isInteger(D.Lane)) a -% b else a - b;
}

pub fn mul(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return if (comptime isInteger(D.Lane)) a *% b else a * b;
}

pub fn addSub(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = if (index & 1 == 0)
            subLane(D.Lane, a[index], b[index])
        else
            addLane(D.Lane, a[index], b[index]);
    }
    return result;
}

pub fn neg(comptime D: type, value: D.Vector) D.Vector {
    return switch (@typeInfo(D.Lane)) {
        .int => |info| if (info.signedness == .signed)
            @as(D.Vector, @splat(0)) -% value
        else
            @compileError("neg requires signed integer or floating-point lanes"),
        .float => -value,
        else => unreachable,
    };
}

pub fn saturatedNeg(comptime D: type, value: D.Vector) D.Vector {
    requireSignedInteger(D.Lane, "saturatedNeg");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = if (value[index] == std.math.minInt(D.Lane))
            std.math.maxInt(D.Lane)
        else
            -value[index];
    }
    return result;
}

pub fn abs(comptime D: type, value: D.Vector) D.Vector {
    return switch (@typeInfo(D.Lane)) {
        .int => |info| if (info.signedness == .signed)
            absInteger(D, value)
        else
            @compileError("abs requires signed integer or floating-point lanes"),
        .float => @abs(value),
        else => unreachable,
    };
}

pub fn saturatedAbs(comptime D: type, value: D.Vector) D.Vector {
    requireSignedInteger(D.Lane, "saturatedAbs");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = if (value[index] == std.math.minInt(D.Lane))
            std.math.maxInt(D.Lane)
        else if (value[index] < 0)
            -value[index]
        else
            value[index];
    }
    return result;
}

pub fn absDiff(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    if (comptime @typeInfo(D.Lane) == .float) return @abs(a - b);
    if (comptime @typeInfo(D.Lane) != .int) @compileError("absDiff requires numeric lanes");
    const U = @Int(.unsigned, @bitSizeOf(D.Lane));
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        const a_bits: U = @bitCast(a[index]);
        const b_bits: U = @bitCast(b[index]);
        const difference = if (a[index] >= b[index]) a_bits -% b_bits else b_bits -% a_bits;
        result[index] = @bitCast(difference);
    }
    return result;
}

pub fn saturatedAdd(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    requireInteger(D.Lane, "saturatedAdd");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = saturatedAddLane(D.Lane, a[index], b[index]);
    }
    return result;
}

pub fn saturatedSub(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    requireInteger(D.Lane, "saturatedSub");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = saturatedSubLane(D.Lane, a[index], b[index]);
    }
    return result;
}

pub fn div(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    if (comptime @typeInfo(D.Lane) == .float) return a / b;
    requireInteger(D.Lane, "div");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = safeDivLane(D.Lane, a[index], b[index]);
    }
    return result;
}

pub fn mod(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    requireInteger(D.Lane, "mod");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = safeModLane(D.Lane, a[index], b[index]);
    }
    return result;
}

pub fn min(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return @select(D.Lane, a < b, a, b);
}

pub fn max(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return @select(D.Lane, a > b, a, b);
}

pub fn minNumber(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    if (comptime @typeInfo(D.Lane) != .float) return min(D, a, b);
    const a_nan = a != a;
    const b_nan = b != b;
    return @select(
        D.Lane,
        a_nan,
        b,
        @select(D.Lane, b_nan, a, min(D, a, b)),
    );
}

pub fn maxNumber(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    if (comptime @typeInfo(D.Lane) != .float) return max(D, a, b);
    const a_nan = a != a;
    const b_nan = b != b;
    return @select(
        D.Lane,
        a_nan,
        b,
        @select(D.Lane, b_nan, a, max(D, a, b)),
    );
}

pub fn minMagnitude(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return magnitudeChoice(D, a, b, false);
}

pub fn maxMagnitude(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return magnitudeChoice(D, a, b, true);
}

pub fn min128(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return choose128(D, a, b, false, false);
}

pub fn max128(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return choose128(D, a, b, true, false);
}

pub fn min128Upper(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return choose128(D, a, b, false, true);
}

pub fn max128Upper(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return choose128(D, a, b, true, true);
}

pub fn clamp(
    comptime D: type,
    value: D.Vector,
    lower: D.Vector,
    upper: D.Vector,
) D.Vector {
    return max(D, lower, min(D, value, upper));
}

pub fn mulAdd(
    comptime D: type,
    multiplicand: D.Vector,
    multiplier: D.Vector,
    addend: D.Vector,
) D.Vector {
    if (comptime isInteger(D.Lane)) {
        return add(D, mul(D, multiplicand, multiplier), addend);
    }
    return @mulAdd(D.Vector, multiplicand, multiplier, addend);
}

pub fn negMulAdd(
    comptime D: type,
    multiplicand: D.Vector,
    multiplier: D.Vector,
    addend: D.Vector,
) D.Vector {
    if (comptime isInteger(D.Lane)) {
        return add(D, mul(D, neg(D, multiplicand), multiplier), addend);
    }
    return @mulAdd(D.Vector, -multiplicand, multiplier, addend);
}

pub fn mulSub(
    comptime D: type,
    multiplicand: D.Vector,
    multiplier: D.Vector,
    subtrahend: D.Vector,
) D.Vector {
    if (comptime isInteger(D.Lane)) {
        return sub(D, mul(D, multiplicand, multiplier), subtrahend);
    }
    return @mulAdd(D.Vector, multiplicand, multiplier, -subtrahend);
}

pub fn negMulSub(
    comptime D: type,
    multiplicand: D.Vector,
    multiplier: D.Vector,
    subtrahend: D.Vector,
) D.Vector {
    if (comptime isInteger(D.Lane)) {
        return sub(D, mul(D, neg(D, multiplicand), multiplier), subtrahend);
    }
    return @mulAdd(D.Vector, -multiplicand, multiplier, -subtrahend);
}

pub fn mulAddSub(
    comptime D: type,
    multiplicand: D.Vector,
    multiplier: D.Vector,
    addend: D.Vector,
) D.Vector {
    return alternate(D, mulSub(D, multiplicand, multiplier, addend), mulAdd(D, multiplicand, multiplier, addend));
}

pub fn mulSubAdd(
    comptime D: type,
    multiplicand: D.Vector,
    multiplier: D.Vector,
    addend: D.Vector,
) D.Vector {
    return alternate(D, mulAdd(D, multiplicand, multiplier, addend), mulSub(D, multiplicand, multiplier, addend));
}

pub fn maskedMinOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedOr(D, no, mask, min(D, a, b));
}

pub fn maskedMaxOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedOr(D, no, mask, max(D, a, b));
}

pub fn maskedAddOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedOr(D, no, mask, add(D, a, b));
}

pub fn maskedSubOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedOr(D, no, mask, sub(D, a, b));
}

pub fn maskedMulOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedOr(D, no, mask, mul(D, a, b));
}

pub fn maskedDivOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedOr(D, no, mask, div(D, a, b));
}

pub fn maskedModOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedOr(D, no, mask, mod(D, a, b));
}

pub fn maskedSatAddOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedOr(D, no, mask, saturatedAdd(D, a, b));
}

pub fn maskedSatSubOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedOr(D, no, mask, saturatedSub(D, a, b));
}

pub fn maskedAbsOr(comptime D: type, no: D.Vector, mask: D.Mask, value: D.Vector) D.Vector {
    return maskedOr(D, no, mask, abs(D, value));
}

pub fn maskedMulAddOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return maskedOr(D, no, mask, mulAdd(D, a, b, c));
}

pub fn maskedMulSubOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return maskedOr(D, no, mask, mulSub(D, a, b, c));
}

pub fn maskedNegMulAddOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return maskedOr(D, no, mask, negMulAdd(D, a, b, c));
}

pub fn maskedNegMulSubOr(comptime D: type, no: D.Vector, mask: D.Mask, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return maskedOr(D, no, mask, negMulSub(D, a, b, c));
}

pub fn maskedAbs(comptime D: type, mask: D.Mask, value: D.Vector) D.Vector {
    return maskedZero(D, mask, abs(D, value));
}

pub fn maskedMax(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedZero(D, mask, max(D, a, b));
}

pub fn maskedAdd(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedZero(D, mask, add(D, a, b));
}

pub fn maskedSub(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedZero(D, mask, sub(D, a, b));
}

pub fn maskedMul(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedZero(D, mask, mul(D, a, b));
}

pub fn maskedDiv(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedZero(D, mask, div(D, a, b));
}

pub fn maskedSaturatedAdd(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedZero(D, mask, saturatedAdd(D, a, b));
}

pub fn maskedSaturatedSub(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Vector {
    return maskedZero(D, mask, saturatedSub(D, a, b));
}

pub fn maskedMulAdd(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return maskedZero(D, mask, mulAdd(D, a, b, c));
}

pub fn maskedMulSub(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return maskedZero(D, mask, mulSub(D, a, b, c));
}

pub fn maskedNegMulAdd(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return maskedZero(D, mask, negMulAdd(D, a, b, c));
}

pub fn maskedNegMulSub(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return maskedZero(D, mask, negMulSub(D, a, b, c));
}

pub fn pairwiseAdd(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    if (D.lane_count < 2) @compileError("pairwiseAdd requires at least two lanes");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / 2) |pair| {
        result[pair * 2] = addLane(D.Lane, a[pair * 2], a[pair * 2 + 1]);
        result[pair * 2 + 1] = addLane(D.Lane, b[pair * 2], b[pair * 2 + 1]);
    }
    return result;
}

pub fn pairwiseSub(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    if (D.lane_count < 2) @compileError("pairwiseSub requires at least two lanes");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / 2) |pair| {
        result[pair * 2] = subLane(D.Lane, a[pair * 2 + 1], a[pair * 2]);
        result[pair * 2 + 1] = subLane(D.Lane, b[pair * 2 + 1], b[pair * 2]);
    }
    return result;
}

pub fn pairwiseAdd128(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return pairwise128(D, false, a, b);
}

pub fn pairwiseSub128(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return pairwise128(D, true, a, b);
}

fn pairwise128(comptime D: type, comptime subtract: bool, a: D.Vector, b: D.Vector) D.Vector {
    if (D.byte_count < 16) @compileError("128-bit pairwise operations require at least one full block");
    const lanes_per_block = 16 / @sizeOf(D.Lane);
    if (lanes_per_block < 2) @compileError("pairwise operations require at least two lanes per block");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / lanes_per_block) |block| {
        inline for (0..lanes_per_block / 2) |pair| {
            const source = block * lanes_per_block + pair * 2;
            const destination = block * lanes_per_block + pair;
            result[destination] = if (subtract)
                subLane(D.Lane, a[source + 1], a[source])
            else
                addLane(D.Lane, a[source], a[source + 1]);
            result[destination + lanes_per_block / 2] = if (subtract)
                subLane(D.Lane, b[source + 1], b[source])
            else
                addLane(D.Lane, b[source], b[source + 1]);
        }
    }
    return result;
}

fn addLane(comptime T: type, a: T, b: T) T {
    return if (@typeInfo(T) == .int) a +% b else a + b;
}

fn subLane(comptime T: type, a: T, b: T) T {
    return if (@typeInfo(T) == .int) a -% b else a - b;
}

fn isInteger(comptime T: type) bool {
    return @typeInfo(T) == .int;
}

fn absInteger(comptime D: type, value: D.Vector) D.Vector {
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = if (value[index] < 0) 0 -% value[index] else value[index];
    }
    return result;
}

fn saturatedAddLane(comptime T: type, a: T, b: T) T {
    return if (@typeInfo(T).int.signedness == .signed) blk: {
        const sum = @as(i128, a) + @as(i128, b);
        break :blk @intCast(std.math.clamp(
            sum,
            @as(i128, std.math.minInt(T)),
            @as(i128, std.math.maxInt(T)),
        ));
    } else blk: {
        const sum = @as(u128, a) + @as(u128, b);
        break :blk @intCast(@min(sum, @as(u128, std.math.maxInt(T))));
    };
}

fn saturatedSubLane(comptime T: type, a: T, b: T) T {
    return if (@typeInfo(T).int.signedness == .signed) blk: {
        const difference = @as(i128, a) - @as(i128, b);
        break :blk @intCast(std.math.clamp(
            difference,
            @as(i128, std.math.minInt(T)),
            @as(i128, std.math.maxInt(T)),
        ));
    } else if (a < b) 0 else a - b;
}

fn safeDivLane(comptime T: type, a: T, b: T) T {
    if (b == 0) return 0;
    if (@typeInfo(T).int.signedness == .signed and
        a == std.math.minInt(T) and b == -1)
    {
        return 0;
    }
    return @divTrunc(a, b);
}

fn safeModLane(comptime T: type, a: T, b: T) T {
    if (b == 0) return 0;
    if (@typeInfo(T).int.signedness == .signed and
        a == std.math.minInt(T) and b == -1)
    {
        return 0;
    }
    return @rem(a, b);
}

fn magnitudeChoice(
    comptime D: type,
    a: D.Vector,
    b: D.Vector,
    comptime choose_maximum: bool,
) D.Vector {
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        const a_smaller = magnitudeLess(D.Lane, a[index], b[index]);
        result[index] = if (choose_maximum)
            (if (a_smaller) b[index] else a[index])
        else
            (if (a_smaller) a[index] else b[index]);
    }
    return result;
}

fn magnitudeLess(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .float => blk: {
            const magnitude_a = @abs(a);
            const magnitude_b = @abs(b);
            break :blk magnitude_a < magnitude_b or
                (magnitude_a == magnitude_b and a < b);
        },
        .int => |info| if (info.signedness == .unsigned)
            a < b
        else blk: {
            const U = @Int(.unsigned, @bitSizeOf(T));
            const a_bits: U = @bitCast(a);
            const b_bits: U = @bitCast(b);
            const magnitude_a = if (a < 0) 0 -% a_bits else a_bits;
            const magnitude_b = if (b < 0) 0 -% b_bits else b_bits;
            break :blk magnitude_a < magnitude_b or
                (magnitude_a == magnitude_b and a < b);
        },
        else => unreachable,
    };
}

fn choose128(
    comptime D: type,
    a: D.Vector,
    b: D.Vector,
    comptime choose_maximum: bool,
    comptime upper_only: bool,
) D.Vector {
    if (D.Lane != u64 or D.lane_count < 2 or D.lane_count & 1 != 0) {
        @compileError("128-bit min/max requires an even number of u64 lanes");
    }
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / 2) |pair| {
        const low = pair * 2;
        const high = low + 1;
        const a_less = if (upper_only)
            a[high] < b[high]
        else
            a[high] < b[high] or (a[high] == b[high] and a[low] < b[low]);
        const a_greater = if (upper_only)
            a[high] > b[high]
        else
            a[high] > b[high] or (a[high] == b[high] and a[low] > b[low]);
        const take_a = if (choose_maximum) a_greater else a_less;
        result[low] = if (take_a) a[low] else b[low];
        result[high] = if (take_a) a[high] else b[high];
    }
    return result;
}

fn alternate(comptime D: type, even: D.Vector, odd: D.Vector) D.Vector {
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = if (index & 1 == 0) even[index] else odd[index];
    }
    return result;
}

fn maskedOr(comptime D: type, no: D.Vector, mask: D.Mask, yes: D.Vector) D.Vector {
    return @select(D.Lane, mask, yes, no);
}

fn maskedZero(comptime D: type, mask: D.Mask, yes: D.Vector) D.Vector {
    return maskedOr(D, @as(D.Vector, @splat(0)), mask, yes);
}

fn requireInteger(comptime T: type, comptime operation: []const u8) void {
    if (@typeInfo(T) != .int) @compileError(operation ++ " requires integer lanes");
}

fn requireSignedInteger(comptime T: type, comptime operation: []const u8) void {
    if (@typeInfo(T) != .int or @typeInfo(T).int.signedness != .signed) {
        @compileError(operation ++ " requires signed integer lanes");
    }
}

fn verifyPairwiseLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, @max(2, 16 / @sizeOf(T)));
    const value: D.Vector = @splat(0);
    try std.testing.expect(@reduce(.And, pairwiseAdd(D, value, value) == value));
    try std.testing.expect(@reduce(.And, pairwiseSub(D, value, value) == value));
    try std.testing.expect(@reduce(.And, pairwiseAdd128(D, value, value) == value));
    try std.testing.expect(@reduce(.And, pairwiseSub128(D, value, value) == value));
}
