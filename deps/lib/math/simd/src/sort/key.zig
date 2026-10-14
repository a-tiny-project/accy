const std = @import("std");

pub const Direction = enum {
    ascending,
    descending,

    pub fn reverse(self: Direction) Direction {
        return switch (self) {
            .ascending => .descending,
            .descending => .ascending,
        };
    }
};

pub const Ascending = struct {};
pub const Descending = struct {};

pub const K32V32 = extern struct {
    value: u32 align(8),
    key: u32,

    pub fn init(key_value: u32, value_value: u32) K32V32 {
        return .{ .value = value_value, .key = key_value };
    }
};

pub const K64V64 = extern struct {
    value: u64 align(16),
    key: u64,

    pub fn init(key_value: u64, value_value: u64) K64V64 {
        return .{ .value = value_value, .key = key_value };
    }
};

pub fn supported(comptime Key: type) bool {
    if (Key == K32V32 or Key == K64V64 or Key == u128) return true;
    return switch (@typeInfo(Key)) {
        .int => |info| info.bits == 16 or info.bits == 32 or info.bits == 64,
        .float => |info| info.bits == 16 or info.bits == 32 or info.bits == 64,
        else => false,
    };
}

pub inline fn before(
    comptime Key: type,
    comptime direction: Direction,
    a: Key,
    b: Key,
) bool {
    requireSupported(Key);
    return if (direction == .ascending)
        lessKeyAscending(Key, a, b)
    else
        lessKeyAscending(Key, b, a);
}

pub inline fn networkBefore(
    comptime Key: type,
    comptime direction: Direction,
    a: Key,
    b: Key,
) bool {
    requireSupported(Key);
    return if (direction == .ascending)
        lessFullAscending(Key, a, b)
    else
        lessFullAscending(Key, b, a);
}

pub inline fn equivalent(comptime Key: type, a: Key, b: Key) bool {
    requireSupported(Key);
    if (Key == K32V32 or Key == K64V64) return a.key == b.key;
    return a == b;
}

pub inline fn first(
    comptime Key: type,
    comptime direction: Direction,
    a: Key,
    b: Key,
) Key {
    return if (before(Key, direction, a, b)) a else b;
}

pub inline fn last(
    comptime Key: type,
    comptime direction: Direction,
    a: Key,
    b: Key,
) Key {
    return if (before(Key, direction, a, b)) b else a;
}

pub fn medianOf3(
    comptime Key: type,
    comptime direction: Direction,
    a: Key,
    b: Key,
    c: Key,
) Key {
    var low = a;
    var high = c;
    if (networkBefore(Key, direction, high, low)) std.mem.swap(Key, &low, &high);
    const middle = if (networkBefore(Key, direction, low, b)) b else low;
    return if (networkBefore(Key, direction, middle, high)) middle else high;
}

pub fn firstValue(comptime Key: type, comptime direction: Direction) Key {
    return if (direction == .ascending) smallestValue(Key) else largestValue(Key);
}

pub fn lastValue(comptime Key: type, comptime direction: Direction) Key {
    return if (direction == .ascending) largestValue(Key) else smallestValue(Key);
}

pub fn previous(
    comptime Key: type,
    comptime direction: Direction,
    value: Key,
) Key {
    requireSupported(Key);
    if (Key == K32V32) {
        return .{
            .value = value.value,
            .key = if (direction == .ascending) value.key -% 1 else value.key +% 1,
        };
    }
    if (Key == K64V64) {
        return .{
            .value = value.value,
            .key = if (direction == .ascending) value.key -% 1 else value.key +% 1,
        };
    }
    return switch (@typeInfo(Key)) {
        .int => if (direction == .ascending) value -% 1 else value +% 1,
        .float => if (direction == .ascending)
            smallerFloat(Key, value)
        else
            largerFloat(Key, value),
        else => unreachable,
    };
}

pub fn validForNetwork(comptime Key: type, value: Key) bool {
    requireSupported(Key);
    return switch (@typeInfo(Key)) {
        .float => !std.math.isNan(value),
        else => true,
    };
}

