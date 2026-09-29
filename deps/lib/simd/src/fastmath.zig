const std = @import("std");
const math = @import("math.zig");

pub fn fastTan(comptime D: type, value: D.Vector) D.Vector {
    return math.tan(D, value);
}

pub fn fastAtan(comptime D: type, value: D.Vector) D.Vector {
    return math.atan(D, value);
}

pub fn fastAtanPositive(comptime D: type, value: D.Vector) D.Vector {
    return math.atan(D, value);
}

pub fn fastAtan2(comptime D: type, y: D.Vector, x: D.Vector) D.Vector {
    return math.atan2(D, y, x);
}

pub fn fastTanh(comptime D: type, value: D.Vector) D.Vector {
    return math.tanh(D, value);
}

pub fn fastLog(comptime D: type, value: D.Vector) D.Vector {
    return math.log(D, value);
}

pub fn fastExp(comptime D: type, value: D.Vector) D.Vector {
    return math.exp(D, value);
}

pub fn fastExp2(comptime D: type, value: D.Vector) D.Vector {
    return math.exp2(D, value);
}

pub fn fastExpMinusOrZero(comptime D: type, value: D.Vector) D.Vector {
    return flushSubnormals(D, math.exp(D, value));
}

pub fn fastLog2(comptime D: type, value: D.Vector) D.Vector {
    return math.log2(D, value);
}

pub fn fastLog10(comptime D: type, value: D.Vector) D.Vector {
    return math.log10(D, value);
}

pub fn fastLog1p(comptime D: type, value: D.Vector) D.Vector {
    return math.log1p(D, value);
}

pub fn fastPow(comptime D: type, base: D.Vector, exponent: D.Vector) D.Vector {
    return math.pow(D, base, exponent);
}

pub fn fastExpNormal(comptime D: type, value: D.Vector) D.Vector {
    return flushSubnormals(D, math.exp(D, value));
}

pub fn fastExp2Normal(comptime D: type, value: D.Vector) D.Vector {
    return flushSubnormals(D, math.exp2(D, value));
}

pub fn fastLogPositiveNormal(comptime D: type, value: D.Vector) D.Vector {
    return math.log(D, value);
}

pub fn fastLog2PositiveNormal(comptime D: type, value: D.Vector) D.Vector {
    return math.log2(D, value);
}

pub fn fastLog10PositiveNormal(comptime D: type, value: D.Vector) D.Vector {
    return math.log10(D, value);
}

pub fn fastLog1pPositiveNormal(comptime D: type, value: D.Vector) D.Vector {
    return math.log1p(D, value);
}

pub fn fastPowNormal(comptime D: type, base: D.Vector, exponent: D.Vector) D.Vector {
    return flushSubnormals(D, math.pow(D, base, exponent));
}

fn flushSubnormals(comptime D: type, value: D.Vector) D.Vector {
    var result = value;
    inline for (0..D.lane_count) |index| {
        if (@abs(result[index]) < std.math.floatMin(D.Lane)) {
            result[index] = std.math.copysign(@as(D.Lane, 0), result[index]);
        }
    }
    return result;
}

test "Highway fast math stays within the documented relative bounds" {
    const simd = @import("root.zig");
    inline for (.{ f32, f64 }) |T| {
        const D = simd.FixedTag(T, 4);
        const values: D.Vector = .{ -0.75, -0.125, 0.125, 0.75 };
        const positive: D.Vector = .{ 0.25, 0.5, 2, 8 };
        const tangent = fastTan(D, values);
        const inverse = fastAtan(D, values);
        const hyperbolic = fastTanh(D, values);
        const logarithm = fastLog(D, positive);
        const exponent = fastExp(D, values);
        inline for (0..D.lane_count) |index| {
            try std.testing.expectApproxEqRel(@tan(values[index]), tangent[index], @as(T, 0.002));
            try std.testing.expectApproxEqRel(std.math.atan(values[index]), inverse[index], @as(T, 0.000006));
            try std.testing.expectApproxEqRel(std.math.tanh(values[index]), hyperbolic[index], @as(T, 0.000006));
            try std.testing.expectApproxEqRel(@log(positive[index]), logarithm[index], @as(T, 0.000012));
            try std.testing.expectApproxEqRel(@exp(values[index]), exponent[index], @as(T, 0.000007));
        }
    }
}

