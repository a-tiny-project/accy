const std = @import("std");

pub fn maskForBits(bits: u8) u64 {
    if (bits >= 64) return std.math.maxInt(u64);
    const shift: u6 = @intCast(bits);
    return (@as(u64, 1) << shift) - 1;
}

pub fn maskToBits(value: i64, bits: u8) u64 {
    return @as(u64, @bitCast(value)) & maskForBits(bits);
}

pub fn signExtend(value: u64, bits: u8) i64 {
    if (bits >= 64) return @as(i64, @bitCast(value));
    const shift: u6 = @intCast(bits - 1);
    const sign_bit = @as(u64, 1) << shift;
    const mask = maskForBits(bits);
    if ((value & sign_bit) != 0) {
        return @as(i64, @bitCast(value | ~mask));
    }
    return @as(i64, @bitCast(value));
}

pub const Limits = struct { min: i128, max: i128 };

pub fn intLimits(bits: u8) Limits {
    if (bits >= 64) {
        return .{ .min = @as(i128, std.math.minInt(i64)), .max = @as(i128, std.math.maxInt(i64)) };
    }
    const shift: u7 = @intCast(bits - 1);
    const max = (@as(i128, 1) << shift) - 1;
    const min = -(@as(i128, 1) << shift);
    return .{ .min = min, .max = max };
}

pub fn fitsSigned(value: i128, bits: u8) bool {
    const limits = intLimits(bits);
    return value >= limits.min and value <= limits.max;
}

pub fn truncate(value: i64, bits: u8) i64 {
    return signExtend(maskToBits(value, bits), bits);
}

pub fn addWrap(lhs: i64, rhs: i64, bits: u8) i64 {
    return truncate(lhs +% rhs, bits);
}

pub fn subWrap(lhs: i64, rhs: i64, bits: u8) i64 {
    return truncate(lhs -% rhs, bits);
}

pub fn mulWrap(lhs: i64, rhs: i64, bits: u8) i64 {
    return truncate(lhs *% rhs, bits);
}

pub fn negWrap(value: i64, bits: u8) i64 {
    return truncate(0 -% value, bits);
}

pub fn absWrap(value: i64, bits: u8) i64 {
    if (value >= 0) return truncate(value, bits);
    return negWrap(value, bits);
}

pub fn addChecked(lhs: i64, rhs: i64, bits: u8) ?i64 {
    const res = @as(i128, lhs) + rhs;
    if (!fitsSigned(res, bits)) return null;
    return @as(i64, @intCast(res));
}

pub fn subChecked(lhs: i64, rhs: i64, bits: u8) ?i64 {
    const res = @as(i128, lhs) - rhs;
    if (!fitsSigned(res, bits)) return null;
    return @as(i64, @intCast(res));
}

pub fn mulChecked(lhs: i64, rhs: i64, bits: u8) ?i64 {
    const res = @as(i128, lhs) * rhs;
    if (!fitsSigned(res, bits)) return null;
    return @as(i64, @intCast(res));
}

pub fn negChecked(value: i64, bits: u8) ?i64 {
    const limits = intLimits(bits);
    if (@as(i128, value) == limits.min) return null;
    return -value;
}

pub fn absChecked(value: i64, bits: u8) ?i64 {
    if (value >= 0) return value;
    return negChecked(value, bits);
}

pub fn divTruncChecked(lhs: i64, rhs: i64, bits: u8) ?i64 {
    const left = truncate(lhs, bits);
    const right = truncate(rhs, bits);
    if (right == 0) return null;
    const limits = intLimits(bits);
    if (@as(i128, left) == limits.min and right == -1) return null;
    return truncate(@divTrunc(left, right), bits);
}

pub fn remTruncChecked(lhs: i64, rhs: i64, bits: u8) ?i64 {
    const left = truncate(lhs, bits);
    const right = truncate(rhs, bits);
    if (right == 0) return null;
    const limits = intLimits(bits);
    if (@as(i128, left) == limits.min and right == -1) return null;
    return truncate(@rem(left, right), bits);
}

