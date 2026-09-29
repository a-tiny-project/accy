const std = @import("std");
const Allocator = std.mem.Allocator;
const conjecture = @import("conjecture.zig");
const ConjectureData = conjecture.ConjectureData;
const DrawError = conjecture.DrawError;

pub fn Strategy(comptime T: type) type {
    return struct {
        context: *const anyopaque,
        drawFn: *const fn (*const anyopaque, *ConjectureData, Allocator) DrawError!T,

        const Self = @This();

        pub fn draw(self: Self, data: *ConjectureData, allocator: Allocator) DrawError!T {
            return self.drawFn(self.context, data, allocator);
        }

        pub fn from(comptime S: type, ptr: *const S) Self {
            return .{
                .context = @ptrCast(ptr),
                .drawFn = &struct {
                    fn call(ctx: *const anyopaque, data: *ConjectureData, allocator: Allocator) DrawError!T {
                        const self: *const S = @ptrCast(@alignCast(ctx));
                        return self.draw(data, allocator);
                    }
                }.call,
            };
        }
    };
}

pub fn IntegerStrategy(comptime Int: type) type {
    const info = @typeInfo(Int);
    if (info != .int) @compileError("IntegerStrategy requires an integer type");

    return struct {
        min: Int,
        max: Int,
        shrink_towards: Int,

        const Self = @This();

        pub fn draw(self: *const Self, data: *ConjectureData, _: Allocator) DrawError!Int {
            const raw = try data.drawInteger(
                intToU64(Int, self.min),
                intToU64(Int, self.max),
                intToU64(Int, self.shrink_towards),
            );
            return u64ToInt(Int, raw);
        }

        pub fn strategy(self: *const Self) Strategy(Int) {
            return Strategy(Int).from(Self, self);
        }
    };
}

pub fn integers(comptime Int: type, min: Int, max: Int) IntegerStrategy(Int) {
    return .{
        .min = min,
        .max = max,
        .shrink_towards = if (min <= 0 and 0 <= max) 0 else min,
    };
}

pub const BooleanStrategy = struct {
    pub fn draw(_: *const BooleanStrategy, data: *ConjectureData, _: Allocator) DrawError!bool {
        return data.drawBoolean();
    }

    pub fn strategy(self: *const BooleanStrategy) Strategy(bool) {
        return Strategy(bool).from(BooleanStrategy, self);
    }
};

pub fn booleans() BooleanStrategy {
    return .{};
}

pub fn FloatStrategy(comptime Float: type) type {
    const info = @typeInfo(Float);
    if (info != .float) @compileError("FloatStrategy requires a float type");

    return struct {
        min: Float,
        max: Float,

        const Self = @This();

        pub fn draw(self: *const Self, data: *ConjectureData, _: Allocator) DrawError!Float {
            const raw = try data.drawFloat(
                @floatCast(self.min),
                @floatCast(self.max),
            );
            return @floatCast(raw);
        }

        pub fn strategy(self: *const Self) Strategy(Float) {
            return Strategy(Float).from(Self, self);
        }
    };
}

pub fn floats(comptime Float: type, min: Float, max: Float) FloatStrategy(Float) {
    return .{
        .min = min,
        .max = max,
    };
}

pub const BytesStrategy = struct {
    min_size: usize,
    max_size: usize,

    pub fn draw(self: *const BytesStrategy, data: *ConjectureData, _: Allocator) DrawError![]const u8 {
        return data.drawBytes(self.min_size, self.max_size);
    }

    pub fn strategy(self: *const BytesStrategy) Strategy([]const u8) {
        return Strategy([]const u8).from(BytesStrategy, self);
    }
};

pub fn bytesOf(min_size: usize, max_size: usize) BytesStrategy {
    return .{
        .min_size = min_size,
        .max_size = max_size,
    };
}

pub const ascii_printable = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
pub const alphanumeric = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
pub const url_safe_tokens = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";

pub fn drawCharFromCharset(data: *ConjectureData, charset: []const u8) DrawError!u8 {
    std.debug.assert(charset.len > 0);
    const max_index: u64 = @intCast(charset.len - 1);
    const idx = try data.drawInteger(0, max_index, 0);
    return charset[@intCast(idx)];
}

