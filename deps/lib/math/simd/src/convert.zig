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
