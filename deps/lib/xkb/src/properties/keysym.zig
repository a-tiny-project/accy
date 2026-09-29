const std = @import("std");
const hypothesis = @import("hypothesis");
const xkb = @import("xkb");

const Keysym = xkb.keysym.Keysym;

fn settings() hypothesis.Settings {
    var value = hypothesis.Settings.quick()
        .withSeed(0x584b_425f_4b45_5953)
        .withDatabase("zig-out/hypothesis-failures/xkb-keysym");
    value.max_examples = 256;
    value.target_examples = 256;
    return value;
}

pub const CaseProperty = struct {
    pub fn property(conjecture: *hypothesis.ConjectureData, _: std.mem.Allocator) !void {
        const raw: u32 = @intCast(try conjecture.drawInteger(0, std.math.maxInt(u32), 0));
        const value: Keysym = @fromBackingInt(@intCast(raw));
        const lower = xkb.keysym.lower(value);
        const upper = xkb.keysym.upper(value);
        try std.testing.expectEqual(lower, xkb.keysym.lower(lower));
        try std.testing.expectEqual(upper, xkb.keysym.upper(upper));
        if (xkb.keysym.codepoint(value)) |codepoint| {
            var buffer: [4]u8 = undefined;
            _ = try std.unicode.utf8Encode(codepoint, &buffer);
        }
    }
};

pub const DirectProperty = struct {
    pub fn property(conjecture: *hypothesis.ConjectureData, _: std.mem.Allocator) !void {
        const codepoint: u21 = @intCast(try conjecture.drawInteger(0x100, 0x10ffff, 0x100));
        if (codepoint >= 0xd800 and codepoint <= 0xdfff) return;
        const value: Keysym = @fromBackingInt(@intCast(xkb.keysym.unicode_offset + @as(u32, codepoint)));
        try std.testing.expectEqual(@as(?u21, codepoint), xkb.keysym.codepoint(value));
        var buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "U{X}", .{codepoint});
        try std.testing.expectEqual(@as(?Keysym, value), xkb.keysym.fromName(name));
    }
};

test "pbt: simple keysym case conversion is idempotent" {
    try hypothesis.checkNamed(CaseProperty, "xkb-keysym-case-idempotent", settings());
}

test "pbt: direct Unicode keysyms round-trip through names" {
    try hypothesis.checkNamed(DirectProperty, "xkb-keysym-unicode-roundtrip", settings());
}
