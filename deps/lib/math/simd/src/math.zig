const std = @import("std");

const Unary = enum {
    acos,
    acosh,
    asin,
    asinh,
    atan,
    atanh,
    cbrt,
    expm1,
    log10,
    log1p,
    sinh,
    cosh,
    tanh,
    tgamma,
    log_gamma,
};

const Binary = enum {
    atan2,
    hypot,
    pow,
};

pub fn acos(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .acos);
}

pub fn acosh(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .acosh);
}

pub fn asin(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .asin);
}

pub fn asinh(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .asinh);
}

pub fn atan(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .atan);
}

pub fn atanh(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .atanh);
}

pub fn atan2(comptime D: type, y: D.Vector, x: D.Vector) D.Vector {
    return mapBinary(D, y, x, .atan2);
}

pub fn cbrt(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .cbrt);
}

pub fn cbrtNormal(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .cbrt);
}

pub fn cos(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane);
    return @cos(value);
}

pub fn tan(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane);
    return @tan(value);
}

pub fn erf(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = erfScalar(D.Lane, value[index]);
    return result;
}

pub fn exp(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane);
    return @exp(value);
}

pub fn exp2(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane);
    return @exp2(value);
}

pub fn expm1(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .expm1);
}

pub fn log(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane);
    return @log(value);
}

pub fn log10(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .log10);
}

pub fn log1p(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .log1p);
}

pub fn log2(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane);
    return @log2(value);
}

pub fn sin(comptime D: type, value: D.Vector) D.Vector {
    requireFloat(D.Lane);
    return @sin(value);
}

pub fn sinh(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .sinh);
}

pub fn cosh(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .cosh);
}

pub fn tanh(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .tanh);
}

pub fn tgamma(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .tgamma);
}

pub fn logGamma(comptime D: type, value: D.Vector) D.Vector {
    return mapUnary(D, value, .log_gamma);
}

pub fn sinCos(
    comptime D: type,
    value: D.Vector,
    sine: *D.Vector,
    cosine: *D.Vector,
) void {
    requireFloat(D.Lane);
    sine.* = @sin(value);
    cosine.* = @cos(value);
}

pub fn hypot(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return mapBinary(D, a, b, .hypot);
}

pub fn pow(comptime D: type, base: D.Vector, exponent: D.Vector) D.Vector {
    return mapBinary(D, base, exponent, .pow);
}

fn mapUnary(comptime D: type, value: D.Vector, comptime operation: Unary) D.Vector {
    requireFloat(D.Lane);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        const lane = value[index];
        result[index] = switch (operation) {
            .acos => std.math.acos(lane),
            .acosh => std.math.acosh(lane),
            .asin => std.math.asin(lane),
            .asinh => std.math.asinh(lane),
            .atan => std.math.atan(lane),
            .atanh => std.math.atanh(lane),
            .cbrt => std.math.cbrt(lane),
            .expm1 => std.math.expm1(lane),
            .log10 => std.math.log10(lane),
            .log1p => std.math.log1p(lane),
            .sinh => std.math.sinh(lane),
            .cosh => std.math.cosh(lane),
            .tanh => std.math.tanh(lane),
            .tgamma => std.math.gamma(D.Lane, lane),
            .log_gamma => std.math.lgamma(D.Lane, lane),
        };
    }
    return result;
}

fn mapBinary(
    comptime D: type,
    a: D.Vector,
    b: D.Vector,
    comptime operation: Binary,
) D.Vector {
    requireFloat(D.Lane);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = switch (operation) {
            .atan2 => std.math.atan2(a[index], b[index]),
            .hypot => std.math.hypot(a[index], b[index]),
            .pow => std.math.pow(D.Lane, a[index], b[index]),
        };
    }
    return result;
}

