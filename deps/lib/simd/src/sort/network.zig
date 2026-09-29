const std = @import("std");
const constants = @import("constants.zig");
const key = @import("key.zig");

pub const Error = error{
    TooManyKeys,
    InvalidKey,
};

pub const Scratch = struct {
    bytes: [constants.maximum_buffer_bytes]u8 align(64) = undefined,
};

pub fn sort(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
    scratch: *Scratch,
) Error!void {
    const capacity = comptime constants.baseCaseKeyCapacity(Key);
    if (values.len > capacity) return error.TooManyKeys;
    for (values) |value| {
        if (!key.validForNetwork(Key, value)) return error.InvalidKey;
    }
    if (values.len < 2) return;
    const padded = powerOfTwoCeiling(values.len, capacity);
    const buffer = scratchBuffer(Key, capacity, scratch);
    @memcpy(buffer[0..values.len], values);
    @memset(buffer[values.len..padded], key.lastValue(Key, direction));
    bitonic(Key, direction, buffer[0..padded]);
    @memcpy(values, buffer[0..values.len]);
}

fn scratchBuffer(
    comptime Key: type,
    comptime capacity: usize,
    scratch: *Scratch,
) *[capacity]Key {
    comptime std.debug.assert(capacity * @sizeOf(Key) <= constants.maximum_buffer_bytes);
    return @ptrCast(&scratch.bytes);
}

fn powerOfTwoCeiling(count: usize, capacity: usize) usize {
    std.debug.assert(count >= 2);
    std.debug.assert(count <= capacity);
    var result: usize = 2;
    var iterations: usize = 0;
    while (result < count) : (iterations += 1) {
        std.debug.assert(iterations < 8);
        result *= 2;
    }
    std.debug.assert(result <= capacity);
    return result;
}

fn bitonic(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
) void {
    std.debug.assert(values.len >= 2);
    std.debug.assert(std.math.isPowerOfTwo(values.len));
    var span: usize = 2;
    var span_iterations: usize = 0;
    while (span <= values.len) : (span *= 2) {
        std.debug.assert(span_iterations < 8);
        var distance = span / 2;
        var distance_iterations: usize = 0;
        while (distance != 0) : (distance /= 2) {
            std.debug.assert(distance_iterations < 8);
            for (0..values.len) |left| {
                const right = left ^ distance;
                if (right > left) compareExchange(
                    Key,
                    direction,
                    values,
                    left,
                    right,
                    left & span == 0,
                );
            }
            distance_iterations += 1;
        }
        span_iterations += 1;
        if (span == values.len) break;
    }
}

fn compareExchange(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
    left: usize,
    right: usize,
    forward: bool,
) void {
    std.debug.assert(left < right);
    std.debug.assert(right < values.len);
    const a = values[left];
    const b = values[right];
    const swap = if (forward)
        key.networkBefore(Key, direction, b, a)
    else
        key.networkBefore(Key, direction, a, b);
    if (swap) {
        values[left] = b;
        values[right] = a;
    }
}

fn Order(comptime Key: type, comptime direction: key.Direction) type {
    return struct {
        fn lessThan(_: void, a: Key, b: Key) bool {
            return key.networkBefore(Key, direction, a, b);
        }
    };
}

fn fillInteger(comptime Key: type, values: []Key) void {
    const UInt = @Int(.unsigned, @bitSizeOf(Key));
    var state: u64 = 0x9e37_79b9_7f4a_7c15;
    for (values, 0..) |*value, index| {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        const mixed = state *% 0x2545_f491_4f6c_dd1d +% index;
        const bits: UInt = @truncate(mixed);
        value.* = @bitCast(bits);
    }
}

