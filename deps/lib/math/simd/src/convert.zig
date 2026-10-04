const std = @import("std");
const bfloat = @import("bfloat.zig");
const shift = @import("shift.zig");
const tag = @import("tag.zig");

pub fn convertTo(comptime D: type, value: anytype) D.Vector {
    const V = @TypeOf(value);
    const From = sourceLane(V);
    validateLaneCount(D, V);
    if (@bitSizeOf(D.Lane) != @bitSizeOf(From)) {
        @compileError("convertTo requires equal source and destination lane widths");
    }
    if ((@typeInfo(From) == .float) == (@typeInfo(D.Lane) == .float)) {
        @compileError("convertTo requires one floating-point and one integer lane type");
    }
    return numericCast(D, value);
}

pub fn convertInRangeTo(comptime D: type, value: anytype) D.Vector {
    return convertTo(D, value);
}

pub fn maskedConvertTo(
    comptime D: type,
    mask: D.Mask,
    value: anytype,
) D.Vector {
    return @select(D.Lane, mask, convertTo(D, value), @as(D.Vector, @splat(0)));
}

pub fn nearestInt(comptime D: type, value: anytype) D.Vector {
    validateSameWidthFloatToSigned(D, @TypeOf(value));
    return roundEvenToInt(D, value);
}

pub fn ceilInt(comptime D: type, value: anytype) D.Vector {
    validateSameWidthFloatToSigned(D, @TypeOf(value));
    return floatToInt(D, @ceil(value));
}

pub fn floorInt(comptime D: type, value: anytype) D.Vector {
    validateSameWidthFloatToSigned(D, @TypeOf(value));
    return floatToInt(D, @floor(value));
}

pub fn demoteToNearestInt(comptime D: type, value: anytype) D.Vector {
    const V = @TypeOf(value);
    const From = sourceLane(V);
    validateLaneCount(D, V);
    if (@typeInfo(D.Lane) != .int or
        @typeInfo(D.Lane).int.signedness != .signed or
        @typeInfo(From) != .float or
        @bitSizeOf(D.Lane) >= @bitSizeOf(From))
    {
        @compileError("demoteToNearestInt requires narrower signed integer destinations");
    }
    return roundEvenToInt(D, value);
}

pub fn promoteTo(comptime D: type, value: anytype) D.Vector {
    const V = @TypeOf(value);
    const From = sourceLane(V);
    validateLaneCount(D, V);
    if (comptime D.Lane == f32 and From == u16) return bfloat.promoteF32(D, value);
    if (@bitSizeOf(D.Lane) <= @bitSizeOf(From)) {
        @compileError("promoteTo requires a wider destination lane");
    }
    if (@typeInfo(From) == .int and @typeInfo(D.Lane) == .int and
        @typeInfo(From).int.signedness == .signed and
        @typeInfo(D.Lane).int.signedness == .unsigned)
    {
        @compileError("promoteTo does not convert signed integers to unsigned integers");
    }
    return numericCast(D, value);
}

pub fn promoteInRangeTo(comptime D: type, value: anytype) D.Vector {
    return promoteTo(D, value);
}

pub fn promoteLowerTo(comptime D: type, value: anytype) D.Vector {
    return promoteSelected(D, value, .lower, false);
}

pub fn promoteUpperTo(comptime D: type, value: anytype) D.Vector {
    return promoteSelected(D, value, .upper, false);
}

pub fn promoteEvenTo(comptime D: type, value: anytype) D.Vector {
    return promoteSelected(D, value, .even, false);
}

pub fn promoteOddTo(comptime D: type, value: anytype) D.Vector {
    return promoteSelected(D, value, .odd, false);
}

pub fn promoteInRangeLowerTo(comptime D: type, value: anytype) D.Vector {
    return promoteSelected(D, value, .lower, true);
}

pub fn promoteInRangeUpperTo(comptime D: type, value: anytype) D.Vector {
    return promoteSelected(D, value, .upper, true);
}

pub fn promoteInRangeEvenTo(comptime D: type, value: anytype) D.Vector {
    return promoteSelected(D, value, .even, true);
}

pub fn promoteInRangeOddTo(comptime D: type, value: anytype) D.Vector {
    return promoteSelected(D, value, .odd, true);
}