fn erfScalar(comptime T: type, input: T) T {
    if (std.math.isNan(input)) return input;
    const magnitude = @abs(input);
    const limit: T = if (T == f32) 14 else 37.519379347;
    const x = @min(magnitude, limit);
    const z = x * x;
    const small = if (T == f32) erfSmall32(x, z) else erfSmall64(x, z);
    const factor = if (T == f32) erfFactor32(x) else erfFactor64(x);
    const large = @as(T, 1) - @exp(-z) * factor;
    return std.math.copysign(if (x < 1) small else large, input);
}

fn erfSmall32(x: f32, z: f32) f32 {
    return x * polynomial(f32, z, .{
        1.128379165726710,
        -0.3761262582423300,
        0.1128358514861418,
        -0.02685381193529856,
        0.005188327685732524,
        -0.0008010193625184903,
        0.00007853861353153693,
    });
}

fn erfFactor32(x: f32) f32 {
    const inverse = 1 / x;
    const w = inverse * inverse;
    const first = polynomial(f32, w, .{
        0.5638259427386472,
        -0.2741127028184656,
        0.3404879937665872,
        -0.4944515323274145,
        0.6210004621745983,
        -0.5824733027278666,
        0.3687424674597105,
        -0.1387039388740657,
        0.02326819970068386,
    });
    const second = polynomial(f32, w, .{
        0.5641895067754075,
        -0.2820767439740514,
        0.4218463358204948,
        -1.015265279202700,
        2.921019019210786,
        -7.495518717768503,
        12.97719955372516,
        -10.47766399936249,
    });
    return inverse * if (x < 2) first else second;
}

fn erfSmall64(x: f64, z: f64) f64 {
    const numerator = polynomial(f64, z, .{
        55592.3013010394962768,
        7003.32514112805075473,
        2232.00534594684319226,
        90.0260197203842689217,
        9.60497373987051638749,
    });
    const denominator = polynomial(f64, z, .{
        49267.3942608635921086,
        22629.0000613890934246,
        4594.32382970980127987,
        521.357949780152679795,
        33.5617141647503099647,
        1,
    });
    return x * numerator / denominator;
}

fn erfFactor64(x: f64) f64 {
    const first_numerator = polynomial(f64, x, .{
        557.535335369399327526,
        1027.55188689515710272,
        934.528527171957607540,
        526.445194995477358631,
        196.520832956077098242,
        48.6371970985681366614,
        7.46321056442269912687,
        0.564189564831068821977,
        0.000000000246196981473530512524,
    });
    const first_denominator = polynomial(f64, x, .{
        557.535340817727675546,
        1656.66309194161350182,
        2246.33760818710981792,
        1823.90916687909736289,
        975.708501743205489753,
        354.937778887819891062,
        86.7072140885989742329,
        13.2281951154744992508,
        1,
    });
    const second_numerator = polynomial(f64, x, .{
        2.97886665372100240670,
        7.40974269950448939160,
        6.16021097993053585195,
        5.01905042251180477414,
        1.27536670759978104416,
        0.564189583547755073984,
    });
    const second_denominator = polynomial(f64, x, .{
        3.36907645100081516050,
        9.60896809063285878198,
        17.0814450747565897222,
        12.0489539808096656605,
        9.39603524938001434673,
        2.26052863220117276590,
        1,
    });
    return if (x < 8)
        first_numerator / first_denominator
    else
        second_numerator / second_denominator;
}

fn polynomial(comptime T: type, x: T, comptime coefficients: anytype) T {
    var result: T = coefficients[coefficients.len - 1];
    inline for (1..coefficients.len) |offset| {
        const index = coefficients.len - 1 - offset;
        result = @mulAdd(T, result, x, @as(T, coefficients[index]));
    }
    return result;
}

fn requireFloat(comptime T: type) void {
    if (T != f32 and T != f64) @compileError("Highway contributed math requires f32 or f64 lanes");
}

fn expectNear(comptime T: type, expected: T, actual: T, tolerance: T) !void {
    if (std.math.isNan(expected)) return std.testing.expect(std.math.isNan(actual));
    if (std.math.isInf(expected)) return std.testing.expectEqual(expected, actual);
    try std.testing.expectApproxEqAbs(expected, actual, tolerance * @max(1, @abs(expected)));
}

