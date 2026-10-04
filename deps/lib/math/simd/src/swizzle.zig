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

test "Highway whole-vector swizzles instantiate every lane type" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f16, f32, f64 }) |T| {
        try verifyLaneType(T);
    }
}

test "Highway lane duplication selection and broadcast retain lane order" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 8);
    const value: D.Vector = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expectEqual(@as(i32, 5), extractLane(D, value, 4));
    try std.testing.expect(@reduce(.And, broadcastLane(D, 4, value) == @as(D.Vector, @splat(5))));
    try std.testing.expect(@reduce(.And, dupEven(D, value) == @as(D.Vector, .{ 1, 1, 3, 3, 5, 5, 7, 7 })));
    try std.testing.expect(@reduce(.And, dupOdd(D, value) == @as(D.Vector, .{ 2, 2, 4, 4, 6, 6, 8, 8 })));
    try std.testing.expect(@reduce(.And, oddEven(D, value + @as(D.Vector, @splat(10)), value) ==
        @as(D.Vector, .{ 1, 12, 3, 14, 5, 16, 7, 18 })));
}

test "Highway reversals distinguish whole vectors groups lanes bits and blocks" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u16, 8);
    const value: D.Vector = .{ 0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040, 0x0080 };
    try std.testing.expect(@reduce(.And, reverse(D, value) == @as(D.Vector, .{
        0x0080, 0x0040, 0x0020, 0x0010, 0x0008, 0x0004, 0x0002, 0x0001,
    })));
    try std.testing.expect(@reduce(.And, reverse2(D, value) == @as(D.Vector, .{
        0x0002, 0x0001, 0x0008, 0x0004, 0x0020, 0x0010, 0x0080, 0x0040,
    })));
    try std.testing.expect(@reduce(.And, reverse4(D, value) == @as(D.Vector, .{
        0x0008, 0x0004, 0x0002, 0x0001, 0x0080, 0x0040, 0x0020, 0x0010,
    })));
    try std.testing.expect(@reduce(.And, reverse8(D, value) == reverse(D, value)));
    try std.testing.expect(@reduce(.And, reverseLaneBytes(D, value) == @as(D.Vector, .{
        0x0100, 0x0200, 0x0400, 0x0800, 0x1000, 0x2000, 0x4000, 0x8000,
    })));
    try std.testing.expect(@reduce(.And, reverseBits(D, value) == @as(D.Vector, .{
        0x8000, 0x4000, 0x2000, 0x1000, 0x0800, 0x0400, 0x0200, 0x0100,
    })));

    const B = simd.FixedTag(u32, 8);
    try std.testing.expect(@reduce(.And, reverseBlocks(B, @as(B.Vector, .{ 0, 1, 2, 3, 4, 5, 6, 7 })) ==
        @as(B.Vector, .{ 4, 5, 6, 7, 0, 1, 2, 3 })));
}
