const std = @import("std");

pub fn eq(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return a == b;
}

pub fn ne(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return a != b;
}

pub fn lt(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return a < b;
}

pub fn le(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return a <= b;
}

pub fn gt(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return a > b;
}

pub fn ge(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return a >= b;
}

pub fn lt128(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return compare128(D, a, b, .less, false);
}

pub fn lt128Upper(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return compare128(D, a, b, .less, true);
}

pub fn eq128(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return compare128(D, a, b, .equal, false);
}

pub fn ne128(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return compare128(D, a, b, .not_equal, false);
}

pub fn eq128Upper(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return compare128(D, a, b, .equal, true);
}

pub fn ne128Upper(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return compare128(D, a, b, .not_equal, true);
}

pub fn isNegative(comptime D: type, value: D.Vector) D.Mask {
    const info = @typeInfo(D.Lane);
    if (info != .float and (info != .int or info.int.signedness != .signed)) {
        @compileError("isNegative requires signed integer or floating-point lanes");
    }
    const U = @Int(.unsigned, @bitSizeOf(D.Lane));
    const UV = @Vector(D.lane_count, U);
    const bits: UV = @bitCast(value);
    const sign: UV = @splat(@as(U, 1) << (@bitSizeOf(D.Lane) - 1));
    return bits & sign != @as(UV, @splat(0));
}

pub fn isNaN(comptime D: type, value: D.Vector) D.Mask {
    validateFloat(D);
    return value != value;
}

pub fn isEitherNaN(comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
    return isNaN(D, a) | isNaN(D, b);
}

pub fn isInf(comptime D: type, value: D.Vector) D.Mask {
    validateFloat(D);
    return @abs(value) == @as(D.Vector, @splat(std.math.inf(D.Lane)));
}

pub fn isFinite(comptime D: type, value: D.Vector) D.Mask {
    validateFloat(D);
    return @abs(value) < @as(D.Vector, @splat(std.math.inf(D.Lane)));
}

