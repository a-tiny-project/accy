const std = @import("std");

pub fn broadcast(comptime D: type, comptime lane: usize, value: D.Vector) D.Vector {
    const lanes_per_block = comptime blockLanes(D);
    if (comptime lane >= lanes_per_block) @compileError("broadcast lane is outside a 128-bit block");
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = lanes[(index / lanes_per_block) * lanes_per_block + lane];
    }
    return @bitCast(result);
}

pub fn interleaveLower(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return interleaveHalf(D, false, a, b);
}

pub fn interleaveUpper(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    if (comptime blockLanes(D) < 2) @compileError("interleaveUpper requires at least two lanes per block");
    return interleaveHalf(D, true, a, b);
}

pub fn interleaveEven(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return interleaveParity(D, 0, a, b);
}

pub fn interleaveOdd(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    if (comptime blockLanes(D) < 2) @compileError("interleaveOdd requires at least two lanes per block");
    return interleaveParity(D, 1, a, b);
}

pub fn zipLower(comptime D: type, a: D.Vector, b: D.Vector) D.repartition(wideInteger(D.Lane)).Vector {
    return @bitCast(interleaveLower(D, a, b));
}

pub fn zipUpper(comptime D: type, a: D.Vector, b: D.Vector) D.repartition(wideInteger(D.Lane)).Vector {
    return @bitCast(interleaveUpper(D, a, b));
}

pub fn shiftLeftBytes(comptime D: type, comptime amount: usize, value: D.Vector) D.Vector {
    return shiftBytes(D, amount, true, value);
}

pub fn shiftRightBytes(comptime D: type, comptime amount: usize, value: D.Vector) D.Vector {
    return shiftBytes(D, amount, false, value);
}

pub fn shiftLeftLanes(comptime D: type, comptime amount: usize, value: D.Vector) D.Vector {
    return shiftLanes(D, amount, true, value);
}

pub fn shiftRightLanes(comptime D: type, comptime amount: usize, value: D.Vector) D.Vector {
    return shiftLanes(D, amount, false, value);
}

pub fn combineShiftRightBytes(
    comptime D: type,
    comptime amount: usize,
    high: D.Vector,
    low: D.Vector,
) D.Vector {
    const bytes_per_block = @min(D.byte_count, 16);
    if (comptime amount >= bytes_per_block) @compileError("combined byte shift must remain inside a block");
    const high_bytes: [D.byte_count]u8 = @bitCast(high);
    const low_bytes: [D.byte_count]u8 = @bitCast(low);
    var result: [D.byte_count]u8 = undefined;
    inline for (0..D.byte_count) |index| {
        const base = index / bytes_per_block * bytes_per_block;
        const source = index % bytes_per_block + amount;
        result[index] = if (source < bytes_per_block)
            low_bytes[base + source]
        else
            high_bytes[base + source - bytes_per_block];
    }
    return @bitCast(result);
}

pub fn combineShiftRightLanes(
    comptime D: type,
    comptime amount: usize,
    high: D.Vector,
    low: D.Vector,
) D.Vector {
    const lanes_per_block = comptime blockLanes(D);
    if (comptime amount >= lanes_per_block) @compileError("combined lane shift must remain inside a block");
    const high_lanes: [D.lane_count]D.Lane = @bitCast(high);
    const low_lanes: [D.lane_count]D.Lane = @bitCast(low);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |index| {
        const base = index / lanes_per_block * lanes_per_block;
        const source = index % lanes_per_block + amount;
        result[index] = if (source < lanes_per_block)
            low_lanes[base + source]
        else
            high_lanes[base + source - lanes_per_block];
    }
    return @bitCast(result);
}

pub fn per4LaneBlockShuffle(
    comptime D: type,
    comptime index3: usize,
    comptime index2: usize,
    comptime index1: usize,
    comptime index0: usize,
    value: D.Vector,
) D.Vector {
    inline for (.{ index0, index1, index2, index3 }) |index| {
        if (comptime index >= 4) @compileError("per-four-lane shuffle index must be below four");
    }
    const group = @min(D.lane_count, 4);
    const indices = [4]usize{ index0, index1, index2, index3 };
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |lane| {
        const source = indices[lane % group];
        result[lane] = if (source < group) lanes[lane / group * group + source] else lanes[lane];
    }
    return @bitCast(result);
}

