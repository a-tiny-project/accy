const std = @import("std");
const arithmetic = @import("arithmetic.zig");

pub fn ifThenElse(comptime D: type, mask: D.Mask, yes: D.Vector, no: D.Vector) D.Vector {
    return @select(D.Lane, mask, yes, no);
}

pub fn ifThenElseZero(comptime D: type, mask: D.Mask, yes: D.Vector) D.Vector {
    return ifThenElse(D, mask, yes, @as(D.Vector, @splat(0)));
}

pub fn ifThenZeroElse(comptime D: type, mask: D.Mask, no: D.Vector) D.Vector {
    return ifThenElse(D, mask, @as(D.Vector, @splat(0)), no);
}

pub fn ifVecThenElse(comptime D: type, mask: D.Vector, yes: D.Vector, no: D.Vector) D.Vector {
    return bitwiseIfThenElse(D, mask, yes, no);
}

pub fn bitwiseIfThenElse(comptime D: type, mask: D.Vector, yes: D.Vector, no: D.Vector) D.Vector {
    const U = @Int(.unsigned, @bitSizeOf(D.Lane));
    const DU = D.rebind(U);
    const mask_bits: DU.Vector = @bitCast(mask);
    const yes_bits: DU.Vector = @bitCast(yes);
    const no_bits: DU.Vector = @bitCast(no);
    return @bitCast((mask_bits & yes_bits) | (~mask_bits & no_bits));
}

pub fn zeroIfNegative(comptime D: type, value: D.Vector) D.Vector {
    return ifThenZeroElse(D, negativeMask(D, value), value);
}

pub fn ifNegativeThenElse(
    comptime D: type,
    sign: D.Vector,
    negative: D.Vector,
    nonnegative: D.Vector,
) D.Vector {
    return ifThenElse(D, negativeMask(D, sign), negative, nonnegative);
}

pub fn ifNegativeThenElseZero(comptime D: type, sign: D.Vector, negative: D.Vector) D.Vector {
    return ifThenElseZero(D, negativeMask(D, sign), negative);
}

pub fn ifNegativeThenZeroElse(comptime D: type, sign: D.Vector, nonnegative: D.Vector) D.Vector {
    return ifThenZeroElse(D, negativeMask(D, sign), nonnegative);
}

pub fn ifNegativeThenNegOrUndefIfZero(
    comptime D: type,
    sign: D.Vector,
    value: D.Vector,
) D.Vector {
    return ifThenElse(D, negativeMask(D, sign), arithmetic.neg(D, value), value);
}

fn negativeMask(comptime D: type, value: D.Vector) D.Mask {
    return switch (@typeInfo(D.Lane)) {
        .int => |info| if (info.signedness == .signed)
            value < @as(D.Vector, @splat(0))
        else
            @compileError("negative selection requires signed integer or floating-point lanes"),
        .float => blk: {
            const U = @Int(.unsigned, @bitSizeOf(D.Lane));
            const DU = D.rebind(U);
            const bits: DU.Vector = @bitCast(value);
            break :blk bits & @as(DU.Vector, @splat(@as(U, 1) << (@bitSizeOf(U) - 1))) !=
                @as(DU.Vector, @splat(0));
        },
        else => unreachable,
    };
}

test "Highway conditional selection covers masks vectors and raw bit patterns" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u32, 4);
    const yes: D.Vector = .{ 1, 2, 3, 4 };
    const no: D.Vector = .{ 10, 20, 30, 40 };
    const mask: D.Mask = .{ true, false, true, false };
    try std.testing.expect(@reduce(.And, ifThenElse(D, mask, yes, no) ==
        @as(D.Vector, .{ 1, 20, 3, 40 })));
    try std.testing.expect(@reduce(.And, ifThenElseZero(D, mask, yes) ==
        @as(D.Vector, .{ 1, 0, 3, 0 })));
    try std.testing.expect(@reduce(.And, ifThenZeroElse(D, mask, no) ==
        @as(D.Vector, .{ 0, 20, 0, 40 })));
    const vector_mask: D.Vector = .{ std.math.maxInt(u32), 0, std.math.maxInt(u32), 0 };
    try std.testing.expect(@reduce(.And, ifVecThenElse(D, vector_mask, yes, no) ==
        @as(D.Vector, .{ 1, 20, 3, 40 })));
    const partial: D.Vector = @splat(0x0f0f_0f0f);
    try std.testing.expect(@reduce(.And, bitwiseIfThenElse(D, partial, @as(D.Vector, @splat(0xaaaa_aaaa)), @as(D.Vector, @splat(0x5555_5555))) ==
        @as(D.Vector, @splat(0x5a5a_5a5a))));
}

test "Highway sign conditionals use representation sign including negative zero" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f32, 4);
    const sign: D.Vector = .{ -1, -0.0, 0, 1 };
    const value: D.Vector = .{ 1, 2, 3, 4 };
    try std.testing.expect(@reduce(.And, zeroIfNegative(D, sign) ==
        @as(D.Vector, .{ 0, 0, 0, 1 })));
    try std.testing.expect(@reduce(.And, ifNegativeThenElse(D, sign, value, @as(D.Vector, @splat(9))) ==
        @as(D.Vector, .{ 1, 2, 9, 9 })));
    try std.testing.expect(@reduce(.And, ifNegativeThenElseZero(D, sign, value) ==
        @as(D.Vector, .{ 1, 2, 0, 0 })));
    try std.testing.expect(@reduce(.And, ifNegativeThenZeroElse(D, sign, value) ==
        @as(D.Vector, .{ 0, 0, 3, 4 })));
    try std.testing.expect(@reduce(.And, ifNegativeThenNegOrUndefIfZero(D, sign, value) ==
        @as(D.Vector, .{ -1, -2, 3, 4 })));
}

test "Highway sign conditionals instantiate signed integer and floating lanes" {
    const simd = @import("root.zig");
    inline for (.{ i8, i16, i32, i64, f16, f32, f64 }) |T| {
        const D = simd.FixedTag(T, 4);
        const value: D.Vector = @splat(1);
        _ = zeroIfNegative(D, value);
        _ = ifNegativeThenElse(D, value, value, value);
        _ = ifNegativeThenNegOrUndefIfZero(D, value, value);
    }
}
