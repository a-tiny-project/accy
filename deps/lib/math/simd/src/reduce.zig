const std = @import("std");

pub fn sum(comptime D: type, value: D.Vector) D.Lane {
    var result: D.Lane = 0;
    inline for (0..D.lane_count) |index| {
        result = if (comptime @typeInfo(D.Lane) == .int)
            result +% value[index]
        else
            result + value[index];
    }
    return result;
}

pub fn min(comptime D: type, value: D.Vector) D.Lane {
    var result = value[0];
    inline for (1..D.lane_count) |index| {
        result = @min(result, value[index]);
    }
    return result;
}

pub fn max(comptime D: type, value: D.Vector) D.Lane {
    var result = value[0];
    inline for (1..D.lane_count) |index| {
        result = @max(result, value[index]);
    }
    return result;
}

pub fn sumOfLanes(comptime D: type, value: D.Vector) D.Vector {
    return @splat(sum(D, value));
}

pub fn minOfLanes(comptime D: type, value: D.Vector) D.Vector {
    return @splat(min(D, value));
}

pub fn maxOfLanes(comptime D: type, value: D.Vector) D.Vector {
    return @splat(max(D, value));
}

pub fn maskedSum(comptime D: type, mask: D.Mask, value: D.Vector) D.Lane {
    var result: D.Lane = 0;
    inline for (0..D.lane_count) |index| {
        if (mask[index]) {
            result = if (comptime @typeInfo(D.Lane) == .int)
                result +% value[index]
            else
                result + value[index];
        }
    }
    return result;
}

pub fn maskedMin(comptime D: type, mask: D.Mask, value: D.Vector) D.Lane {
    var result: D.Lane = 0;
    var found = false;
    inline for (0..D.lane_count) |index| {
        if (mask[index]) {
            result = if (found) @min(result, value[index]) else value[index];
            found = true;
        }
    }
    return result;
}

pub fn maskedMax(comptime D: type, mask: D.Mask, value: D.Vector) D.Lane {
    var result: D.Lane = 0;
    var found = false;
    inline for (0..D.lane_count) |index| {
        if (mask[index]) {
            result = if (found) @max(result, value[index]) else value[index];
            found = true;
        }
    }
    return result;
}

pub fn sumsOf2(comptime D: type, value: D.Vector) D.repartition(wideLane(D.Lane)).Vector {
    const W = wideLane(D.Lane);
    const R = D.repartition(W);
    if (D.lane_count < 2) @compileError("sumsOf2 requires at least two lanes");
    var result: R.Vector = undefined;
    inline for (0..R.lane_count) |index| {
        result[index] = widen(W, value[index * 2]) + widen(W, value[index * 2 + 1]);
    }
    return result;
}

pub fn sumsOf4(comptime D: type, value: D.Vector) D.repartition(wideLane(wideLane(D.Lane))).Vector {
    const W = wideLane(wideLane(D.Lane));
    const R = D.repartition(W);
    if (D.lane_count < 4) @compileError("sumsOf4 requires at least four lanes");
    var result: R.Vector = undefined;
    inline for (0..R.lane_count) |index| {
        const base = index * 4;
        result[index] = widen(W, value[base]) + widen(W, value[base + 1]) +
            widen(W, value[base + 2]) + widen(W, value[base + 3]);
    }
    return result;
}

pub fn sumsOf8(comptime D: type, value: D.Vector) D.repartition(wideLane(wideLane(wideLane(D.Lane)))).Vector {
    const W = wideLane(wideLane(wideLane(D.Lane)));
    const R = D.repartition(W);
    if (D.lane_count < 8) @compileError("sumsOf8 requires at least eight lanes");
    var result: R.Vector = undefined;
    inline for (0..R.lane_count) |index| {
        const base = index * 8;
        result[index] = widen(W, value[base]) + widen(W, value[base + 1]) +
            widen(W, value[base + 2]) + widen(W, value[base + 3]) +
            widen(W, value[base + 4]) + widen(W, value[base + 5]) +
            widen(W, value[base + 6]) + widen(W, value[base + 7]);
    }
    return result;
}

pub fn sumsOf8AbsDiff(
    comptime D: type,
    a: D.Vector,
    b: D.Vector,
) D.repartition(wideLane(wideLane(wideLane(D.Lane)))).Vector {
    requireByteLane(D, "sumsOf8AbsDiff");
    const W = wideLane(wideLane(wideLane(D.Lane)));
    const R = D.repartition(W);
    if (D.lane_count < 8) @compileError("sumsOf8AbsDiff requires at least eight lanes");
    var result: R.Vector = undefined;
    inline for (0..R.lane_count) |index| {
        var total: W = 0;
        inline for (0..8) |offset| {
            total += absoluteDifference(W, a[index * 8 + offset], b[index * 8 + offset]);
        }
        result[index] = total;
    }
    return result;
}