pub fn demoteTo(comptime D: type, value: anytype) D.Vector {
    const V = @TypeOf(value);
    const From = sourceLane(V);
    validateLaneCount(D, V);
    if (comptime isBFloatTag(D) and From == f32) return bfloat.demoteF32(D, value);
    if (@bitSizeOf(D.Lane) >= @bitSizeOf(From)) {
        @compileError("demoteTo requires a narrower destination lane");
    }
    return numericCast(D, value);
}

pub fn demoteInRangeTo(comptime D: type, value: anytype) D.Vector {
    return demoteTo(D, value);
}

pub fn truncateTo(comptime D: type, value: anytype) D.Vector {
    const V = @TypeOf(value);
    const From = sourceLane(V);
    validateLaneCount(D, V);
    if (@typeInfo(D.Lane) != .int or @typeInfo(From) != .int or
        @typeInfo(D.Lane).int.signedness != .unsigned or
        @typeInfo(From).int.signedness != .unsigned or
        @bitSizeOf(D.Lane) >= @bitSizeOf(From))
    {
        @compileError("truncateTo requires narrower unsigned integer destinations");
    }
    return @truncate(value);
}

pub fn u8FromU32(comptime D: type, value: anytype) D.Vector {
    const V = @TypeOf(value);
    validateLaneCount(D, V);
    if (D.Lane != u8 or sourceLane(V) != u32) {
        @compileError("u8FromU32 requires u32 sources and a u8 destination");
    }
    std.debug.assert(@reduce(.And, value < @as(V, @splat(256))));
    return @truncate(value);
}

pub fn orderedDemote2To(
    comptime D: type,
    a: anytype,
    b: @TypeOf(a),
) D.Vector {
    validatePair(D, @TypeOf(a));
    const H = D.half();
    return combinePair(D, demoteTo(H, a), demoteTo(H, b));
}

pub fn reorderDemote2To(
    comptime D: type,
    a: anytype,
    b: @TypeOf(a),
) D.Vector {
    return orderedDemote2To(D, a, b);
}

pub fn orderedTruncate2To(
    comptime D: type,
    a: anytype,
    b: @TypeOf(a),
) D.Vector {
    validatePair(D, @TypeOf(a));
    const H = D.half();
    return combinePair(D, truncateTo(H, a), truncateTo(H, b));
}

pub fn shiftRightAndDemoteTo(
    comptime D: type,
    comptime amount: usize,
    value: anytype,
) D.Vector {
    const S = sourceDescriptor(@TypeOf(value));
    return demoteTo(D, shift.shiftRight(S, amount, value));
}

pub fn roundingShiftRightAndDemoteTo(
    comptime D: type,
    comptime amount: usize,
    value: anytype,
) D.Vector {
    const S = sourceDescriptor(@TypeOf(value));
    return demoteTo(D, shift.roundingShiftRight(S, amount, value));
}

pub fn reorderShiftRightAndDemote2To(
    comptime D: type,
    comptime amount: usize,
    a: anytype,
    b: @TypeOf(a),
) D.Vector {
    const S = sourceDescriptor(@TypeOf(a));
    return reorderDemote2To(
        D,
        shift.shiftRight(S, amount, a),
        shift.shiftRight(S, amount, b),
    );
}

pub fn reorderRoundingShiftRightAndDemote2To(
    comptime D: type,
    comptime amount: usize,
    a: anytype,
    b: @TypeOf(a),
) D.Vector {
    const S = sourceDescriptor(@TypeOf(a));
    return reorderDemote2To(
        D,
        shift.roundingShiftRight(S, amount, a),
        shift.roundingShiftRight(S, amount, b),
    );
}

pub fn orderedShiftRightAndDemote2To(
    comptime D: type,
    comptime amount: usize,
    a: anytype,
    b: @TypeOf(a),
) D.Vector {
    const S = sourceDescriptor(@TypeOf(a));
    return orderedDemote2To(
        D,
        shift.shiftRight(S, amount, a),
        shift.shiftRight(S, amount, b),
    );
}

pub fn orderedRoundingShiftRightAndDemote2To(
    comptime D: type,
    comptime amount: usize,
    a: anytype,
    b: @TypeOf(a),
) D.Vector {
    const S = sourceDescriptor(@TypeOf(a));
    return orderedDemote2To(
        D,
        shift.roundingShiftRight(S, amount, a),
        shift.roundingShiftRight(S, amount, b),
    );
}

