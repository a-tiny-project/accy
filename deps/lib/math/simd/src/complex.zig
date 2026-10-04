const std = @import("std");

pub fn complexConj(comptime D: type, value: D.Vector) D.Vector {
    validate(D);
    var result = value;
    inline for (0..D.lane_count / 2) |index| {
        result[index * 2 + 1] = -value[index * 2 + 1];
    }
    return result;
}

pub fn mulComplex(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return multiply(D, a, b, false, null);
}

pub fn mulComplexConj(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return multiply(D, a, b, true, null);
}

pub fn mulComplexAdd(comptime D: type, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return multiply(D, a, b, false, c);
}

pub fn mulComplexConjAdd(comptime D: type, a: D.Vector, b: D.Vector, c: D.Vector) D.Vector {
    return multiply(D, a, b, true, c);
}

pub fn maskedMulComplexConjAdd(
    comptime D: type,
    mask: D.Mask,
    a: D.Vector,
    b: D.Vector,
    c: D.Vector,
) D.Vector {
    return @select(
        D.Lane,
        mask,
        mulComplexConjAdd(D, a, b, c),
        @as(D.Vector, @splat(0)),
    );
}

pub fn maskedMulComplexConj(
    comptime D: type,
    mask: D.Mask,
    a: D.Vector,
    b: D.Vector,
) D.Vector {
    return @select(
        D.Lane,
        mask,
        mulComplexConj(D, a, b),
        @as(D.Vector, @splat(0)),
    );
}

pub fn maskedMulComplexOr(
    comptime D: type,
    no: D.Vector,
    mask: D.Mask,
    a: D.Vector,
    b: D.Vector,
) D.Vector {
    return @select(D.Lane, mask, mulComplex(D, a, b), no);
}

fn multiply(
    comptime D: type,
    a: D.Vector,
    b: D.Vector,
    comptime conjugate_b: bool,
    addend: ?D.Vector,
) D.Vector {
    validate(D);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / 2) |index| {
        const real = index * 2;
        const imaginary = real + 1;
        const c_real = if (addend) |c| c[real] else 0;
        const c_imaginary = if (addend) |c| c[imaginary] else 0;
        if (conjugate_b) {
            result[real] = @mulAdd(D.Lane, a[imaginary], b[imaginary], @mulAdd(D.Lane, a[real], b[real], c_real));
            result[imaginary] = @mulAdd(D.Lane, a[imaginary], b[real], @mulAdd(D.Lane, -a[real], b[imaginary], c_imaginary));
        } else {
            result[real] = @mulAdd(D.Lane, -a[imaginary], b[imaginary], @mulAdd(D.Lane, a[real], b[real], c_real));
            result[imaginary] = @mulAdd(D.Lane, a[imaginary], b[real], @mulAdd(D.Lane, a[real], b[imaginary], c_imaginary));
        }
    }
    return result;
}

fn validate(comptime D: type) void {
    if (comptime @typeInfo(D.Lane) != .float or D.lane_count & 1 != 0) {
        @compileError("complex arithmetic requires an even number of floating-point lanes");
    }
}

test "Highway complex multiply conjugate add and masks preserve lane pairs" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f32, 8);
    const a: D.Vector = .{ 1, 2, 3, 4, -2, 5, 7, -3 };
    const b: D.Vector = .{ 5, 6, 7, 8, 4, -1, -2, 6 };
    try std.testing.expect(@reduce(.And, complexConj(D, a) ==
        @as(D.Vector, .{ 1, -2, 3, -4, -2, -5, 7, 3 })));
    try std.testing.expect(@reduce(.And, mulComplex(D, a, b) ==
        @as(D.Vector, .{ -7, 16, -11, 52, -3, 22, 4, 48 })));
    try std.testing.expect(@reduce(.And, mulComplexConj(D, a, b) ==
        @as(D.Vector, .{ 17, 4, 53, 4, -13, 18, -32, -36 })));
    try std.testing.expect(@reduce(.And, mulComplexAdd(D, a, b, @as(D.Vector, @splat(1))) ==
        @as(D.Vector, .{ -6, 17, -10, 53, -2, 23, 5, 49 })));
    const mask: D.Mask = .{ true, true, false, false, true, false, false, true };
    try std.testing.expect(@reduce(.And, maskedMulComplexOr(D, @splat(9), mask, a, b) ==
        @as(D.Vector, .{ -7, 16, 9, 9, -3, 9, 9, 48 })));
    _ = maskedMulComplexConj(D, mask, a, b);
    _ = maskedMulComplexConjAdd(D, mask, a, b, @splat(1));
}

test "Highway complex arithmetic instantiates every floating lane type" {
    const simd = @import("root.zig");
    inline for (.{ f16, f32, f64 }) |T| {
        const D = simd.FixedTag(T, 4);
        const value: D.Vector = @splat(1);
        _ = mulComplex(D, value, value);
        _ = mulComplexConj(D, value, value);
        _ = mulComplexAdd(D, value, value, value);
        _ = mulComplexConjAdd(D, value, value, value);
    }
}
