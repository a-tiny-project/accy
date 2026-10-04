const std = @import("std");

pub fn load(comptime D: type, input: []const D.Lane) D.Vector {
    std.debug.assert(input.len >= D.lane_count);
    return @as(D.Vector, input[0..D.lane_count].*);
}

pub fn store(comptime D: type, value: D.Vector, output: []D.Lane) void {
    std.debug.assert(output.len >= D.lane_count);
    output[0..D.lane_count].* = value;
}

pub fn loadN(comptime D: type, input: []const D.Lane, count: usize) D.Vector {
    const lanes = @min(count, D.lane_count);
    std.debug.assert(input.len >= lanes);
    var result: D.Vector = @splat(0);
    inline for (0..D.lane_count) |index| {
        if (index < lanes) result[index] = input[index];
    }
    return result;
}

pub fn loadNOr(
    comptime D: type,
    inactive: D.Vector,
    input: []const D.Lane,
    count: usize,
) D.Vector {
    const lanes = @min(count, D.lane_count);
    std.debug.assert(input.len >= lanes);
    var result = inactive;
    inline for (0..D.lane_count) |index| {
        if (index < lanes) result[index] = input[index];
    }
    return result;
}

pub fn storeN(
    comptime D: type,
    value: D.Vector,
    output: []D.Lane,
    count: usize,
) void {
    const lanes = @min(count, D.lane_count);
    std.debug.assert(output.len >= lanes);
    inline for (0..D.lane_count) |index| {
        if (index < lanes) output[index] = value[index];
    }
}

pub fn loadDup128(comptime D: type, input: []const D.Lane) D.Vector {
    const block_lanes = @min(D.lane_count, 16 / @sizeOf(D.Lane));
    std.debug.assert(input.len >= block_lanes);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| {
        result[index] = input[index % block_lanes];
    }
    return result;
}

pub fn maskedLoadOr(
    comptime D: type,
    inactive: D.Vector,
    mask: D.Mask,
    input: []const D.Lane,
) D.Vector {
    var result = inactive;
    inline for (0..D.lane_count) |index| {
        if (mask[index]) {
            std.debug.assert(index < input.len);
            result[index] = input[index];
        }
    }
    return result;
}

pub fn maskedLoad(
    comptime D: type,
    mask: D.Mask,
    input: []const D.Lane,
) D.Vector {
    return maskedLoadOr(D, @splat(0), mask, input);
}

pub fn insertIntoUpper(
    comptime D: type,
    input: []const D.Lane,
    value: D.Vector,
) D.Vector {
    const half = D.lane_count / 2;
    std.debug.assert(input.len >= half);
    var result = value;
    inline for (0..half) |index| result[index + half] = input[index];
    return result;
}

pub fn safeFillN(
    comptime D: type,
    count: usize,
    value: D.Lane,
    output: []D.Lane,
) void {
    const lanes = @min(count, D.lane_count);
    std.debug.assert(output.len >= lanes);
    for (output[0..lanes]) |*lane_value| lane_value.* = value;
}

pub fn safeCopyN(
    comptime D: type,
    count: usize,
    input: []const D.Lane,
    output: []D.Lane,
) void {
    const lanes = @min(count, D.lane_count);
    std.debug.assert(input.len >= lanes);
    std.debug.assert(output.len >= lanes);
    std.mem.copyForwards(D.Lane, output[0..lanes], input[0..lanes]);
}

pub fn truncateStore(comptime D: type, value: D.Vector, output: anytype) void {
    const OutputLane = outputLane(@TypeOf(output));
    if (comptime @typeInfo(D.Lane) != .int or @typeInfo(OutputLane) != .int or
        @typeInfo(D.Lane).int.signedness != .unsigned or
        @typeInfo(OutputLane).int.signedness != .unsigned or
        @bitSizeOf(OutputLane) >= @bitSizeOf(D.Lane))
    {
        @compileError("truncateStore requires a narrower unsigned integer output");
    }
    std.debug.assert(output.len >= D.lane_count);
    inline for (0..D.lane_count) |index| output[index] = @truncate(value[index]);
}

pub fn stream(comptime D: type, value: D.Vector, output: []D.Lane) void {
    store(D, value, output);
}