pub fn sumsOfAdjQuadAbsDiff(
    comptime D: type,
    comptime a_offset: usize,
    comptime b_offset: usize,
    a: D.Vector,
    b: D.Vector,
) D.repartition(wideLane(D.Lane)).Vector {
    requireByteLane(D, "sumsOfAdjQuadAbsDiff");
    if (a_offset > 1 or b_offset > 3) @compileError("quad offsets exceed a 128-bit block");
    const W = wideLane(D.Lane);
    const R = D.repartition(W);
    var result: R.Vector = @splat(0);
    inline for (0..R.lane_count) |index| {
        const a_base = a_offset * 4 + (index / 8) * 16 + (index & 7);
        const b_base = b_offset * 4 + (index / 8) * 16;
        if (a_base + 3 < D.lane_count and b_base + 3 < D.lane_count) {
            var total: W = 0;
            inline for (0..4) |offset| {
                total += absoluteDifference(W, a[a_base + offset], b[b_base + offset]);
            }
            result[index] = total;
        }
    }
    return result;
}

pub fn sumsOfShuffledQuadAbsDiff(
    comptime D: type,
    comptime index3: usize,
    comptime index2: usize,
    comptime index1: usize,
    comptime index0: usize,
    a: D.Vector,
    b: D.Vector,
) D.repartition(wideLane(D.Lane)).Vector {
    requireByteLane(D, "sumsOfShuffledQuadAbsDiff");
    if (index0 > 3 or index1 > 3 or index2 > 3 or index3 > 3) {
        @compileError("quad shuffle indices must be less than four");
    }
    const W = wideLane(D.Lane);
    const R = D.repartition(W);
    const selectors = [4]usize{ index0, index1, index2, index3 };
    var shuffled: [D.lane_count]D.Lane = @splat(0);
    inline for (0..(D.lane_count + 15) / 16) |block_index| {
        inline for (0..4) |group| {
            inline for (0..4) |byte| {
                const destination = block_index * 16 + group * 4 + byte;
                const source = block_index * 16 + selectors[group] * 4 + byte;
                if (destination < D.lane_count and source < D.lane_count) {
                    shuffled[destination] = a[source];
                }
            }
        }
    }
    var result: R.Vector = @splat(0);
    inline for (0..R.lane_count) |index| {
        const a_base = (index / 4) * 8 + (index & 3);
        const b_base = (index / 2) * 4;
        if (a_base + 3 < D.lane_count and b_base + 3 < D.lane_count) {
            var total: W = 0;
            inline for (0..4) |offset| {
                total += absoluteDifference(W, shuffled[a_base + offset], b[b_base + offset]);
            }
            result[index] = total;
        }
    }
    return result;
}

fn wideLane(comptime T: type) type {
    return switch (T) {
        i8 => i16,
        u8 => u16,
        i16 => i32,
        u16 => u32,
        i32 => i64,
        u32 => u64,
        f16 => f32,
        f32 => f64,
        else => @compileError("lane type has no Highway wide representation"),
    };
}

fn widen(comptime T: type, value: anytype) T {
    return if (@typeInfo(T) == .float) @floatCast(value) else @intCast(value);
}

fn absoluteDifference(comptime T: type, a: anytype, b: @TypeOf(a)) T {
    const a_wide: i128 = a;
    const b_wide: i128 = b;
    const difference = a_wide - b_wide;
    return @intCast(if (difference < 0) -difference else difference);
}

fn requireByteLane(comptime D: type, comptime operation: []const u8) void {
    if (comptime D.Lane != u8 and D.Lane != i8) {
        @compileError(operation ++ " requires byte integer lanes");
    }
}

test "reductions match scalar Highway models" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i16, 8);
    const value: D.Vector = .{ 7, -4, 2, 9, -11, 3, 1, 6 };
    try std.testing.expectEqual(@as(i16, 13), sum(D, value));
    try std.testing.expectEqual(@as(i16, -11), min(D, value));
    try std.testing.expectEqual(@as(i16, 9), max(D, value));
}

test "integer sum uses Highway wrapping semantics" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u8, 4);
    try std.testing.expectEqual(@as(u8, 4), sum(D, @as(D.Vector, @splat(129))));
}

test "Highway broadcast and masked reductions match scalar selection" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i16, 8);
    const value: D.Vector = .{ 7, -4, 2, 9, -11, 3, 1, 6 };
    const mask: D.Mask = .{ false, true, false, true, true, false, true, false };
    try std.testing.expect(@reduce(.And, sumOfLanes(D, value) == @as(D.Vector, @splat(13))));
    try std.testing.expect(@reduce(.And, minOfLanes(D, value) == @as(D.Vector, @splat(-11))));
    try std.testing.expect(@reduce(.And, maxOfLanes(D, value) == @as(D.Vector, @splat(9))));
    try std.testing.expectEqual(@as(i16, -5), maskedSum(D, mask, value));
    try std.testing.expectEqual(@as(i16, -11), maskedMin(D, mask, value));
    try std.testing.expectEqual(@as(i16, 9), maskedMax(D, mask, value));
}