pub fn promoteMaskTo(
    comptime DTo: type,
    comptime DFrom: type,
    mask: DFrom.Mask,
) DTo.Mask {
    if (DTo.lane_count != DFrom.lane_count or @sizeOf(DTo.Lane) <= @sizeOf(DFrom.Lane)) {
        @compileError("promoteMaskTo requires equal lane counts and wider destination lanes");
    }
    return mask;
}

pub fn demoteMaskTo(
    comptime DTo: type,
    comptime DFrom: type,
    mask: DFrom.Mask,
) DTo.Mask {
    if (DTo.lane_count != DFrom.lane_count or @sizeOf(DTo.Lane) >= @sizeOf(DFrom.Lane)) {
        @compileError("demoteMaskTo requires equal lane counts and narrower destination lanes");
    }
    return mask;
}

pub fn orderedDemote2MasksTo(
    comptime DTo: type,
    comptime DFrom: type,
    a: DFrom.Mask,
    b: DFrom.Mask,
) DTo.Mask {
    if (DTo.lane_count != DFrom.lane_count * 2 or @sizeOf(DTo.Lane) >= @sizeOf(DFrom.Lane)) {
        @compileError("orderedDemote2MasksTo requires two source masks and narrower destination lanes");
    }
    var result: DTo.Mask = undefined;
    inline for (0..DFrom.lane_count) |index| {
        result[index] = a[index];
        result[DFrom.lane_count + index] = b[index];
    }
    return result;
}

const Selection = enum { lower, upper, even, odd };

fn promoteSelected(
    comptime D: type,
    value: anytype,
    comptime selection: Selection,
    comptime in_range: bool,
) D.Vector {
    const V = @TypeOf(value);
    const From = sourceLane(V);
    if (comptime sourceLaneCount(V) != D.lane_count * 2) {
        @compileError("selected promotion requires twice the destination lane count");
    }
    if (comptime D.Lane == f32 and From == u16) {
        return switch (selection) {
            .lower => bfloat.promoteLowerF32(D, value),
            .upper => bfloat.promoteUpperF32(D, value),
            .even => bfloat.promoteEvenF32(D, value),
            .odd => bfloat.promoteOddF32(D, value),
        };
    }
    var selected: @Vector(D.lane_count, From) = undefined;
    inline for (0..D.lane_count) |index| {
        const source_index = switch (selection) {
            .lower => index,
            .upper => D.lane_count + index,
            .even => index * 2,
            .odd => index * 2 + 1,
        };
        selected[index] = value[source_index];
    }
    return if (in_range) promoteInRangeTo(D, selected) else promoteTo(D, selected);
}

fn numericCast(comptime D: type, value: anytype) D.Vector {
    const From = sourceLane(@TypeOf(value));
    const from_info = @typeInfo(From);
    const to_info = @typeInfo(D.Lane);
    if (from_info == .float and to_info == .int) return floatToInt(D, value);
    if (from_info == .int and to_info == .int) return saturatingIntToInt(D, value);
    if (from_info == .int and to_info == .float) return @floatFromInt(value);
    if (from_info == .float and to_info == .float) return @floatCast(value);
    @compileError("numeric conversion requires integer or floating-point lanes");
}

fn floatToInt(comptime D: type, value: anytype) D.Vector {
    const V = @TypeOf(value);
    const From = sourceLane(V);
    const FromUnsigned = @Int(.unsigned, @bitSizeOf(From));
    const FromBits = @Vector(D.lane_count, FromUnsigned);
    const bits: FromBits = @bitCast(value);
    const sign_bit: FromBits = @splat(@as(FromUnsigned, 1) << (@bitSizeOf(From) - 1));
    const negative = bits & sign_bit != @as(FromBits, @splat(0));
    const nan = value != value;
    const destination_bits: i32 = @intCast(@bitSizeOf(D.Lane));
    const sign_bits: i32 = if (@typeInfo(D.Lane).int.signedness == .signed) 1 else 0;
    const upper = std.math.ldexp(@as(From, 1), destination_bits - sign_bits);
    const high = (value >= @as(V, @splat(upper))) | (nan & ~negative);
    const low = if (@typeInfo(D.Lane).int.signedness == .signed)
        (value <= @as(V, @splat(-upper))) | (nan & negative)
    else
        (value <= @as(V, @splat(0))) | (nan & negative);
    const safe = @select(From, high | low, @as(V, @splat(0)), value);
    const converted: D.Vector = @intFromFloat(safe);
    const maximum: D.Vector = @splat(std.math.maxInt(D.Lane));
    const minimum: D.Vector = if (@typeInfo(D.Lane).int.signedness == .signed)
        @splat(std.math.minInt(D.Lane))
    else
        @splat(0);
    return @select(D.Lane, low, minimum, @select(D.Lane, high, maximum, converted));
}

