const std = @import("std");

pub fn tableLookupBytes(comptime D: type, table: anytype, indices: D.Vector) D.Vector {
    return lookupBytes(D, false, table, indices);
}

pub fn tableLookupBytesOr0(comptime D: type, table: anytype, indices: D.Vector) D.Vector {
    return lookupBytes(D, true, table, indices);
}

pub fn bitShuffle(comptime D: type, values: D.Vector, indices: anytype) D.Vector {
    if (D.Lane != u64 and D.Lane != i64) @compileError("bitShuffle requires 64-bit integer lanes");
    const index_info = vectorInfo(@TypeOf(indices));
    if (@typeInfo(index_info.child) != .int or @bitSizeOf(index_info.child) != 8) {
        @compileError("bitShuffle indices require 8-bit integer lanes");
    }
    if (index_info.len != D.lane_count * 8) @compileError("bitShuffle requires eight indices per lane");
    const value_lanes: [D.lane_count]D.Lane = @bitCast(values);
    const index_lanes: [index_info.len]index_info.child = @bitCast(indices);
    var result: [D.lane_count]u64 = @splat(0);
    inline for (0..D.lane_count) |lane| {
        const bits: u64 = @bitCast(value_lanes[lane]);
        inline for (0..8) |bit| {
            const index = checkedIndex(index_lanes[lane * 8 + bit]);
            std.debug.assert(index < 64);
            result[lane] |= ((bits >> @intCast(index)) & 1) << bit;
        }
    }
    return @bitCast(result);
}

pub fn indicesFromVec(comptime D: type, indices: anytype) @TypeOf(indices) {
    const info = vectorInfo(@TypeOf(indices));
    if (info.len < D.lane_count or @typeInfo(info.child) != .int or
        @bitSizeOf(info.child) != @bitSizeOf(D.Lane))
    {
        @compileError("table indices require enough integer lanes matching the table lane width");
    }
    return indices;
}

pub fn setTableIndices(
    comptime D: type,
    input: []const indexLane(D),
) D.rebind(indexLane(D)).Vector {
    std.debug.assert(input.len >= D.lane_count);
    return @as(D.rebind(indexLane(D)).Vector, input[0..D.lane_count].*);
}

pub fn tableLookupLanes(comptime D: type, table: D.Vector, indices: anytype) D.Vector {
    const index_info = validateLaneIndices(D, @TypeOf(indices));
    const table_lanes: [D.lane_count]D.Lane = @bitCast(table);
    const index_lanes: [index_info.len]index_info.child = @bitCast(indices);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |lane| {
        const index = checkedIndex(index_lanes[lane]);
        std.debug.assert(index < D.lane_count);
        result[lane] = table_lanes[index];
    }
    return @bitCast(result);
}

pub fn twoTablesLookupLanes(
    comptime D: type,
    first: D.Vector,
    second: D.Vector,
    indices: anytype,
) D.Vector {
    const index_info = validateLaneIndices(D, @TypeOf(indices));
    const first_lanes: [D.lane_count]D.Lane = @bitCast(first);
    const second_lanes: [D.lane_count]D.Lane = @bitCast(second);
    const index_lanes: [index_info.len]index_info.child = @bitCast(indices);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |lane| {
        const index = checkedIndex(index_lanes[lane]);
        std.debug.assert(index < D.lane_count * 2);
        result[lane] = if (index < D.lane_count)
            first_lanes[index]
        else
            second_lanes[index - D.lane_count];
    }
    return @bitCast(result);
}

pub fn lookup8(comptime D: type, table: []const D.Lane, indices: anytype) D.Vector {
    return lookupN(D, 8, table, indices);
}

pub fn lookup16(comptime D: type, table: []const D.Lane, indices: anytype) D.Vector {
    return lookupN(D, 16, table, indices);
}

pub fn lookup32(comptime D: type, table: []const D.Lane, indices: anytype) D.Vector {
    return lookupN(D, 32, table, indices);
}

pub fn canLookup8(comptime D: type) bool {
    _ = D;
    return true;
}

pub fn canLookup16(comptime D: type) bool {
    _ = D;
    return true;
}

pub fn canLookup32(comptime D: type) bool {
    _ = D;
    return true;
}

fn lookupBytes(comptime D: type, comptime or_zero: bool, table: anytype, indices: D.Vector) D.Vector {
    if (@typeInfo(D.Lane) != .int) @compileError("byte table indices require integer vectors");
    const table_type = @TypeOf(table);
    const table_info = vectorInfo(table_type);
    if (@typeInfo(table_info.child) != .int) @compileError("byte lookup tables require integer vectors");
    const table_byte_count = @bitSizeOf(table_type) / 8;
    if (table_byte_count == 0) @compileError("byte lookup table cannot be empty");
    const table_bytes: [table_byte_count]u8 = @bitCast(table);
    const index_bytes: [D.byte_count]u8 = @bitCast(indices);
    var result: [D.byte_count]u8 = undefined;
    inline for (0..D.byte_count) |index| {
        const requested = index_bytes[index];
        if (or_zero and requested & 0x80 != 0) {
            result[index] = 0;
        } else {
            const block = index / 16 * 16;
            result[index] = table_bytes[(block + requested) % @min(table_byte_count, 256)];
        }
    }
    return @bitCast(result);
}

fn lookupN(
    comptime D: type,
    comptime table_size: usize,
    table: []const D.Lane,
    indices: anytype,
) D.Vector {
    const index_info = validateLaneIndices(D, @TypeOf(indices));
    std.debug.assert(table.len >= table_size);
    const index_lanes: [index_info.len]index_info.child = @bitCast(indices);
    var result: [D.lane_count]D.Lane = undefined;
    inline for (0..D.lane_count) |lane| {
        const index = checkedIndex(index_lanes[lane]);
        std.debug.assert(index < table_size);
        result[lane] = table[index];
    }
    return @bitCast(result);
}

