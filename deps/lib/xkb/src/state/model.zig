const std = @import("std");
const xkb = @import("../root.zig");

const keymap = xkb.keymap;
const keysym = xkb.keysym;

pub const Mask = struct {
    depressed_modifiers: keymap.ModifierMask = 0,
    latched_modifiers: keymap.ModifierMask = 0,
    locked_modifiers: keymap.ModifierMask = 0,
    depressed_layout: u32 = 0,
    latched_layout: u32 = 0,
    locked_layout: u32 = 0,
};

pub const Changes = struct {
    depressed_modifiers: bool = false,
    latched_modifiers: bool = false,
    locked_modifiers: bool = false,
    effective_modifiers: bool = false,
    depressed_layout: bool = false,
    latched_layout: bool = false,
    locked_layout: bool = false,
    effective_layout: bool = false,

    pub fn any(self: Changes) bool {
        return self.depressed_modifiers or self.latched_modifiers or
            self.locked_modifiers or self.effective_modifiers or
            self.depressed_layout or self.latched_layout or
            self.locked_layout or self.effective_layout;
    }
};

pub const ModifierComponents = struct {
    depressed: bool = false,
    latched: bool = false,
    locked: bool = false,
    effective: bool = false,
};

pub const TextError = error{BufferTooSmall};

const Components = struct {
    depressed_modifiers: keymap.ModifierMask = 0,
    latched_modifiers: keymap.ModifierMask = 0,
    locked_modifiers: keymap.ModifierMask = 0,
    effective_modifiers: keymap.ModifierMask = 0,
    depressed_layout: i32 = 0,
    latched_layout: i32 = 0,
    locked_layout: i32 = 0,
    effective_layout: i32 = 0,
};