fn saturatingIntToInt(comptime D: type, value: anytype) D.Vector {
    const V = @TypeOf(value);
    const From = sourceLane(V);
    const from_signed = @typeInfo(From).int.signedness == .signed;
    const to_signed = @typeInfo(D.Lane).int.signedness == .signed;
    if (@bitSizeOf(D.Lane) >= @bitSizeOf(From)) return @intCast(value);
    var clamped = value;
    if (from_signed) {
        if (to_signed) {
            const minimum: V = @splat(@as(From, @intCast(std.math.minInt(D.Lane))));
            clamped = @select(From, clamped < minimum, minimum, clamped);
        } else {
            const zero: V = @splat(0);
            clamped = @select(From, clamped < zero, zero, clamped);
        }
    }
    const maximum: V = @splat(@as(From, @intCast(std.math.maxInt(D.Lane))));
    clamped = @select(From, clamped > maximum, maximum, clamped);
    return @intCast(clamped);
}

fn roundEvenToInt(comptime D: type, value: anytype) D.Vector {
    const V = @TypeOf(value);
    const From = sourceLane(V);
    const rounded_float = @round(value);
    const rounded = floatToInt(D, rounded_float);
    const fraction = @abs(value - @trunc(value));
    const tie = fraction == @as(V, @splat(@as(From, 0.5)));
    const odd = rounded & @as(D.Vector, @splat(1)) != @as(D.Vector, @splat(0));
    const FromUnsigned = @Int(.unsigned, @bitSizeOf(From));
    const FromBits = @Vector(D.lane_count, FromUnsigned);
    const bits: FromBits = @bitCast(value);
    const sign_bit: FromBits = @splat(@as(FromUnsigned, 1) << (@bitSizeOf(From) - 1));
    const negative = bits & sign_bit != @as(FromBits, @splat(0));
    const adjustment: D.Vector = @select(
        D.Lane,
        negative,
        @as(D.Vector, @splat(1)),
        @as(D.Vector, @splat(-1)),
    );
    const destination_bits: i32 = @intCast(@bitSizeOf(D.Lane));
    const upper = std.math.ldexp(@as(From, 1), destination_bits - 1);
    const in_range = (rounded_float >= @as(V, @splat(-upper))) &
        (rounded_float < @as(V, @splat(upper)));
    return @select(D.Lane, tie & odd & in_range, rounded +% adjustment, rounded);
}

fn combinePair(comptime D: type, low: D.half().Vector, high: D.half().Vector) D.Vector {
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / 2) |index| {
        result[index] = low[index];
        result[D.lane_count / 2 + index] = high[index];
    }
    return result;
}

fn validatePair(comptime D: type, comptime V: type) void {
    if (D.lane_count < 2 or comptime sourceLaneCount(V) * 2 != D.lane_count) {
        @compileError("two-vector conversion requires each source to fill one destination half");
    }
}

fn validateSameWidthFloatToSigned(comptime D: type, comptime V: type) void {
    const From = sourceLane(V);
    validateLaneCount(D, V);
    if (@typeInfo(From) != .float or @typeInfo(D.Lane) != .int or
        @typeInfo(D.Lane).int.signedness != .signed or
        @bitSizeOf(D.Lane) != @bitSizeOf(From))
    {
        @compileError("integer rounding requires same-width float and signed integer lanes");
    }
}

fn validateLaneCount(comptime D: type, comptime V: type) void {
    if (comptime sourceLaneCount(V) != D.lane_count) {
        @compileError("numeric conversion requires equal source and destination lane counts");
    }
}

fn sourceDescriptor(comptime V: type) type {
    return tag.FixedTag(sourceLane(V), sourceLaneCount(V));
}

fn sourceLane(comptime V: type) type {
    return switch (@typeInfo(V)) {
        .vector => |info| info.child,
        else => @compileError("numeric conversion requires a vector source"),
    };
}

fn sourceLaneCount(comptime V: type) usize {
    return switch (@typeInfo(V)) {
        .vector => |info| info.len,
        else => @compileError("numeric conversion requires a vector source"),
    };
}

