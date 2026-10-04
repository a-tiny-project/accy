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

test "comparisons and selection operate independently per lane" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 4);
    const a: D.Vector = .{ 1, 5, -3, 8 };
    const b: D.Vector = .{ 2, 5, -4, 9 };
    const expected_mask: D.Mask = .{ true, false, false, true };
    try std.testing.expect(allTrue(D, lt(D, a, b) == expected_mask));
    const expected: D.Vector = .{ 1, 5, -4, 8 };
    try std.testing.expect(allTrue(D, eq(D, select(D, expected_mask, a, b), expected)));
}

test "mask bit round trips retain lane order" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u8, 8);
    const mask = maskFromBits(D, 0xa5);
    try std.testing.expectEqual(@as(u64, 0xa5), bitsFromMask(D, mask));
    try std.testing.expectEqual(@as(usize, 4), countTrue(D, mask));
    try std.testing.expect(allTrue(D, maskOr(D, mask, maskNot(D, mask))));
    try std.testing.expect(allFalse(D, maskAnd(D, mask, maskNot(D, mask))));
}

test "Highway mask vectors and byte storage retain canonical bits" {
    const simd = @import("root.zig");
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f16, f32, f64 }) |T| {
        const E = simd.FixedTag(T, 4);
        const expected: E.Mask = .{ true, false, true, false };
        try std.testing.expect(@reduce(.And, maskFromVec(E, vecFromMask(E, expected)) == expected));
    }
    const D = simd.FixedTag(u16, 16);
    const mask: D.Mask = .{
        true,  false, true,  false, false, true,  false, true,
        false, true,  false, false, true,  false, true,  false,
    };
    try std.testing.expect(@reduce(.And, maskFromVec(D, vecFromMask(D, mask)) == mask));
    var bytes: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), storeMaskBits(D, mask, &bytes));
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0x52 }, &bytes);
    try std.testing.expect(@reduce(.And, loadMaskBits(D, &bytes) == mask));
    try std.testing.expect(@reduce(.And, dup128MaskFromMaskBits(D, 0xa5) ==
        @as(D.Mask, .{
            true, false, true, false, false, true, false, true,
            true, false, true, false, false, true, false, true,
        })));
    try std.testing.expect(allFalse(D, maskFalse(D)));
    try std.testing.expect(allTrue(D, setMask(D, true)));
    try std.testing.expect(@reduce(.And, rebindMask(simd.FixedTag(f16, 16), mask) == mask));
}

test "Highway sign classification reads bits for integers and floats" {
    const simd = @import("root.zig");
    const DI = simd.FixedTag(i32, 4);
    const DF = simd.FixedTag(f32, 4);
    const DU = simd.FixedTag(u32, 4);
    const integers: DI.Vector = .{ 0, -1, 1, std.math.minInt(i32) };
    const floats: DF.Vector = @bitCast(@as(DU.Vector, .{
        0, 0x8000_0000, 0x7fc0_0001, 0xffc0_0001,
    }));
    try std.testing.expect(allTrue(DI, isNegative(DI, integers) ==
        @as(DI.Mask, .{ false, true, false, true })));
    try std.testing.expect(allTrue(DF, isNegative(DF, floats) ==
        @as(DF.Mask, .{ false, true, false, true })));
    try std.testing.expect(allTrue(DF, isNaN(DF, floats) ==
        @as(DF.Mask, .{ false, false, true, true })));
    try std.testing.expect(allTrue(DF, isEitherNaN(DF, floats, @as(DF.Vector, @splat(0))) ==
        @as(DF.Mask, .{ false, false, true, true })));
}

test "Highway floating classification distinguishes infinity and finiteness" {
    const simd = @import("root.zig");
    inline for (.{ f16, f32, f64 }) |T| {
        const D = simd.FixedTag(T, 4);
        const value: D.Vector = .{ 0, -1, std.math.inf(T), std.math.nan(T) };
        try std.testing.expect(allTrue(D, isInf(D, value) ==
            @as(D.Mask, .{ false, false, true, false })));
        try std.testing.expect(allTrue(D, isFinite(D, value) ==
            @as(D.Mask, .{ true, true, false, false })));
    }
}

