const std = @import("std");
const Allocator = std.mem.Allocator;
const conjecture = @import("conjecture.zig");
const ConjectureData = conjecture.ConjectureData;
const DrawError = conjecture.DrawError;
const strategy_mod = @import("strategy.zig");
const Strategy = strategy_mod.Strategy;
const intToU64 = strategy_mod.intToU64;
const u64ToInt = strategy_mod.u64ToInt;

const default_float_abs: f64 = 1.0e6;

const default_slice_max: usize = 8;

fn AutoStrategy(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn draw(_: *const Self, data: *ConjectureData, allocator: Allocator) DrawError!T {
            return autoDraw(T, data, allocator);
        }

        pub fn strategy(self: *const Self) Strategy(T) {
            return Strategy(T).from(Self, self);
        }
    };
}

pub fn auto(comptime T: type) Strategy(T) {
    const Helper = struct {
        const inst: AutoStrategy(T) = .{};
    };
    return Strategy(T).from(AutoStrategy(T), &Helper.inst);
}

fn autoDraw(comptime T: type, data: *ConjectureData, allocator: Allocator) DrawError!T {
    switch (@typeInfo(T)) {
        .bool => return data.drawBoolean(),
        .int => |info| {
            _ = info;
            const lo = std.math.minInt(T);
            const hi = std.math.maxInt(T);
            const shrink_target: T = if (lo <= 0 and hi >= 0) 0 else lo;
            const raw = try data.drawInteger(
                intToU64(T, lo),
                intToU64(T, hi),
                intToU64(T, shrink_target),
            );
            return u64ToInt(T, raw);
        },
        .float => {
            const lo: T = -@as(T, @floatCast(default_float_abs));
            const hi: T = @as(T, @floatCast(default_float_abs));
            const f = try data.drawFloat(@floatCast(lo), @floatCast(hi));
            return @floatCast(f);
        },
        .@"enum" => |info| {
            if (info.field_names.len == 0)
                @compileError("auto cannot derive a strategy for an empty enum: " ++ @typeName(T));
            if (info.field_names.len == 1)
                return @field(T, info.field_names[0]);
            const max_idx: u64 = @intCast(info.field_names.len - 1);
            const idx = try data.drawInteger(0, max_idx, 0);
            inline for (info.field_names, 0..) |field_name, i| {
                if (idx == @as(u64, @intCast(i))) return @field(T, field_name);
            }
            unreachable;
        },
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |field_name, field_type| {
                @field(result, field_name) = try autoDraw(field_type, data, allocator);
            }
            return result;
        },
        .@"union" => |info| {
            if (info.tag_type == null)
                @compileError("auto requires a tagged union, got " ++ @typeName(T));
            if (info.field_names.len == 0)
                @compileError("auto cannot derive a strategy for an empty union: " ++ @typeName(T));
            const idx: u64 = if (info.field_names.len == 1)
                0
            else blk: {
                const max_idx: u64 = @intCast(info.field_names.len - 1);
                break :blk try data.drawInteger(0, max_idx, 0);
            };
            inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
                if (idx == @as(u64, @intCast(i))) {
                    if (field_type == void) return @unionInit(T, field_name, {});
                    const payload = try autoDraw(field_type, data, allocator);
                    return @unionInit(T, field_name, payload);
                }
            }
            unreachable;
        },
        .optional => |opt| {
            const present = try data.drawBoolean();
            if (!present) return null;
            return try autoDraw(opt.child, data, allocator);
        },
        .pointer => |ptr| {
            if (ptr.size != .slice)
                @compileError("auto only supports slice pointers, got " ++ @typeName(T));
            try data.beginSpan("auto-slice");
            const len = try data.drawInteger(0, default_slice_max, 0);
            const Child = ptr.child;
            const items = try allocator.alloc(Child, @intCast(len));
            for (items) |*item| {
                item.* = try autoDraw(Child, data, allocator);
            }
            data.endSpan();
            return items;
        },
        else => @compileError("auto does not support " ++ @typeName(T)),
    }
}

test "auto bool draws both values" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = auto(bool);
    var saw_true = false;
    var saw_false = false;
    for (0..100) |_| {
        const v = try s.draw(&data, allocator);
        if (v) saw_true = true else saw_false = true;
    }
    try std.testing.expect(saw_true and saw_false);
}

test "auto u8 draws in full range" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = auto(u8);
    for (0..100) |_| {
        const v = try s.draw(&data, allocator);
        _ = v;
    }
}

test "auto i32 draws in signed range" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = auto(i32);
    var saw_negative = false;
    for (0..200) |_| {
        const v = try s.draw(&data, allocator);
        if (v < 0) saw_negative = true;
    }
    try std.testing.expect(saw_negative);
}

test "auto f64 draws in default range" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = auto(f64);
    for (0..100) |_| {
        const v = try s.draw(&data, allocator);
        try std.testing.expect(v >= -default_float_abs);
        try std.testing.expect(v <= default_float_abs);
    }
}

test "auto enum picks every variant" {
    const Color = enum { red, green, blue };

    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = auto(Color);
    var seen = [_]bool{ false, false, false };
    for (0..100) |_| {
        const v = try s.draw(&data, allocator);
        seen[@backingInt(v)] = true;
    }
    try std.testing.expect(seen[0] and seen[1] and seen[2]);
}

const AutoStructFixture = struct {
    x: i16,
    y: i16,
    flag: bool,
};

test "auto struct draws every field" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = auto(AutoStructFixture);
    const v = try s.draw(&data, allocator);
    _ = v.x;
    _ = v.y;
    _ = v.flag;
}

test "auto optional yields both null and present" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = auto(?u8);
    var saw_null = false;
    var saw_present = false;
    for (0..100) |_| {
        const v = try s.draw(&data, allocator);
        if (v == null) saw_null = true else saw_present = true;
    }
    try std.testing.expect(saw_null and saw_present);
}

const AutoUnionFixture = union(enum) {
    none: void,
    one: u8,
    two: i16,
};

test "auto tagged union picks every variant" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = auto(AutoUnionFixture);
    var saw_none = false;
    var saw_one = false;
    var saw_two = false;
    for (0..200) |_| {
        const v = try s.draw(&data, allocator);
        switch (v) {
            .none => saw_none = true,
            .one => saw_one = true,
            .two => saw_two = true,
        }
    }
    try std.testing.expect(saw_none and saw_one and saw_two);
}

test "auto slice yields varied lengths within default bound" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const s = auto([]u8);
    var saw_empty = false;
    var saw_nonempty = false;
    for (0..200) |_| {
        const v = try s.draw(&data, allocator);
        defer allocator.free(v);
        if (v.len == 0) saw_empty = true else saw_nonempty = true;
        try std.testing.expect(v.len <= default_slice_max);
    }
    try std.testing.expect(saw_empty and saw_nonempty);
}
