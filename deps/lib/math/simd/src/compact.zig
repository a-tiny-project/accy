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