pub fn shuffle1032(comptime D: type, value: D.Vector) D.Vector {
    validate32BitLanes(D);
    return per4LaneBlockShuffle(D, 1, 0, 3, 2, value);
}

pub fn shuffle0321(comptime D: type, value: D.Vector) D.Vector {
    validate32BitLanes(D);
    return per4LaneBlockShuffle(D, 0, 3, 2, 1, value);
}

pub fn shuffle2103(comptime D: type, value: D.Vector) D.Vector {
    validate32BitLanes(D);
    return per4LaneBlockShuffle(D, 2, 1, 0, 3, value);
}

pub fn shuffle2301(comptime D: type, value: D.Vector) D.Vector {
    validate32BitLanes(D);
    return per4LaneBlockShuffle(D, 2, 3, 0, 1, value);
}

pub fn shuffle01(comptime D: type, value: D.Vector) D.Vector {
    if (comptime @bitSizeOf(D.Lane) != 64) @compileError("shuffle01 requires 64-bit lanes");
    const lanes: [D.lane_count]D.Lane = value;
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |index| result[index] = lanes[index ^ 1];
    return result;
}

pub fn shuffle0123(comptime D: type, value: D.Vector) D.Vector {
    validate32BitLanes(D);
    return per4LaneBlockShuffle(D, 0, 1, 2, 3, value);
}

pub fn blocks(comptime D: type) usize {
    return @max(1, D.byte_count / 16);
}

pub fn extractBlock(
    comptime D: type,
    comptime block_index: usize,
    value: D.Vector,
) @Vector(blockLanes(D), D.Lane) {
    const block_count = comptime blocks(D);
    if (comptime block_index >= block_count) @compileError("block index is outside the vector");
    const lanes_per_block = comptime blockLanes(D);
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    var result: [lanes_per_block]D.Lane = undefined;
    inline for (0..lanes_per_block) |lane| {
        result[lane] = lanes[block_index * lanes_per_block + lane];
    }
    return @bitCast(result);
}

pub fn insertBlock(
    comptime D: type,
    comptime block_index: usize,
    value: D.Vector,
    inserted: @Vector(blockLanes(D), D.Lane),
) D.Vector {
    const block_count = comptime blocks(D);
    if (comptime block_index >= block_count) @compileError("block index is outside the vector");
    const lanes_per_block = comptime blockLanes(D);
    var result: [D.lane_count]D.Lane = @bitCast(value);
    const inserted_lanes: [lanes_per_block]D.Lane = @bitCast(inserted);
    inline for (0..lanes_per_block) |lane| {
        result[block_index * lanes_per_block + lane] = inserted_lanes[lane];
    }
    return @bitCast(result);
}

pub fn broadcastBlock(comptime D: type, comptime block_index: usize, value: D.Vector) D.Vector {
    const block_count = comptime blocks(D);
    if (comptime block_index >= block_count) @compileError("block index is outside the vector");
    if (block_count == 1) return value;
    const lanes_per_block = comptime blockLanes(D);
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |lane| {
        result[lane] = lanes[block_index * lanes_per_block + lane % lanes_per_block];
    }
    return @bitCast(result);
}

pub fn oddEvenBlocks(comptime D: type, odd: D.Vector, even: D.Vector) D.Vector {
    const block_count = comptime blocks(D);
    if (block_count == 1) return even;
    const lanes_per_block = comptime blockLanes(D);
    const odd_lanes: [D.lane_count]D.Lane = @bitCast(odd);
    const even_lanes: [D.lane_count]D.Lane = @bitCast(even);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |lane| {
        result[lane] = if ((lane / lanes_per_block) & 1 == 0) even_lanes[lane] else odd_lanes[lane];
    }
    return @bitCast(result);
}

