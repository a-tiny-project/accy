const std = @import("std");

pub fn lowerHalf(comptime D: type, value: anytype) D.Vector {
    if (D.lane_count == 1) {
        if (@TypeOf(value) != D.Vector) @compileError("scalar lowerHalf requires the same descriptor");
        return value;
    }
    if (@TypeOf(value) != D.twice().Vector) {
        @compileError("lowerHalf source must have twice the destination lanes");
    }
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = value[index];
    return result;
}

pub fn upperHalf(comptime D: type, value: D.twice().Vector) D.Vector {
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = value[D.lane_count + index];
    return result;
}

pub fn zeroExtendVector(comptime D: type, value: D.half().Vector) D.Vector {
    validate(D);
    var result: D.Vector = @splat(0);
    inline for (0..D.lane_count / 2) |index| result[index] = value[index];
    return result;
}

pub fn combine(
    comptime D: type,
    high: D.half().Vector,
    low: D.half().Vector,
) D.Vector {
    validate(D);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / 2) |index| {
        result[index] = low[index];
        result[D.lane_count / 2 + index] = high[index];
    }
    return result;
}

pub fn concatLowerLower(comptime D: type, high: D.Vector, low: D.Vector) D.Vector {
    const H = D.half();
    return combine(D, lowerHalf(H, high), lowerHalf(H, low));
}

pub fn concatUpperUpper(comptime D: type, high: D.Vector, low: D.Vector) D.Vector {
    const H = D.half();
    return combine(D, upperHalf(H, high), upperHalf(H, low));
}

pub fn concatLowerUpper(comptime D: type, high: D.Vector, low: D.Vector) D.Vector {
    const H = D.half();
    return combine(D, lowerHalf(H, high), upperHalf(H, low));
}

pub fn concatUpperLower(comptime D: type, high: D.Vector, low: D.Vector) D.Vector {
    const H = D.half();
    return combine(D, upperHalf(H, high), lowerHalf(H, low));
}

pub fn concatOdd(comptime D: type, high: D.Vector, low: D.Vector) D.Vector {
    validate(D);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / 2) |index| {
        result[index] = low[index * 2 + 1];
        result[D.lane_count / 2 + index] = high[index * 2 + 1];
    }
    return result;
}

pub fn concatEven(comptime D: type, high: D.Vector, low: D.Vector) D.Vector {
    validate(D);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / 2) |index| {
        result[index] = low[index * 2];
        result[D.lane_count / 2 + index] = high[index * 2];
    }
    return result;
}

pub fn interleaveWholeLower(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    validate(D);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / 2) |index| {
        result[index * 2] = a[index];
        result[index * 2 + 1] = b[index];
    }
    return result;
}

pub fn interleaveWholeUpper(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    validate(D);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / 2) |index| {
        result[index * 2] = a[D.lane_count / 2 + index];
        result[index * 2 + 1] = b[D.lane_count / 2 + index];
    }
    return result;
}

pub fn lowerHalfOfMask(comptime D: type, mask: D.twice().Mask) D.Mask {
    var result: D.Mask = undefined;
    inline for (0..D.lane_count) |index| result[index] = mask[index];
    return result;
}

pub fn upperHalfOfMask(comptime D: type, mask: D.twice().Mask) D.Mask {
    var result: D.Mask = undefined;
    inline for (0..D.lane_count) |index| result[index] = mask[D.lane_count + index];
    return result;
}

pub fn combineMasks(
    comptime D: type,
    high: D.half().Mask,
    low: D.half().Mask,
) D.Mask {
    validate(D);
    var result: D.Mask = undefined;
    inline for (0..D.lane_count / 2) |index| {
        result[index] = low[index];
        result[D.lane_count / 2 + index] = high[index];
    }
    return result;
}

fn validate(comptime D: type) void {
    if (D.lane_count < 2) @compileError("lane combination requires at least two lanes");
}

fn verifyLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 8);
    const H = D.half();
    const value: D.Vector = @splat(0);
    const low = lowerHalf(H, value);
    const high = upperHalf(H, value);
    try std.testing.expect(@reduce(.And, combine(D, high, low) == value));
    try std.testing.expect(@reduce(.And, concatOdd(D, value, value) == value));
    try std.testing.expect(@reduce(.And, concatEven(D, value, value) == value));
    try std.testing.expect(@reduce(.And, interleaveWholeLower(D, value, value) == value));
    try std.testing.expect(@reduce(.And, interleaveWholeUpper(D, value, value) == value));
}

test "Highway lane geometry instantiates every lane type" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f16, f32, f64 }) |T| {
        try verifyLaneType(T);
    }
    const D = @import("root.zig").FixedTag(u32, 1);
    try std.testing.expect(@reduce(.And, lowerHalf(D, @as(D.Vector, .{9})) ==
        @as(D.Vector, .{9})));
}

test "Highway vector halves combine and zero extend in lane order" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u32, 8);
    const H = D.half();
    const value: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const low = lowerHalf(H, value);
    const high = upperHalf(H, value);
    try std.testing.expect(@reduce(.And, low == @as(H.Vector, .{ 0, 1, 2, 3 })));
    try std.testing.expect(@reduce(.And, high == @as(H.Vector, .{ 4, 5, 6, 7 })));
    try std.testing.expect(@reduce(.And, combine(D, high, low) == value));
    try std.testing.expect(@reduce(.And, zeroExtendVector(D, low) ==
        @as(D.Vector, .{ 0, 1, 2, 3, 0, 0, 0, 0 })));
}

test "Highway whole-vector concatenations select exact quarters" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u16, 8);
    const low: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const high: D.Vector = .{ 10, 11, 12, 13, 14, 15, 16, 17 };
    try std.testing.expect(@reduce(.And, concatLowerLower(D, high, low) ==
        @as(D.Vector, .{ 0, 1, 2, 3, 10, 11, 12, 13 })));
    try std.testing.expect(@reduce(.And, concatUpperUpper(D, high, low) ==
        @as(D.Vector, .{ 4, 5, 6, 7, 14, 15, 16, 17 })));
    try std.testing.expect(@reduce(.And, concatLowerUpper(D, high, low) ==
        @as(D.Vector, .{ 4, 5, 6, 7, 10, 11, 12, 13 })));
    try std.testing.expect(@reduce(.And, concatUpperLower(D, high, low) ==
        @as(D.Vector, .{ 0, 1, 2, 3, 14, 15, 16, 17 })));
    try std.testing.expect(@reduce(.And, concatOdd(D, high, low) ==
        @as(D.Vector, .{ 1, 3, 5, 7, 11, 13, 15, 17 })));
    try std.testing.expect(@reduce(.And, concatEven(D, high, low) ==
        @as(D.Vector, .{ 0, 2, 4, 6, 10, 12, 14, 16 })));
}

test "Highway whole interleave and mask halves retain ordering" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 8);
    const H = D.half();
    const a: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const b: D.Vector = .{ 10, 11, 12, 13, 14, 15, 16, 17 };
    try std.testing.expect(@reduce(.And, interleaveWholeLower(D, a, b) ==
        @as(D.Vector, .{ 0, 10, 1, 11, 2, 12, 3, 13 })));
    try std.testing.expect(@reduce(.And, interleaveWholeUpper(D, a, b) ==
        @as(D.Vector, .{ 4, 14, 5, 15, 6, 16, 7, 17 })));
    const mask: D.Mask = .{ true, false, true, false, false, true, false, true };
    const low = lowerHalfOfMask(H, mask);
    const high = upperHalfOfMask(H, mask);
    try std.testing.expect(@reduce(.And, combineMasks(D, high, low) == mask));
}
