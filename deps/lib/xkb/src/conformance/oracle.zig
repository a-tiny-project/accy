const std = @import("std");
const xkb = @import("xkb");

const Context = opaque {};
const CKeymap = opaque {};
const CState = opaque {};
const CComposeTable = opaque {};
const CComposeState = opaque {};
const CComposeIterator = opaque {};
const CComposeEntry = opaque {};

const CRuleNames = extern struct {
    rules: ?[*:0]const u8 = null,
    model: ?[*:0]const u8 = null,
    layout: ?[*:0]const u8 = null,
    variant: ?[*:0]const u8 = null,
    options: ?[*:0]const u8 = null,
};

extern fn xkb_context_new(flags: c_uint) ?*Context;
extern fn xkb_context_unref(context: *Context) void;
extern fn xkb_keymap_new_from_string(context: *Context, text: [*:0]const u8, format: c_uint, flags: c_uint) ?*CKeymap;
extern fn xkb_keymap_new_from_names(context: *Context, names: *const CRuleNames, flags: c_uint) ?*CKeymap;
extern fn xkb_keymap_get_as_string(keymap: *CKeymap, format: c_uint) ?[*:0]u8;
extern fn xkb_keymap_unref(keymap: *CKeymap) void;
extern fn xkb_keymap_min_keycode(keymap: *CKeymap) u32;
extern fn xkb_keymap_max_keycode(keymap: *CKeymap) u32;
extern fn xkb_keymap_num_layouts(keymap: *CKeymap) u32;
extern fn xkb_keymap_num_mods(keymap: *CKeymap) u32;
extern fn xkb_keymap_mod_get_name(keymap: *CKeymap, index: u32) ?[*:0]const u8;
extern fn xkb_keymap_key_repeats(keymap: *CKeymap, code: u32) c_int;
extern fn xkb_state_new(keymap: *CKeymap) ?*CState;
extern fn xkb_state_unref(state: *CState) void;
extern fn xkb_state_update_mask(state: *CState, depressed: u32, latched: u32, locked: u32, depressed_layout: u32, latched_layout: u32, locked_layout: u32) c_uint;
extern fn xkb_state_serialize_mods(state: *CState, components: c_uint) u32;
extern fn xkb_state_mod_name_is_active(state: *CState, name: [*:0]const u8, components: c_uint) c_int;
extern fn xkb_state_key_get_syms(state: *CState, code: u32, symbols: *[*]const u32) c_int;
extern fn xkb_state_key_get_one_sym(state: *CState, code: u32) u32;
extern fn xkb_state_key_get_utf8(state: *CState, code: u32, buffer: [*]u8, size: usize) c_int;
extern fn xkb_state_key_get_layout(state: *CState, code: u32) u32;
extern fn xkb_state_key_get_level(state: *CState, code: u32, layout: u32) u32;
extern fn xkb_state_key_get_consumed_mods(state: *CState, code: u32) u32;
extern fn xkb_compose_table_new_from_buffer(
    context: *Context,
    buffer: [*]const u8,
    length: usize,
    locale: [*:0]const u8,
    format: c_uint,
    flags: c_uint,
) ?*CComposeTable;
extern fn xkb_compose_table_unref(table: *CComposeTable) void;
extern fn xkb_compose_table_iterator_new(table: *CComposeTable) ?*CComposeIterator;
extern fn xkb_compose_table_iterator_free(iterator: *CComposeIterator) void;
extern fn xkb_compose_table_iterator_next(iterator: *CComposeIterator) ?*CComposeEntry;
extern fn xkb_compose_table_entry_sequence(entry: *CComposeEntry, length: *usize) [*]const u32;
extern fn xkb_compose_table_entry_keysym(entry: *CComposeEntry) u32;
extern fn xkb_compose_table_entry_utf8(entry: *CComposeEntry) [*:0]const u8;
extern fn xkb_compose_state_new(table: *CComposeTable, flags: c_uint) ?*CComposeState;
extern fn xkb_compose_state_unref(state: *CComposeState) void;
extern fn xkb_compose_state_feed(state: *CComposeState, symbol: u32) c_uint;
extern fn xkb_compose_state_reset(state: *CComposeState) void;
extern fn xkb_compose_state_get_status(state: *CComposeState) c_uint;
extern fn xkb_compose_state_get_utf8(state: *CComposeState, buffer: [*]u8, size: usize) c_int;
extern fn xkb_compose_state_get_one_sym(state: *CComposeState) u32;
extern fn free(pointer: ?*anyopaque) void;

const state_mods_effective = 1 << 3;
const layout_invalid = std.math.maxInt(u32);