test "Highway fast logarithm and exponent variants retain identities" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f64, 4);
    const values: D.Vector = .{ 0.125, 0.5, 2, 8 };
    const log_two = fastLog2(D, values);
    const exp_two = fastExp2(D, log_two);
    inline for (0..D.lane_count) |index| {
        try std.testing.expectApproxEqRel(values[index], exp_two[index], 0x1p-50);
    }

    const log_ten = fastLog10(D, @as(D.Vector, .{ 0.1, 1, 10, 100 }));
    try std.testing.expectApproxEqAbs(@as(f64, -1), log_ten[0], 0x1p-50);
    try std.testing.expectApproxEqAbs(@as(f64, 2), log_ten[3], 0x1p-50);
    const log_one = fastLog1p(D, @as(D.Vector, .{ -0.5, -0.25, 0.25, 1 }));
    try std.testing.expectApproxEqAbs(std.math.log1p(@as(f64, -0.5)), log_one[0], 0x1p-50);
}

test "Highway fast normal modes flush subnormal results" {
    const simd = @import("root.zig");
    const D32 = simd.FixedTag(f32, 4);
    const result32 = fastExpNormal(D32, @as(D32.Vector, .{ -100, -90, -80, 0 }));
    try std.testing.expectEqual(@as(f32, 0), result32[0]);
    try std.testing.expectEqual(@as(f32, 0), result32[1]);
    try std.testing.expect(result32[2] > 0);
    try std.testing.expectEqual(@as(f32, 1), result32[3]);

    const D64 = simd.FixedTag(f64, 4);
    const result64 = fastExpMinusOrZero(D64, @as(D64.Vector, .{ -1000, -800, -700, 0 }));
    try std.testing.expectEqual(@as(f64, 0), result64[0]);
    try std.testing.expectEqual(@as(f64, 0), result64[1]);
    try std.testing.expect(result64[2] > 0);
    try std.testing.expectEqual(@as(f64, 1), result64[3]);
}

test "Highway fast binary and positive-only entry points remain available" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f32, 4);
    const positive: D.Vector = .{ 0, 0.25, 1, 8 };
    const signed_values: D.Vector = .{ -2, -0.5, 0.5, 2 };
    const positive_atan = fastAtanPositive(D, positive);
    const ordinary_atan = fastAtan(D, positive);
    try std.testing.expect(@reduce(.And, positive_atan == ordinary_atan));

    const quadrants = fastAtan2(D, signed_values, @as(D.Vector, .{ -1, 1, 1, -1 }));
    inline for (0..D.lane_count) |index| {
        try std.testing.expectApproxEqAbs(
            std.math.atan2(signed_values[index], @as(D.Vector, .{ -1, 1, 1, -1 })[index]),
            quadrants[index],
            0.000001,
        );
    }

    const powers = fastPow(D, @as(D.Vector, .{ 2, 4, 8, 16 }), @as(D.Vector, .{ 3, 0.5, -1, 0.25 }));
    const normal_powers = fastPowNormal(D, @as(D.Vector, .{ 2, 4, 8, 16 }), @as(D.Vector, .{ 3, 0.5, -1, 0.25 }));
    try std.testing.expect(@reduce(.And, powers == normal_powers));
    _ = fastLogPositiveNormal(D, positive + @as(D.Vector, @splat(1)));
    _ = fastLog2PositiveNormal(D, positive + @as(D.Vector, @splat(1)));
    _ = fastLog10PositiveNormal(D, positive + @as(D.Vector, @splat(1)));
    _ = fastLog1pPositiveNormal(D, positive);
    _ = fastExp2Normal(D, signed_values);
}
