const std = @import("std");
const constants = @import("constants.zig");
const heap = @import("heap.zig");
const key = @import("key.zig");
const network = @import("network.zig");
const partition = @import("partition.zig");
const pivot = @import("pivot.zig");
const random = @import("random.zig");
const sort = @import("root.zig");
const vq = @import("vq.zig");

const K32V32 = sort.K32V32;
const K64V64 = sort.K64V64;

test {
    _ = constants;
    _ = heap;
    _ = key;
    _ = network;
    _ = partition;
    _ = pivot;
    _ = random;
    _ = vq;
}

fn fold(digest: u64, value: anytype) u64 {
    return (digest ^ @as(u64, @intCast(value))) *% 0x0000_0100_0000_01b3;
}

fn mix(input: u64) u64 {
    var value = input;
    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
    return value ^ (value >> 31);
}

fn foldSmallOracle(digest: *u64, scratch: *network.Scratch) !void {
    var u16_values: [256]u16 = undefined;
    var i16_values: [256]i16 = undefined;
    var u32_values: [256]u32 = undefined;
    var i32_values: [256]i32 = undefined;
    var f32_values: [256]f32 = undefined;
    for (0..256) |index| {
        u16_values[index] = @truncate(index * 73 + 19);
        i16_values[index] = @bitCast(@as(u16, @truncate(mix(index + 11))));
        u32_values[index] = @truncate(mix(index + 23));
        i32_values[index] = @bitCast(@as(u32, @truncate(mix(index + 37))));
        const integer: i32 = @intCast(index * 73 % 257);
        f32_values[index] = @floatFromInt(integer - 128);
    }
    f32_values[31] = std.math.inf(f32);
    f32_values[191] = -std.math.inf(f32);
    try network.sort(u16, .ascending, &u16_values, scratch);
    try network.sort(i16, .descending, &i16_values, scratch);
    try network.sort(u32, .ascending, &u32_values, scratch);
    try network.sort(i32, .descending, &i32_values, scratch);
    try network.sort(f32, .ascending, &f32_values, scratch);
    for (0..256) |index| {
        digest.* = fold(digest.*, u16_values[index]);
        digest.* = fold(digest.*, @as(u16, @bitCast(i16_values[index])));
        digest.* = fold(digest.*, u32_values[index]);
        digest.* = fold(digest.*, @as(u32, @bitCast(i32_values[index])));
        digest.* = fold(digest.*, @as(u32, @bitCast(f32_values[index])));
    }
}

fn foldMediumOracle(digest: *u64, scratch: *network.Scratch) !void {
    var u64_values: [128]u64 = undefined;
    var i64_values: [128]i64 = undefined;
    var f64_values: [128]f64 = undefined;
    var kv32_values: [128]K32V32 = undefined;
    for (0..128) |index| {
        u64_values[index] = mix(index + 41);
        i64_values[index] = @bitCast(mix(index + 53));
        const integer: i32 = @intCast(index * 67 % 131);
        f64_values[index] = @floatFromInt(integer - 65);
        kv32_values[index] = .{
            .value = @truncate(mix(index + 67)),
            .key = @intCast(index * 97 + 3),
        };
    }
    f64_values[17] = std.math.inf(f64);
    f64_values[93] = -std.math.inf(f64);
    try network.sort(u64, .ascending, &u64_values, scratch);
    try network.sort(i64, .descending, &i64_values, scratch);
    try network.sort(f64, .descending, &f64_values, scratch);
    try network.sort(K32V32, .ascending, &kv32_values, scratch);
    for (0..128) |index| {
        digest.* = fold(digest.*, u64_values[index]);
        digest.* = fold(digest.*, @as(u64, @bitCast(i64_values[index])));
        digest.* = fold(digest.*, @as(u64, @bitCast(f64_values[index])));
        digest.* = fold(digest.*, kv32_values[index].value);
        digest.* = fold(digest.*, kv32_values[index].key);
    }
}

fn foldWideOracle(digest: *u64, scratch: *network.Scratch) !void {
    var u128_values: [64]u128 = undefined;
    var kv64_values: [64]K64V64 = undefined;
    for (0..64) |index| {
        const low: u128 = mix(index + 71);
        const high: u128 = mix(index + 83);
        u128_values[index] = low | (high << 64);
        kv64_values[index] = .{
            .value = mix(index + 97),
            .key = mix(index + 109),
        };
    }
    try network.sort(u128, .descending, &u128_values, scratch);
    try network.sort(K64V64, .ascending, &kv64_values, scratch);
    for (0..64) |index| {
        digest.* = fold(digest.*, @as(u64, @truncate(u128_values[index])));
        digest.* = fold(digest.*, @as(u64, @truncate(u128_values[index] >> 64)));
        digest.* = fold(digest.*, kv64_values[index].value);
        digest.* = fold(digest.*, kv64_values[index].key);
    }
}

fn pinnedOracleDigest() !u64 {
    var digest: u64 = 0xcbf2_9ce4_8422_2325;
    digest = fold(digest, constants.maximumBufferBytes(1, 64));
    digest = fold(digest, constants.maximumBufferBytes(2, 64));
    var state = [3]u64{ 0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210, 1 };
    for (0..16) |_| digest = fold(digest, random.randomBits(&state));
    var count: u32 = 1;
    while (count <= 257) : (count += 16) {
        const bits: u32 = @truncate(mix(count));
        digest = fold(digest, random.chunkIndex(count, bits));
    }
    var scratch = network.Scratch{};
    try foldSmallOracle(&digest, &scratch);
    try foldMediumOracle(&digest, &scratch);
    try foldWideOracle(&digest, &scratch);
    return digest;
}

test "pinned Highway VQSort foundation oracle agrees across all key families" {
    try std.testing.expectEqual(@as(u64, 7_536_285_086_982_434_547), try pinnedOracleDigest());
}
