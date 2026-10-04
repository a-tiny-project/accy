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