test "Highway contributed elementary math matches scalar references" {
    const simd = @import("root.zig");
    inline for (.{ f32, f64 }) |T| {
        const D = simd.FixedTag(T, 4);
        const angles: D.Vector = .{ -1, -0.25, 0.25, 1 };
        const sine = sin(D, angles);
        const cosine = cos(D, angles);
        const tangent = tan(D, angles);
        inline for (0..D.lane_count) |index| {
            try std.testing.expectApproxEqRel(@sin(angles[index]), sine[index], std.math.floatEps(T) * 2);
            try std.testing.expectApproxEqRel(@cos(angles[index]), cosine[index], std.math.floatEps(T) * 2);
            try std.testing.expectApproxEqRel(@tan(angles[index]), tangent[index], std.math.floatEps(T) * 2);
        }

        const positive: D.Vector = .{ 0.25, 0.5, 2, 4 };
        const exponent = exp(D, angles);
        const exponent2 = exp2(D, angles);
        const natural_log = log(D, positive);
        inline for (0..D.lane_count) |index| {
            try std.testing.expectApproxEqRel(@exp(angles[index]), exponent[index], std.math.floatEps(T) * 2);
            try std.testing.expectApproxEqRel(@exp2(angles[index]), exponent2[index], std.math.floatEps(T) * 2);
            try std.testing.expectApproxEqAbs(@log(positive[index]), natural_log[index], std.math.floatEps(T) * 2);
        }
    }
}

test "Highway contributed inverse hyperbolic and paired functions preserve identities" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f64, 4);
    const unit: D.Vector = .{ -0.75, -0.25, 0.25, 0.75 };
    const asin_result = asin(D, unit);
    const acos_result = acos(D, unit);
    const atan_result = atan(D, unit);
    const atanh_result = atanh(D, unit);
    inline for (0..D.lane_count) |index| {
        try std.testing.expectApproxEqAbs(unit[index], @sin(asin_result[index]), 0x1p-50);
        try std.testing.expectApproxEqAbs(@as(f64, std.math.pi / 2.0), asin_result[index] + acos_result[index], 0x1p-50);
        try std.testing.expectApproxEqAbs(unit[index], @tan(atan_result[index]), 0x1p-50);
        try std.testing.expectApproxEqAbs(unit[index], std.math.tanh(atanh_result[index]), 0x1p-50);
    }

    var sine: D.Vector = undefined;
    var cosine: D.Vector = undefined;
    sinCos(D, unit, &sine, &cosine);
    try std.testing.expect(@reduce(.And, sine == sin(D, unit)));
    try std.testing.expect(@reduce(.And, cosine == cos(D, unit)));
}

test "Highway contributed roots error function gamma power and hypot cover reference values" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f64, 4);
    const roots = cbrt(D, @as(D.Vector, .{ -8, -1, 1, 27 }));
    try std.testing.expectApproxEqAbs(@as(f64, -2), roots[0], 0x1p-50);
    try std.testing.expectApproxEqAbs(@as(f64, 3), roots[3], 0x1p-50);

    const errors = erf(D, @as(D.Vector, .{ -2, -1, 0, 1 }));
    try std.testing.expectApproxEqAbs(@as(f64, -0.9953222650189527), errors[0], 0x1p-50);
    try std.testing.expectApproxEqAbs(@as(f64, -0.8427007929497149), errors[1], 0x1p-50);
    try std.testing.expectEqual(@as(f64, 0), errors[2]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8427007929497149), errors[3], 0x1p-50);

    const gamma = tgamma(D, @as(D.Vector, .{ 0.5, 1, 4, 5 }));
    try std.testing.expectApproxEqAbs(@sqrt(std.math.pi), gamma[0], 0x1p-48);
    try std.testing.expectApproxEqAbs(@as(f64, 24), gamma[3], 0x1p-48);
    const log_gamma = logGamma(D, @as(D.Vector, .{ 1, 2, 4, 5 }));
    try std.testing.expectApproxEqAbs(@log(@as(f64, 24)), log_gamma[3], 0x1p-48);

    const powers = pow(D, @as(D.Vector, .{ 2, 4, 9, 16 }), @as(D.Vector, .{ 3, 0.5, 0.5, -1 }));
    try std.testing.expect(@reduce(.And, powers == @as(D.Vector, .{ 8, 2, 3, 0.0625 })));
    const lengths = hypot(D, @as(D.Vector, .{ 3, 5, 8, 7 }), @as(D.Vector, .{ 4, 12, 15, 24 }));
    try std.testing.expect(@reduce(.And, lengths == @as(D.Vector, .{ 5, 13, 17, 25 })));
}