fn isBFloatTag(comptime D: type) bool {
    if (!@hasDecl(D, "is_bfloat16")) return false;
    return D.is_bfloat16;
}

test "Highway convert saturates floating point by destination range and NaN sign" {
    const simd = @import("root.zig");
    const F = simd.FixedTag(f32, 8);
    const I = simd.FixedTag(i32, 8);
    const U = simd.FixedTag(u32, 8);
    const B = simd.FixedTag(u32, 8);
    const value: F.Vector = @bitCast(@as(B.Vector, .{
        0xc060_0000,
        0xbf00_0000,
        0,
        0x409c_cccd,
        0x4f00_0000,
        0xcf00_0000,
        0x7fc0_1234,
        0xffc0_1234,
    }));
    try std.testing.expect(@reduce(.And, convertTo(I, value) == @as(I.Vector, .{
        -3,
        0,
        0,
        4,
        std.math.maxInt(i32),
        std.math.minInt(i32),
        std.math.maxInt(i32),
        std.math.minInt(i32),
    })));
    try std.testing.expect(@reduce(.And, convertTo(U, value) == @as(U.Vector, .{
        0,
        0,
        0,
        4,
        2_147_483_648,
        0,
        std.math.maxInt(u32),
        0,
    })));
}

test "Highway integer conversions widen and demote with saturation" {
    const simd = @import("root.zig");
    const S = simd.FixedTag(i32, 8);
    const U = simd.FixedTag(u32, 8);
    const I16 = simd.FixedTag(i16, 8);
    const U16 = simd.FixedTag(u16, 8);
    const I64 = simd.FixedTag(i64, 8);
    const value: S.Vector = .{
        std.math.minInt(i32), -65_536, -1, 0, 1, 65_535, 65_536, std.math.maxInt(i32),
    };
    try std.testing.expect(@reduce(.And, demoteTo(I16, value) == @as(I16.Vector, .{
        -32_768, -32_768, -1, 0, 1, 32_767, 32_767, 32_767,
    })));
    try std.testing.expect(@reduce(.And, demoteTo(U16, value) == @as(U16.Vector, .{
        0, 0, 0, 0, 1, 65_535, 65_535, 65_535,
    })));
    const unsigned: U.Vector = .{ 0, 1, 32_767, 32_768, 65_535, 65_536, 0x8000_0000, 0xffff_ffff };
    try std.testing.expect(@reduce(.And, demoteTo(I16, unsigned) == @as(I16.Vector, .{
        0, 1, 32_767, 32_767, 32_767, 32_767, 32_767, 32_767,
    })));
    try std.testing.expect(@reduce(.And, promoteTo(I64, unsigned) ==
        @as(I64.Vector, .{ 0, 1, 32_767, 32_768, 65_535, 65_536, 0x8000_0000, 0xffff_ffff })));
}

test "Highway promotion selects exact lower upper even and odd lanes" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u16, 4);
    const S = simd.FixedTag(u8, 8);
    const value: S.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expect(@reduce(.And, promoteLowerTo(D, value) == @as(D.Vector, .{ 0, 1, 2, 3 })));
    try std.testing.expect(@reduce(.And, promoteUpperTo(D, value) == @as(D.Vector, .{ 4, 5, 6, 7 })));
    try std.testing.expect(@reduce(.And, promoteEvenTo(D, value) == @as(D.Vector, .{ 0, 2, 4, 6 })));
    try std.testing.expect(@reduce(.And, promoteOddTo(D, value) == @as(D.Vector, .{ 1, 3, 5, 7 })));
}

