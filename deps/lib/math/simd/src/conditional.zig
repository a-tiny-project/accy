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