test "Highway contributed logarithmic and hyperbolic families cover both precisions" {
    const simd = @import("root.zig");
    inline for (.{ f32, f64 }) |T| {
        const D = simd.FixedTag(T, 4);
        const values: D.Vector = .{ 0.125, 0.5, 2, 8 };
        const signed_values: D.Vector = .{ -2, -0.5, 0.5, 2 };
        const epsilon = std.math.floatEps(T) * 8;

        const base_ten = log10(D, values);
        const base_two = log2(D, values);
        const one_plus = log1p(D, values);
        const exp_minus_one = expm1(D, signed_values);
        const hyperbolic_sine = sinh(D, signed_values);
        const hyperbolic_cosine = cosh(D, signed_values);
        const inverse_sine = asinh(D, signed_values);
        const inverse_cosine = acosh(D, values + @as(D.Vector, @splat(1)));
        inline for (0..D.lane_count) |index| {
            try std.testing.expectApproxEqAbs(std.math.log10(values[index]), base_ten[index], epsilon);
            try std.testing.expectApproxEqAbs(std.math.log2(values[index]), base_two[index], epsilon);
            try std.testing.expectApproxEqAbs(std.math.log1p(values[index]), one_plus[index], epsilon);
            try std.testing.expectApproxEqRel(std.math.expm1(signed_values[index]), exp_minus_one[index], epsilon);
            try std.testing.expectApproxEqRel(std.math.sinh(signed_values[index]), hyperbolic_sine[index], epsilon);
            try std.testing.expectApproxEqRel(std.math.cosh(signed_values[index]), hyperbolic_cosine[index], epsilon);
            try std.testing.expectApproxEqAbs(signed_values[index], std.math.sinh(inverse_sine[index]), epsilon * 2);
            try std.testing.expectApproxEqAbs(values[index] + 1, std.math.cosh(inverse_cosine[index]), epsilon * 4);
        }

        const errors = erf(D, signed_values);
        try std.testing.expectApproxEqAbs(@as(T, -0.9953222650189527), errors[0], epsilon * 4);
        try std.testing.expectApproxEqAbs(@as(T, 0.9953222650189527), errors[3], epsilon * 4);
        _ = cbrtNormal(D, values);
    }
}

test "Highway contributed atan2 preserves signed zero infinity and NaN" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f64, 4);
    const y: D.Vector = .{ 0.0, -0.0, std.math.inf(f64), std.math.nan(f64) };
    const x: D.Vector = .{ -1, -1, std.math.inf(f64), 1 };
    const result = atan2(D, y, x);
    try std.testing.expectEqual(std.math.pi, result[0]);
    try std.testing.expectEqual(-std.math.pi, result[1]);
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi / 4.0), result[2], 0x1p-52);
    try std.testing.expect(std.math.isNan(result[3]));
}

