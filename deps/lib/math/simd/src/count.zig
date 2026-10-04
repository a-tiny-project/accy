const std = @import("std");

pub fn populationCount(comptime D: type, value: D.Vector) D.Vector {
    validate(D);
    if (@typeInfo(D.Lane).int.signedness != .unsigned) {
        @compileError("populationCount requires unsigned lanes");
    }
    return @popCount(value);
}

pub fn leadingZeroCount(comptime D: type, value: D.Vector) D.Vector {
    validate(D);
    const U = UnsignedVector(D);
    const bits: U = @bitCast(value);
    const result: U = @intCast(@clz(bits));
    return @bitCast(result);
}

pub fn maskedLeadingZeroCount(
    comptime D: type,
    mask: D.Mask,
    value: D.Vector,
) D.Vector {
    return @select(D.Lane, mask, leadingZeroCount(D, value), @as(D.Vector, @splat(0)));
}

pub fn trailingZeroCount(comptime D: type, value: D.Vector) D.Vector {
    validate(D);
    const U = UnsignedVector(D);
    const bits: U = @bitCast(value);
    const result: U = @intCast(@ctz(bits));
    return @bitCast(result);
}

pub fn highestSetBitIndex(comptime D: type, value: D.Vector) D.Vector {
    validate(D);
    const U = UnsignedVector(D);
    const bits: U = @bitCast(value);
    const top: U = @splat(@bitSizeOf(D.Lane) - 1);
    const leading: U = @intCast(@clz(bits));
    return @bitCast(top -% leading);
}

fn UnsignedVector(comptime D: type) type {
    return @Vector(D.lane_count, @Int(.unsigned, @bitSizeOf(D.Lane)));
}

fn validate(comptime D: type) void {
    if (@typeInfo(D.Lane) != .int) @compileError("bit counts require integer lanes");
}

fn verifyCounts(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const U = @Int(.unsigned, @bitSizeOf(T));
    const UV = @Vector(4, U);
    const bits = @bitSizeOf(T);
    const input_bits: UV = .{ 0, 1, @as(U, 1) << (bits - 1), 0x2b };
    const input: D.Vector = @bitCast(input_bits);
    const leading: D.Vector = @bitCast(@as(UV, .{ bits, bits - 1, 0, bits - 6 }));
    const trailing: D.Vector = @bitCast(@as(UV, .{ bits, 0, bits - 1, 0 }));
    const highest: D.Vector = @bitCast(@as(UV, .{
        std.math.maxInt(U), 0, bits - 1, 5,
    }));
    try std.testing.expect(@reduce(.And, leadingZeroCount(D, input) == leading));
    try std.testing.expect(@reduce(.And, trailingZeroCount(D, input) == trailing));
    try std.testing.expect(@reduce(.And, highestSetBitIndex(D, input) == highest));
}