pub fn maskedEq(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Mask {
    return mask & eq(D, a, b);
}

pub fn maskedNe(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Mask {
    return mask & ne(D, a, b);
}

pub fn maskedLt(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Mask {
    return mask & lt(D, a, b);
}

pub fn maskedLe(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Mask {
    return mask & le(D, a, b);
}

pub fn maskedGt(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Mask {
    return mask & gt(D, a, b);
}

pub fn maskedGe(comptime D: type, mask: D.Mask, a: D.Vector, b: D.Vector) D.Mask {
    return mask & ge(D, a, b);
}

pub fn maskedIsNaN(comptime D: type, mask: D.Mask, value: D.Vector) D.Mask {
    return mask & isNaN(D, value);
}

pub fn select(
    comptime D: type,
    mask: D.Mask,
    yes: D.Vector,
    no: D.Vector,
) D.Vector {
    return @select(D.Lane, mask, yes, no);
}

pub fn maskNot(comptime D: type, mask: D.Mask) D.Mask {
    return @select(bool, mask, @as(D.Mask, @splat(false)), @as(D.Mask, @splat(true)));
}

pub fn maskAnd(comptime D: type, a: D.Mask, b: D.Mask) D.Mask {
    return a & b;
}

pub fn maskAndNot(comptime D: type, not_a: D.Mask, b: D.Mask) D.Mask {
    return maskNot(D, not_a) & b;
}

pub fn maskOr(comptime D: type, a: D.Mask, b: D.Mask) D.Mask {
    return a | b;
}

pub fn maskXor(comptime D: type, a: D.Mask, b: D.Mask) D.Mask {
    return a ^ b;
}

pub fn exclusiveNeither(comptime D: type, a: D.Mask, b: D.Mask) D.Mask {
    return maskNot(D, a) & maskNot(D, b);
}

pub fn allTrue(comptime D: type, mask: D.Mask) bool {
    return @reduce(.And, mask);
}

pub fn anyTrue(comptime D: type, mask: D.Mask) bool {
    return @reduce(.Or, mask);
}

pub fn allFalse(comptime D: type, mask: D.Mask) bool {
    return !anyTrue(D, mask);
}

pub fn countTrue(comptime D: type, mask: D.Mask) usize {
    var count: usize = 0;
    inline for (0..D.lane_count) |index| {
        count += @intFromBool(mask[index]);
    }
    std.debug.assert(count <= D.lane_count);
    return count;
}

/// Returns the lowest true lane, or -1 when no lane is true. The mask selects
/// lane indices and a minimum reduction picks the first, which compiles to a
/// few vector instructions. Walking the lanes of an array copy, or bitcasting
/// the mask to an integer, scalarizes under the pinned compiler.
pub fn findFirstTrue(comptime D: type, mask: D.Mask) isize {
    const index = std.simd.firstTrue(mask) orelse return -1;
    return @intCast(index);
}

pub fn findKnownFirstTrue(comptime D: type, mask: D.Mask) usize {
    std.debug.assert(anyTrue(D, mask));
    return @intCast(findFirstTrue(D, mask));
}

/// Returns the highest true lane, or -1 when no lane is true, by a maximum
/// reduction over the selected lane indices.
pub fn findLastTrue(comptime D: type, mask: D.Mask) isize {
    const index = std.simd.lastTrue(mask) orelse return -1;
    return @intCast(index);
}

pub fn findKnownLastTrue(comptime D: type, mask: D.Mask) usize {
    std.debug.assert(anyTrue(D, mask));
    return @intCast(findLastTrue(D, mask));
}

pub fn setOnlyFirst(comptime D: type, mask: D.Mask) D.Mask {
    var result: [D.lane_count]bool = @splat(false);
    const first = findFirstTrue(D, mask);
    if (first >= 0) result[@intCast(first)] = true;
    return result;
}

pub fn setBeforeFirst(comptime D: type, mask: D.Mask) D.Mask {
    const first = findFirstTrue(D, mask);
    const boundary: usize = if (first < 0) D.lane_count else @intCast(first);
    var result: D.Mask = @splat(false);
    inline for (0..D.lane_count) |index| result[index] = index < boundary;
    return result;
}

pub fn setAtOrBeforeFirst(comptime D: type, mask: D.Mask) D.Mask {
    return maskOr(D, setBeforeFirst(D, mask), setOnlyFirst(D, mask));
}

pub fn setAtOrAfterFirst(comptime D: type, mask: D.Mask) D.Mask {
    return maskNot(D, setBeforeFirst(D, mask));
}

pub fn bitsFromMask(comptime D: type, mask: D.Mask) u64 {
    if (D.lane_count > 64) @compileError("bitsFromMask supports at most 64 lanes");
    var bits: u64 = 0;
    inline for (0..D.lane_count) |index| {
        if (mask[index]) bits |= @as(u64, 1) << @intCast(index);
    }
    return bits;
}

pub fn maskFromBits(comptime D: type, bits: u64) D.Mask {
    if (D.lane_count > 64) @compileError("maskFromBits supports at most 64 lanes");
    var mask: D.Mask = @splat(false);
    inline for (0..D.lane_count) |index| {
        mask[index] = bits & (@as(u64, 1) << @intCast(index)) != 0;
    }
    return mask;
}

pub fn rebindMask(comptime D: type, mask: anytype) D.Mask {
    if (@TypeOf(mask) != D.Mask) @compileError("rebindMask requires equal lane counts");
    return mask;
}

pub fn vecFromMask(comptime D: type, mask: D.Mask) D.Vector {
    const U = @Int(.unsigned, @bitSizeOf(D.Lane));
    const UV = @Vector(D.lane_count, U);
    const bits: UV = @select(
        U,
        mask,
        @as(UV, @splat(std.math.maxInt(U))),
        @as(UV, @splat(0)),
    );
    return @bitCast(bits);
}

pub fn maskFromVec(comptime D: type, value: D.Vector) D.Mask {
    const U = @Int(.unsigned, @bitSizeOf(D.Lane));
    const UV = @Vector(D.lane_count, U);
    const bits: UV = @bitCast(value);
    return bits != @as(UV, @splat(0));
}

pub fn loadMaskBits(comptime D: type, input: []const u8) D.Mask {
    const byte_count = (D.lane_count + 7) / 8;
    std.debug.assert(input.len >= byte_count);
    var result: D.Mask = @splat(false);
    inline for (0..D.lane_count) |index| {
        result[index] = input[index / 8] & (@as(u8, 1) << @intCast(index % 8)) != 0;
    }
    return result;
}

pub fn storeMaskBits(comptime D: type, mask: D.Mask, output: []u8) usize {
    const byte_count = (D.lane_count + 7) / 8;
    std.debug.assert(output.len >= byte_count);
    @memset(output[0..byte_count], 0);
    inline for (0..D.lane_count) |index| {
        if (mask[index]) output[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }
    return byte_count;
}

pub fn dup128MaskFromMaskBits(comptime D: type, bits: u64) D.Mask {
    const period = 16 / @sizeOf(D.Lane);
    var result: D.Mask = @splat(false);
    inline for (0..D.lane_count) |index| {
        result[index] = bits & (@as(u64, 1) << @intCast(index % period)) != 0;
    }
    return result;
}

pub fn maskFalse(comptime D: type) D.Mask {
    return @splat(false);
}

pub fn setMask(comptime D: type, value: bool) D.Mask {
    return @splat(value);
}

fn validateFloat(comptime D: type) void {
    if (@typeInfo(D.Lane) != .float) @compileError("classification requires floating-point lanes");
}

const PairComparison = enum { less, equal, not_equal };

fn compare128(
    comptime D: type,
    a: D.Vector,
    b: D.Vector,
    comptime comparison: PairComparison,
    comptime upper_only: bool,
) D.Mask {
    if (comptime D.Lane != u64 or D.lane_count < 2 or D.lane_count & 1 != 0) {
        @compileError("128-bit comparison requires an even number of u64 lanes");
    }
    var result: D.Mask = @splat(false);
    inline for (0..D.lane_count / 2) |pair| {
        const low = pair * 2;
        const high = low + 1;
        const matches = switch (comparison) {
            .less => if (upper_only)
                a[high] < b[high]
            else
                a[high] < b[high] or (a[high] == b[high] and a[low] < b[low]),
            .equal => a[high] == b[high] and (upper_only or a[low] == b[low]),
            .not_equal => a[high] != b[high] or (!upper_only and a[low] != b[low]),
        };
        result[low] = matches;
        result[high] = matches;
    }
    return result;
}
