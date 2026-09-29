const std = @import("std");
const hypothesis = @import("hypothesis");
const xkb = @import("xkb");

fn settings() hypothesis.Settings {
    var value = hypothesis.Settings.quick()
        .withSeed(0x584b_425f_5445_5854)
        .withDatabase("zig-out/hypothesis-failures/xkb-text");
    value.max_examples = 256;
    value.target_examples = 256;
    return value;
}

const source =
    \\xkb_keymap {
    \\xkb_keycodes {
    \\    <TEST> = 38;
    \\    <VMOD> = 92;
    \\};
    \\xkb_types {
    \\    virtual_modifiers LevelThree;
    \\    type "ONE_LEVEL" { modifiers=none; level_name[1]="Any"; };
    \\    type "VMOD_LEVEL" {
    \\        modifiers=LevelThree;
    \\        map[LevelThree]=2;
    \\        level_name[1]="Base";
    \\        level_name[2]="Selected";
    \\    };
    \\};
    \\xkb_compatibility {
    \\    virtual_modifiers LevelThree;
    \\    interpret.useModMapMods=AnyLevel;
    \\    interpret.repeat=False;
    \\    interpret 0xfe03+AnyOf(all) {
    \\        virtualModifier=LevelThree;
    \\        useModMapMods=level1;
    \\        action=SetMods(modifiers=LevelThree);
    \\    };
    \\};
    \\xkb_symbols {
    \\    key <TEST> {
    \\        type="VMOD_LEVEL",
    \\        symbols[1]=[ a, A ],
    \\        symbols[2]=[ x, X ],
    \\        repeat=Yes
    \\    };
    \\    key <VMOD> { [ ISO_Level3_Shift ] };
    \\    modifier_map Mod5 { <VMOD> };
    \\};
    \\};
;

pub const CompilerProperty = struct {
    pub fn property(conjecture: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
        const first: u8 = @intCast(try conjecture.drawInteger('a', 'z', 'a'));
        const second: u8 = @intCast(try conjecture.drawInteger('a', 'z', 'x'));
        const modifier_index: usize = @intCast(try conjecture.drawInteger(3, 7, 7));
        const active = try conjecture.drawBoolean();
        const repeats = try conjecture.drawBoolean();
        const layout: u32 = @intCast(try conjecture.drawInteger(0, std.math.maxInt(u32), 0));

        const text = try allocator.dupe(u8, source);
        defer allocator.free(text);
        mutateGroup(text, "symbols[1]", first);
        mutateGroup(text, "symbols[2]", second);
        text[std.mem.indexOf(u8, text, "modifier_map Mod5").? + "modifier_map Mod".len] =
            @as(u8, @intCast(modifier_index)) + '1' - 3;
        if (!repeats) @memcpy(
            text[std.mem.indexOf(u8, text, "repeat=Yes").? + "repeat=".len ..][0..3],
            "No ",
        );

        var compiled = try xkb.keymap.text.compile(allocator, text);
        defer compiled.deinit();
        const keymap = compiled.keymap();
        try std.testing.expectEqual(
            @as(?u32, xkb.keymap.modifierBit(modifier_index)),
            keymap.modifierMapping(xkb.keymap.core_modifier_count),
        );

        var state = xkb.state.State.init(keymap);
        _ = state.update(.{
            .depressed_modifiers = if (active) xkb.keymap.modifierBit(modifier_index) else 0,
            .locked_layout = layout,
        });
        const base = if (@mod(layout, 2) == 0) first else second;
        const expected = if (active) std.ascii.toUpper(base) else base;
        try std.testing.expectEqual(
            @as(?xkb.keysym.Keysym, @fromBackingInt(@intCast(expected))),
            state.oneSymbol(38),
        );
        try std.testing.expectEqual(repeats, state.keyRepeats(38));
    }
};

fn mutateGroup(text: []u8, needle: []const u8, lower: u8) void {
    const position = std.mem.indexOf(u8, text, needle).?;
    const symbols = std.mem.indexOfScalarPos(u8, text, position + needle.len, '[').?;
    text[symbols + 2] = lower;
    text[symbols + 5] = std.ascii.toUpper(lower);
}

test "pbt: TEXT V1 compilation preserves generated groups modifiers levels and repeat" {
    try hypothesis.checkNamed(CompilerProperty, "xkb-text-compiler", settings());
}
