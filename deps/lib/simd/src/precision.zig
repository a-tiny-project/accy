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

test "Highway error-free sums and products reconstruct in wider precision" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f32, 4);
    const a: D.Vector = .{ 1.0e20, 1.0, 1.25, -7.0 };
    const b: D.Vector = .{ 1.0, 0x1p-24, 3.5, 0.3 };

    var sum_err: D.Vector = undefined;
    const sum = twoSums(D, a, b, &sum_err);
    var product_err: D.Vector = undefined;
    const product = twoProducts(D, a, b, &product_err);
    inline for (0..D.lane_count) |index| {
        try std.testing.expectEqual(
            @as(f64, a[index]) + @as(f64, b[index]),
            @as(f64, sum[index]) + @as(f64, sum_err[index]),
        );
        try std.testing.expectEqual(
            @as(f64, a[index]) * @as(f64, b[index]),
            @as(f64, product[index]) + @as(f64, product_err[index]),
        );
    }
}

test "Highway cascaded sums retain low-order values" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f64, 4);
    var sum: D.Vector = @splat(0);
    var sum_err: D.Vector = @splat(0);
    updateCascadedSums(D, @as(D.Vector, .{ 1.0e16, 1, -1.0e16, 1 }), &sum, &sum_err);
    try std.testing.expectEqual(@as(f64, 2), reduceCascadedSums(D, sum, sum_err));

    var other_sum: D.Vector = .{ 2, 3, 4, 5 };
    var other_err: D.Vector = @splat(0);
    assimilateCascadedSums(D, other_sum, other_err, &sum, &sum_err);
    try std.testing.expectEqual(@as(f64, 16), reduceCascadedSums(D, sum, sum_err));
    _ = &other_sum;
    _ = &other_err;
}

test "Highway double-double helpers preserve low components" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f64, 2);
    const a_hi: D.Vector = .{ 1.0e16, 3 };
    const a_lo: D.Vector = .{ 1, 0x1p-52 };
    const b_hi: D.Vector = .{ 2, 7 };
    const b_lo: D.Vector = .{ 0, -0x1p-51 };

    var result_lo: D.Vector = undefined;
    const add_hi = ddAdd(D, a_hi, a_lo, b_hi, b_lo, &result_lo);
    try std.testing.expectEqual(@as(f128, a_hi[0]) + a_lo[0] + b_hi[0] + b_lo[0], @as(f128, add_hi[0]) + result_lo[0]);

    const mul_hi = ddMul2(D, a_hi, a_lo, b_hi, b_lo, &result_lo);
    try std.testing.expectApproxEqRel(
        (@as(f128, a_hi[1]) + a_lo[1]) * (@as(f128, b_hi[1]) + b_lo[1]),
        @as(f128, mul_hi[1]) + result_lo[1],
        0x1p-100,
    );

    const div_hi = ddDiv(D, a_hi, a_lo, b_hi, b_lo, &result_lo);
    try std.testing.expectApproxEqRel(
        (@as(f128, a_hi[1]) + a_lo[1]) / (@as(f128, b_hi[1]) + b_lo[1]),
        @as(f128, div_hi[1]) + result_lo[1],
        0x1p-100,
    );
}