fn lessKeyAscending(comptime Key: type, a: Key, b: Key) bool {
    if (Key == K32V32 or Key == K64V64) return a.key < b.key;
    return a < b;
}

fn lessFullAscending(comptime Key: type, a: Key, b: Key) bool {
    if (Key == K32V32 or Key == K64V64) {
        return a.key < b.key or (a.key == b.key and a.value < b.value);
    }
    return a < b;
}

fn smallestValue(comptime Key: type) Key {
    requireSupported(Key);
    if (Key == K32V32) return .{ .value = 0, .key = 0 };
    if (Key == K64V64) return .{ .value = 0, .key = 0 };
    return switch (@typeInfo(Key)) {
        .int => std.math.minInt(Key),
        .float => -std.math.inf(Key),
        else => unreachable,
    };
}

fn largestValue(comptime Key: type) Key {
    requireSupported(Key);
    if (Key == K32V32) {
        return .{ .value = std.math.maxInt(u32), .key = std.math.maxInt(u32) };
    }
    if (Key == K64V64) {
        return .{ .value = std.math.maxInt(u64), .key = std.math.maxInt(u64) };
    }
    return switch (@typeInfo(Key)) {
        .int => std.math.maxInt(Key),
        .float => std.math.inf(Key),
        else => unreachable,
    };
}

fn largerFloat(comptime Float: type, value: Float) Float {
    const UInt = @Int(.unsigned, @bitSizeOf(Float));
    const sign_bit = @as(UInt, 1) << (@bitSizeOf(Float) - 1);
    const bits: UInt = @bitCast(value);
    const magnitude = bits & ~sign_bit;
    const was_positive = bits <= sign_bit;
    const add: UInt = if (was_positive) 1 else std.math.maxInt(UInt);
    var result: Float = @bitCast(magnitude +% add);
    if (!std.math.isFinite(result)) {
        result = if (was_positive) std.math.inf(Float) else std.math.floatMax(Float);
    }
    return if (was_positive) result else -result;
}

fn smallerFloat(comptime Float: type, value: Float) Float {
    const UInt = @Int(.unsigned, @bitSizeOf(Float));
    const sign_bit = @as(UInt, 1) << (@bitSizeOf(Float) - 1);
    const bits: UInt = @bitCast(value);
    const magnitude = bits & ~sign_bit;
    const was_positive = value > 0;
    const add: UInt = if (was_positive) std.math.maxInt(UInt) else 1;
    var result: Float = @bitCast(magnitude +% add);
    if (!std.math.isFinite(result)) {
        result = if (was_positive) std.math.floatMax(Float) else std.math.inf(Float);
    }
    return if (was_positive) result else -result;
}

fn requireSupported(comptime Key: type) void {
    if (comptime !supported(Key)) @compileError("VQSort key type is not supported");
}

fn verifyFloatNeighbors(comptime Float: type) !void {
    const UInt = @Int(.unsigned, @bitSizeOf(Float));
    const positive_subnormal: Float = @bitCast(@as(UInt, 1));
    const negative_subnormal: Float = @bitCast(
        (@as(UInt, 1) << (@bitSizeOf(Float) - 1)) | 1,
    );
    try std.testing.expectEqual(positive_subnormal, previous(Float, .descending, 0));
    try std.testing.expectEqual(negative_subnormal, previous(Float, .ascending, 0));
    try std.testing.expectEqual(
        std.math.inf(Float),
        previous(Float, .descending, std.math.inf(Float)),
    );
    try std.testing.expectEqual(
        -std.math.inf(Float),
        previous(Float, .ascending, -std.math.inf(Float)),
    );
    try std.testing.expectEqual(
        std.math.floatMax(Float),
        previous(Float, .ascending, std.math.inf(Float)),
    );
    try std.testing.expectEqual(
        -std.math.floatMax(Float),
        previous(Float, .descending, -std.math.inf(Float)),
    );
}