test "Highway pairwise sums widen adjacent groups" {
    const simd = @import("root.zig");
    const D8 = simd.FixedTag(i8, 16);
    const value: D8.Vector = .{
        100, 100, -100, -100, 1, 2,  3,  4,
        5,   6,   7,    8,    9, 10, 11, 12,
    };
    const D16 = D8.repartition(i16);
    const D32 = D8.repartition(i32);
    const D64 = D8.repartition(i64);
    try std.testing.expect(@reduce(.And, sumsOf2(D8, value) == @as(D16.Vector, .{
        200, -200, 3, 7, 11, 15, 19, 23,
    })));
    try std.testing.expect(@reduce(.And, sumsOf4(D8, value) == @as(D32.Vector, .{ 0, 10, 26, 42 })));
    try std.testing.expect(@reduce(.And, sumsOf8(D8, value) == @as(D64.Vector, .{ 10, 68 })));

    const F = simd.FixedTag(f32, 4);
    try std.testing.expect(@reduce(.And, sumsOf2(F, @as(F.Vector, .{ 1.5, 2.5, -4, 1 })) ==
        @as(F.repartition(f64).Vector, .{ 4, -3 })));
}

fn verifyReductionLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const value: D.Vector = @splat(0);
    const mask: D.Mask = .{ true, false, true, false };
    try std.testing.expectEqual(@as(T, 0), sum(D, value));
    try std.testing.expectEqual(@as(T, 0), min(D, value));
    try std.testing.expectEqual(@as(T, 0), max(D, value));
    try std.testing.expectEqual(@as(T, 0), maskedSum(D, mask, value));
    try std.testing.expectEqual(@as(T, 0), maskedMin(D, mask, value));
    try std.testing.expectEqual(@as(T, 0), maskedMax(D, mask, value));
    try std.testing.expect(@reduce(.And, sumOfLanes(D, value) == value));
    try std.testing.expect(@reduce(.And, minOfLanes(D, value) == value));
    try std.testing.expect(@reduce(.And, maxOfLanes(D, value) == value));
}

fn verifySumsOf2(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 8);
    const value: D.Vector = @splat(0);
    try std.testing.expect(@reduce(.And, sumsOf2(D, value) == @as(D.repartition(wideLane(T)).Vector, @splat(0))));
}

fn verifySumsOf4(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 8);
    const W = wideLane(wideLane(T));
    const value: D.Vector = @splat(0);
    try std.testing.expect(@reduce(.And, sumsOf4(D, value) == @as(D.repartition(W).Vector, @splat(0))));
}

test "Highway reductions instantiate every lane type and supported widening" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f16, f32, f64 }) |T| {
        try verifyReductionLaneType(T);
    }
    inline for (.{ u8, i8, u16, i16, u32, i32, f16, f32 }) |T| try verifySumsOf2(T);
    inline for (.{ u8, i8, u16, i16 }) |T| try verifySumsOf4(T);
    const simd = @import("root.zig");
    inline for (.{ u8, i8 }) |T| {
        const D = simd.FixedTag(T, 8);
        try std.testing.expect(@reduce(.And, sumsOf8(D, @as(D.Vector, @splat(0))) ==
            @as(D.repartition(wideLane(wideLane(wideLane(T)))).Vector, @splat(0))));
    }
}

test "Highway absolute-difference reductions match scalar block formulas" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i8, 16);
    const a: D.Vector = .{ 1, 2, 3, 4, 9, 8, 7, 6, -1, -2, -3, -4, 5, 6, 7, 8 };
    const b: D.Vector = .{ 4, 3, 2, 1, 1, 2, 3, 4, 1, 2, 3, 4, 8, 7, 6, 5 };
    try std.testing.expect(@reduce(.And, sumsOf8AbsDiff(D, a, b) ==
        @as(D.repartition(i64).Vector, .{ 28, 28 })));
    try std.testing.expect(@reduce(.And, sumsOfAdjQuadAbsDiff(D, 0, 1, a, b) ==
        @as(D.repartition(i16).Vector, .{ 0, 8, 14, 18, 20, 20, 20, 20 })));
    try std.testing.expect(@reduce(.And, sumsOfShuffledQuadAbsDiff(D, 3, 2, 1, 0, a, b) ==
        @as(D.repartition(i16).Vector, .{ 8, 12, 14, 18, 20, 16, 24, 16 })));
}