pub fn swapAdjacentBlocks(comptime D: type, value: D.Vector) D.Vector {
    validateMultipleBlocks(D);
    const lanes_per_block = comptime blockLanes(D);
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |lane| {
        const block_index = lane / lanes_per_block;
        result[lane] = lanes[(block_index ^ 1) * lanes_per_block + lane % lanes_per_block];
    }
    return @bitCast(result);
}

pub fn interleaveEvenBlocks(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return interleaveBlockParity(D, 0, a, b);
}

pub fn interleaveOddBlocks(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return interleaveBlockParity(D, 1, a, b);
}

pub fn interleaveLowerBlocks(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return interleaveBlockHalf(D, false, a, b);
}

pub fn interleaveUpperBlocks(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return interleaveBlockHalf(D, true, a, b);
}

fn interleaveHalf(comptime D: type, comptime upper: bool, a: D.Vector, b: D.Vector) D.Vector {
    const lanes_per_block = comptime blockLanes(D);
    if (lanes_per_block == 1) return a;
    const a_lanes: [D.lane_count]D.Lane = @bitCast(a);
    const b_lanes: [D.lane_count]D.Lane = @bitCast(b);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |index| {
        const base = index / lanes_per_block * lanes_per_block;
        const within = index % lanes_per_block;
        const source = base + within / 2 + if (upper) lanes_per_block / 2 else 0;
        result[index] = if (within & 1 == 0) a_lanes[source] else b_lanes[source];
    }
    return @bitCast(result);
}

fn interleaveBlockParity(
    comptime D: type,
    comptime parity: usize,
    a: D.Vector,
    b: D.Vector,
) D.Vector {
    validateMultipleBlocks(D);
    const lanes_per_block = comptime blockLanes(D);
    const a_lanes: [D.lane_count]D.Lane = @bitCast(a);
    const b_lanes: [D.lane_count]D.Lane = @bitCast(b);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |lane| {
        const output_block = lane / lanes_per_block;
        const source_block = (output_block / 2) * 2 + parity;
        const source_lane = source_block * lanes_per_block + lane % lanes_per_block;
        result[lane] = if (output_block & 1 == 0) a_lanes[source_lane] else b_lanes[source_lane];
    }
    return @bitCast(result);
}

fn interleaveBlockHalf(
    comptime D: type,
    comptime upper: bool,
    a: D.Vector,
    b: D.Vector,
) D.Vector {
    validateMultipleBlocks(D);
    const block_count = comptime blocks(D);
    const lanes_per_block = comptime blockLanes(D);
    const a_lanes: [D.lane_count]D.Lane = @bitCast(a);
    const b_lanes: [D.lane_count]D.Lane = @bitCast(b);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |lane| {
        const output_block = lane / lanes_per_block;
        const source_block = output_block / 2 + if (upper) block_count / 2 else 0;
        const source_lane = source_block * lanes_per_block + lane % lanes_per_block;
        result[lane] = if (output_block & 1 == 0) a_lanes[source_lane] else b_lanes[source_lane];
    }
    return @bitCast(result);
}

fn interleaveParity(
    comptime D: type,
    comptime parity: usize,
    a: D.Vector,
    b: D.Vector,
) D.Vector {
    const lanes_per_block = comptime blockLanes(D);
    const a_lanes: [D.lane_count]D.Lane = @bitCast(a);
    const b_lanes: [D.lane_count]D.Lane = @bitCast(b);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |index| {
        const base = index / lanes_per_block * lanes_per_block;
        const within = index % lanes_per_block;
        const source = base + (within / 2) * 2 + parity;
        result[index] = if (within & 1 == 0) a_lanes[source] else b_lanes[source];
    }
    return @bitCast(result);
}