const Oracle = struct {
    context: *Context,
    keymap: *CKeymap,
    state: *CState,

    fn init(text: [:0]const u8) !Oracle {
        const context = xkb_context_new(0) orelse return error.Context;
        errdefer xkb_context_unref(context);
        const keymap = xkb_keymap_new_from_string(context, text.ptr, 1, 0) orelse return error.Keymap;
        errdefer xkb_keymap_unref(keymap);
        const state = xkb_state_new(keymap) orelse return error.State;
        return .{ .context = context, .keymap = keymap, .state = state };
    }

    fn initNames(names: RuleNames) !Oracle {
        const context = xkb_context_new(0) orelse return error.Context;
        errdefer xkb_context_unref(context);
        const rule_names = CRuleNames{
            .rules = "evdev",
            .model = "pc105",
            .layout = names.layout.ptr,
            .variant = if (names.variant) |variant| variant.ptr else null,
            .options = if (names.options) |options| options.ptr else null,
        };
        const keymap = xkb_keymap_new_from_names(context, &rule_names, 0) orelse return error.Keymap;
        errdefer xkb_keymap_unref(keymap);
        const state = xkb_state_new(keymap) orelse return error.State;
        return .{ .context = context, .keymap = keymap, .state = state };
    }

    fn deinit(self: Oracle) void {
        xkb_state_unref(self.state);
        xkb_keymap_unref(self.keymap);
        xkb_context_unref(self.context);
    }

    fn symbols(self: Oracle, code: u32) []const u32 {
        var values: [*]const u32 = undefined;
        const count = xkb_state_key_get_syms(self.state, code, &values);
        if (count <= 0) return &.{};
        return values[0..@intCast(count)];
    }
};

const RuleNames = struct {
    layout: [:0]const u8,
    variant: ?[:0]const u8 = null,
    options: ?[:0]const u8 = null,
};

const empty_text: [:0]const u8 =
    \\xkb_keymap {
    \\xkb_keycodes {
    \\  minimum = 8;
    \\  maximum = 255;
    \\};
    \\xkb_types {};
    \\xkb_compatibility {};
    \\xkb_symbols {};
    \\};
;

const repeat_text: [:0]const u8 =
    \\xkb_keymap {
    \\xkb_keycodes {
    \\  minimum = 8;
    \\  maximum = 255;
    \\  <RPT> = 38;
    \\};
    \\xkb_types {};
    \\xkb_compatibility {};
    \\xkb_symbols {
    \\  key <RPT> { repeat=yes };
    \\};
    \\};
;

const state_text: [:0]const u8 =
    \\xkb_keymap {
    \\xkb_keycodes {
    \\  minimum = 8;
    \\  maximum = 255;
    \\  <AC01> = 38;
    \\  <MULT> = 39;
    \\  <FALL> = 40;
    \\};
    \\xkb_types {
    \\  type "ALPHABET" {
    \\    modifiers = Shift+Lock;
    \\    map[Shift] = Level2;
    \\    map[Lock] = Level1;
    \\    preserve[Lock] = Lock;
    \\    map[Shift+Lock] = Level2;
    \\    preserve[Shift+Lock] = Lock;
    \\    level_name[Level1] = "Base";
    \\    level_name[Level2] = "Shift";
    \\  };
    \\  type "ONE_LEVEL" {
    \\    modifiers = none;
    \\    level_name[Level1] = "Any";
    \\  };
    \\};
    \\xkb_compatibility {
    \\  interpret.useModMapMods = AnyLevel;
    \\  interpret.repeat = False;
    \\};
    \\xkb_symbols {
    \\  name[Group1] = "One";
    \\  name[Group2] = "Two";
    \\  key <AC01> { type[Group1]="ALPHABET", symbols[Group1]=[a,A], repeat=yes };
    \\  key <MULT> { type[Group1]="ONE_LEVEL", symbols[Group1]=[{x,y}], repeat=no };
    \\  key <FALL> { type[Group1]="ONE_LEVEL", symbols[Group1]=[U03BB], type[Group2]="ONE_LEVEL", symbols[Group2]=[l], repeat=no };
    \\};
    \\};
;

const edge_text: [:0]const u8 =
    \\xkb_keymap {
    \\xkb_keycodes {
    \\  minimum = 8;
    \\  maximum = 255;
    \\  <EMPTY> = 38;
    \\  <PRES> = 39;
    \\};
    \\xkb_types {
    \\  type "ONE_LEVEL" {
    \\    modifiers = none;
    \\    level_name[Level1] = "Any";
    \\  };
    \\  type "PRESERVE_EDGE" {
    \\    modifiers = Shift+Lock;
    \\    map[Shift] = Level2;
    \\    preserve[Shift] = Lock;
    \\    level_name[Level1] = "Base";
    \\    level_name[Level2] = "Shift";
    \\  };
    \\};
    \\xkb_compatibility {};
    \\xkb_symbols {
    \\  key <EMPTY> { type[Group1]="ONE_LEVEL", symbols[Group1]=[NoSymbol] };
    \\  key <PRES> { type[Group1]="PRESERVE_EDGE", symbols[Group1]=[a,A] };
    \\};
    \\};
