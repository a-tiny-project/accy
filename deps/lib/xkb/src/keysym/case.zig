const std = @import("std");
const keysym = @import("root.zig");
const data = @import("generated/root.zig").case;

const Keysym = keysym.Keysym;
const Mapping = data.Mapping;

pub fn lower(value: Keysym) Keysym {
    return mapped(data.lower[0..], value) orelse value;
}

pub fn upper(value: Keysym) Keysym {
    return mapped(data.upper[0..], value) orelse value;
}

pub fn isLower(value: Keysym) bool {
    return contains(data.upper[0..], value) and !contains(data.lower[0..], value);
}

pub fn isUpperOrTitle(value: Keysym) bool {
    return contains(data.lower[0..], value);
}

fn mapped(entries: []const Mapping, value: Keysym) ?Keysym {
    const index = find(entries, value) orelse return null;
    return @fromBackingInt(@intCast(entries[index].output));
}

fn contains(entries: []const Mapping, value: Keysym) bool {
    return find(entries, value) != null;
}

fn find(entries: []const Mapping, value: Keysym) ?usize {
    const raw = @backingInt(value);
    var low: usize = 0;
    var high: usize = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = entries[middle];
        if (raw < entry.input) {
            high = middle;
        } else if (raw > entry.input) {
            low = middle + 1;
        } else {
            return middle;
        }
    }
    return null;
}

test "every pinned simple case mapping resolves" {
    try std.testing.expectEqual(@as(usize, data.lower_count), data.lower.len);
    try std.testing.expectEqual(@as(usize, data.upper_count), data.upper.len);
    for (data.lower) |entry| {
        const output: Keysym = @fromBackingInt(@intCast(entry.output));
        try std.testing.expectEqual(output, lower(@fromBackingInt(@intCast(entry.input))));
        try std.testing.expectEqual(output, lower(output));
    }
    for (data.upper) |entry| {
        const output: Keysym = @fromBackingInt(@intCast(entry.output));
        try std.testing.expectEqual(output, upper(@fromBackingInt(@intCast(entry.input))));
        try std.testing.expectEqual(output, upper(output));
    }
}

test "legacy Unicode and titlecase mappings retain XKB values" {
    const cases = [_]struct { input: u32, lower: u32, upper: u32 }{
        .{ .input = 0x00000041, .lower = 0x00000061, .upper = 0x00000041 },
        .{ .input = 0x000000df, .lower = 0x000000df, .upper = 0x01001e9e },
        .{ .input = 0x01001e9e, .lower = 0x000000df, .upper = 0x01001e9e },
        .{ .input = 0x01000130, .lower = 0x00000069, .upper = 0x01000130 },
        .{ .input = 0x010001f2, .lower = 0x010001f3, .upper = 0x010001f1 },
        .{ .input = 0x000007c1, .lower = 0x000007e1, .upper = 0x000007c1 },
    };
    for (cases) |case| {
        const input: Keysym = @fromBackingInt(@intCast(case.input));
        try std.testing.expectEqual(@as(Keysym, @fromBackingInt(@intCast(case.lower))), lower(input));
        try std.testing.expectEqual(@as(Keysym, @fromBackingInt(@intCast(case.upper))), upper(input));
    }
}

test "lower upper and title predicates retain XKB boundaries" {
    const cases = [_]struct { input: u32, is_lower: bool, is_upper_or_title: bool }{
        .{ .input = 0x00000041, .is_lower = false, .is_upper_or_title = true },
        .{ .input = 0x00000061, .is_lower = true, .is_upper_or_title = false },
        .{ .input = 0x000000df, .is_lower = true, .is_upper_or_title = false },
        .{ .input = 0x01001e9e, .is_lower = false, .is_upper_or_title = true },
        .{ .input = 0x010001f1, .is_lower = false, .is_upper_or_title = true },
        .{ .input = 0x010001f2, .is_lower = false, .is_upper_or_title = true },
        .{ .input = 0x010001f3, .is_lower = true, .is_upper_or_title = false },
        .{ .input = 0x01001f80, .is_lower = true, .is_upper_or_title = false },
        .{ .input = 0x01001f88, .is_lower = false, .is_upper_or_title = true },
        .{ .input = 0x0000ff0d, .is_lower = false, .is_upper_or_title = false },
        .{ .input = 0x010005d0, .is_lower = false, .is_upper_or_title = false },
    };
    for (cases) |case| {
        const input: Keysym = @fromBackingInt(@intCast(case.input));
        try std.testing.expectEqual(case.is_lower, isLower(input));
        try std.testing.expectEqual(case.is_upper_or_title, isUpperOrTitle(input));
    }
}