fn verifyIntegerType(comptime Key: type) !void {
    const capacity = comptime constants.baseCaseKeyCapacity(Key);
    const lengths = [_]usize{ 0, 1, 3, capacity / 2 + 1, capacity - 1, capacity };
    inline for (.{ key.Direction.ascending, key.Direction.descending }) |direction| {
        for (lengths) |length| {
            var storage: [capacity + 2]Key = undefined;
            fillInteger(Key, storage[1 .. length + 1]);
            storage[0] = @bitCast(@as(@Int(.unsigned, @bitSizeOf(Key)), 0xa55a));
            storage[length + 1] = storage[0];
            var expected: [capacity]Key = undefined;
            @memcpy(expected[0..length], storage[1 .. length + 1]);
            std.mem.sort(Key, expected[0..length], {}, Order(Key, direction).lessThan);
            var scratch = Scratch{};
            try sort(Key, direction, storage[1 .. length + 1], &scratch);
            try std.testing.expectEqualSlices(Key, expected[0..length], storage[1 .. length + 1]);
            try std.testing.expectEqual(storage[0], storage[length + 1]);
        }
    }
}

test "Highway VQSort scratch capacity rejects before mutation" {
    var values = @as([(constants.baseCaseKeyCapacity(u64) + 1)]u64, @splat(17));
    const expected = values;
    var scratch = Scratch{};
    try std.testing.expectError(error.TooManyKeys, sort(u64, .ascending, &values, &scratch));
    try std.testing.expectEqualSlices(u64, &expected, &values);
    try std.testing.expectEqual(@as(usize, 1664), @sizeOf(Scratch));
    try std.testing.expectEqual(@as(usize, 64), @alignOf(Scratch));
}

test "Highway VQSort base networks preserve red zones and order" {
    try verifyIntegerType(u16);
    try verifyIntegerType(i16);
    try verifyIntegerType(u32);
    try verifyIntegerType(i32);
    try verifyIntegerType(u64);
    try verifyIntegerType(i64);
}

test "Highway VQSort base networks sort records and 128-bit keys" {
    const count = comptime constants.baseCaseKeyCapacity(key.K32V32);
    var values: [count]key.K32V32 = undefined;
    for (&values, 0..) |*value, index| {
        value.* = key.K32V32.init(@intCast((count - index) % 17), @intCast(index));
    }
    var expected = values;
    std.mem.sort(key.K32V32, &expected, {}, Order(key.K32V32, .ascending).lessThan);
    var scratch = Scratch{};
    try sort(key.K32V32, .ascending, &values, &scratch);
    try std.testing.expectEqualSlices(key.K32V32, &expected, &values);

    var wide: [constants.baseCaseKeyCapacity(u128)]u128 = undefined;
    fillInteger(u128, &wide);
    var wide_expected = wide;
    std.mem.sort(u128, &wide_expected, {}, Order(u128, .descending).lessThan);
    try sort(u128, .descending, &wide, &scratch);
    try std.testing.expectEqualSlices(u128, &wide_expected, &wide);
}

fn verifyFloatType(comptime Float: type) !void {
    const capacity = comptime constants.baseCaseKeyCapacity(Float);
    var values: [capacity]Float = undefined;
    for (&values, 0..) |*value, index| {
        const magnitude: Float = @floatFromInt(index + 1);
        value.* = if (index & 1 == 0) magnitude else -magnitude;
    }
    values[capacity / 3] = std.math.inf(Float);
    values[capacity * 2 / 3] = -std.math.inf(Float);
    var expected = values;
    std.mem.sort(Float, &expected, {}, Order(Float, .ascending).lessThan);
    var scratch = Scratch{};
    try sort(Float, .ascending, &values, &scratch);
    try std.testing.expectEqualSlices(Float, &expected, &values);
}

test "Highway VQSort base networks retain floating infinities" {
    try verifyFloatType(f16);
    try verifyFloatType(f32);
    try verifyFloatType(f64);
}

test "Highway VQSort base networks reject NaN before mutation" {
    var values = [_]f32{ 3, std.math.nan(f32), 1 };
    const first_bits: u32 = @bitCast(values[0]);
    const nan_bits: u32 = @bitCast(values[1]);
    const last_bits: u32 = @bitCast(values[2]);
    var scratch = Scratch{};
    try std.testing.expectError(error.InvalidKey, sort(f32, .ascending, &values, &scratch));
    try std.testing.expectEqual(first_bits, @as(u32, @bitCast(values[0])));
    try std.testing.expectEqual(nan_bits, @as(u32, @bitCast(values[1])));
    try std.testing.expectEqual(last_bits, @as(u32, @bitCast(values[2])));
}