;

const virtual_text: [:0]const u8 =
    \\xkb_keymap {
    \\xkb_keycodes {
    \\  <TEST> = 38;
    \\  <VMOD> = 92;
    \\};
    \\xkb_types {
    \\  virtual_modifiers LevelThree;
    \\  type "ONE_LEVEL" {
    \\    modifiers = none;
    \\    level_name[1] = "Any";
    \\  };
    \\  type "VMOD_LEVEL" {
    \\    modifiers = LevelThree;
    \\    map[LevelThree] = 2;
    \\    level_name[1] = "Base";
    \\    level_name[2] = "Selected";
    \\  };
    \\};
    \\xkb_compatibility {
    \\  virtual_modifiers LevelThree;
    \\  interpret.useModMapMods = AnyLevel;
    \\  interpret.repeat = False;
    \\  interpret 0xfe03+AnyOf(all) {
    \\    virtualModifier = LevelThree;
    \\    useModMapMods = level1;
    \\    action = SetMods(modifiers=LevelThree);
    \\  };
    \\  interpret Any+AnyOf(all) {
    \\    action = SetMods(modifiers=modMapMods);
    \\  };
    \\};
    \\xkb_symbols {
    \\  key <TEST> {
    \\    type = "VMOD_LEVEL",
    \\    symbols[1] = [ a, A ],
    \\    symbols[2] = [ x, X ]
    \\  };
    \\  key <VMOD> { [ ISO_Level3_Shift ] };
    \\  modifier_map Mod5 { <VMOD> };
    \\};
    \\};
;

const km = xkb.keymap;
const modifiers = km.core_modifiers;
const alphabet_entries = [_]km.TypeEntry{
    .{ .modifiers = 1 << 0, .level = 1 },
    .{ .modifiers = 1 << 1, .level = 0, .preserve = 1 << 1 },
    .{ .modifiers = (1 << 0) | (1 << 1), .level = 1, .preserve = 1 << 1 },
};
const state_types = [_]km.KeyType{
    .{ .modifiers = (1 << 0) | (1 << 1), .level_count = 2, .entries = &alphabet_entries },
    .{ .modifiers = 0, .level_count = 1, .entries = &.{} },
};
const a_levels = [_]km.Level{
    .{ .symbols = &.{@fromBackingInt(@intCast('a'))}, .uppercase_symbols = &.{@fromBackingInt(@intCast('A'))} },
    .{ .symbols = &.{@fromBackingInt(@intCast('A'))} },
};
const a_groups = [_]km.Group{.{ .type_index = 0, .levels = &a_levels }};
const multi_levels = [_]km.Level{.{
    .symbols = &.{ @fromBackingInt(@intCast('x')), @fromBackingInt(@intCast('y')) },
    .uppercase_symbols = &.{ @fromBackingInt(@intCast('X')), @fromBackingInt(@intCast('Y')) },
}};
const multi_groups = [_]km.Group{.{ .type_index = 1, .levels = &multi_levels }};
const unicode_levels = [_]km.Level{.{
    .symbols = &.{@fromBackingInt(@intCast(0x010003bb))},
    .uppercase_symbols = &.{@fromBackingInt(@intCast(0x0100039b))},
}};
const ascii_levels = [_]km.Level{.{
    .symbols = &.{@fromBackingInt(@intCast('l'))},
    .uppercase_symbols = &.{@fromBackingInt(@intCast('L'))},
}};
const fallback_groups = [_]km.Group{
    .{ .type_index = 1, .levels = &unicode_levels },
    .{ .type_index = 1, .levels = &ascii_levels },
};
const state_keys = [_]km.Key{
    .{ .code = 38, .groups = &a_groups, .repeats = true },
    .{ .code = 39, .groups = &multi_groups },
    .{ .code = 40, .groups = &fallback_groups },
};
const state_definition = km.Definition{
    .modifiers = &modifiers,
    .types = &state_types,
    .keys = &state_keys,
};

