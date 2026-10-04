const std = @import("std");

pub fn extractLane(comptime D: type, value: D.Vector, index: usize) D.Lane {
    std.debug.assert(index < D.lane_count);
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    return lanes[index];
}

pub fn broadcastLane(comptime D: type, comptime index: usize, value: D.Vector) D.Vector {
    if (index >= D.lane_count) @compileError("broadcast lane is outside the vector");
    return @splat(value[index]);
}

pub fn dupEven(comptime D: type, value: D.Vector) D.Vector {
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = value[index & ~@as(usize, 1)];
    return result;
}

pub fn dupOdd(comptime D: type, value: D.Vector) D.Vector {
    if (D.lane_count < 2) @compileError("dupOdd requires at least two lanes");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = value[(index & ~@as(usize, 1)) + 1];
    return result;
}

pub fn oddEven(comptime D: type, odd: D.Vector, even: D.Vector) D.Vector {
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = if (index & 1 == 0) even[index] else odd[index];
    }
    return result;
}

pub fn reverse(comptime D: type, value: D.Vector) D.Vector {
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = value[D.lane_count - 1 - index];
    return result;
}

pub fn reverse2(comptime D: type, value: D.Vector) D.Vector {
    if (D.lane_count == 1) return value;
    return reverseGroups(D, 2, value);
}

pub fn reverse4(comptime D: type, value: D.Vector) D.Vector {
    return reverseGroups(D, 4, value);
}

pub fn reverse8(comptime D: type, value: D.Vector) D.Vector {
    return reverseGroups(D, 8, value);
}

pub fn reverseLaneBytes(comptime D: type, value: D.Vector) D.Vector {
    if (@typeInfo(D.Lane) != .int) @compileError("reverseLaneBytes requires integer lanes");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = @byteSwap(value[index]);
    return result;
}

pub fn reverseBits(comptime D: type, value: D.Vector) D.Vector {
    if (@typeInfo(D.Lane) != .int) @compileError("reverseBits requires integer lanes");
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = @bitReverse(value[index]);
    return result;
}

pub fn reverseBlocks(comptime D: type, value: D.Vector) D.Vector {
    if (D.byte_count < 16 or D.byte_count % 16 != 0) {
        @compileError("reverseBlocks requires complete 128-bit blocks");
    }
    const lanes_per_block = 16 / @sizeOf(D.Lane);
    const block_count = D.lane_count / lanes_per_block;
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        const block = index / lanes_per_block;
        const lane = index % lanes_per_block;
        result[index] = value[(block_count - 1 - block) * lanes_per_block + lane];
    }
    return result;
}

fn reverseGroups(comptime D: type, comptime group: usize, value: D.Vector) D.Vector {
    if (D.lane_count < group or D.lane_count % group != 0) {
        @compileError("lane count must contain complete reversal groups");
    }
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = value[index ^ (group - 1)];
    return result;
}

fn verifyLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 8);
    const value: D.Vector = @splat(0);
    try std.testing.expect(@reduce(.And, reverse(D, reverse(D, value)) == value));
    try std.testing.expect(@reduce(.And, dupEven(D, value) == value));
    try std.testing.expect(@reduce(.And, dupOdd(D, value) == value));
    try std.testing.expect(@reduce(.And, oddEven(D, value, value) == value));
}