pub const State = struct {
    keymap: *const keymap.Keymap,
    components: Components = .{},

    pub fn init(compiled: *const keymap.Keymap) State {
        return .{ .keymap = compiled };
    }

    pub fn update(self: *State, input: Mask) Changes {
        const previous = self.components;
        self.components.depressed_modifiers = self.keymap.resolveToCanonicalModifiers(input.depressed_modifiers);
        self.components.latched_modifiers = self.keymap.resolveToCanonicalModifiers(input.latched_modifiers);
        self.components.locked_modifiers = self.keymap.resolveToCanonicalModifiers(input.locked_modifiers);
        self.components.effective_modifiers = self.components.depressed_modifiers |
            self.components.latched_modifiers |
            self.components.locked_modifiers;
        self.components.depressed_layout = @bitCast(input.depressed_layout);
        self.components.latched_layout = @bitCast(input.latched_layout);
        self.components.locked_layout = layoutInRange(@bitCast(input.locked_layout), self.keymap.layoutCount());
        const layout_sum = self.components.depressed_layout +%
            self.components.latched_layout +% self.components.locked_layout;
        self.components.effective_layout = layoutInRange(layout_sum, self.keymap.layoutCount());
        return changes(previous, self.components);
    }

    pub fn effectiveModifiers(self: *const State) keymap.ModifierMask {
        return self.components.effective_modifiers;
    }

    pub fn effectiveLayout(self: *const State) usize {
        return @intCast(self.components.effective_layout);
    }

    pub fn modifierActive(self: *const State, name: []const u8) bool {
        const index = self.keymap.modifierIndex(name) orelse return false;
        return self.modifierIndexActive(index, .{ .effective = true });
    }

    pub fn modifierIndexActive(
        self: *const State,
        index: usize,
        requested: ModifierComponents,
    ) bool {
        const mapping = self.keymap.modifierMapping(index) orelse return false;
        if (mapping == 0) return false;
        const active = self.serializeModifiers(requested);
        return active & mapping == mapping;
    }

    pub fn keyRepeats(self: *const State, code: keymap.Keycode) bool {
        const key_value = self.keymap.key(code) orelse return false;
        return key_value.repeats;
    }

    pub fn layout(self: *const State, code: keymap.Keycode) ?usize {
        const key_value = self.keymap.key(code) orelse return null;
        return self.keymap.group(key_value, self.components.effective_layout);
    }

    pub fn level(self: *const State, code: keymap.Keycode) ?usize {
        const key_value = self.keymap.key(code) orelse return null;
        const group_index = self.keymap.group(key_value, self.components.effective_layout) orelse return null;
        return self.levelForGroup(key_value, group_index);
    }

    pub fn symbols(self: *const State, code: keymap.Keycode) []const keysym.Keysym {
        const selection_value = self.selection(code) orelse return &.{};
        return selection_value.level.resolvedSymbols(self.capsTransforms(code));
    }

    pub fn oneSymbol(self: *const State, code: keymap.Keycode) ?keysym.Keysym {
        const selected = self.symbols(code);
        if (selected.len != 1) return null;
        return selected[0];
    }

    pub fn consumedModifiers(self: *const State, code: keymap.Keycode) keymap.ModifierMask {
        const selection_value = self.selection(code) orelse return 0;
        const key_type = self.keymap.keyType(selection_value.group.type_index).?;
        const active = self.components.effective_modifiers & key_type.modifiers;
        var preserve: keymap.ModifierMask = 0;
        for (key_type.entries) |entry| {
            if (entry.modifiers == active) {
                preserve = entry.preserve;
                break;
            }
        }
        return key_type.modifiers & ~preserve;
    }

    pub fn modifierConsumed(self: *const State, code: keymap.Keycode, name: []const u8) bool {
        const index = self.keymap.modifierIndex(name) orelse return false;
        const mapping = self.keymap.modifierMapping(index) orelse return false;
        if (mapping == 0) return false;
        return self.consumedModifiers(code) & mapping == mapping;
    }

    pub fn writeUtf8(
        self: *const State,
        code: keymap.Keycode,
        buffer: []u8,
    ) TextError!?[]const u8 {
        const control = self.controlTransforms(code);
        if (self.oneSymbolForText(code, control)) |symbol| {
            const written = try writeSymbol(symbol, buffer);
            if (written == 0) return null;
            if (written == 1 and control) buffer[0] = toControl(buffer[0]);
            return buffer[0..written];
        }

        const selected = self.symbols(code);
        if (selected.len == 0) return null;
        var written: usize = 0;
        for (selected) |symbol| {
            const count = try writeSymbol(symbol, buffer[written..]);
            if (count == 0) return null;
            written += count;
        }
        if (written == 1 and control) buffer[0] = toControl(buffer[0]);
        return buffer[0..written];
    }

    fn serializeModifiers(self: *const State, requested: ModifierComponents) keymap.ModifierMask {
        if (requested.effective) return self.components.effective_modifiers;
        var result: keymap.ModifierMask = 0;
        if (requested.depressed) result |= self.components.depressed_modifiers;
        if (requested.latched) result |= self.components.latched_modifiers;
        if (requested.locked) result |= self.components.locked_modifiers;
        return result;
    }

    fn selection(self: *const State, code: keymap.Keycode) ?Selection {
        const key_value = self.keymap.key(code) orelse return null;
        const group_index = self.keymap.group(key_value, self.components.effective_layout) orelse return null;
        const group = &key_value.groups[group_index];
        const level_index = self.levelForGroup(key_value, group_index);
        if (level_index >= group.levels.len) return null;
        return .{
            .key = key_value,
            .group = group,
            .level = &group.levels[level_index],
        };
    }

    fn levelForGroup(self: *const State, key_value: *const keymap.Key, group_index: usize) usize {
        const group = key_value.groups[group_index];
        const key_type = self.keymap.keyType(group.type_index).?;
        const active = self.components.effective_modifiers & key_type.modifiers;
        for (key_type.entries) |entry| {
            if (entry.modifiers == active) return entry.level;
        }
        return 0;
    }

    fn capsTransforms(self: *const State, code: keymap.Keycode) bool {
        return self.modifierActive("Lock") and !self.modifierConsumed(code, "Lock");
    }

    fn controlTransforms(self: *const State, code: keymap.Keycode) bool {
        return self.modifierActive("Control") and !self.modifierConsumed(code, "Control");
    }

    fn oneSymbolForText(
        self: *const State,
        code: keymap.Keycode,
        control: bool,
    ) ?keysym.Keysym {
        const selected = self.selection(code) orelse return null;
        if (selected.level.symbols.len != 1) return null;
        var selected_level = selected.level;
        if (control and @backingInt(selected_level.symbols[0]) > 127) {
            for (selected.key.groups, 0..) |group, group_index| {
                const level_index = self.levelForGroup(selected.key, group_index);
                if (level_index >= group.levels.len) continue;
                const candidates = group.levels[level_index].symbols;
                if (candidates.len == 1 and @backingInt(candidates[0]) <= 127) {
                    selected_level = &group.levels[level_index];
                    break;
                }
            }
        }
        const resolved = selected_level.resolvedSymbols(self.capsTransforms(code));
        return resolved[0];
    }
};

const Selection = struct {
    key: *const keymap.Key,
    group: *const keymap.Group,
    level: *const keymap.Level,
};

fn layoutInRange(value: i32, count: usize) i32 {
    if (count == 0) return 0;
    return @intCast(@mod(@as(i64, value), @as(i64, @intCast(count))));
}