test "Highway float widening narrowing and integer rounding preserve semantics" {
    const simd = @import("root.zig");
    const F16 = simd.FixedTag(f16, 8);
    const F32 = simd.FixedTag(f32, 8);
    const F64 = simd.FixedTag(f64, 8);
    const I32 = simd.FixedTag(i32, 8);
    const I16 = simd.FixedTag(i16, 8);
    const halves: F16.Vector = .{ -4, -1.5, -0.5, 0, 0.5, 1.5, 2.5, 65_504 };
    try std.testing.expect(@reduce(.And, demoteTo(F16, promoteTo(F32, halves)) == halves));
    const doubles: F64.Vector = .{ -1.0e300, -3.5, -0.0, 0, 3.5, 65_504, 65_520, 1.0e300 };
    const narrowed = demoteTo(F16, doubles);
    try std.testing.expect(std.math.isInf(narrowed[0]) and std.math.signbit(narrowed[0]));
    try std.testing.expect(std.math.isInf(narrowed[7]) and !std.math.signbit(narrowed[7]));
    try std.testing.expect(@reduce(.And, nearestInt(I32, @as(F32.Vector, .{
        -3.5, -2.5, -1.5, -0.5, 0.5, 1.5, 2.5, 3.5,
    })) == @as(I32.Vector, .{ -4, -2, -2, 0, 0, 2, 2, 4 })));
    try std.testing.expect(@reduce(.And, demoteToNearestInt(I16, doubles) == @as(I16.Vector, .{
        std.math.minInt(i16), -4, 0, 0, 4, std.math.maxInt(i16), std.math.maxInt(i16), std.math.maxInt(i16),
    })));
    const boundaries: F64.Vector = .{
        -32_769.5, -32_768.5, -32_767.5, -32_766.5,
        32_766.5,  32_767.5,  32_768.5,  32_769.5,
    };
    try std.testing.expect(@reduce(.And, demoteToNearestInt(I16, boundaries) == @as(I16.Vector, .{
        -32_768, -32_768, -32_768, -32_766, 32_766, 32_767, 32_767, 32_767,
    })));
}

test "Highway truncation ordered packing and shifted demotion retain lane order" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u8, 8);
    const H = simd.FixedTag(u16, 4);
    const a: H.Vector = .{ 0x0102, 0x03ff, 0x0400, 0xffff };
    const b: H.Vector = .{ 0x1005, 0x2006, 0x3007, 0x4008 };
    try std.testing.expect(@reduce(.And, orderedTruncate2To(D, a, b) ==
        @as(D.Vector, .{ 2, 255, 0, 255, 5, 6, 7, 8 })));
    try std.testing.expect(@reduce(.And, orderedDemote2To(D, a, b) ==
        @as(D.Vector, .{ 255, 255, 255, 255, 255, 255, 255, 255 })));
    try std.testing.expect(@reduce(.And, orderedShiftRightAndDemote2To(D, 8, a, b) ==
        @as(D.Vector, .{ 1, 3, 4, 255, 16, 32, 48, 64 })));
    try std.testing.expect(@reduce(.And, orderedRoundingShiftRightAndDemote2To(D, 8, a, b) ==
        @as(D.Vector, .{ 1, 4, 4, 255, 16, 32, 48, 64 })));
}

