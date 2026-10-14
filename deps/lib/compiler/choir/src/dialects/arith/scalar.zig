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

/// The absolute value of `value` read as a `bits`-bit signed integer, wrapping at the minimum.
/// The operand is normalized to its width first, so its sign is the sign of those bits and not of
/// whatever wider carrier produced it.
pub fn absWrap(value: i64, bits: u8) i64 {
    const signed = truncate(value, bits);
    if (signed >= 0) return signed;
    return negWrap(signed, bits);
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

/// The f64 that carries the f32 whose bits are `bits`. A number converts exactly. A NaN keeps its
/// sign, its quiet bit and its payload, where a host conversion would quiet a signaling NaN.
pub fn float32Carrier(bits: u32) f64 {
    const narrow: f32 = @bitCast(bits);
    if (!std.math.isNan(narrow)) return narrow;
    const sign: u64 = @as(u64, bits >> 31) << 63;
    const payload: u64 = @as(u64, bits & 0x007f_ffff) << 29;
    return @bitCast(sign | 0x7ff0_0000_0000_0000 | payload);
}

/// The bits of the f32 that `carrier` carries: the inverse of `float32Carrier` on its image. A
/// number that no f32 holds rounds to nearest. A NaN whose payload lies below f32's 23 bits
/// becomes the quiet NaN of its sign, since f32 has no bits to hold it.
pub fn float32Bits(carrier: f64) u32 {
    if (!std.math.isNan(carrier)) return @bitCast(@as(f32, @floatCast(carrier)));
    const wide: u64 = @bitCast(carrier);
    const sign: u32 = @as(u32, @intCast(wide >> 63)) << 31;
    const payload: u32 = @intCast((wide >> 29) & 0x007f_ffff);
    return sign | 0x7f80_0000 | if (payload == 0) @as(u32, 0x0040_0000) else payload;
}

/// The carrier of a NaN at a kind whose significand has `fraction_bits` bits below the leading
/// one: the sign, the quiet bit and the payload bits the kind holds are kept, and the bits below
/// them are dropped. A NaN whose whole payload lay below becomes the quiet NaN of its sign.
pub fn nanCarrier(carrier: f64, fraction_bits: u6) f64 {
    std.debug.assert(std.math.isNan(carrier));
    std.debug.assert(fraction_bits >= 1);
    std.debug.assert(fraction_bits <= 52);
    const wide: u64 = @bitCast(carrier);
    const fraction: u64 = (@as(u64, 1) << 52) - 1;
    const held: u64 = fraction & ~((@as(u64, 1) << (52 - fraction_bits)) - 1);
    const payload = wide & held;
    const quiet: u64 = @as(u64, 1) << 51;
    return @bitCast((wide & ~fraction) | if (payload == 0) quiet else payload);
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