fn shiftBytes(comptime D: type, comptime amount: usize, comptime left: bool, value: D.Vector) D.Vector {
    const bytes_per_block = @min(D.byte_count, 16);
    if (comptime amount > bytes_per_block) @compileError("byte shift exceeds a block");
    const bytes: [D.byte_count]u8 = @bitCast(value);
    var result: [D.byte_count]u8 = @splat(0);
    inline for (0..D.byte_count) |index| {
        const within = index % bytes_per_block;
        if (left) {
            if (within >= amount) result[index] = bytes[index - amount];
        } else if (within + amount < bytes_per_block) {
            result[index] = bytes[index + amount];
        }
    }
    return @bitCast(result);
}

fn shiftLanes(comptime D: type, comptime amount: usize, comptime left: bool, value: D.Vector) D.Vector {
    const lanes_per_block = comptime blockLanes(D);
    if (comptime amount > lanes_per_block) @compileError("lane shift exceeds a block");
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    var result = @as([D.lane_count]D.Lane, @splat(0));
    inline for (0..D.lane_count) |index| {
        const within = index % lanes_per_block;
        if (left) {
            if (within >= amount) result[index] = lanes[index - amount];
        } else if (within + amount < lanes_per_block) {
            result[index] = lanes[index + amount];
        }
    }
    return @bitCast(result);
}

fn blockLanes(comptime D: type) comptime_int {
    return @min(D.lane_count, 16 / @sizeOf(D.Lane));
}

fn validateMultipleBlocks(comptime D: type) void {
    if (comptime blocks(D) < 2) @compileError("operation requires at least two 128-bit blocks");
}

fn validate32BitLanes(comptime D: type) void {
    if (comptime @bitSizeOf(D.Lane) != 32) @compileError("shuffle requires 32-bit lanes");
}

fn wideInteger(comptime T: type) type {
    return switch (T) {
        i8 => i16,
        u8 => u16,
        i16 => i32,
        u16 => u32,
        i32 => i64,
        u32 => u64,
        else => @compileError("zip requires 8-, 16-, or 32-bit integer lanes"),
    };
}

test "Highway block broadcast and interleave restart at 128-bit boundaries" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u32, 8);
    const a: D.Vector = .{ 0, 2, 4, 6, 8, 10, 12, 14 };
    const b: D.Vector = .{ 1, 3, 5, 7, 9, 11, 13, 15 };
    try std.testing.expect(@reduce(.And, broadcast(D, 2, a) == @as(D.Vector, .{ 4, 4, 4, 4, 12, 12, 12, 12 })));
    try std.testing.expect(@reduce(.And, interleaveLower(D, a, b) == @as(D.Vector, .{ 0, 1, 2, 3, 8, 9, 10, 11 })));
    try std.testing.expect(@reduce(.And, interleaveUpper(D, a, b) == @as(D.Vector, .{ 4, 5, 6, 7, 12, 13, 14, 15 })));
    try std.testing.expect(@reduce(.And, interleaveEven(D, a, b) == @as(D.Vector, .{ 0, 1, 4, 5, 8, 9, 12, 13 })));
    try std.testing.expect(@reduce(.And, interleaveOdd(D, a, b) == @as(D.Vector, .{ 2, 3, 6, 7, 10, 11, 14, 15 })));
}

test "Highway zip retains interleaved bits in wide lanes" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u16, 8);
    const a: D.Vector = .{ 0, 2, 4, 6, 8, 10, 12, 14 };
    const b: D.Vector = .{ 1, 3, 5, 7, 9, 11, 13, 15 };
    const W = D.repartition(u32);
    try std.testing.expect(@reduce(.And, zipLower(D, a, b) == @as(W.Vector, .{
        0x0001_0000, 0x0003_0002, 0x0005_0004, 0x0007_0006,
    })));
    try std.testing.expect(@reduce(.And, zipUpper(D, a, b) == @as(W.Vector, .{
        0x0009_0008, 0x000b_000a, 0x000d_000c, 0x000f_000e,
    })));
}

