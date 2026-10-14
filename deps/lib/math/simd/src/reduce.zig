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