pub fn blendedStore(
    comptime D: type,
    value: D.Vector,
    mask: D.Mask,
    output: []D.Lane,
) void {
    std.debug.assert(output.len >= D.lane_count);
    inline for (0..D.lane_count) |index| {
        if (mask[index]) output[index] = value[index];
    }
}

pub fn loadInterleaved2(comptime D: type, input: []const D.Lane) [2]D.Vector {
    std.debug.assert(input.len >= D.lane_count * 2);
    var result: [2]D.Vector = undefined;
    inline for (0..D.lane_count) |lane_index| {
        inline for (0..2) |vector_index| {
            result[vector_index][lane_index] = input[lane_index * 2 + vector_index];
        }
    }
    return result;
}

pub fn loadInterleaved3(comptime D: type, input: []const D.Lane) [3]D.Vector {
    std.debug.assert(input.len >= D.lane_count * 3);
    var result: [3]D.Vector = undefined;
    inline for (0..D.lane_count) |lane_index| {
        inline for (0..3) |vector_index| {
            result[vector_index][lane_index] = input[lane_index * 3 + vector_index];
        }
    }
    return result;
}

pub fn loadInterleaved4(comptime D: type, input: []const D.Lane) [4]D.Vector {
    std.debug.assert(input.len >= D.lane_count * 4);
    var result: [4]D.Vector = undefined;
    inline for (0..D.lane_count) |lane_index| {
        inline for (0..4) |vector_index| {
            result[vector_index][lane_index] = input[lane_index * 4 + vector_index];
        }
    }
    return result;
}

pub fn storeInterleaved2(
    comptime D: type,
    a: D.Vector,
    b: D.Vector,
    output: []D.Lane,
) void {
    std.debug.assert(output.len >= D.lane_count * 2);
    const values = [2]D.Vector{ a, b };
    inline for (0..D.lane_count) |lane_index| {
        inline for (0..2) |vector_index| {
            output[lane_index * 2 + vector_index] = values[vector_index][lane_index];
        }
    }
}

pub fn storeInterleaved3(
    comptime D: type,
    a: D.Vector,
    b: D.Vector,
    c: D.Vector,
    output: []D.Lane,
) void {
    std.debug.assert(output.len >= D.lane_count * 3);
    const values = [3]D.Vector{ a, b, c };
    inline for (0..D.lane_count) |lane_index| {
        inline for (0..3) |vector_index| {
            output[lane_index * 3 + vector_index] = values[vector_index][lane_index];
        }
    }
}

pub fn storeInterleaved4(
    comptime D: type,
    a: D.Vector,
    b: D.Vector,
    c: D.Vector,
    d: D.Vector,
    output: []D.Lane,
) void {
    std.debug.assert(output.len >= D.lane_count * 4);
    const values = [4]D.Vector{ a, b, c, d };
    inline for (0..D.lane_count) |lane_index| {
        inline for (0..4) |vector_index| {
            output[lane_index * 4 + vector_index] = values[vector_index][lane_index];
        }
    }
}

fn outputLane(comptime Output: type) type {
    return switch (@typeInfo(Output)) {
        .pointer => |info| switch (@typeInfo(info.child)) {
            .array => |array_info| array_info.child,
            else => info.child,
        },
        else => @compileError("truncateStore output must be a slice or pointer"),
    };
}

test "full load and store preserve every lane" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u32, 4);
    const input = [_]u32{ 1, 2, 3, 4 };
    var output = [_]u32{ 0, 0, 0, 0 };
    store(D, load(D, &input), &output);
    try std.testing.expectEqualSlices(u32, &input, &output);
}

test "partial and masked memory operations leave inactive lanes alone" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u16, 4);
    const input = [_]u16{ 1, 2, 3, 4 };
    const loaded = loadNOr(D, @splat(9), &input, 2);
    const expected: D.Vector = .{ 1, 2, 9, 9 };
    try std.testing.expect(@reduce(.And, loaded == expected));

    var output = [_]u16{ 7, 7, 7, 7 };
    const mask: D.Mask = .{ true, false, true, false };
    blendedStore(D, load(D, &input), mask, &output);
    try std.testing.expectEqualSlices(u16, &.{ 1, 7, 3, 7 }, &output);
}