fn validateLaneIndices(comptime D: type, comptime T: type) @TypeOf(vectorInfo(T)) {
    const info = vectorInfo(T);
    if (@typeInfo(info.child) != .int or info.len < D.lane_count or
        @bitSizeOf(info.child) != @bitSizeOf(D.Lane))
    {
        @compileError("lane lookup indices require enough same-width integer lanes");
    }
    return info;
}

fn vectorInfo(comptime T: type) std.builtin.Type.Vector {
    return switch (@typeInfo(T)) {
        .vector => |info| info,
        else => @compileError("table operation requires a vector"),
    };
}

fn checkedIndex(value: anytype) usize {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T).int.signedness == .signed) std.debug.assert(value >= 0);
    return @intCast(value);
}

fn indexLane(comptime D: type) type {
    return @Int(.unsigned, @bitSizeOf(D.Lane));
}

test "Highway byte table lookup is block-local and optionally zeroes high-bit indices" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u8, 32);
    const table = simd.iota(D, 1);
    const indices: D.Vector = .{
        15, 0, 2, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 1,
        15, 0, 2, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 1,
    };
    try std.testing.expect(@reduce(.And, tableLookupBytes(D, table, indices) == @as(D.Vector, .{
        16, 1,  3,  3,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 2,
        32, 17, 19, 19, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 18,
    })));
    var zero_indices = indices;
    zero_indices[3] = 0x82;
    zero_indices[20] = 0x90;
    const zeroed = tableLookupBytesOr0(D, table, zero_indices);
    try std.testing.expectEqual(@as(u8, 0), zeroed[3]);
    try std.testing.expectEqual(@as(u8, 0), zeroed[20]);
}

test "Highway lane tables gather across the full vector and two tables" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f32, 8);
    const I = D.rebind(u32);
    const first: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const second: D.Vector = .{ 8, 9, 10, 11, 12, 13, 14, 15 };
    const indices: I.Vector = .{ 7, 0, 5, 2, 4, 1, 6, 3 };
    try std.testing.expect(@reduce(.And, tableLookupLanes(D, first, indices) ==
        @as(D.Vector, .{ 7, 0, 5, 2, 4, 1, 6, 3 })));
    const both: I.Vector = .{ 15, 0, 9, 2, 12, 1, 14, 3 };
    try std.testing.expect(@reduce(.And, twoTablesLookupLanes(D, first, second, both) ==
        @as(D.Vector, .{ 15, 0, 9, 2, 12, 1, 14, 3 })));
}

test "Highway fixed table lookups and bit shuffle match scalar indexing" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u16, 8);
    const I = D.rebind(u16);
    const table = [_]u16{ 10, 11, 12, 13, 14, 15, 16, 17 };
    const indices: I.Vector = .{ 7, 0, 6, 1, 5, 2, 4, 3 };
    try std.testing.expect(@reduce(.And, lookup8(D, &table, indices) == @as(D.Vector, .{
        17, 10, 16, 11, 15, 12, 14, 13,
    })));

    const B = simd.FixedTag(u64, 2);
    const BI = B.repartition(u8);
    const values: B.Vector = .{ 0x8000_0000_0000_0001, 0x0123_4567_89ab_cdef };
    const bit_indices: BI.Vector = .{ 0, 63, 1, 62, 2, 61, 3, 60, 0, 4, 8, 12, 16, 20, 24, 28 };
    try std.testing.expect(@reduce(.And, bitShuffle(B, values, bit_indices) == @as(B.Vector, .{ 3, 0x55 })));
}

fn verifyTableLaneType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const I = D.rebind(@Int(.unsigned, @bitSizeOf(T)));
    const value: D.Vector = @splat(0);
    const indices: I.Vector = .{ 3, 2, 1, 0 };
    try std.testing.expect(@reduce(.And, tableLookupLanes(D, value, indicesFromVec(D, indices)) == value));
    const source = [_]I.Lane{ 3, 2, 1, 0 };
    try std.testing.expect(@reduce(.And, setTableIndices(D, &source) == indices));
}

test "Highway lane table setup instantiates every lane type" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f16, f32, f64 }) |T| {
        try verifyTableLaneType(T);
    }
}

test "Highway mixed byte tables and sixteen and thirty-two element gathers retain bits" {
    const simd = @import("root.zig");
    const Table = simd.FixedTag(u8, 16);
    const D = simd.FixedTag(u32, 2);
    const table = simd.iota(Table, 1);
    const index_bytes = [8]u8{ 15, 0, 2, 1, 7, 6, 5, 4 };
    const indices: D.Vector = @bitCast(index_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 16, 1, 3, 2, 8, 7, 6, 5 }, &@as([8]u8, @bitCast(tableLookupBytes(D, table, indices))));

    const G = simd.FixedTag(u8, 16);
    var table32: [32]u8 = undefined;
    for (0..32) |index| table32[index] = @intCast(index + 10);
    const indices16: G.Vector = .{ 15, 0, 14, 1, 13, 2, 12, 3, 11, 4, 10, 5, 9, 6, 8, 7 };
    try std.testing.expectEqual(@as(u8, 25), lookup16(G, table32[0..16], indices16)[0]);
    const indices32: G.Vector = .{ 31, 16, 30, 17, 29, 18, 28, 19, 27, 20, 26, 21, 25, 22, 24, 23 };
    try std.testing.expectEqual(@as(u8, 41), lookup32(G, &table32, indices32)[0]);
    try std.testing.expect(canLookup8(G) and canLookup16(G) and canLookup32(G));
}
