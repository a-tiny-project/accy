const std = @import("std");

pub fn zero(comptime D: type) D.Vector {
    return @splat(0);
}

pub fn set(comptime D: type, value: D.Lane) D.Vector {
    return @splat(value);
}

pub fn @"undefined"(comptime D: type) D.Vector {
    return undefined;
}

pub fn dup128VecFromValues(
    comptime D: type,
    values: [128 / @bitSizeOf(D.Lane)]D.Lane,
) D.Vector {
    const lanes_per_block = 128 / @bitSizeOf(D.Lane);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = values[index % lanes_per_block];
    }
    return result;
}

pub fn maskedSetOr(
    comptime D: type,
    inactive: D.Vector,
    mask: D.Mask,
    value: D.Lane,
) D.Vector {
    return @select(D.Lane, mask, @as(D.Vector, @splat(value)), inactive);
}

pub fn maskedSet(comptime D: type, mask: D.Mask, value: D.Lane) D.Vector {
    return maskedSetOr(D, @splat(0), mask, value);
}

pub fn inf(comptime D: type) D.Vector {
    if (@typeInfo(D.Lane) != .float) @compileError("inf requires floating-point lanes");
    return @splat(std.math.inf(D.Lane));
}

pub fn nan(comptime D: type) D.Vector {
    if (@typeInfo(D.Lane) != .float) @compileError("nan requires floating-point lanes");
    return @splat(std.math.nan(D.Lane));
}

pub fn iota(comptime D: type, first: D.Lane) D.Vector {
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = iotaLane(D.Lane, first, index);
    }
    return result;
}

pub fn firstN(comptime D: type, count: usize) D.Mask {
    var result: D.Mask = @splat(false);
    inline for (0..D.lane_count) |index| {
        result[index] = index < count;
    }
    return result;
}

pub fn lane(comptime D: type, value: D.Vector, index: usize) D.Lane {
    std.debug.assert(index < D.lane_count);
    const values: [D.lane_count]D.Lane = value;
    return values[index];
}

pub fn insertLane(
    comptime D: type,
    value: D.Vector,
    index: usize,
    inserted: D.Lane,
) D.Vector {
    std.debug.assert(index < D.lane_count);
    var values: [D.lane_count]D.Lane = value;
    values[index] = inserted;
    std.debug.assert(values[index] == inserted);
    return values;
}

fn iotaLane(comptime T: type, first: T, index: usize) T {
    return switch (@typeInfo(T)) {
        .int => blk: {
            const U = @Int(.unsigned, @bitSizeOf(T));
            const first_bits: U = @bitCast(first);
            const offset: U = @truncate(index);
            break :blk @bitCast(first_bits +% offset);
        },
        .float => first + @as(T, @floatFromInt(index)),
        else => unreachable,
    };
}