pub fn unsignedResult(value: u64, bits: u8) i64 {
    if (bits >= 64) return @as(i64, @bitCast(value));
    return @intCast(value & maskForBits(bits));
}

pub fn divTruncUnsignedChecked(lhs: i64, rhs: i64, bits: u8) ?i64 {
    const left = maskToBits(lhs, bits);
    const right = maskToBits(rhs, bits);
    if (right == 0) return null;
    return unsignedResult(@divTrunc(left, right), bits);
}

pub fn remTruncUnsignedChecked(lhs: i64, rhs: i64, bits: u8) ?i64 {
    const left = maskToBits(lhs, bits);
    const right = maskToBits(rhs, bits);
    if (right == 0) return null;
    return unsignedResult(@rem(left, right), bits);
}

pub fn bitAnd(lhs: i64, rhs: i64, bits: u8) i64 {
    return signExtend(maskToBits(lhs, bits) & maskToBits(rhs, bits), bits);
}

pub fn bitOr(lhs: i64, rhs: i64, bits: u8) i64 {
    return signExtend(maskToBits(lhs, bits) | maskToBits(rhs, bits), bits);
}

pub fn bitXor(lhs: i64, rhs: i64, bits: u8) i64 {
    return signExtend(maskToBits(lhs, bits) ^ maskToBits(rhs, bits), bits);
}

pub fn bitNot(value: i64, bits: u8) i64 {
    return signExtend(~maskToBits(value, bits) & maskForBits(bits), bits);
}

pub fn shiftCount(value: i64, bits: u8) ?u6 {
    if (value < 0) return null;
    const count: u64 = @intCast(value);
    if (count >= bits) return null;
    return @intCast(count);
}

pub fn shiftLeftWrap(value: i64, count: u6, bits: u8) i64 {
    const shifted = maskToBits(value, bits) *% (@as(u64, 1) << count);
    return signExtend(shifted & maskForBits(bits), bits);
}

pub fn shiftRightArithmetic(value: i64, count: u6, bits: u8) i64 {
    return truncate(truncate(value, bits) >> count, bits);
}

pub fn shiftRightLogical(value: i64, count: u6, bits: u8) i64 {
    return signExtend(maskToBits(value, bits) >> count, bits);
}

/// Test the finite truncation against exact exclusive upper bounds.
pub fn floatToInt(value: f64, bits: u8, signed: bool) ?i64 {
    std.debug.assert(bits > 0);
    std.debug.assert(bits <= 64);
    if (!std.math.isFinite(value)) return null;
    const truncated = @trunc(value);
    const exponent: u7 = @intCast(bits - @as(u8, if (signed) 1 else 0));
    const upper: f64 = @floatFromInt(@as(u128, 1) << exponent);
    const lower: f64 = if (signed) -upper else 0;
    if (truncated < lower or truncated >= upper) return null;
    return if (signed) @intFromFloat(truncated) else @bitCast(@as(u64, @intFromFloat(truncated)));
}

/// Round f64 directly to bfloat16, correcting ties introduced by the f32 intermediate.
pub fn roundBfloat(value: f64) f64 {
    if (std.math.isNan(value)) return std.math.nan(f64);
    const narrow: f32 = @floatCast(value);
    const bits: u32 = @bitCast(narrow);
    if (!std.math.isFinite(narrow)) return narrow;
    const remainder = bits & 0xffff;
    var high = bits >> 16;
    const up = if (remainder == 0x8000 and @abs(value) != @abs(@as(f64, narrow)))
        @abs(value) > @abs(@as(f64, narrow))
    else
        remainder > 0x8000 or (remainder == 0x8000 and high & 1 != 0);
    if (up) high += 1;
    return @as(f32, @bitCast(high << 16));
}
