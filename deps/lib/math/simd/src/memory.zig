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

fn verifyInterleavedLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const zero: D.Vector = @splat(0);
    var output: [D.lane_count * 4]T = undefined;
    storeInterleaved4(D, zero, zero, zero, zero, &output);
    const loaded = loadInterleaved4(D, &output);
    inline for (loaded) |value| try std.testing.expect(@reduce(.And, value == zero));
}
