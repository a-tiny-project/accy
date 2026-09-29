const std = @import("std");
const hypothesis = @import("hypothesis");
const xkb = @import("xkb");

const keymap = xkb.keymap;

fn settings() hypothesis.Settings {
    var value = hypothesis.Settings.quick()
        .withSeed(0x584b_425f_5354_4154)
        .withDatabase("zig-out/hypothesis-failures/xkb-state");
    value.max_examples = 512;
    value.target_examples = 512;
    return value;
}

const modifiers = keymap.core_modifiers ++ [_]keymap.Modifier{
    .{ .name = "NumLock", .mapping = 1 << 4, .kind = .virtual },
};
const types = [_]keymap.KeyType{.{ .modifiers = 0, .level_count = 1, .entries = &.{} }};
const levels = [_]keymap.Level{.{
    .symbols = &.{@fromBackingInt(@intCast('a'))},
    .uppercase_symbols = &.{@fromBackingInt(@intCast('A'))},
}};
const groups = [_]keymap.Group{
    .{ .type_index = 0, .levels = &levels },
    .{ .type_index = 0, .levels = &levels },
    .{ .type_index = 0, .levels = &levels },
};
const keys = [_]keymap.Key{.{ .code = 38, .groups = &groups }};
const definition = keymap.Definition{
    .modifiers = &modifiers,
    .types = &types,
    .keys = &keys,
};

pub const MaskProperty = struct {
    pub fn property(conjecture: *hypothesis.ConjectureData, _: std.mem.Allocator) !void {
        const depressed: u32 = @intCast(try conjecture.drawInteger(0, std.math.maxInt(u32), 0));
        const latched: u32 = @intCast(try conjecture.drawInteger(0, std.math.maxInt(u32), 0));
        const locked: u32 = @intCast(try conjecture.drawInteger(0, std.math.maxInt(u32), 0));
        const depressed_layout: u32 = @intCast(try conjecture.drawInteger(0, std.math.maxInt(u32), 0));
        const latched_layout: u32 = @intCast(try conjecture.drawInteger(0, std.math.maxInt(u32), 0));
        const locked_layout: u32 = @intCast(try conjecture.drawInteger(0, std.math.maxInt(u32), 0));

        var storage: keymap.Keymap.Storage = undefined;
        var state = xkb.state.State.init(try keymap.Keymap.init(&storage, definition));
        const input = xkb.state.Mask{
            .depressed_modifiers = depressed,
            .latched_modifiers = latched,
            .locked_modifiers = locked,
            .depressed_layout = depressed_layout,
            .latched_layout = latched_layout,
            .locked_layout = locked_layout,
        };
        _ = state.update(input);

        const expected_depressed = (depressed & 0xff) | if (depressed & (1 << 8) != 0) @as(u32, 1 << 4) else 0;
        const expected_latched = (latched & 0xff) | if (latched & (1 << 8) != 0) @as(u32, 1 << 4) else 0;
        const expected_locked = (locked & 0xff) | if (locked & (1 << 8) != 0) @as(u32, 1 << 4) else 0;
        try std.testing.expectEqual(expected_depressed | expected_latched | expected_locked, state.effectiveModifiers());

        const wrapped_locked = @mod(@as(i64, @as(i32, @bitCast(locked_layout))), 3);
        const layout_sum = @as(i32, @bitCast(depressed_layout)) +%
            @as(i32, @bitCast(latched_layout)) +% @as(i32, @intCast(wrapped_locked));
        try std.testing.expectEqual(@as(usize, @intCast(@mod(@as(i64, layout_sum), 3))), state.effectiveLayout());
        try std.testing.expect(!state.update(input).any());
    }
};

pub const GroupProperty = struct {
    pub fn property(conjecture: *hypothesis.ConjectureData, _: std.mem.Allocator) !void {
        const group: i32 = @bitCast(@as(u32, @intCast(try conjecture.drawInteger(0, std.math.maxInt(u32), 0))));
        const count: usize = @intCast(try conjecture.drawInteger(1, 32, 1));
        const expected: usize = @intCast(@mod(@as(i64, group), @as(i64, @intCast(count))));
        try std.testing.expectEqual(expected, keymap.groupInRange(group, count, .wrap));
        try std.testing.expect(keymap.groupInRange(group, count, .saturate) < count);
        const redirect: usize = count - 1;
        try std.testing.expect(keymap.groupInRange(group, count, .{ .redirect = redirect }) < count);
    }
};

test "pbt: external XKB state masks resolve and update idempotently" {
    try hypothesis.checkNamed(MaskProperty, "xkb-state-mask-idempotent", settings());
}

test "pbt: key group policies always select an existing group" {
    try hypothesis.checkNamed(GroupProperty, "xkb-state-group-in-range", settings());
}