test "Highway block shifts zero fill and combined shifts concatenate low then high" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u32, 8);
    const low: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const high: D.Vector = .{ 10, 11, 12, 13, 14, 15, 16, 17 };
    try std.testing.expect(@reduce(.And, shiftLeftLanes(D, 1, low) == @as(D.Vector, .{ 0, 0, 1, 2, 0, 4, 5, 6 })));
    try std.testing.expect(@reduce(.And, shiftRightLanes(D, 1, low) == @as(D.Vector, .{ 1, 2, 3, 0, 5, 6, 7, 0 })));
    try std.testing.expect(@reduce(.And, combineShiftRightLanes(D, 2, high, low) == @as(D.Vector, .{ 2, 3, 10, 11, 6, 7, 14, 15 })));

    const B = simd.FixedTag(u8, 32);
    const bytes = simd.iota(B, 1);
    try std.testing.expectEqual(@as(u8, 0), shiftLeftBytes(B, 1, bytes)[0]);
    try std.testing.expectEqual(@as(u8, 1), shiftLeftBytes(B, 1, bytes)[1]);
    try std.testing.expectEqual(@as(u8, 0), shiftLeftBytes(B, 1, bytes)[16]);
    try std.testing.expectEqual(@as(u8, 2), shiftRightBytes(B, 1, bytes)[0]);
    try std.testing.expectEqual(@as(u8, 0), shiftRightBytes(B, 1, bytes)[15]);
}

test "Highway per-four-lane shuffle repeats its pattern" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 8);
    const value: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expect(@reduce(.And, per4LaneBlockShuffle(D, 0, 1, 2, 3, value) ==
        @as(D.Vector, .{ 3, 2, 1, 0, 7, 6, 5, 4 })));
    try std.testing.expect(@reduce(.And, shuffle1032(D, value) == @as(D.Vector, .{ 2, 3, 0, 1, 6, 7, 4, 5 })));
    try std.testing.expect(@reduce(.And, shuffle0321(D, value) == @as(D.Vector, .{ 1, 2, 3, 0, 5, 6, 7, 4 })));
    try std.testing.expect(@reduce(.And, shuffle2103(D, value) == @as(D.Vector, .{ 3, 0, 1, 2, 7, 4, 5, 6 })));
    try std.testing.expect(@reduce(.And, shuffle2301(D, value) == @as(D.Vector, .{ 1, 0, 3, 2, 5, 4, 7, 6 })));
    try std.testing.expect(@reduce(.And, shuffle0123(D, value) == @as(D.Vector, .{ 3, 2, 1, 0, 7, 6, 5, 4 })));
    const D64 = simd.FixedTag(u64, 4);
    try std.testing.expect(@reduce(.And, shuffle01(D64, .{ 0, 1, 2, 3 }) ==
        @as(D64.Vector, .{ 1, 0, 3, 2 })));
}

test "Highway block extraction insertion broadcast and selection retain block boundaries" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u32, 16);
    const value: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const replacement: @Vector(4, u32) = .{ 90, 91, 92, 93 };
    try std.testing.expectEqual(@as(usize, 4), blocks(D));
    try std.testing.expect(@reduce(.And, extractBlock(D, 2, value) == replacement - @as(@Vector(4, u32), @splat(82))));
    try std.testing.expect(@reduce(.And, insertBlock(D, 1, value, replacement) == @as(D.Vector, .{
        0, 1, 2, 3, 90, 91, 92, 93, 8, 9, 10, 11, 12, 13, 14, 15,
    })));
    try std.testing.expect(@reduce(.And, broadcastBlock(D, 2, value) == @as(D.Vector, .{
        8, 9, 10, 11, 8, 9, 10, 11, 8, 9, 10, 11, 8, 9, 10, 11,
    })));
    try std.testing.expect(@reduce(.And, swapAdjacentBlocks(D, value) == @as(D.Vector, .{
        4, 5, 6, 7, 0, 1, 2, 3, 12, 13, 14, 15, 8, 9, 10, 11,
    })));
}

