const std = @import("std");

pub fn slideUpLanes(comptime D: type, value: D.Vector, amount: usize) D.Vector {
    std.debug.assert(amount <= D.lane_count);
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    var result = @as([D.lane_count]D.Lane, @splat(0));
    for (amount..D.lane_count) |index| result[index] = lanes[index - amount];
    return @bitCast(result);
}

pub fn slideDownLanes(comptime D: type, value: D.Vector, amount: usize) D.Vector {
    std.debug.assert(amount <= D.lane_count);
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    var result = @as([D.lane_count]D.Lane, @splat(0));
    for (0..D.lane_count - amount) |index| result[index] = lanes[index + amount];
    return @bitCast(result);
}

pub fn slideUpLanesOr(
    comptime D: type,
    low: D.Vector,
    high: D.Vector,
    amount: usize,
) D.Vector {
    std.debug.assert(amount <= D.lane_count);
    const low_lanes: [D.lane_count]D.Lane = @bitCast(low);
    const high_lanes: [D.lane_count]D.Lane = @bitCast(high);
    var result: [D.lane_count]D.Lane = undefined;
    for (0..D.lane_count) |index| {
        result[index] = if (index < amount) low_lanes[index] else high_lanes[index - amount];
    }
    return @bitCast(result);
}

pub fn slideDownLanesOr(
    comptime D: type,
    high: D.Vector,
    low: D.Vector,
    amount: usize,
) D.Vector {
    std.debug.assert(amount <= D.lane_count);
    const high_lanes: [D.lane_count]D.Lane = @bitCast(high);
    const low_lanes: [D.lane_count]D.Lane = @bitCast(low);
    var result: [D.lane_count]D.Lane = undefined;
    for (0..D.lane_count) |index| {
        result[index] = if (index < D.lane_count - amount)
            low_lanes[index + amount]
        else
            high_lanes[index];
    }
    return @bitCast(result);
}

pub fn slide1Up(comptime D: type, value: D.Vector) D.Vector {
    return slideUpLanes(D, value, 1);
}

pub fn slide1Down(comptime D: type, value: D.Vector) D.Vector {
    return slideDownLanes(D, value, 1);
}

pub fn slide1UpOr(comptime D: type, fill: D.Lane, value: D.Vector) D.Vector {
    var result = slide1Up(D, value);
    result[0] = fill;
    return result;
}

pub fn slide1DownOr(comptime D: type, fill: D.Lane, value: D.Vector) D.Vector {
    var result = slide1Down(D, value);
    result[D.lane_count - 1] = fill;
    return result;
}

pub fn slideUpBlocks(comptime D: type, comptime blocks: usize, value: D.Vector) D.Vector {
    const lanes_per_block = 16 / @sizeOf(D.Lane);
    if (blocks * lanes_per_block > D.lane_count) @compileError("block slide exceeds the vector");
    return slideUpLanes(D, value, blocks * lanes_per_block);
}

pub fn slideDownBlocks(comptime D: type, comptime blocks: usize, value: D.Vector) D.Vector {
    const lanes_per_block = 16 / @sizeOf(D.Lane);
    if (blocks * lanes_per_block > D.lane_count) @compileError("block slide exceeds the vector");
    return slideDownLanes(D, value, blocks * lanes_per_block);
}

pub fn slideMaskUpLanes(comptime D: type, mask: D.Mask, amount: usize) D.Mask {
    std.debug.assert(amount <= D.lane_count);
    var lanes: [D.lane_count]bool = undefined;
    inline for (0..D.lane_count) |index| lanes[index] = mask[index];
    var shifted = @as([D.lane_count]bool, @splat(false));
    for (amount..D.lane_count) |index| shifted[index] = lanes[index - amount];
    var result: D.Mask = undefined;
    inline for (0..D.lane_count) |index| result[index] = shifted[index];
    return result;
}

pub fn slideMaskDownLanes(comptime D: type, mask: D.Mask, amount: usize) D.Mask {
    std.debug.assert(amount <= D.lane_count);
    var lanes: [D.lane_count]bool = undefined;
    inline for (0..D.lane_count) |index| lanes[index] = mask[index];
    var shifted = @as([D.lane_count]bool, @splat(false));
    for (0..D.lane_count - amount) |index| shifted[index] = lanes[index + amount];
    var result: D.Mask = undefined;
    inline for (0..D.lane_count) |index| result[index] = shifted[index];
    return result;
}

pub fn slideMask1Up(comptime D: type, mask: D.Mask) D.Mask {
    return slideMaskUpLanes(D, mask, 1);
}

pub fn slideMask1Down(comptime D: type, mask: D.Mask) D.Mask {
    return slideMaskDownLanes(D, mask, 1);
}

fn verifyLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const zero: D.Vector = @splat(0);
    try std.testing.expect(@reduce(.And, slideUpLanes(D, zero, 2) == zero));
    try std.testing.expect(@reduce(.And, slideDownLanes(D, zero, 2) == zero));
}
