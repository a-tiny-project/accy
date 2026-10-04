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