test "Highway masked comparisons clear inactive lanes" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u16, 4);
    const a: D.Vector = .{ 1, 2, 3, 4 };
    const b: D.Vector = .{ 1, 3, 2, 4 };
    const mask: D.Mask = .{ true, true, false, false };
    try std.testing.expect(allTrue(D, maskedEq(D, mask, a, b) ==
        @as(D.Mask, .{ true, false, false, false })));
    try std.testing.expect(allTrue(D, maskedLt(D, mask, a, b) ==
        @as(D.Mask, .{ false, true, false, false })));
    try std.testing.expect(allTrue(D, maskedNe(D, mask, a, b) ==
        @as(D.Mask, .{ false, true, false, false })));
    try std.testing.expect(allTrue(D, maskedLe(D, mask, a, b) ==
        @as(D.Mask, .{ true, true, false, false })));
    try std.testing.expect(allTrue(D, maskedGt(D, mask, a, b) ==
        @as(D.Mask, .{ false, false, false, false })));
    try std.testing.expect(allTrue(D, maskedGe(D, mask, a, b) ==
        @as(D.Mask, .{ true, false, false, false })));
    const F = simd.FixedTag(f32, 4);
    const floats: F.Vector = .{ std.math.nan(f32), 0, std.math.nan(f32), 1 };
    try std.testing.expect(allTrue(F, maskedIsNaN(F, @as(F.Mask, mask), floats) ==
        @as(F.Mask, .{ true, false, false, false })));
}

test "Highway pair comparisons broadcast full and upper-key results" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u64, 8);
    const a: D.Vector = .{ 9, 1, 7, 4, 10, 6, 20, 8 };
    const b: D.Vector = .{ 10, 1, 8, 3, 10, 6, 19, 8 };
    try std.testing.expect(@reduce(.And, lt128(D, a, b) ==
        @as(D.Mask, .{ true, true, false, false, false, false, false, false })));
    try std.testing.expect(@reduce(.And, lt128Upper(D, a, b) ==
        @as(D.Mask, .{ false, false, false, false, false, false, false, false })));
    try std.testing.expect(@reduce(.And, eq128(D, a, b) ==
        @as(D.Mask, .{ false, false, false, false, true, true, false, false })));
    try std.testing.expect(@reduce(.And, ne128(D, a, b) ==
        @as(D.Mask, .{ true, true, true, true, false, false, true, true })));
    try std.testing.expect(@reduce(.And, eq128Upper(D, a, b) ==
        @as(D.Mask, .{ true, true, false, false, true, true, true, true })));
    try std.testing.expect(@reduce(.And, ne128Upper(D, a, b) ==
        @as(D.Mask, .{ false, false, true, true, false, false, false, false })));
}

test "Highway mask searches and first-boundary transforms cover empty and populated masks" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u8, 8);
    const mask: D.Mask = .{ false, false, true, false, true, false, false, true };
    try std.testing.expectEqual(@as(isize, 2), findFirstTrue(D, mask));
    try std.testing.expectEqual(@as(usize, 2), findKnownFirstTrue(D, mask));
    try std.testing.expectEqual(@as(isize, 7), findLastTrue(D, mask));
    try std.testing.expectEqual(@as(usize, 7), findKnownLastTrue(D, mask));
    try std.testing.expect(@reduce(.And, setOnlyFirst(D, mask) ==
        @as(D.Mask, .{ false, false, true, false, false, false, false, false })));
    try std.testing.expect(@reduce(.And, setBeforeFirst(D, mask) ==
        @as(D.Mask, .{ true, true, false, false, false, false, false, false })));
    try std.testing.expect(@reduce(.And, setAtOrBeforeFirst(D, mask) ==
        @as(D.Mask, .{ true, true, true, false, false, false, false, false })));
    try std.testing.expect(@reduce(.And, setAtOrAfterFirst(D, mask) ==
        @as(D.Mask, .{ false, false, true, true, true, true, true, true })));
    const empty: D.Mask = @splat(false);
    try std.testing.expectEqual(@as(isize, -1), findFirstTrue(D, empty));
    try std.testing.expectEqual(@as(isize, -1), findLastTrue(D, empty));
    try std.testing.expect(allTrue(D, setBeforeFirst(D, empty)));
    try std.testing.expect(allFalse(D, setOnlyFirst(D, empty)));
    try std.testing.expect(@reduce(.And, maskAndNot(D, mask, setBeforeFirst(D, mask)) ==
        @as(D.Mask, .{ true, true, false, false, false, false, false, false })));
    try std.testing.expect(@reduce(.And, exclusiveNeither(D, mask, setBeforeFirst(D, mask)) ==
        @as(D.Mask, .{ false, false, false, true, false, true, true, false })));
}
