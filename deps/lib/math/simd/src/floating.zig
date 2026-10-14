const std = @import("std");

pub fn sqrt(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane, "sqrt");
    return @sqrt(value);
}

pub fn approximateReciprocalSqrt(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane, "approximateReciprocalSqrt");
    return @as(D.Vector, @splat(1)) / @sqrt(value);
}

pub fn approximateReciprocal(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane, "approximateReciprocal");
    return @as(D.Vector, @splat(1)) / value;
}

pub fn getExponent(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane, "getExponent");
    const U = @Int(.unsigned, @bitSizeOf(D.Lane));
    const mantissa_bits = mantissaBits(D.Lane);
    const exponent_mask = exponentMask(D.Lane);
    const bias = exponentBias(D.Lane);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        const bits: U = @bitCast(value[index]);
        const biased = (bits >> mantissa_bits) & exponent_mask;
        result[index] = @floatFromInt(@as(i32, @intCast(biased)) - bias);
    }
    return result;
}

pub fn getBiasedExponent(
    comptime D: type,
    value: D.Vector,
) D.rebind(@Int(.unsigned, @bitSizeOf(D.Lane))).Vector {
    requireFloat(D.Lane, "getBiasedExponent");
    const U = @Int(.unsigned, @bitSizeOf(D.Lane));
    const DU = D.rebind(U);
    const mantissa_bits = mantissaBits(D.Lane);
    const exponent_mask = exponentMask(D.Lane);
    var result: DU.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        const bits: U = @bitCast(value[index]);
        result[index] = (bits >> mantissa_bits) & exponent_mask;
    }
    return result;
}

pub fn round(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane, "round");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = roundEvenScalar(D.Lane, value[index]);
    }
    return result;
}

pub fn trunc(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane, "trunc");
    return @trunc(value);
}

pub fn ceil(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane, "ceil");
    return @ceil(value);
}

pub fn floor(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane, "floor");
    return @floor(value);
}

pub fn maskedSqrtOr(comptime D: type, no: D.Vector, mask: D.Mask, value: D.Vector) D.Vector {
    return @select(D.Lane, mask, sqrt(D, value), no);
}

pub fn maskedSqrt(comptime D: type, mask: D.Mask, value: D.Vector) D.Vector {
    return @select(D.Lane, mask, sqrt(D, value), @as(D.Vector, @splat(0)));
}

pub fn maskedApproximateReciprocalSqrt(comptime D: type, mask: D.Mask, value: D.Vector) D.Vector {
    return @select(
        D.Lane,
        mask,
        approximateReciprocalSqrt(D, value),
        @as(D.Vector, @splat(0)),
    );
}

pub fn maskedApproximateReciprocal(comptime D: type, mask: D.Mask, value: D.Vector) D.Vector {
    return @select(
        D.Lane,
        mask,
        approximateReciprocal(D, value),
        @as(D.Vector, @splat(0)),
    );
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

fn mantissaBits(comptime T: type) comptime_int {
    return switch (T) {
        f16 => 10,
        f32 => 23,
        f64 => 52,
        else => @compileError("unsupported floating-point lane"),
    };
}

fn exponentMask(comptime T: type) @Int(.unsigned, @bitSizeOf(T)) {
    return switch (T) {
        f16 => 0x1f,
        f32 => 0xff,
        f64 => 0x7ff,
        else => @compileError("unsupported floating-point lane"),
    };
}

fn exponentBias(comptime T: type) i32 {
    return switch (T) {
        f16 => 15,
        f32 => 127,
        f64 => 1023,
        else => @compileError("unsupported floating-point lane"),
    };
}

fn requireFloat(comptime T: type, comptime operation: []const u8) void {
    if (comptime @typeInfo(T) != .float) @compileError(operation ++ " requires floating-point lanes");
}