const compose_text: [:0]const u8 =
    \\None <A> : "foo" X
    \\Shift <B> : Y
    \\<C> : dead_acute
    \\<o> <e> : "\401f\x0o\0o" X
    \\<Multi_key> <a> : "first" a
    \\<Multi_key> <a> <b> : "long" b
    \\<Multi_key> <a> : "replacement" c
    \\<Multi_key> <d> : "old" d
    \\<Multi_key> <d> : "new" e
    \\<dead_acute> <space> : "'" apostrophe
    \\<dead_acute> <dead_acute> : "´" acute
    \\<U1F600> : "" U1F600
    \\<G> : "\0011" G
    \\<H> : "\7777" H
;

test "conformance provenance is libxkbcommon 1.13.2" {
    try std.testing.expectEqualStrings("1.13.2", xkb.keysym.provenance.libxkbcommon_version);
    try std.testing.expectEqualStrings(
        "d1442aaa6b635551182e83c3b55037f4c118c962",
        xkb.keysym.provenance.libxkbcommon_commit,
    );
}

test "empty maps retain the eight ordered core modifiers" {
    const oracle = try Oracle.init(empty_text);
    defer oracle.deinit();
    try std.testing.expectEqual(@as(u32, km.core_modifier_count), xkb_keymap_num_mods(oracle.keymap));
    for (km.core_modifiers, 0..) |modifier, index| {
        const name = xkb_keymap_mod_get_name(oracle.keymap, @intCast(index)) orelse return error.ModifierName;
        try std.testing.expectEqualStrings(modifier.name, std.mem.span(name));
    }

    var storage: km.Keymap.Storage = undefined;
    const compiled = try km.Keymap.init(&storage, .{
        .modifiers = &km.core_modifiers,
        .types = &.{},
        .keys = &.{},
    });
    var native = xkb.state.State.init(compiled);
    _ = xkb_state_update_mask(oracle.state, std.math.maxInt(u32), 0, 0, 0, 0, 0);
    _ = native.update(.{ .depressed_modifiers = std.math.maxInt(u32) });
    try std.testing.expectEqual(
        xkb_state_serialize_mods(oracle.state, state_mods_effective),
        native.effectiveModifiers(),
    );
    try std.testing.expectEqual(km.core_modifier_mask, compiled.canonicalModifierMask());
}

test "repeat-only keys remain keys without symbol groups" {
    const oracle = try Oracle.init(repeat_text);
    defer oracle.deinit();
    const keys = [_]km.Key{.{ .code = 38, .groups = &.{}, .repeats = true }};
    var storage: km.Keymap.Storage = undefined;
    const compiled = try km.Keymap.init(&storage, .{
        .modifiers = &km.core_modifiers,
        .types = &.{},
        .keys = &keys,
    });
    const native = xkb.state.State.init(compiled);
    try std.testing.expectEqual(xkb_keymap_key_repeats(oracle.keymap, 38) != 0, native.keyRepeats(38));
    try std.testing.expectEqual(layout_invalid, xkb_state_key_get_layout(oracle.state, 38));
    try std.testing.expect(native.layout(38) == null);
    try std.testing.expect(native.level(38) == null);
    try std.testing.expectEqual(@as(usize, 0), oracle.symbols(38).len);
    try std.testing.expectEqual(@as(usize, 0), native.symbols(38).len);
}

