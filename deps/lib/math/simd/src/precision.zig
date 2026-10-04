const std = @import("std");

pub fn twoSumScalar(comptime T: type, a: T, b: T, err: *T) T {
    requireFloat(T);
    const sum = a + b;
    const a2 = sum - b;
    const b2 = sum - a2;
    err.* = (a - a2) + (b - b2);
    return sum;
}

pub fn twoProducts(comptime D: type, a: D.Vector, b: D.Vector, err: *D.Vector) D.Vector {
    requireFloat(D.Lane);
    const product = a * b;
    err.* = @mulAdd(D.Vector, a, b, -product);
    return product;
}

pub fn twoSums(comptime D: type, a: D.Vector, b: D.Vector, err: *D.Vector) D.Vector {
    requireFloat(D.Lane);
    const sum = a + b;
    const a2 = sum - b;
    const b2 = sum - a2;
    err.* = (a - a2) + (b - b2);
    return sum;
}

pub fn fastTwoSums(comptime D: type, a: D.Vector, b: D.Vector, err: *D.Vector) D.Vector {
    requireFloat(D.Lane);
    const sum = a + b;
    err.* = b - (sum - a);
    return sum;
}

pub fn updateCascadedSums(
    comptime D: type,
    value: D.Vector,
    sum: *D.Vector,
    sum_err: *D.Vector,
) void {
    var err: D.Vector = undefined;
    sum.* = twoSums(D, sum.*, value, &err);
    sum_err.* += err;
}

pub fn assimilateCascadedSums(
    comptime D: type,
    other_sum: D.Vector,
    other_sum_err: D.Vector,
    sum: *D.Vector,
    sum_err: *D.Vector,
) void {
    sum_err.* += other_sum_err;
    updateCascadedSums(D, other_sum, sum, sum_err);
}

pub fn reduceCascadedSums(comptime D: type, sum: D.Vector, sum_err: D.Vector) D.Lane {
    requireFloat(D.Lane);
    var total: D.Lane = 0;
    var total_err: D.Lane = 0;
    inline for (0..D.lane_count) |index| {
        var err: D.Lane = undefined;
        total_err += sum_err[index];
        total = twoSumScalar(D.Lane, total, sum[index], &err);
        total_err += err;
    }
    return total + total_err;
}

pub fn ddAdd(
    comptime D: type,
    a_hi: D.Vector,
    a_lo: D.Vector,
    b_hi: D.Vector,
    b_lo: D.Vector,
    result_lo: *D.Vector,
) D.Vector {
    var error_value: D.Vector = undefined;
    const sum = twoSums(D, a_hi, b_hi, &error_value);
    error_value += a_lo + b_lo;
    return fastTwoSums(D, sum, error_value, result_lo);
}

pub fn ddMul1(
    comptime D: type,
    a_hi: D.Vector,
    a_lo: D.Vector,
    b: D.Vector,
    result_lo: *D.Vector,
) D.Vector {
    var product_lo: D.Vector = undefined;
    const product_hi = twoProducts(D, a_hi, b, &product_lo);
    product_lo = @mulAdd(D.Vector, a_lo, b, product_lo);
    return fastTwoSums(D, product_hi, product_lo, result_lo);
}

pub fn ddMul2(
    comptime D: type,
    a_hi: D.Vector,
    a_lo: D.Vector,
    b_hi: D.Vector,
    b_lo: D.Vector,
    result_lo: *D.Vector,
) D.Vector {
    var product_lo: D.Vector = undefined;
    const product_hi = twoProducts(D, a_hi, b_hi, &product_lo);
    product_lo = @mulAdd(D.Vector, a_hi, b_lo, @mulAdd(D.Vector, a_lo, b_hi, product_lo));
    return fastTwoSums(D, product_hi, product_lo, result_lo);
}

pub fn ddDiv(
    comptime D: type,
    a_hi: D.Vector,
    a_lo: D.Vector,
    b_hi: D.Vector,
    b_lo: D.Vector,
    result_lo: *D.Vector,
) D.Vector {
    const q1 = a_hi / b_hi;
    var product_lo: D.Vector = undefined;
    const product_hi = ddMul1(D, b_hi, b_lo, q1, &product_lo);
    var remainder_lo: D.Vector = undefined;
    const remainder_hi = ddAdd(D, a_hi, a_lo, -product_hi, -product_lo, &remainder_lo);
    const q2 = remainder_hi / b_hi;
    return fastTwoSums(D, q1, q2, result_lo);
}

fn requireFloat(comptime T: type) void {
    if (T != f32 and T != f64) @compileError("compensated arithmetic requires f32 or f64 lanes");
}