test "Highway contributed math samples every upstream numerical family" {
    const simd = @import("root.zig");
    inline for (.{ f32, f64 }) |T| {
        const D = simd.FixedTag(T, 4);
        const tolerance: T = std.math.floatEps(T) * 16;
        var sample: usize = 0;
        while (sample < 256) : (sample += 1) {
            var unit_array: [D.lane_count]T = undefined;
            inline for (0..D.lane_count) |lane_index| {
                const ordinal = sample * D.lane_count + lane_index;
                const fraction = @as(T, @floatFromInt(ordinal * 2 + 1)) / @as(T, 2048);
                unit_array[lane_index] = fraction * 2 - 1;
            }
            const unit: D.Vector = unit_array;
            const positive = (unit + @as(D.Vector, @splat(1))) * @as(D.Vector, @splat(3.9375)) + @as(D.Vector, @splat(0.125));
            const moderate = unit * @as(D.Vector, @splat(8));
            const angle = unit * @as(D.Vector, @splat(39_000));
            const near_unit = unit * @as(D.Vector, @splat(0.99));
            const gamma_input = (unit + @as(D.Vector, @splat(1))) * @as(D.Vector, @splat(17.25)) + @as(D.Vector, @splat(0.5));
            const power_exponent = unit * @as(D.Vector, @splat(2));

            const outputs = .{
                acos(D, unit),
                asin(D, unit),
                atan(D, angle),
                acosh(D, positive + @as(D.Vector, @splat(1))),
                asinh(D, moderate),
                atanh(D, near_unit),
                cbrt(D, angle),
                cos(D, angle),
                tan(D, angle),
                exp(D, moderate),
                exp2(D, moderate),
                expm1(D, moderate),
                log(D, positive),
                log10(D, positive),
                log1p(D, positive),
                log2(D, positive),
                sin(D, angle),
                sinh(D, moderate),
                cosh(D, moderate),
                tanh(D, moderate),
                tgamma(D, gamma_input),
                logGamma(D, gamma_input),
                hypot(D, angle, moderate),
                pow(D, positive, power_exponent),
            };

            inline for (0..D.lane_count) |lane_index| {
                const x = unit[lane_index];
                const p = positive[lane_index];
                const m = moderate[lane_index];
                const a = angle[lane_index];
                const g = gamma_input[lane_index];
                const e = power_exponent[lane_index];
                const references = .{
                    std.math.acos(x),
                    std.math.asin(x),
                    std.math.atan(a),
                    std.math.acosh(p + 1),
                    std.math.asinh(m),
                    std.math.atanh(x * 0.99),
                    std.math.cbrt(a),
                    @cos(a),
                    @tan(a),
                    @exp(m),
                    @exp2(m),
                    std.math.expm1(m),
                    @log(p),
                    std.math.log10(p),
                    std.math.log1p(p),
                    std.math.log2(p),
                    @sin(a),
                    std.math.sinh(m),
                    std.math.cosh(m),
                    std.math.tanh(m),
                    std.math.gamma(T, g),
                    std.math.lgamma(T, g),
                    std.math.hypot(a, m),
                    std.math.pow(T, p, e),
                };
                inline for (outputs, references) |output, expected| {
                    try expectNear(T, expected, output[lane_index], tolerance);
                }
            }
        }
    }
}

test "Highway contributed hypot and power preserve special values" {
    const simd = @import("root.zig");
    inline for (.{ f32, f64 }) |T| {
        const D = simd.FixedTag(T, 4);
        const infinity = std.math.inf(T);
        const not_number = std.math.nan(T);
        const lengths = hypot(
            D,
            @as(D.Vector, .{ infinity, not_number, std.math.floatMax(T), 0 }),
            @as(D.Vector, .{ not_number, infinity, std.math.floatMax(T), -0.0 }),
        );
        try std.testing.expect(std.math.isInf(lengths[0]));
        try std.testing.expect(std.math.isInf(lengths[1]));
        try std.testing.expect(std.math.isInf(lengths[2]));
        try std.testing.expectEqual(@as(T, 0), lengths[3]);

        const powers = pow(
            D,
            @as(D.Vector, .{ -2, -2, -2, -0.0 }),
            @as(D.Vector, .{ 3, 4, 0.5, -3 }),
        );
        try std.testing.expectEqual(@as(T, -8), powers[0]);
        try std.testing.expectEqual(@as(T, 16), powers[1]);
        try std.testing.expect(std.math.isNan(powers[2]));
        try std.testing.expect(std.math.isNegativeInf(powers[3]));
    }
}