test "canonical symbol sequences and state behavior match libxkbcommon" {
    const oracle = try Oracle.init(state_text);
    defer oracle.deinit();
    var storage: km.Keymap.Storage = undefined;
    var native = xkb.state.State.init(try km.Keymap.init(&storage, state_definition));

    _ = xkb_state_update_mask(oracle.state, 0, 0, 1 << 1, 0, 0, 0);
    _ = native.update(.{ .locked_modifiers = 1 << 1 });
    try expectSymbolsEqual(oracle.symbols(39), native.symbols(39));
    try std.testing.expectEqualSlices(u32, &.{ 'X', 'Y' }, oracle.symbols(39));

    const layout_cases = [_][3]u32{
        .{ 0, 0, 0 },
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
        .{ 3, 2, 1 },
        .{ std.math.maxInt(u32), 0, 0 },
        .{ 0, std.math.maxInt(u32), 1 },
        .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) },
    };
    for (0..8) |depressed| for (0..8) |latched| for (0..8) |locked| for (layout_cases) |layouts| {
        const oracle_changes = xkb_state_update_mask(
            oracle.state,
            @intCast(depressed),
            @intCast(latched),
            @intCast(locked),
            layouts[0],
            layouts[1],
            layouts[2],
        );
        const native_changes = native.update(.{
            .depressed_modifiers = @intCast(depressed),
            .latched_modifiers = @intCast(latched),
            .locked_modifiers = @intCast(locked),
            .depressed_layout = layouts[0],
            .latched_layout = layouts[1],
            .locked_layout = layouts[2],
        });
        try std.testing.expectEqual(oracle_changes & 0xff, changeMask(native_changes));
        for ([_]u32{ 38, 39, 40 }) |code| {
            const oracle_symbol = xkb_state_key_get_one_sym(oracle.state, code);
            const native_symbol = if (native.oneSymbol(code)) |symbol| @backingInt(symbol) else 0;
            try std.testing.expectEqual(oracle_symbol, native_symbol);
            try expectSymbolsEqual(oracle.symbols(code), native.symbols(code));
            const oracle_layout = xkb_state_key_get_layout(oracle.state, code);
            try std.testing.expectEqual(oracle_layout, @as(u32, @intCast(native.layout(code).?)));
            const oracle_level = xkb_state_key_get_level(oracle.state, code, oracle_layout);
            try std.testing.expectEqual(oracle_level, @as(u32, @intCast(native.level(code).?)));
            try std.testing.expectEqual(
                xkb_state_key_get_consumed_mods(oracle.state, code),
                native.consumedModifiers(code),
            );

            var oracle_buffer: [64]u8 = undefined;
            const oracle_length = xkb_state_key_get_utf8(oracle.state, code, &oracle_buffer, oracle_buffer.len);
            var native_buffer: [64]u8 = undefined;
            const native_text = (try native.writeUtf8(code, &native_buffer)) orelse &.{};
            try std.testing.expectEqual(@as(usize, @intCast(oracle_length)), native_text.len);
            try std.testing.expectEqualSlices(u8, oracle_buffer[0..@intCast(oracle_length)], native_text);
        }
    };
    try std.testing.expectEqual(xkb_keymap_key_repeats(oracle.keymap, 38) != 0, native.keyRepeats(38));
    try std.testing.expectEqual(xkb_keymap_key_repeats(oracle.keymap, 39) != 0, native.keyRepeats(39));
}

test "TEXT V1 compiler matches a pinned oracle canonical round trip" {
    const oracle = try Oracle.init(state_text);
    defer oracle.deinit();
    const dumped = xkb_keymap_get_as_string(oracle.keymap, 1) orelse return error.Dump;
    defer free(dumped);
    var compiled = try km.text.compile(std.testing.allocator, std.mem.span(dumped));
    defer compiled.deinit();
    var native = xkb.state.State.init(compiled.keymap());

    const masks = [_][4]u32{
        .{ 0, 0, 0, 0 },
        .{ 1 << 0, 0, 0, 0 },
        .{ 0, 0, 1 << 1, 0 },
        .{ 1 << 2, 1 << 0, 0, 1 },
        .{ std.math.maxInt(u8), 0, 0, std.math.maxInt(u32) },
    };
    for (masks) |mask| {
        _ = xkb_state_update_mask(oracle.state, mask[0], mask[1], mask[2], 0, 0, mask[3]);
        _ = native.update(.{
            .depressed_modifiers = mask[0],
            .latched_modifiers = mask[1],
            .locked_modifiers = mask[2],
            .locked_layout = mask[3],
        });
        for ([_]u32{ 38, 39, 40 }) |code| {
            try expectSymbolsEqual(oracle.symbols(code), native.symbols(code));
            const oracle_symbol = xkb_state_key_get_one_sym(oracle.state, code);
            const native_symbol = if (native.oneSymbol(code)) |symbol| @backingInt(symbol) else 0;
            try std.testing.expectEqual(oracle_symbol, native_symbol);
            try std.testing.expectEqual(
                xkb_keymap_key_repeats(oracle.keymap, code) != 0,
                native.keyRepeats(code),
            );
            var oracle_buffer: [64]u8 = undefined;
            const oracle_length = xkb_state_key_get_utf8(oracle.state, code, &oracle_buffer, oracle_buffer.len);
            var native_buffer: [64]u8 = undefined;
            const native_text = (try native.writeUtf8(code, &native_buffer)) orelse &.{};
            try std.testing.expectEqual(@as(usize, @intCast(oracle_length)), native_text.len);
            try std.testing.expectEqualSlices(u8, oracle_buffer[0..@intCast(oracle_length)], native_text);
        }
    }
}