fn changes(previous: Components, next: Components) Changes {
    return .{
        .depressed_modifiers = previous.depressed_modifiers != next.depressed_modifiers,
        .latched_modifiers = previous.latched_modifiers != next.latched_modifiers,
        .locked_modifiers = previous.locked_modifiers != next.locked_modifiers,
        .effective_modifiers = previous.effective_modifiers != next.effective_modifiers,
        .depressed_layout = previous.depressed_layout != next.depressed_layout,
        .latched_layout = previous.latched_layout != next.latched_layout,
        .locked_layout = previous.locked_layout != next.locked_layout,
        .effective_layout = previous.effective_layout != next.effective_layout,
    };
}

fn writeSymbol(symbol: keysym.Keysym, buffer: []u8) TextError!usize {
    const codepoint = keysym.codepoint(symbol) orelse return 0;
    var encoded: [4]u8 = undefined;
    const count = std.unicode.utf8Encode(codepoint, &encoded) catch return 0;
    if (count > buffer.len) return error.BufferTooSmall;
    @memcpy(buffer[0..count], encoded[0..count]);
    return count;
}

fn toControl(input: u8) u8 {
    if ((input >= '@' and input < 0x7f) or input == ' ') return input & 0x1f;
    if (input == '2') return 0;
    if (input >= '3' and input <= '7') return input - ('3' - 0x1b);
    if (input == '8') return 0x7f;
    if (input == '/') return '_' & 0x1f;
    return input;
}

const Fixture = struct {
    const modifiers = keymap.core_modifiers ++ [_]keymap.Modifier{
        .{ .name = "NumLock", .mapping = 1 << 3, .kind = .virtual },
    };
    const alphabet_entries = [_]keymap.TypeEntry{
        .{ .modifiers = 1 << 0, .level = 1 },
        .{ .modifiers = 1 << 1, .level = 0, .preserve = 1 << 1 },
        .{ .modifiers = (1 << 0) | (1 << 1), .level = 1, .preserve = 1 << 1 },
    };
    const types = [_]keymap.KeyType{
        .{ .modifiers = (1 << 0) | (1 << 1), .level_count = 2, .entries = &alphabet_entries },
        .{ .modifiers = 0, .level_count = 1, .entries = &.{} },
    };
    const a_levels = [_]keymap.Level{
        .{ .symbols = &.{@fromBackingInt(@intCast('a'))}, .uppercase_symbols = &.{@fromBackingInt(@intCast('A'))} },
        .{ .symbols = &.{@fromBackingInt(@intCast('A'))} },
    };
    const a_groups = [_]keymap.Group{.{ .type_index = 0, .levels = &a_levels }};
    const multi_levels = [_]keymap.Level{.{
        .symbols = &.{ @fromBackingInt(@intCast('x')), @fromBackingInt(@intCast('y')) },
        .uppercase_symbols = &.{ @fromBackingInt(@intCast('X')), @fromBackingInt(@intCast('Y')) },
    }};
    const multi_groups = [_]keymap.Group{.{ .type_index = 1, .levels = &multi_levels }};
    const unicode_levels = [_]keymap.Level{.{
        .symbols = &.{@fromBackingInt(@intCast(0x010003bb))},
        .uppercase_symbols = &.{@fromBackingInt(@intCast(0x0100039b))},
    }};
    const ascii_levels = [_]keymap.Level{.{
        .symbols = &.{@fromBackingInt(@intCast('l'))},
        .uppercase_symbols = &.{@fromBackingInt(@intCast('L'))},
    }};
    const fallback_groups = [_]keymap.Group{
        .{ .type_index = 1, .levels = &unicode_levels },
        .{ .type_index = 1, .levels = &ascii_levels },
    };
    const keys = [_]keymap.Key{
        .{ .code = 38, .groups = &a_groups, .repeats = true },
        .{ .code = 39, .groups = &multi_groups },
        .{ .code = 40, .groups = &fallback_groups },
    };

    fn definition() keymap.Definition {
        return .{
            .modifiers = &modifiers,
            .types = &types,
            .keys = &keys,
        };
    }
};

test "external masks select levels and report state changes" {
    var storage: keymap.Keymap.Storage = undefined;
    var state = State.init(try keymap.Keymap.init(&storage, Fixture.definition()));

    try std.testing.expectEqual(@as(?keysym.Keysym, @fromBackingInt(@intCast('a'))), state.oneSymbol(38));
    const first = state.update(.{ .depressed_modifiers = 1 });
    try std.testing.expect(first.depressed_modifiers);
    try std.testing.expect(first.effective_modifiers);
    try std.testing.expectEqual(@as(?keysym.Keysym, @fromBackingInt(@intCast('A'))), state.oneSymbol(38));
    try std.testing.expect(!state.update(.{ .depressed_modifiers = 1 }).any());

    const virtual_num_lock = keymap.modifierBit(8);
    _ = state.update(.{ .locked_modifiers = virtual_num_lock });
    try std.testing.expect(state.modifierActive("Mod1"));
    try std.testing.expect(state.modifierActive("NumLock"));
}

