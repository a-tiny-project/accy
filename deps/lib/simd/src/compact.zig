const std = @import("std");

pub fn compress(comptime D: type, value: D.Vector, mask: D.Mask) D.Vector {
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    var result: [D.lane_count]D.Lane = undefined;
    var position: usize = 0;
    inline for (0..D.lane_count) |index| {
        if (mask[index]) {
            result[position] = lanes[index];
            position += 1;
        }
    }
    inline for (0..D.lane_count) |index| {
        if (!mask[index]) {
            result[position] = lanes[index];
            position += 1;
        }
    }
    std.debug.assert(position == D.lane_count);
    return @bitCast(result);
}

pub fn compressIsPartition(comptime D: type) bool {
    _ = D;
    return true;
}

pub fn compressNot(comptime D: type, value: D.Vector, mask: D.Mask) D.Vector {
    return compress(D, value, !mask);
}

pub fn compressBlocksNot(comptime D: type, value: D.Vector, mask: D.Mask) D.Vector {
    if (D.Lane != u64) @compileError("compressBlocksNot requires u64 lanes");
    if (D.lane_count < 2 or D.lane_count % 2 != 0) {
        @compileError("compressBlocksNot requires complete 128-bit blocks");
    }
    return compressNot(D, value, mask);
}

pub fn compressStore(
    comptime D: type,
    value: D.Vector,
    mask: D.Mask,
    output: []D.Lane,
) usize {
    const count = countTrue(D, mask);
    std.debug.assert(output.len >= count);
    const compacted = compress(D, value, mask);
    inline for (0..D.lane_count) |index| {
        if (index < count) output[index] = compacted[index];
    }
    return count;
}

pub fn compressBlendedStore(
    comptime D: type,
    value: D.Vector,
    mask: D.Mask,
    output: []D.Lane,
) usize {
    return compressStore(D, value, mask, output);
}

pub fn compressBits(
    comptime D: type,
    value: D.Vector,
    bits: []const u8,
) D.Vector {
    return compress(D, value, @import("compare.zig").loadMaskBits(D, bits));
}

pub fn compressBitsStore(
    comptime D: type,
    value: D.Vector,
    bits: []const u8,
    output: []D.Lane,
) usize {
    return compressStore(D, value, @import("compare.zig").loadMaskBits(D, bits), output);
}

pub fn expand(comptime D: type, value: D.Vector, mask: D.Mask) D.Vector {
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    var result: [D.lane_count]D.Lane = @splat(0);
    var position: usize = 0;
    inline for (0..D.lane_count) |index| {
        if (mask[index]) {
            result[index] = lanes[position];
            position += 1;
        }
    }
    return @bitCast(result);
}

pub fn loadExpand(
    comptime D: type,
    mask: D.Mask,
    input: []const D.Lane,
) D.Vector {
    const count = countTrue(D, mask);
    std.debug.assert(input.len >= count);
    var result: D.Vector = @splat(0);
    var position: usize = 0;
    inline for (0..D.lane_count) |index| {
        if (mask[index]) {
            result[index] = input[position];
            position += 1;
        }
    }
    return result;
}

fn countTrue(comptime D: type, mask: D.Mask) usize {
    return @import("compare.zig").countTrue(D, mask);
}

fn verifyLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 8);
    const value: D.Vector = @splat(0);
    const mask: D.Mask = .{ true, false, true, false, false, true, false, true };
    const compacted = compress(D, value, mask);
    try std.testing.expect(@reduce(.And, expand(D, compacted, mask) == value));
    var stored: [D.lane_count]T = undefined;
    try std.testing.expectEqual(@as(usize, 4), compressStore(D, value, mask, &stored));
}

test "Highway compact operations instantiate every lane type" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f16, f32, f64 }) |T| {
        try verifyLaneType(T);
    }
    try std.testing.expect(compressIsPartition(@import("root.zig").FixedTag(u32, 8)));
}

test "Highway compress is a stable partition and stores its selected prefix" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 8);
    const value: D.Vector = .{ 10, 11, 12, 13, 14, 15, 16, 17 };
    const mask: D.Mask = .{ false, true, true, false, true, false, false, true };
    const expected: D.Vector = .{ 11, 12, 14, 17, 10, 13, 15, 16 };
    try std.testing.expect(@reduce(.And, compress(D, value, mask) == expected));
    try std.testing.expect(@reduce(.And, compressNot(D, value, !mask) == expected));

    var output = @as([8]i32, @splat(99));
    try std.testing.expectEqual(@as(usize, 4), compressBlendedStore(D, value, mask, &output));
    try std.testing.expectEqualSlices(i32, &.{ 11, 12, 14, 17, 99, 99, 99, 99 }, &output);

    var bits = [_]u8{0x96};
    try std.testing.expect(@reduce(.And, compressBits(D, value, &bits) == expected));
    @memset(&output, 99);
    try std.testing.expectEqual(@as(usize, 4), compressBitsStore(D, value, &bits, &output));
    try std.testing.expectEqualSlices(i32, &.{ 11, 12, 14, 17, 99, 99, 99, 99 }, &output);
}

test "Highway expand scatters consecutive lanes and loadExpand reads only selected input" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u16, 8);
    const compacted: D.Vector = .{ 20, 30, 50, 80, 91, 92, 93, 94 };
    const mask: D.Mask = .{ false, true, true, false, true, false, false, true };
    const expected: D.Vector = .{ 0, 20, 30, 0, 50, 0, 0, 80 };
    try std.testing.expect(@reduce(.And, expand(D, compacted, mask) == expected));
    try std.testing.expect(@reduce(.And, loadExpand(D, mask, &.{ 20, 30, 50, 80 }) == expected));
}

test "Highway block compression retains complete u64 pairs" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u64, 8);
    const value: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const not_mask: D.Mask = .{ true, true, false, false, true, true, false, false };
    try std.testing.expect(@reduce(.And, compressBlocksNot(D, value, not_mask) ==
        @as(D.Vector, .{ 2, 3, 6, 7, 0, 1, 4, 5 })));
}