test "TEXT V1 compat derives repeat and virtual modifier mappings" {
    const oracle = try Oracle.init(virtual_text);
    defer oracle.deinit();
    const dumped = xkb_keymap_get_as_string(oracle.keymap, 1) orelse return error.Dump;
    defer free(dumped);
    var compiled = try km.text.compile(std.testing.allocator, std.mem.span(dumped));
    defer compiled.deinit();
    var native = xkb.state.State.init(compiled.keymap());

    for ([_]u32{ 0, 1 << 7 }) |modifiers_mask| for ([_]u32{ 0, 1 }) |layout| {
        _ = xkb_state_update_mask(oracle.state, modifiers_mask, 0, 0, 0, 0, layout);
        _ = native.update(.{
            .depressed_modifiers = modifiers_mask,
            .locked_layout = layout,
        });
        try expectSymbolsEqual(oracle.symbols(38), native.symbols(38));
        try std.testing.expectEqual(
            xkb_state_mod_name_is_active(oracle.state, "LevelThree", state_mods_effective) != 0,
            native.modifierActive("LevelThree"),
        );
    };
    try std.testing.expectEqual(xkb_keymap_key_repeats(oracle.keymap, 38) != 0, native.keyRepeats(38));
    try std.testing.expectEqual(xkb_keymap_key_repeats(oracle.keymap, 92) != 0, native.keyRepeats(92));
    try std.testing.expect(native.keyRepeats(38));
    try std.testing.expect(!native.keyRepeats(92));
}

test "TEXT V1 compiles the evdev us keymap" {
    try expectRuleNamesRoundTrip(.{ .layout = "us" });
}

test "TEXT V1 compiles the evdev us intl keymap" {
    try expectRuleNamesRoundTrip(.{ .layout = "us", .variant = "intl" });
}

test "TEXT V1 compiles the evdev us ru group-switching keymap" {
    try expectRuleNamesRoundTrip(.{
        .layout = "us,ru",
        .options = "grp:alt_shift_toggle",
    });
}

test "TEXT V1 compiles the evdev de neo keymap" {
    try expectRuleNamesRoundTrip(.{ .layout = "de", .variant = "neo" });
}

test "TEXT V1 compiles the evdev jp compose and pointer-key keymap" {
    try expectRuleNamesRoundTrip(.{
        .layout = "jp",
        .options = "compose:ralt,ctrl:nocaps,keypad:pointerkeys",
    });
}

test "TEXT V1 compiles the evdev ara level-switching keymap" {
    try expectRuleNamesRoundTrip(.{
        .layout = "ara",
        .options = "lv3:ralt_switch,lv5:rctrl_switch",
    });
}

test "preserve clamping and NoSymbol elimination match canonical levels" {
    const oracle = try Oracle.init(edge_text);
    defer oracle.deinit();
    const preserve_entries = [_]km.TypeEntry{.{ .modifiers = 1 << 0, .level = 1 }};
    const edge_types = [_]km.KeyType{
        .{ .modifiers = 0, .level_count = 1, .entries = &.{} },
        .{ .modifiers = (1 << 0) | (1 << 1), .level_count = 2, .entries = &preserve_entries },
    };
    const empty_levels = [_]km.Level{.{ .symbols = &.{} }};
    const empty_groups = [_]km.Group{.{ .type_index = 0, .levels = &empty_levels }};
    const preserve_levels = [_]km.Level{
        .{ .symbols = &.{@fromBackingInt(@intCast('a'))}, .uppercase_symbols = &.{@fromBackingInt(@intCast('A'))} },
        .{ .symbols = &.{@fromBackingInt(@intCast('A'))} },
    };
    const preserve_groups = [_]km.Group{.{ .type_index = 1, .levels = &preserve_levels }};
    const edge_keys = [_]km.Key{
        .{ .code = 38, .groups = &empty_groups },
        .{ .code = 39, .groups = &preserve_groups },
    };
    var storage: km.Keymap.Storage = undefined;
    var native = xkb.state.State.init(try km.Keymap.init(&storage, .{
        .modifiers = &km.core_modifiers,
        .types = &edge_types,
        .keys = &edge_keys,
    }));
    try std.testing.expectEqual(@as(usize, 0), oracle.symbols(38).len);
    try std.testing.expectEqual(@as(usize, 0), native.symbols(38).len);

    _ = xkb_state_update_mask(oracle.state, 1 << 0, 0, 0, 0, 0, 0);
    _ = native.update(.{ .depressed_modifiers = 1 << 0 });
    try std.testing.expectEqual(
        xkb_state_key_get_consumed_mods(oracle.state, 39),
        native.consumedModifiers(39),
    );
}