test "Highway block interleaves select even odd lower and upper source blocks" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u32, 16);
    const a: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const b = a + @as(D.Vector, @splat(100));
    try std.testing.expect(@reduce(.And, oddEvenBlocks(D, b, a) == @as(D.Vector, .{
        0, 1, 2, 3, 104, 105, 106, 107, 8, 9, 10, 11, 112, 113, 114, 115,
    })));
    try std.testing.expect(@reduce(.And, interleaveEvenBlocks(D, a, b) == @as(D.Vector, .{
        0, 1, 2, 3, 100, 101, 102, 103, 8, 9, 10, 11, 108, 109, 110, 111,
    })));
    try std.testing.expect(@reduce(.And, interleaveOddBlocks(D, a, b) == @as(D.Vector, .{
        4, 5, 6, 7, 104, 105, 106, 107, 12, 13, 14, 15, 112, 113, 114, 115,
    })));
    try std.testing.expect(@reduce(.And, interleaveLowerBlocks(D, a, b) == @as(D.Vector, .{
        0, 1, 2, 3, 100, 101, 102, 103, 4, 5, 6, 7, 104, 105, 106, 107,
    })));
    try std.testing.expect(@reduce(.And, interleaveUpperBlocks(D, a, b) == @as(D.Vector, .{
        8, 9, 10, 11, 108, 109, 110, 111, 12, 13, 14, 15, 112, 113, 114, 115,
    })));
}

fn verifyBlockLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 32 / @sizeOf(T));
    const B = @Vector(16 / @sizeOf(T), T);
    const value: D.Vector = @splat(0);
    const block_value: B = @splat(0);
    try std.testing.expect(@reduce(.And, broadcast(D, 0, value) == value));
    try std.testing.expect(@reduce(.And, interleaveLower(D, value, value) == value));
    try std.testing.expect(@reduce(.And, interleaveUpper(D, value, value) == value));
    try std.testing.expect(@reduce(.And, interleaveEven(D, value, value) == value));
    try std.testing.expect(@reduce(.And, interleaveOdd(D, value, value) == value));
    try std.testing.expect(@reduce(.And, shiftLeftLanes(D, 1, value) == value));
    try std.testing.expect(@reduce(.And, shiftRightLanes(D, 1, value) == value));
    try std.testing.expect(@reduce(.And, combineShiftRightLanes(D, 1, value, value) == value));
    if (comptime @typeInfo(T) == .int) {
        try std.testing.expect(@reduce(.And, shiftLeftBytes(D, 1, value) == value));
        try std.testing.expect(@reduce(.And, shiftRightBytes(D, 1, value) == value));
        try std.testing.expect(@reduce(.And, combineShiftRightBytes(D, 1, value, value) == value));
    }
    try std.testing.expect(@reduce(.And, insertBlock(D, 1, value, block_value) == value));
    try std.testing.expect(@reduce(.And, extractBlock(D, 1, value) == block_value));
    try std.testing.expect(@reduce(.And, broadcastBlock(D, 1, value) == value));
    try std.testing.expect(@reduce(.And, oddEvenBlocks(D, value, value) == value));
    try std.testing.expect(@reduce(.And, swapAdjacentBlocks(D, value) == value));
    try std.testing.expect(@reduce(.And, interleaveEvenBlocks(D, value, value) == value));
    try std.testing.expect(@reduce(.And, interleaveOddBlocks(D, value, value) == value));
    try std.testing.expect(@reduce(.And, interleaveLowerBlocks(D, value, value) == value));
    try std.testing.expect(@reduce(.And, interleaveUpperBlocks(D, value, value) == value));
}

test "Highway block geometry instantiates every lane type" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f16, f32, f64 }) |T| {
        try verifyBlockLaneType(T);
    }
    inline for (.{ u8, i8, u16, i16, u32, i32 }) |T| {
        const simd = @import("root.zig");
        const D = simd.FixedTag(T, 16 / @sizeOf(T));
        const value: D.Vector = @splat(0);
        try std.testing.expect(@reduce(.And, zipLower(D, value, value) ==
            @as(D.repartition(wideInteger(T)).Vector, @splat(0))));
        try std.testing.expect(@reduce(.And, zipUpper(D, value, value) ==
            @as(D.repartition(wideInteger(T)).Vector, @splat(0))));
    }
}
