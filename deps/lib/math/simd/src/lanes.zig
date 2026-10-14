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
