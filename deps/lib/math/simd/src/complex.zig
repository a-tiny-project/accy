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