test "caps preserve and control transformations match XKB text semantics" {
    var storage: keymap.Keymap.Storage = undefined;
    var state = State.init(try keymap.Keymap.init(&storage, Fixture.definition()));
    var buffer: [8]u8 = undefined;

    _ = state.update(.{ .locked_modifiers = 1 << 1 });
    try std.testing.expectEqual(@as(?keysym.Keysym, @fromBackingInt(@intCast('A'))), state.oneSymbol(38));
    try std.testing.expectEqualStrings("A", (try state.writeUtf8(38, &buffer)).?);

    _ = state.update(.{ .depressed_modifiers = 1 << 2 });
    const control_a = (try state.writeUtf8(38, &buffer)).?;
    try std.testing.expectEqual(@as(usize, 1), control_a.len);
    try std.testing.expectEqual(@as(u8, 1), control_a[0]);

    _ = state.update(.{ .depressed_modifiers = 1 << 2, .depressed_layout = 0 });
    const fallback = (try state.writeUtf8(40, &buffer)).?;
    try std.testing.expectEqual(@as(usize, 1), fallback.len);
    try std.testing.expectEqual(@as(u8, 12), fallback[0]);
}

test "multi-symbol levels concatenate Unicode and preserve one-symbol absence" {
    var storage: keymap.Keymap.Storage = undefined;
    var state = State.init(try keymap.Keymap.init(&storage, Fixture.definition()));
    var buffer: [8]u8 = undefined;

    try std.testing.expectEqual(@as(?keysym.Keysym, null), state.oneSymbol(39));
    try std.testing.expectEqualStrings("xy", (try state.writeUtf8(39, &buffer)).?);
    try std.testing.expectError(error.BufferTooSmall, state.writeUtf8(39, buffer[0..1]));
    try std.testing.expect(state.keyRepeats(38));
    try std.testing.expect(!state.keyRepeats(39));
}

test "effective layout and per-key group rules are distinct" {
    var storage: keymap.Keymap.Storage = undefined;
    var state = State.init(try keymap.Keymap.init(&storage, Fixture.definition()));
    const changed = state.update(.{ .depressed_layout = 3 });
    try std.testing.expect(changed.depressed_layout);
    try std.testing.expect(changed.effective_layout);
    try std.testing.expectEqual(@as(usize, 1), state.effectiveLayout());
    try std.testing.expectEqual(@as(?usize, 0), state.layout(38));
    try std.testing.expectEqual(@as(?usize, 1), state.layout(40));
}

test "empty keymaps retain canonical core modifiers" {
    var storage: keymap.Keymap.Storage = undefined;
    const empty = try keymap.Keymap.init(&storage, .{
        .modifiers = &keymap.core_modifiers,
        .types = &.{},
        .keys = &.{},
    });
    var state = State.init(empty);
    _ = state.update(.{
        .depressed_modifiers = std.math.maxInt(u32),
        .depressed_layout = std.math.maxInt(u32),
    });
    try std.testing.expectEqual(keymap.core_modifier_mask, state.effectiveModifiers());
    try std.testing.expectEqual(@as(usize, 0), state.effectiveLayout());
    try std.testing.expect(state.oneSymbol(38) == null);
}

test "repeat-only keys expose no layout level or symbols" {
    const keys = [_]keymap.Key{.{ .code = 38, .groups = &.{}, .repeats = true }};
    var storage: keymap.Keymap.Storage = undefined;
    const compiled = try keymap.Keymap.init(&storage, .{
        .modifiers = &keymap.core_modifiers,
        .types = &.{},
        .keys = &keys,
    });
    const state = State.init(compiled);
    try std.testing.expect(state.keyRepeats(38));
    try std.testing.expect(state.layout(38) == null);
    try std.testing.expect(state.level(38) == null);
    try std.testing.expectEqual(@as(usize, 0), state.symbols(38).len);
}

test "symbols exposes the canonical transformed sequence" {
    var storage: keymap.Keymap.Storage = undefined;
    var state = State.init(try keymap.Keymap.init(&storage, Fixture.definition()));
    _ = state.update(.{ .locked_modifiers = 1 << 1 });
    try std.testing.expectEqualSlices(keysym.Keysym, &.{ @fromBackingInt(@intCast('X')), @fromBackingInt(@intCast('Y')) }, state.symbols(39));
}