test "Highway conversion entry points instantiate supported lane families" {
    const simd = @import("root.zig");
    const integer_types = .{ i8, u8, i16, u16, i32, u32, i64, u64 };
    inline for (integer_types) |From| {
        inline for (integer_types) |To| {
            const DFrom = simd.FixedTag(From, 4);
            const DTo = simd.FixedTag(To, 4);
            const value: DFrom.Vector = @splat(0);
            if (comptime @bitSizeOf(To) < @bitSizeOf(From)) {
                _ = demoteTo(DTo, value);
            }
            if (comptime @bitSizeOf(To) > @bitSizeOf(From) and
                (@typeInfo(From).int.signedness == .unsigned or
                    @typeInfo(To).int.signedness == .signed))
            {
                _ = promoteTo(DTo, value);
            }
        }
    }
    inline for (.{ .{ f16, f32 }, .{ f16, f64 }, .{ f32, f64 } }) |types| {
        const Narrow = types[0];
        const Wide = types[1];
        const DN = simd.FixedTag(Narrow, 4);
        const DW = simd.FixedTag(Wide, 4);
        const value: DN.Vector = @splat(1.5);
        try std.testing.expect(@reduce(.And, demoteTo(DN, promoteTo(DW, value)) == value));
    }
    inline for (.{ f16, f32, f64 }) |Float| {
        const Signed = @Int(.signed, @bitSizeOf(Float));
        const Unsigned = @Int(.unsigned, @bitSizeOf(Float));
        const DF = simd.FixedTag(Float, 4);
        const DI = simd.FixedTag(Signed, 4);
        const DU = simd.FixedTag(Unsigned, 4);
        const floats: DF.Vector = @splat(1.5);
        const signed: DI.Vector = @splat(1);
        const unsigned: DU.Vector = @splat(1);
        _ = convertTo(DI, floats);
        _ = convertTo(DU, floats);
        _ = convertTo(DF, signed);
        _ = convertTo(DF, unsigned);
        _ = convertInRangeTo(DI, floats);
        _ = nearestInt(DI, floats);
        _ = ceilInt(DI, floats);
        _ = floorInt(DI, floats);
        _ = maskedConvertTo(DI, @as(DI.Mask, @splat(true)), floats);
        _ = maskedConvertTo(DF, @as(DF.Mask, @splat(true)), signed);
    }
    const unsigned_types = .{ u8, u16, u32, u64 };
    inline for (unsigned_types) |From| {
        inline for (unsigned_types) |To| {
            if (comptime @bitSizeOf(To) < @bitSizeOf(From)) {
                const DFrom = simd.FixedTag(From, 4);
                const DTo = simd.FixedTag(To, 4);
                _ = truncateTo(DTo, @as(DFrom.Vector, @splat(0)));
            }
        }
    }
    const F32 = simd.FixedTag(f32, 4);
    const I32 = simd.FixedTag(i32, 4);
    const U32 = simd.FixedTag(u32, 4);
    const F64 = simd.FixedTag(f64, 4);
    const I64 = simd.FixedTag(i64, 4);
    const U64 = simd.FixedTag(u64, 4);
    const floats: F32.Vector = .{ -1, 0, 1, 2 };
    _ = convertInRangeTo(I32, floats);
    _ = maskedConvertTo(I32, @as(I32.Mask, .{ true, false, true, false }), floats);
    _ = ceilInt(I32, floats);
    _ = floorInt(I32, floats);
    _ = promoteInRangeTo(I64, floats);
    _ = promoteInRangeTo(U64, floats);
    _ = promoteTo(F64, @as(I32.Vector, @splat(1)));
    _ = promoteTo(F64, @as(U32.Vector, @splat(1)));
    _ = demoteTo(F32, @as(I64.Vector, @splat(1)));
    _ = demoteTo(F32, @as(U64.Vector, @splat(1)));
    _ = demoteInRangeTo(I32, @as(F64.Vector, @splat(1)));
    _ = demoteInRangeTo(U32, @as(F64.Vector, @splat(1)));
    _ = demoteToNearestInt(I32, @as(F64.Vector, @splat(1)));
    _ = u8FromU32(simd.FixedTag(u8, 4), @as(U32.Vector, .{ 0, 1, 254, 255 }));
    _ = reorderDemote2To(simd.FixedTag(i16, 8), @as(I32.Vector, @splat(0)), @as(I32.Vector, @splat(1)));
    _ = shiftRightAndDemoteTo(simd.FixedTag(i16, 4), 1, @as(I32.Vector, @splat(1)));
    _ = roundingShiftRightAndDemoteTo(simd.FixedTag(i16, 4), 1, @as(I32.Vector, @splat(1)));
    _ = reorderShiftRightAndDemote2To(simd.FixedTag(i16, 8), 1, @as(I32.Vector, @splat(1)), @as(I32.Vector, @splat(2)));
    _ = reorderRoundingShiftRightAndDemote2To(simd.FixedTag(i16, 8), 1, @as(I32.Vector, @splat(1)), @as(I32.Vector, @splat(2)));
    _ = promoteInRangeLowerTo(I64, @as(simd.FixedTag(f32, 8).Vector, @splat(1)));
    _ = promoteInRangeUpperTo(U64, @as(simd.FixedTag(f32, 8).Vector, @splat(1)));
    _ = promoteInRangeEvenTo(I64, @as(simd.FixedTag(f32, 8).Vector, @splat(1)));
    _ = promoteInRangeOddTo(U64, @as(simd.FixedTag(f32, 8).Vector, @splat(1)));
}

test "Highway mask promotion demotion and ordered packing preserve truth values" {
    const simd = @import("root.zig");
    const B = simd.FixedTag(u8, 4);
    const W = simd.FixedTag(i32, 4);
    const N = simd.FixedTag(u16, 8);
    const a: B.Mask = .{ true, false, false, true };
    const b: B.Mask = .{ false, true, true, false };
    try std.testing.expect(@reduce(.And, promoteMaskTo(W, B, a) == a));
    try std.testing.expect(@reduce(.And, demoteMaskTo(B, W, a) == a));
    try std.testing.expect(@reduce(.And, orderedDemote2MasksTo(N, W, a, b) ==
        @as(N.Mask, .{ true, false, false, true, false, true, true, false })));
}
