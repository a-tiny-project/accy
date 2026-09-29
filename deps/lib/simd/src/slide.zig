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

test "Highway slides instantiate every lane type" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f16, f32, f64 }) |T| {
        try verifyLaneType(T);
    }
}

test "Highway lane slides cross blocks and preserve explicit fill lanes" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 8);
    const value: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const fill: D.Vector = @splat(99);
    try std.testing.expect(@reduce(.And, slideUpLanes(D, value, 3) == @as(D.Vector, .{ 0, 0, 0, 0, 1, 2, 3, 4 })));
    try std.testing.expect(@reduce(.And, slideDownLanes(D, value, 3) == @as(D.Vector, .{ 3, 4, 5, 6, 7, 0, 0, 0 })));
    try std.testing.expect(@reduce(.And, slideUpLanesOr(D, fill, value, 3) == @as(D.Vector, .{ 99, 99, 99, 0, 1, 2, 3, 4 })));
    try std.testing.expect(@reduce(.And, slideDownLanesOr(D, fill, value, 3) == @as(D.Vector, .{ 3, 4, 5, 6, 7, 99, 99, 99 })));
    try std.testing.expect(@reduce(.And, slide1UpOr(D, -1, value) == @as(D.Vector, .{ -1, 0, 1, 2, 3, 4, 5, 6 })));
    try std.testing.expect(@reduce(.And, slide1DownOr(D, -1, value) == @as(D.Vector, .{ 1, 2, 3, 4, 5, 6, 7, -1 })));
}

test "Highway mask and block slides use the same whole-vector geometry" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u32, 8);
    const mask: D.Mask = .{ true, false, true, false, false, true, false, true };
    try std.testing.expect(@reduce(.And, slideMaskUpLanes(D, mask, 2) ==
        @as(D.Mask, .{ false, false, true, false, true, false, false, true })));
    try std.testing.expect(@reduce(.And, slideMaskDownLanes(D, mask, 2) ==
        @as(D.Mask, .{ true, false, false, true, false, true, false, false })));
    const value: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expect(@reduce(.And, slideUpBlocks(D, 1, value) == @as(D.Vector, .{ 0, 0, 0, 0, 0, 1, 2, 3 })));
    try std.testing.expect(@reduce(.And, slideDownBlocks(D, 1, value) == @as(D.Vector, .{ 4, 5, 6, 7, 0, 0, 0, 0 })));
}