test "Highway bounded memory clamps counts and duplicates 128-bit blocks" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u32, 8);
    const input = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expect(@reduce(.And, loadN(D, &input, 99) == @as(D.Vector, input)));
    try std.testing.expect(@reduce(.And, loadDup128(D, &input) ==
        @as(D.Vector, .{ 1, 2, 3, 4, 1, 2, 3, 4 })));
    const mask: D.Mask = .{ true, false, true, false, false, false, false, false };
    try std.testing.expect(@reduce(.And, maskedLoadOr(D, @splat(9), mask, input[0..3]) ==
        @as(D.Vector, .{ 1, 9, 3, 9, 9, 9, 9, 9 })));
    try std.testing.expect(@reduce(.And, insertIntoUpper(D, input[0..4], @splat(7)) ==
        @as(D.Vector, .{ 7, 7, 7, 7, 1, 2, 3, 4 })));
}

test "Highway safe copy fill and truncated store preserve bounds" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u16, 4);
    const input = [_]u16{ 1, 2, 3, 4 };
    var output = [_]u16{ 9, 9, 9, 9, 9 };
    safeCopyN(D, 2, &input, &output);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 9, 9, 9 }, &output);
    safeFillN(D, 99, 6, &output);
    try std.testing.expectEqualSlices(u16, &.{ 6, 6, 6, 6, 9 }, &output);
    var bytes: [4]u8 = undefined;
    truncateStore(D, @as(D.Vector, .{ 0x123, 0x2ff, 3, 4 }), &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x23, 0xff, 3, 4 }, &bytes);
}

fn verifyStream(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    var expected: [4]T = undefined;
    for (&expected, 0..) |*value, index| {
        value.* = switch (@typeInfo(T)) {
            .int => @intCast(index + 1),
            .float => @floatFromInt(index + 1),
            else => unreachable,
        };
    }
    var output: [8]T = @splat(0);
    stream(D, @as(D.Vector, expected), &output);
    simd.flushStream();
    try std.testing.expectEqualSlices(T, &expected, output[0..4]);
    try std.testing.expectEqualSlices(T, &@as([4]T, @splat(0)), output[4..]);
}

test "Highway vector stream preserves typed lanes and rounded bounds" {
    inline for (.{ u32, i32, u64, i64, f32, f64 }) |T| try verifyStream(T);
}

fn verifyInterleavedLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const zero: D.Vector = @splat(0);
    var output: [D.lane_count * 4]T = undefined;
    storeInterleaved4(D, zero, zero, zero, zero, &output);
    const loaded = loadInterleaved4(D, &output);
    inline for (loaded) |value| try std.testing.expect(@reduce(.And, value == zero));
}

test "Highway interleaved memory instantiates every lane type" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f16, f32, f64 }) |T| {
        try verifyInterleavedLaneType(T);
    }
}

test "Highway two three and four channel memory uses lane-major order" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u16, 4);
    const a: D.Vector = .{ 10, 11, 12, 13 };
    const b: D.Vector = .{ 20, 21, 22, 23 };
    const c: D.Vector = .{ 30, 31, 32, 33 };
    const d: D.Vector = .{ 40, 41, 42, 43 };

    var two: [8]u16 = undefined;
    storeInterleaved2(D, a, b, &two);
    try std.testing.expectEqualSlices(u16, &.{ 10, 20, 11, 21, 12, 22, 13, 23 }, &two);
    const loaded_two = loadInterleaved2(D, &two);
    try std.testing.expect(@reduce(.And, loaded_two[0] == a));
    try std.testing.expect(@reduce(.And, loaded_two[1] == b));

    var three: [12]u16 = undefined;
    storeInterleaved3(D, a, b, c, &three);
    try std.testing.expectEqualSlices(u16, &.{
        10, 20, 30, 11, 21, 31, 12, 22, 32, 13, 23, 33,
    }, &three);
    const loaded_three = loadInterleaved3(D, &three);
    try std.testing.expect(@reduce(.And, loaded_three[2] == c));

    var four: [16]u16 = undefined;
    storeInterleaved4(D, a, b, c, d, &four);
    try std.testing.expectEqualSlices(u16, &.{
        10, 20, 30, 40, 11, 21, 31, 41,
        12, 22, 32, 42, 13, 23, 33, 43,
    }, &four);
    const loaded_four = loadInterleaved4(D, &four);
    try std.testing.expect(@reduce(.And, loaded_four[3] == d));
}
