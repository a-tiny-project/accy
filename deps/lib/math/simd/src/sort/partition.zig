const std = @import("std");
const key = @import("key.zig");

pub const Bounds = struct {
    before: usize,
    after: usize,
};

pub fn around(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
    pivot: Key,
) Bounds {
    if (comptime !key.supported(Key)) @compileError("VQSort key type is not supported");
    var before: usize = 0;
    var scan: usize = 0;
    var after = values.len;
    var iterations: usize = 0;
    while (scan < after) : (iterations += 1) {
        std.debug.assert(iterations < values.len);
        if (key.before(Key, direction, values[scan], pivot)) {
            std.mem.swap(Key, &values[before], &values[scan]);
            before += 1;
            scan += 1;
        } else if (key.before(Key, direction, pivot, values[scan])) {
            after -= 1;
            std.mem.swap(Key, &values[scan], &values[after]);
        } else {
            scan += 1;
        }
    }
    std.debug.assert(before <= after);
    std.debug.assert(after <= values.len);
    return .{ .before = before, .after = after };
}

pub fn nanToBack(comptime Key: type, values: []Key) usize {
    if (comptime !key.supported(Key)) @compileError("VQSort key type is not supported");
    if (comptime floating(Key)) {
        var write: usize = 0;
        for (values) |value| {
            if (!std.math.isNan(value)) {
                values[write] = value;
                write += 1;
            }
        }
        @memset(values[write..], canonicalNaN(Key));
        return values.len - write;
    }
    return 0;
}

pub fn canonicalNaN(comptime Float: type) Float {
    if (comptime !floating(Float)) @compileError("canonical NaN requires a floating type");
    const UInt = @Int(.unsigned, @bitSizeOf(Float));
    const bits: UInt = std.math.maxInt(UInt) >> 1;
    return @bitCast(bits);
}

fn floating(comptime Key: type) bool {
    return switch (@typeInfo(Key)) {
        .float => true,
        else => false,
    };
}

fn Order(comptime Key: type, comptime direction: key.Direction) type {
    return struct {
        fn lessThan(_: void, a: Key, b: Key) bool {
            return key.networkBefore(Key, direction, a, b);
        }
    };
}

test "Highway VQSort partition preserves red zones counts and boundaries" {
    var storage = [_]u32{
        0xa55a_5aa5,
        7,
        2,
        9,
        4,
        4,
        1,
        8,
        4,
        3,
        0x5aa5_a55a,
    };
    const original = storage;
    const bounds = around(u32, .ascending, storage[1 .. storage.len - 1], 4);
    try std.testing.expectEqual(@as(usize, 3), bounds.before);
    try std.testing.expectEqual(@as(usize, 6), bounds.after);
    for (storage[1 .. bounds.before + 1]) |value| try std.testing.expect(value < 4);
    for (storage[bounds.before + 1 .. bounds.after + 1]) |value| {
        try std.testing.expectEqual(@as(u32, 4), value);
    }
    for (storage[bounds.after + 1 .. storage.len - 1]) |value| try std.testing.expect(value > 4);
    try std.testing.expectEqual(original[0], storage[0]);
    try std.testing.expectEqual(original[original.len - 1], storage[storage.len - 1]);
    var expected = original[1 .. original.len - 1].*;
    var actual = storage[1 .. storage.len - 1].*;
    std.mem.sort(u32, &expected, {}, Order(u32, .ascending).lessThan);
    std.mem.sort(u32, &actual, {}, Order(u32, .ascending).lessThan);
    try std.testing.expectEqualSlices(u32, &expected, &actual);
}

test "Highway VQSort partition treats record values as equivalent keys" {
    var values = [_]key.K32V32{
        key.K32V32.init(7, 9),
        key.K32V32.init(3, 8),
        key.K32V32.init(7, 1),
        key.K32V32.init(11, 4),
        key.K32V32.init(7, 5),
    };
    const bounds = around(key.K32V32, .ascending, &values, key.K32V32.init(7, 0));
    try std.testing.expectEqual(@as(usize, 1), bounds.before);
    try std.testing.expectEqual(@as(usize, 4), bounds.after);
    for (values[bounds.before..bounds.after]) |value| try std.testing.expectEqual(@as(u32, 7), value.key);
}

test "Highway VQSort NaN compaction retains infinities and canonicalizes the tail" {
    const payload_nan: f32 = @bitCast(@as(u32, 0x7fc0_1234));
    var values = [_]f32{ 3, payload_nan, std.math.inf(f32), -4, std.math.nan(f32), -std.math.inf(f32) };
    try std.testing.expectEqual(@as(usize, 2), nanToBack(f32, &values));
    try std.testing.expectEqualSlices(f32, &[_]f32{ 3, std.math.inf(f32), -4, -std.math.inf(f32) }, values[0..4]);
    const canonical_bits: u32 = @bitCast(canonicalNaN(f32));
    for (values[4..]) |value| try std.testing.expectEqual(canonical_bits, @as(u32, @bitCast(value)));

    var integers = [_]u64{ 3, 1, 2 };
    const expected = integers;
    try std.testing.expectEqual(@as(usize, 0), nanToBack(u64, &integers));
    try std.testing.expectEqualSlices(u64, &expected, &integers);
}
