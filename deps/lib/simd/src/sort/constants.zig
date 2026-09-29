const std = @import("std");
const key = @import("key.zig");

pub const maximum_vector_bytes: usize = 64;
pub const maximum_columns: usize = 16;
pub const maximum_rows: usize = 16;
pub const partition_unroll: usize = 4;
pub const maximum_buffer_bytes: usize = 1664;

pub fn lanesPerKey(comptime Key: type) usize {
    if (Key == u128 or Key == key.K64V64) return 2;
    return 1;
}

pub fn Lane(comptime Key: type) type {
    if (Key == key.K32V32) return u64;
    if (Key == u128 or Key == key.K64V64) return u64;
    return Key;
}

pub fn lanesPerChunk(comptime LaneType: type) usize {
    std.debug.assert(@sizeOf(LaneType) >= 2);
    std.debug.assert(@sizeOf(LaneType) <= 8);
    std.debug.assert(64 % @sizeOf(LaneType) == 0);
    return 64 / @sizeOf(LaneType);
}

pub fn sampleLanes(comptime LaneType: type) usize {
    return 2 * lanesPerChunk(LaneType);
}

pub fn baseCaseNumLanes(lanes_per_key: usize, vector_lanes: usize) usize {
    std.debug.assert(lanes_per_key >= 1);
    std.debug.assert(lanes_per_key <= 2);
    std.debug.assert(vector_lanes >= lanes_per_key);
    const rows = if (vector_lanes / lanes_per_key >= 4) maximum_rows else 8;
    return rows * @min(vector_lanes, maximum_columns);
}

pub fn partitionBufferLanes(vector_lanes: usize) usize {
    std.debug.assert(vector_lanes >= 1);
    return 2 * (3 * partition_unroll + 1) * vector_lanes;
}

pub fn bufferLanes(
    comptime LaneType: type,
    lanes_per_key: usize,
    vector_lanes: usize,
) usize {
    const base = sampleLanes(LaneType) +
        baseCaseNumLanes(lanes_per_key, vector_lanes) + vector_lanes;
    return @max(base, partitionBufferLanes(vector_lanes));
}

pub fn bufferBytes(
    comptime LaneType: type,
    lanes_per_key: usize,
    vector_bytes: usize,
) usize {
    std.debug.assert(vector_bytes >= @sizeOf(LaneType));
    std.debug.assert(vector_bytes % @sizeOf(LaneType) == 0);
    return bufferLanes(
        LaneType,
        lanes_per_key,
        vector_bytes / @sizeOf(LaneType),
    ) * @sizeOf(LaneType);
}

pub fn maximumBufferBytes(lanes_per_key: usize, vector_bytes: usize) usize {
    if (lanes_per_key == 2) return bufferBytes(u64, 2, vector_bytes);
    return @max(
        bufferBytes(u16, 1, vector_bytes),
        @max(
            bufferBytes(u32, 1, vector_bytes),
            bufferBytes(u64, 1, vector_bytes),
        ),
    );
}

pub fn baseCaseKeyCapacity(comptime Key: type) usize {
    if (comptime !key.supported(Key)) @compileError("VQSort key type is not supported");
    const LaneType = Lane(Key);
    const lanes_per_key = lanesPerKey(Key);
    const vector_lanes = maximum_vector_bytes / @sizeOf(LaneType);
    return baseCaseNumLanes(lanes_per_key, vector_lanes) / lanes_per_key;
}

comptime {
    std.debug.assert(maximumBufferBytes(1, maximum_vector_bytes) == maximum_buffer_bytes);
    std.debug.assert(maximumBufferBytes(2, maximum_vector_bytes) == maximum_buffer_bytes);
}

test "Highway sort capacities preserve the 1664 byte bound" {
    try std.testing.expectEqual(@as(usize, 1664), bufferBytes(u16, 1, 64));
    try std.testing.expectEqual(@as(usize, 1664), bufferBytes(u32, 1, 64));
    try std.testing.expectEqual(@as(usize, 1664), bufferBytes(u64, 1, 64));
    try std.testing.expectEqual(@as(usize, 1664), bufferBytes(u64, 2, 64));
    try std.testing.expectEqual(@as(usize, 256), baseCaseKeyCapacity(u16));
    try std.testing.expectEqual(@as(usize, 256), baseCaseKeyCapacity(u32));
    try std.testing.expectEqual(@as(usize, 128), baseCaseKeyCapacity(u64));
    try std.testing.expectEqual(@as(usize, 128), baseCaseKeyCapacity(key.K32V32));
    try std.testing.expectEqual(@as(usize, 64), baseCaseKeyCapacity(u128));
    try std.testing.expectEqual(@as(usize, 64), baseCaseKeyCapacity(key.K64V64));
}