test "Compose parser entries match the pinned oracle" {
    const allocator = std.testing.allocator;
    const context = xkb_context_new(0) orelse return error.Context;
    defer xkb_context_unref(context);
    const oracle_table = xkb_compose_table_new_from_buffer(
        context,
        compose_text.ptr,
        compose_text.len,
        "C",
        1,
        0,
    ) orelse return error.ComposeTable;
    defer xkb_compose_table_unref(oracle_table);
    const oracle_iterator = xkb_compose_table_iterator_new(oracle_table) orelse
        return error.ComposeIterator;
    defer xkb_compose_table_iterator_free(oracle_iterator);

    var native_storage = try xkb.compose.Storage.init(allocator, .{
        .sequence_symbols = compose_text.len,
        .text_bytes = compose_text.len,
    });
    defer native_storage.deinit(allocator);
    var scratch_storage = try xkb.compose.ScratchStorage.init(
        allocator,
        xkb.compose.default_scratch_limits,
    );
    defer scratch_storage.deinit(allocator);
    native_storage.activate();
    scratch_storage.activate();
    const native_table = try xkb.compose.compile(
        &native_storage,
        &scratch_storage,
        compose_text,
        .{ .locale = "C" },
    );
    defer native_storage.reset();
    var native_iterator = native_table.iterator();
    var count: usize = 0;
    while (true) {
        const native_entry = native_iterator.next();
        const oracle_entry = xkb_compose_table_iterator_next(oracle_iterator);
        try std.testing.expectEqual(native_entry == null, oracle_entry == null);
        if (native_entry == null) break;
        const native_value = native_entry.?;
        const oracle_value = oracle_entry.?;
        var oracle_length: usize = 0;
        const oracle_sequence = xkb_compose_table_entry_sequence(oracle_value, &oracle_length);
        try std.testing.expectEqual(native_value.sequence.len, oracle_length);
        for (native_value.sequence, oracle_sequence[0..oracle_length]) |native_symbol, oracle_symbol| {
            try std.testing.expectEqual(oracle_symbol, @backingInt(native_symbol));
        }
        try std.testing.expectEqual(
            xkb_compose_table_entry_keysym(oracle_value),
            if (native_value.symbol) |symbol| @backingInt(symbol) else 0,
        );
        try std.testing.expectEqualStrings(
            std.mem.span(xkb_compose_table_entry_utf8(oracle_value)),
            native_value.text orelse "",
        );
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 11), count);
}

test "Compose state transitions and outputs match every oracle entry" {
    const allocator = std.testing.allocator;
    const context = xkb_context_new(0) orelse return error.Context;
    defer xkb_context_unref(context);
    const oracle_table = xkb_compose_table_new_from_buffer(
        context,
        compose_text.ptr,
        compose_text.len,
        "C",
        1,
        0,
    ) orelse return error.ComposeTable;
    defer xkb_compose_table_unref(oracle_table);
    const oracle_state = xkb_compose_state_new(oracle_table, 0) orelse return error.ComposeState;
    defer xkb_compose_state_unref(oracle_state);

    var native_storage = try xkb.compose.Storage.init(allocator, .{
        .sequence_symbols = compose_text.len,
        .text_bytes = compose_text.len,
    });
    defer native_storage.deinit(allocator);
    var scratch_storage = try xkb.compose.ScratchStorage.init(
        allocator,
        xkb.compose.default_scratch_limits,
    );
    defer scratch_storage.deinit(allocator);
    native_storage.activate();
    scratch_storage.activate();
    const native_table = try xkb.compose.compile(
        &native_storage,
        &scratch_storage,
        compose_text,
        .{ .locale = "C" },
    );
    defer native_storage.reset();
    var native_state = xkb.compose.State.init(&native_table);
    var iterator_value = native_table.iterator();
    while (iterator_value.next()) |entry| {
        native_state.reset();
        xkb_compose_state_reset(oracle_state);
        for (entry.sequence) |symbol| {
            const oracle_feed = xkb_compose_state_feed(oracle_state, @backingInt(symbol));
            const native_feed = native_state.feed(symbol);
            try std.testing.expectEqual(oracle_feed, @backingInt(native_feed));
            try std.testing.expectEqual(
                xkb_compose_state_get_status(oracle_state),
                @backingInt(native_state.status()),
            );
        }
        try std.testing.expectEqual(
            xkb_compose_state_get_one_sym(oracle_state),
            if (native_state.symbol()) |symbol| @backingInt(symbol) else 0,
        );

        var oracle_buffer: [xkb.compose.max_output_bytes + 1]u8 = undefined;
        const oracle_length = xkb_compose_state_get_utf8(
            oracle_state,
            &oracle_buffer,
            oracle_buffer.len,
        );
        var native_buffer: [xkb.compose.max_output_bytes]u8 = undefined;
        const native_text = (try native_state.writeUtf8(&native_buffer)) orelse &.{};
        try std.testing.expectEqual(@as(usize, @intCast(oracle_length)), native_text.len);
        try std.testing.expectEqualSlices(
            u8,
            oracle_buffer[0..@intCast(oracle_length)],
            native_text,
        );
    }

    native_state.reset();
    xkb_compose_state_reset(oracle_state);
    for ([_]u32{ 0xff20, 'a', '7', 'A', 0xffe1 }) |symbol_value| {
        const symbol: xkb.keysym.Keysym = @fromBackingInt(@intCast(symbol_value));
        try std.testing.expectEqual(
            xkb_compose_state_feed(oracle_state, symbol_value),
            @backingInt(native_state.feed(symbol)),
        );
        try std.testing.expectEqual(
            xkb_compose_state_get_status(oracle_state),
            @backingInt(native_state.status()),
        );
    }
}

