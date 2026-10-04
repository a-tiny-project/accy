const std = @import("std");

pub fn scatterIndex(
    comptime D: type,
    value: D.Vector,
    base: []D.Lane,
    indices: anytype,
) void {
    validateIndices(D, @TypeOf(indices));
    inline for (0..D.lane_count) |lane_index| {
        const destination = checkedIndex(indices[lane_index]);
        std.debug.assert(destination < base.len);
        base[destination] = value[lane_index];
    }
}

pub fn scatterIndexN(
    comptime D: type,
    value: D.Vector,
    base: []D.Lane,
    indices: anytype,
    count: usize,
) void {
    validateIndices(D, @TypeOf(indices));
    const lanes = @min(count, D.lane_count);
    inline for (0..D.lane_count) |lane_index| {
        if (lane_index < lanes) {
            const destination = checkedIndex(indices[lane_index]);
            std.debug.assert(destination < base.len);
            base[destination] = value[lane_index];
        }
    }
}

pub fn maskedScatterIndex(
    comptime D: type,
    value: D.Vector,
    mask: D.Mask,
    base: []D.Lane,
    indices: anytype,
) void {
    validateIndices(D, @TypeOf(indices));
    inline for (0..D.lane_count) |lane_index| {
        if (mask[lane_index]) {
            const destination = checkedIndex(indices[lane_index]);
            std.debug.assert(destination < base.len);
            base[destination] = value[lane_index];
        }
    }
}

pub fn scatterOffset(
    comptime D: type,
    value: D.Vector,
    base: []D.Lane,
    offsets: anytype,
) void {
    validateIndices(D, @TypeOf(offsets));
    inline for (0..D.lane_count) |lane_index| {
        const destination = offsetIndex(D.Lane, offsets[lane_index]);
        std.debug.assert(destination < base.len);
        base[destination] = value[lane_index];
    }
}

pub fn gatherIndex(comptime D: type, base: []const D.Lane, indices: anytype) D.Vector {
    validateIndices(D, @TypeOf(indices));
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |lane_index| {
        const source = checkedIndex(indices[lane_index]);
        std.debug.assert(source < base.len);
        result[lane_index] = base[source];
    }
    return result;
}

pub fn gatherIndexN(
    comptime D: type,
    base: []const D.Lane,
    indices: anytype,
    count: usize,
) D.Vector {
    return gatherIndexNOr(D, @splat(0), base, indices, count);
}

pub fn gatherIndexNOr(
    comptime D: type,
    inactive: D.Vector,
    base: []const D.Lane,
    indices: anytype,
    count: usize,
) D.Vector {
    const lanes = @min(count, D.lane_count);
    var mask: D.Mask = @splat(false);
    inline for (0..D.lane_count) |index| mask[index] = index < lanes;
    return maskedGatherIndexOr(D, inactive, mask, base, indices);
}

pub fn maskedGatherIndexOr(
    comptime D: type,
    inactive: D.Vector,
    mask: D.Mask,
    base: []const D.Lane,
    indices: anytype,
) D.Vector {
    validateIndices(D, @TypeOf(indices));
    var result = inactive;
    inline for (0..D.lane_count) |lane_index| {
        if (mask[lane_index]) {
            const source = checkedIndex(indices[lane_index]);
            std.debug.assert(source < base.len);
            result[lane_index] = base[source];
        }
    }
    return result;
}

pub fn maskedGatherIndex(
    comptime D: type,
    mask: D.Mask,
    base: []const D.Lane,
    indices: anytype,
) D.Vector {
    return maskedGatherIndexOr(D, @splat(0), mask, base, indices);
}

pub fn gatherOffset(comptime D: type, base: []const D.Lane, offsets: anytype) D.Vector {
    validateIndices(D, @TypeOf(offsets));
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |lane_index| {
        const source = offsetIndex(D.Lane, offsets[lane_index]);
        std.debug.assert(source < base.len);
        result[lane_index] = base[source];
    }
    return result;
}

fn checkedIndex(value: anytype) usize {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) != .int) @compileError("indices must be integers");
    if (comptime @typeInfo(T).int.signedness == .signed) std.debug.assert(value >= 0);
    return @intCast(value);
}

fn offsetIndex(comptime T: type, offset: anytype) usize {
    const bytes = checkedIndex(offset);
    std.debug.assert(bytes % @sizeOf(T) == 0);
    return bytes / @sizeOf(T);
}

fn validateIndices(comptime D: type, comptime V: type) void {
    if (comptime @typeInfo(V) != .vector or @typeInfo(V).vector.len != D.lane_count or
        @typeInfo(@typeInfo(V).vector.child) != .int)
    {
        @compileError("indices must be an integer vector with one index per lane");
    }
}

test "Highway indexed gather and scatter use lane order and clamped counts" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u32, 4);
    const I = simd.FixedTag(i32, 4);
    const indices: I.Vector = .{ 3, 0, 5, 2 };
    const source = [_]u32{ 10, 11, 12, 13, 14, 15 };
    try std.testing.expect(@reduce(.And, gatherIndex(D, &source, indices) ==
        @as(D.Vector, .{ 13, 10, 15, 12 })));
    try std.testing.expect(@reduce(.And, gatherIndexN(D, &source, indices, 2) ==
        @as(D.Vector, .{ 13, 10, 0, 0 })));
    var output = [_]u32{ 0, 0, 0, 0, 0, 0 };
    scatterIndexN(D, .{ 1, 2, 3, 4 }, &output, indices, 3);
    try std.testing.expectEqualSlices(u32, &.{ 2, 0, 0, 1, 0, 3 }, &output);
}

test "Highway masked and byte-offset memory avoids inactive indices" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f64, 2);
    const I = simd.FixedTag(i64, 2);
    const source = [_]f64{ 1, 2, 3, 4 };
    const mask: D.Mask = .{ true, false };
    const indices: I.Vector = .{ 2, -1 };
    try std.testing.expect(@reduce(.And, maskedGatherIndexOr(D, @splat(9), mask, &source, indices) ==
        @as(D.Vector, .{ 3, 9 })));
    const offsets: I.Vector = .{ 24, 0 };
    try std.testing.expect(@reduce(.And, gatherOffset(D, &source, offsets) ==
        @as(D.Vector, .{ 4, 1 })));
    var output = [_]f64{ 0, 0, 0, 0 };
    scatterOffset(D, .{ 7, 8 }, &output, offsets);
    try std.testing.expectEqualSlices(f64, &.{ 8, 0, 0, 7 }, &output);
}