pub fn intToU64(comptime Int: type, value: Int) u64 {
    const info = @typeInfo(Int).int;
    if (info.signedness == .signed) {
        const Unsigned = @Int(.unsigned, info.bits);
        const sign_bit: Unsigned = @as(Unsigned, 1) << @intCast(info.bits - 1);
        const as_unsigned: Unsigned = @bitCast(value);
        return @as(u64, as_unsigned ^ sign_bit);
    } else {
        return @intCast(value);
    }
}

pub fn u64ToInt(comptime Int: type, raw: u64) Int {
    const info = @typeInfo(Int).int;
    if (info.signedness == .signed) {
        const Unsigned = @Int(.unsigned, info.bits);
        const sign_bit: Unsigned = @as(Unsigned, 1) << @intCast(info.bits - 1);
        const as_unsigned: Unsigned = @truncate(raw);
        return @bitCast(as_unsigned ^ sign_bit);
    } else {
        return @intCast(raw);
    }
}

test "IntegerStrategy draws in range" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = integers(i32, -100, 100);
    for (0..100) |_| {
        const v = try s.strategy().draw(&data, allocator);
        try std.testing.expect(v >= -100 and v <= 100);
    }
}

test "BooleanStrategy draws booleans" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = booleans();
    var saw_true = false;
    var saw_false = false;
    for (0..100) |_| {
        const v = try s.strategy().draw(&data, allocator);
        if (v) saw_true = true else saw_false = true;
    }
    try std.testing.expect(saw_true and saw_false);
}

test "IntegerStrategy u8 draws in range" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = integers(u8, 0, 255);
    for (0..100) |_| {
        const v = try s.strategy().draw(&data, allocator);
        try std.testing.expect(v <= 255);
    }
}

test "signed integer encoding roundtrips" {
    try std.testing.expectEqual(@as(i8, -128), u64ToInt(i8, intToU64(i8, -128)));
    try std.testing.expectEqual(@as(i8, -1), u64ToInt(i8, intToU64(i8, -1)));
    try std.testing.expectEqual(@as(i8, 0), u64ToInt(i8, intToU64(i8, 0)));
    try std.testing.expectEqual(@as(i8, 127), u64ToInt(i8, intToU64(i8, 127)));
    try std.testing.expectEqual(@as(i32, -1000), u64ToInt(i32, intToU64(i32, -1000)));
    try std.testing.expectEqual(@as(i32, 1000), u64ToInt(i32, intToU64(i32, 1000)));
}

test "signed integer encoding is order-preserving" {
    try std.testing.expect(intToU64(i8, -128) < intToU64(i8, 0));
    try std.testing.expect(intToU64(i8, 0) < intToU64(i8, 127));
    try std.testing.expect(intToU64(i32, -100) < intToU64(i32, 100));
    try std.testing.expect(intToU64(i32, std.math.minInt(i32)) <
        intToU64(i32, std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(u64, 0), intToU64(i8, std.math.minInt(i8)));
    try std.testing.expectEqual(@as(u64, 0xFF), intToU64(i8, std.math.maxInt(i8)));
    try std.testing.expectEqual(@as(u64, 0), intToU64(i32, std.math.minInt(i32)));
    try std.testing.expectEqual(
        @as(u64, 0xFFFF_FFFF),
        intToU64(i32, std.math.maxInt(i32)),
    );
}

test "IntegerStrategy spans signed range without clamp collapse" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = integers(i32, -100, 100);
    var saw_negative = false;
    var saw_positive = false;
    for (0..200) |_| {
        const v = try s.strategy().draw(&data, allocator);
        try std.testing.expect(v >= -100 and v <= 100);
        if (v < 0) saw_negative = true;
        if (v > 0) saw_positive = true;
    }
    try std.testing.expect(saw_negative and saw_positive);
}

test "FloatStrategy draws in range" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = floats(f32, -1.0, 1.0);
    for (0..100) |_| {
        const v = try s.strategy().draw(&data, allocator);
        try std.testing.expect(v >= -1.0 and v <= 1.0);
    }
}

test "BytesStrategy draws in size range" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = bytesOf(2, 8);
    for (0..20) |_| {
        const v = try s.strategy().draw(&data, allocator);
        try std.testing.expect(v.len >= 2 and v.len <= 8);
    }
}

test "drawCharFromCharset draws from charset" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const charset = "abc123";
    for (0..100) |_| {
        const ch = try drawCharFromCharset(&data, charset);
        try std.testing.expect(std.mem.indexOfScalar(u8, charset, ch) != null);
    }
}
