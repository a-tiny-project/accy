const std = @import("std");
const keysym = @import("root.zig");
const data = @import("generated/root.zig").unicode;

const Keysym = keysym.Keysym;

pub fn codepoint(value: Keysym) ?u21 {
    const raw = @backingInt(value);
    if (raw >= keysym.unicode_offset and raw <= keysym.unicode_max) {
        const direct = raw - keysym.unicode_offset;
        if (direct == 0 or isSurrogate(direct)) return null;
        return @intCast(direct);
    }
    var low: usize = 0;
    var high: usize = data.entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = data.entries[middle];
        if (raw < entry.keysym) {
            high = middle;
        } else if (raw > entry.keysym) {
            low = middle + 1;
        } else {
            return entry.codepoint;
        }
    }
    return null;
}

fn isSurrogate(value: u32) bool {
    return value >= 0xd800 and value <= 0xdfff;
}

test "every pinned keysym Unicode mapping resolves" {
    try std.testing.expectEqual(@as(usize, data.count), data.entries.len);
    for (data.entries) |entry| {
        try std.testing.expectEqual(@as(?u21, entry.codepoint), codepoint(@fromBackingInt(@intCast(entry.keysym))));
    }
}

test "legacy special and direct keysyms resolve to Unicode scalars" {
    const cases = [_]struct { value: u32, expected: ?u21 }{
        .{ .value = 0x000001a1, .expected = 0x0104 },
        .{ .value = 0x0000ff08, .expected = 0x0008 },
        .{ .value = 0x0000ffb7, .expected = 0x0037 },
        .{ .value = 0x10081200, .expected = 0x0030 },
        .{ .value = 0x1008120a, .expected = 0x002a },
        .{ .value = 0x01000080, .expected = 0x0080 },
        .{ .value = 0x0101f600, .expected = 0x1f600 },
        .{ .value = 0x0110ffff, .expected = 0x10ffff },
        .{ .value = 0x0000ffff, .expected = 0x007f },
        .{ .value = 0x0000ffbe, .expected = null },
        .{ .value = 0x01000000, .expected = null },
        .{ .value = 0x0100d800, .expected = null },
        .{ .value = 0x0100dfff, .expected = null },
        .{ .value = 0x01110000, .expected = null },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, codepoint(@fromBackingInt(@intCast(case.value))));
    }
}