fn expectSymbolsEqual(oracle_symbols: []const u32, native_symbols: []const xkb.keysym.Keysym) !void {
    try std.testing.expectEqual(oracle_symbols.len, native_symbols.len);
    for (oracle_symbols, native_symbols) |oracle_symbol, native_symbol| {
        try std.testing.expectEqual(oracle_symbol, @backingInt(native_symbol));
    }
}

fn expectRuleNamesRoundTrip(names: RuleNames) !void {
    const oracle = try Oracle.initNames(names);
    defer oracle.deinit();
    const dumped = xkb_keymap_get_as_string(oracle.keymap, 1) orelse return error.Dump;
    defer free(dumped);
    var compiled = try km.text.compile(std.testing.allocator, std.mem.span(dumped));
    defer compiled.deinit();
    const keymap = compiled.keymap();
    var native = xkb.state.State.init(keymap);

    const layout_count = xkb_keymap_num_layouts(oracle.keymap);
    try std.testing.expect(layout_count <= km.max_layouts);
    try std.testing.expectEqual(@as(usize, @intCast(layout_count)), keymap.layoutCount());

    const minimum = xkb_keymap_min_keycode(oracle.keymap);
    const maximum = xkb_keymap_max_keycode(oracle.keymap);
    var code = minimum;
    while (true) {
        try std.testing.expectEqual(
            xkb_keymap_key_repeats(oracle.keymap, code) != 0,
            native.keyRepeats(code),
        );
        if (code == maximum) break;
        code += 1;
    }

    var masks: [304]u32 = undefined;
    var mask_count: usize = 0;
    for (0..256) |mask| {
        masks[mask_count] = @intCast(mask);
        mask_count += 1;
    }
    const modifier_count = @min(xkb_keymap_num_mods(oracle.keymap), @bitSizeOf(u32));
    for (km.core_modifier_count..modifier_count) |index| {
        const bit = @as(u32, 1) << @intCast(index);
        masks[mask_count] = bit;
        mask_count += 1;
        masks[mask_count] = bit | km.core_modifier_mask;
        mask_count += 1;
    }

    var groups: [km.max_layouts + 2]u32 = undefined;
    var group_count: usize = 0;
    for (0..layout_count) |group| {
        groups[group_count] = @intCast(group);
        group_count += 1;
    }
    groups[group_count] = layout_count;
    group_count += 1;
    groups[group_count] = std.math.maxInt(u32);
    group_count += 1;

    for (groups[0..group_count]) |group| for (masks[0..mask_count]) |mask| {
        _ = xkb_state_update_mask(oracle.state, mask, 0, 0, 0, 0, group);
        _ = native.update(.{
            .depressed_modifiers = mask,
            .locked_layout = group,
        });
        code = minimum;
        while (true) {
            try expectSymbolsEqual(oracle.symbols(code), native.symbols(code));
            const oracle_symbol = xkb_state_key_get_one_sym(oracle.state, code);
            const native_symbol = if (native.oneSymbol(code)) |symbol| @backingInt(symbol) else 0;
            try std.testing.expectEqual(oracle_symbol, native_symbol);

            const oracle_layout = xkb_state_key_get_layout(oracle.state, code);
            const native_layout = native.layout(code);
            if (oracle_layout == layout_invalid) {
                try std.testing.expect(native_layout == null);
            } else {
                try std.testing.expectEqual(oracle_layout, @as(u32, @intCast(native_layout.?)));
                try std.testing.expectEqual(
                    xkb_state_key_get_level(oracle.state, code, oracle_layout),
                    @as(u32, @intCast(native.level(code).?)),
                );
            }
            if (code == maximum) break;
            code += 1;
        }
    };
}

fn changeMask(value: xkb.state.Changes) u32 {
    var result: u32 = 0;
    if (value.depressed_modifiers) result |= 1;
    if (value.latched_modifiers) result |= 2;
    if (value.locked_modifiers) result |= 4;
    if (value.effective_modifiers) result |= 8;
    if (value.depressed_layout) result |= 16;
    if (value.latched_layout) result |= 32;
    if (value.locked_layout) result |= 64;
    if (value.effective_layout) result |= 128;
    return result;
}
