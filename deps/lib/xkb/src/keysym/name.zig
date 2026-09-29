const std = @import("std");
const keysym = @import("root.zig");
const data = @import("generated/root.zig").name;

const Keysym = keysym.Keysym;

pub fn fromName(input: []const u8) ?Keysym {
    if (findExact(input)) |value| return value;
    if (input.len > 1 and input[0] == 'U') return unicodeNotation(input[1..]);
    if (input.len > 2 and std.mem.eql(u8, input[0..2], "0x")) return numericNotation(input[2..]);
    if (std.mem.startsWith(u8, input, "XF86_")) return xf86Notation(input);
    return null;
}

fn findExact(input: []const u8) ?Keysym {
    var low: usize = 0;
    var high: usize = data.entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = data.entries[middle];
        const candidate = data.bytes[entry.offset..][0..entry.length];
        switch (std.mem.order(u8, input, candidate)) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => return @fromBackingInt(@intCast(entry.keysym)),
        }
    }
    return null;
}

fn unicodeNotation(digits: []const u8) ?Keysym {
    const value = parseHex(digits) orelse return null;
    if (value > 0x10ffff) return null;
    if (value > 0xff) return @fromBackingInt(@intCast(keysym.unicode_offset + value));
    return @fromBackingInt(@intCast(legacyUnicodeNotation(value)));
}

fn legacyUnicodeNotation(value: u32) u32 {
    if ((value >= 0x20 and value <= 0x7e) or (value >= 0xa0 and value <= 0xff)) return value;
    return switch (value) {
        0 => 0,
        0x08...0x0b => value | 0xff00,
        0x0d => 0xff0d,
        0x1b => 0xff1b,
        0x7f => 0xffff,
        else => keysym.unicode_offset | value,
    };
}

fn numericNotation(digits: []const u8) ?Keysym {
    const value = parseHex(digits) orelse return null;
    if (value > keysym.max) return null;
    return @fromBackingInt(@intCast(value));
}

fn parseHex(digits: []const u8) ?u32 {
    if (digits.len == 0 or digits.len > 8) return null;
    return std.fmt.parseInt(u32, digits, 16) catch null;
}

fn xf86Notation(input: []const u8) ?Keysym {
    const normalized_length = input.len - 1;
    if (normalized_length > data.max_length) return null;
    var buffer: [data.max_length]u8 = undefined;
    @memcpy(buffer[0..4], input[0..4]);
    @memcpy(buffer[4..normalized_length], input[5..]);
    return findExact(buffer[0..normalized_length]);
}

test "every pinned name and alias resolves" {
    try std.testing.expectEqual(@as(usize, data.count), data.entries.len);
    for (data.entries) |entry| {
        const input = data.bytes[entry.offset..][0..entry.length];
        try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast(entry.keysym))), fromName(input));
    }
}

test "aliases retain their shared values" {
    try std.testing.expectEqual(fromName("Prior"), fromName("Page_Up"));
    try std.testing.expectEqual(fromName("Henkan_Mode"), fromName("Henkan"));
    try std.testing.expectEqual(fromName("ISO_Group_Shift"), fromName("Mode_switch"));
    try std.testing.expectEqual(fromName("ISO_Group_Shift"), fromName("script_switch"));
}

test "numeric and Unicode notation resolve without allocation" {
    try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast(0x0101f600))), fromName("U1F600"));
    try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast(0x0100d800))), fromName("U0D800"));
    try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast(0x01000080))), fromName("U0080"));
    try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast(0x00000041))), fromName("U0041"));
    try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast(0x0000ff08))), fromName("U0008"));
    try std.testing.expectEqual(@as(?Keysym, .no_symbol), fromName("U0000"));
    try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast(0x1008ff12))), fromName("0x1008ff12"));
    try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast(keysym.max))), fromName("0x1fffffff"));
    try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast(0x1008ff12))), fromName("XF86_AudioMute"));
    try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast(0x1008fe05))), fromName("XF86_Switch_VT_5"));
}

test "invalid notation is absent" {
    try std.testing.expectEqual(@as(?Keysym, null), fromName(""));
    try std.testing.expectEqual(@as(?Keysym, null), fromName("NotAKeysym"));
    try std.testing.expectEqual(@as(?Keysym, null), fromName("U_"));
    try std.testing.expectEqual(@as(?Keysym, null), fromName("U110000"));
    try std.testing.expectEqual(@as(?Keysym, null), fromName("0x"));
    try std.testing.expectEqual(@as(?Keysym, null), fromName("0x20000000"));
    try std.testing.expectEqual(@as(?Keysym, null), fromName("XF86_NotAKeysym"));
}
