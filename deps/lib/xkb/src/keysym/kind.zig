const std = @import("std");
const Keysym = @import("root.zig").Keysym;
const data = @import("generated/root.zig").kind;

pub fn isModifier(value: Keysym) bool {
    const raw = @backingInt(value);
    return (raw >= data.modifier_core_min and raw <= data.modifier_core_max) or
        (raw >= data.modifier_iso_min and raw <= data.modifier_iso_max) or
        raw == data.mode_switch or
        raw == data.num_lock;
}

pub fn isKeypad(value: Keysym) bool {
    const raw = @backingInt(value);
    return raw >= data.keypad_min and raw <= data.keypad_max;
}

test "modifier classification covers XKB ranges and isolated symbols" {
    const modifiers = [_]u32{ 0xffe1, 0xffee, 0xfe01, 0xfe13, 0xff7e, 0xff7f };
    const other = [_]u32{ 0xffe0, 0xffef, 0xfe00, 0xfe14, 0xff7d, 0xff80 };
    for (modifiers) |value| try std.testing.expect(isModifier(@fromBackingInt(@intCast(value))));
    for (other) |value| try std.testing.expect(!isModifier(@fromBackingInt(@intCast(value))));
}

test "keypad classification uses the complete contiguous range" {
    try std.testing.expect(!isKeypad(@fromBackingInt(@intCast(0xff7f))));
    try std.testing.expect(isKeypad(@fromBackingInt(@intCast(0xff80))));
    try std.testing.expect(isKeypad(@fromBackingInt(@intCast(0xffbd))));
    try std.testing.expect(!isKeypad(@fromBackingInt(@intCast(0xffbe))));
}
