const std = @import("std");
const xkb = @import("../../root.zig");
const root = @import("root.zig");

const Compiled = root.Compiled;
const Error = root.Error;
const compile = root.compile;

const fixture =
    \\xkb_keymap {
    \\xkb_keycodes "fixture" {
    \\    minimum = 8;
    \\    maximum = 92;
    \\    <AC01> = 38;
    \\    <LVL3> = 92;
    \\    alias <ALGR> = <LVL3>;
    \\};
    \\xkb_types "fixture" {
    \\    virtual_modifiers LevelThree;
    \\    type "ONE_LEVEL" {
    \\        modifiers = none;
    \\        level_name[1] = "Any";
    \\    };
    \\    type "ALPHABETIC" {
    \\        modifiers = Shift+Lock;
    \\        map[Shift] = 2;
    \\        map[Lock] = 2;
    \\        level_name[1] = "Base";
    \\        level_name[2] = "Caps";
    \\    };
    \\};
    \\xkb_compatibility "fixture" {
    \\    virtual_modifiers LevelThree;
    \\    interpret.useModMapMods = AnyLevel;
    \\    interpret.repeat = False;
    \\    interpret 0xfe03+AnyOf(all) {
    \\        virtualModifier = LevelThree;
    \\        useModMapMods = level1;
    \\        action = SetMods(modifiers=LevelThree,clearLocks);
    \\    };
    \\    interpret Any+AnyOf(all) {
    \\        action = SetMods(modifiers=modMapMods,clearLocks);
    \\    };
    \\};
    \\xkb_symbols "fixture" {
    \\    name[1] = "English";
    \\    name[2] = "Alternate";
    \\    key <AC01> {
    \\        symbols[1] = [ 0x61, 0x41 ],
    \\        symbols[2] = [ 0x78, 0x58 ]
    \\    };
    \\    key <LVL3> { [ 0xfe03 ] };
    \\    modifier_map Mod5 { <ALGR> };
    \\};
    \\};
;

test "resolved TEXT V1 compiles groups repeat and virtual modifier mapping" {
    var compiled = try compile(std.testing.allocator, fixture);
    defer compiled.deinit();
    const keymap = compiled.keymap();
    try std.testing.expectEqual(@as(usize, 2), keymap.layoutCount());
    try std.testing.expectEqual(@as(?usize, 8), keymap.modifierIndex("LevelThree"));
    try std.testing.expectEqual(@as(?u32, 1 << 7), keymap.modifierMapping(8));

    var state = xkb.state.State.init(keymap);
    try std.testing.expectEqual(@as(?xkb.keysym.Keysym, @fromBackingInt(@intCast('a'))), state.oneSymbol(38));
    try std.testing.expect(state.keyRepeats(38));
    try std.testing.expect(!state.keyRepeats(92));
    _ = state.update(.{ .depressed_modifiers = 1 << 0, .locked_layout = 1 });
    try std.testing.expectEqual(@as(?xkb.keysym.Keysym, @fromBackingInt(@intCast('X'))), state.oneSymbol(38));
}

fn compileFixture(allocator: std.mem.Allocator) Error!Compiled {
    return compile(allocator, fixture);
}

test "compiled owner moves without moving keymap storage" {
    var original = try compileFixture(std.testing.allocator);
    const address = @intFromPtr(original.keymap());
    var moved = original;
    original = undefined;
    defer moved.deinit();
    try std.testing.expectEqual(address, @intFromPtr(moved.keymap()));
    var state = xkb.state.State.init(moved.keymap());
    _ = state.update(.{ .locked_modifiers = 1 << 1 });
    try std.testing.expectEqual(@as(?xkb.keysym.Keysym, @fromBackingInt(@intCast('A'))), state.oneSymbol(38));
}

fn compileAllocationFailure(allocator: std.mem.Allocator) !void {
    var compiled = try compile(allocator, fixture);
    defer compiled.deinit();
}

test "compiler unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compileAllocationFailure,
        .{},
    );
}

test "compiler rejects missing sections unknown modifiers and alias cycles" {
    try std.testing.expectError(error.InvalidSyntax, compile(
        std.testing.allocator,
        "xkb_keymap { xkb_keycodes { <A> = 9; }; };",
    ));
    const broken = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixture,
        "Shift+Lock",
        "Ghost",
    );
    defer std.testing.allocator.free(broken);
    try std.testing.expectError(error.InvalidSyntax, compile(std.testing.allocator, broken));
    try std.testing.expectError(
        error.InvalidEncoding,
        compile(std.testing.allocator, "xkb_keymap {\x00"),
    );
    try std.testing.expectError(error.InvalidSyntax, compile(std.testing.allocator,
        \\xkb_keymap {
        \\xkb_keycodes { alias <A> = <B>; alias <B> = <A>; };
        \\xkb_types {};
        \\xkb_compatibility {};
        \\xkb_symbols { key <A> { repeat=Yes }; };
        \\};
    ));
}
