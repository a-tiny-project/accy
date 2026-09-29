const std = @import("std");
const xkb = @import("../root.zig");

pub const ModifierMask = u32;
pub const Keycode = u32;
pub const max_layouts = 32;
pub const core_modifier_count = 8;
pub const core_modifier_mask: ModifierMask = (1 << core_modifier_count) - 1;

pub const Modifier = struct {
    name: []const u8,
    mapping: ModifierMask,
    kind: Kind,

    pub const Kind = enum {
        real,
        virtual,
    };
};

pub const core_modifiers = [_]Modifier{
    .{ .name = "Shift", .mapping = 1 << 0, .kind = .real },
    .{ .name = "Lock", .mapping = 1 << 1, .kind = .real },
    .{ .name = "Control", .mapping = 1 << 2, .kind = .real },
    .{ .name = "Mod1", .mapping = 1 << 3, .kind = .real },
    .{ .name = "Mod2", .mapping = 1 << 4, .kind = .real },
    .{ .name = "Mod3", .mapping = 1 << 5, .kind = .real },
    .{ .name = "Mod4", .mapping = 1 << 6, .kind = .real },
    .{ .name = "Mod5", .mapping = 1 << 7, .kind = .real },
};

pub const TypeEntry = struct {
    modifiers: ModifierMask,
    preserve: ModifierMask = 0,
    level: usize,
};

pub const KeyType = struct {
    modifiers: ModifierMask,
    level_count: usize,
    entries: []const TypeEntry,
};

pub const Level = struct {
    symbols: []const xkb.keysym.Keysym,
    uppercase_symbols: ?[]const xkb.keysym.Keysym = null,

    pub fn resolvedSymbols(self: *const Level, uppercase: bool) []const xkb.keysym.Keysym {
        if (uppercase) return self.uppercase_symbols orelse self.symbols;
        return self.symbols;
    }
};

pub const Group = struct {
    type_index: usize,
    levels: []const Level,
};

pub const OutOfRange = union(enum) {
    wrap,
    saturate,
    redirect: usize,
};

pub const Key = struct {
    code: Keycode,
    groups: []const Group,
    out_of_range: OutOfRange = .wrap,
    repeats: bool = false,
};

pub const Definition = struct {
    modifiers: []const Modifier,
    types: []const KeyType,
    keys: []const Key,
};

pub const ValidationError = error{
    TooManyModifiers,
    InvalidCoreModifiers,
    DuplicateModifierName,
    InvalidModifierMapping,
    EmptyKeyType,
    InvalidTypeEntry,
    DuplicateTypeEntry,
    InvalidGroupType,
    InvalidGroupLevels,
    InvalidGroupRedirect,
    InvalidKeyOrder,
    InvalidLayoutCount,
    InvalidKeysym,
    InvalidUppercaseSymbols,
};

const Backing = struct {
    definition: Definition,
    layout_count: usize,
};

pub const Keymap = opaque {
    pub const Storage = struct {
        bytes: [@sizeOf(Backing)]u8 align(@alignOf(Backing)),
    };

    pub fn init(storage_value: *Storage, definition: Definition) ValidationError!*const Keymap {
        const layout_count = try validate(definition);
        const backing: *Backing = @ptrCast(storage_value);
        backing.* = .{
            .definition = definition,
            .layout_count = layout_count,
        };
        return @ptrCast(storage_value);
    }

    pub fn modifierIndex(self: *const Keymap, name: []const u8) ?usize {
        for (self.storage().definition.modifiers, 0..) |modifier, index| {
            if (std.mem.eql(u8, modifier.name, name)) return index;
        }
        return null;
    }

    pub fn modifierMapping(self: *const Keymap, index: usize) ?ModifierMask {
        const modifiers = self.storage().definition.modifiers;
        if (index >= modifiers.len) return null;
        return modifiers[index].mapping;
    }

    pub fn canonicalModifierMask(self: *const Keymap) ModifierMask {
        _ = self;
        return core_modifier_mask;
    }

    pub fn effectiveModifiers(self: *const Keymap, input: ModifierMask) ModifierMask {
        const modifiers = self.storage().definition.modifiers;
        var result = input & core_modifier_mask;
        for (modifiers[core_modifier_count..], core_modifier_count..) |modifier, index| {
            if (input & modifierBit(index) != 0) result |= modifier.mapping;
        }
        return result;
    }

    pub fn resolveToCanonicalModifiers(self: *const Keymap, input: ModifierMask) ModifierMask {
        return (input & core_modifier_mask) |
            self.effectiveModifiers(input & ~core_modifier_mask);
    }

    pub fn layoutCount(self: *const Keymap) usize {
        return self.storage().layout_count;
    }

    pub fn keyType(self: *const Keymap, index: usize) ?*const KeyType {
        const types = self.storage().definition.types;
        if (index >= types.len) return null;
        return &types[index];
    }

    pub fn key(self: *const Keymap, code: Keycode) ?*const Key {
        const keys = self.storage().definition.keys;
        var low: usize = 0;
        var high = keys.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const candidate = &keys[middle];
            if (code < candidate.code) {
                high = middle;
            } else if (code > candidate.code) {
                low = middle + 1;
            } else {
                return candidate;
            }
        }
        return null;
    }

    pub fn group(self: *const Keymap, key_value: *const Key, effective_layout: i32) ?usize {
        _ = self;
        if (key_value.groups.len == 0) return null;
        return groupInRange(effective_layout, key_value.groups.len, key_value.out_of_range);
    }

    fn storage(self: *const Keymap) *const Backing {
        return @ptrCast(@alignCast(self));
    }
};

comptime {
    std.debug.assert(@sizeOf(Keymap.Storage) == @sizeOf(Backing));
    std.debug.assert(@alignOf(Keymap.Storage) == @alignOf(Backing));
}

pub fn modifierBit(index: usize) ModifierMask {
    std.debug.assert(index < @bitSizeOf(ModifierMask));
    return @as(ModifierMask, 1) << @intCast(index);
}

pub fn groupInRange(group: i32, count: usize, out_of_range: OutOfRange) usize {
    std.debug.assert(count != 0);
    if (group >= 0 and @as(usize, @intCast(group)) < count) return @intCast(group);
    return switch (out_of_range) {
        .redirect => |redirect| if (redirect < count) redirect else 0,
        .saturate => if (group < 0) 0 else count - 1,
        .wrap => @intCast(@mod(@as(i64, group), @as(i64, @intCast(count)))),
    };
}

fn validate(definition: Definition) ValidationError!usize {
    if (definition.modifiers.len > @bitSizeOf(ModifierMask)) return error.TooManyModifiers;
    if (definition.modifiers.len < core_modifier_count) return error.InvalidCoreModifiers;

    for (definition.modifiers, 0..) |modifier, index| {
        if (index < core_modifier_count) {
            const core = core_modifiers[index];
            if (modifier.kind != .real or modifier.mapping != core.mapping or
                !std.mem.eql(u8, modifier.name, core.name))
            {
                return error.InvalidCoreModifiers;
            }
        } else if (modifier.kind != .virtual or modifier.mapping & ~core_modifier_mask != 0) {
            return error.InvalidModifierMapping;
        }
        for (definition.modifiers[index + 1 ..]) |other| {
            if (std.mem.eql(u8, modifier.name, other.name)) return error.DuplicateModifierName;
        }
    }

    for (definition.types) |key_type| {
        if (key_type.level_count == 0) return error.EmptyKeyType;
        for (key_type.entries, 0..) |entry, entry_index| {
            if (entry.level >= key_type.level_count or
                entry.modifiers & ~key_type.modifiers != 0 or
                entry.preserve & ~entry.modifiers != 0)
            {
                return error.InvalidTypeEntry;
            }
            for (key_type.entries[entry_index + 1 ..]) |other| {
                if (entry.modifiers == other.modifiers) return error.DuplicateTypeEntry;
            }
        }
    }

    var layout_count: usize = 0;
    var previous_code: ?Keycode = null;
    for (definition.keys) |key_value| {
        if (previous_code) |previous| {
            if (key_value.code <= previous) return error.InvalidKeyOrder;
        }
        previous_code = key_value.code;
        layout_count = @max(layout_count, key_value.groups.len);
        if (layout_count > max_layouts) return error.InvalidLayoutCount;
        if (key_value.out_of_range == .redirect and
            key_value.out_of_range.redirect >= key_value.groups.len)
        {
            return error.InvalidGroupRedirect;
        }
        for (key_value.groups) |group_value| {
            if (group_value.type_index >= definition.types.len) return error.InvalidGroupType;
            if (group_value.levels.len != definition.types[group_value.type_index].level_count) {
                return error.InvalidGroupLevels;
            }
            for (group_value.levels) |level| try validateLevel(level);
        }
    }
    return layout_count;
}

fn validateLevel(level: Level) ValidationError!void {
    for (level.symbols) |symbol| try validateSymbol(symbol);
    if (level.uppercase_symbols) |uppercase_symbols| {
        if (uppercase_symbols.len != level.symbols.len) return error.InvalidUppercaseSymbols;
        var changed = false;
        for (level.symbols, uppercase_symbols) |symbol, uppercase_symbol| {
            try validateSymbol(uppercase_symbol);
            if (xkb.keysym.upper(symbol) != uppercase_symbol) return error.InvalidUppercaseSymbols;
            changed = changed or symbol != uppercase_symbol;
        }
        if (!changed) return error.InvalidUppercaseSymbols;
    } else {
        for (level.symbols) |symbol| {
            if (xkb.keysym.upper(symbol) != symbol) return error.InvalidUppercaseSymbols;
        }
    }
}

fn validateSymbol(symbol: xkb.keysym.Keysym) ValidationError!void {
    if (symbol == .no_symbol or @backingInt(symbol) > xkb.keysym.max) return error.InvalidKeysym;
}

test "compiled keymap validates and resolves virtual modifiers" {
    const modifiers = core_modifiers ++ [_]Modifier{
        .{ .name = "LevelThree", .mapping = 1, .kind = .virtual },
    };
    const entries = [_]TypeEntry{.{ .modifiers = 1, .level = 1 }};
    const types = [_]KeyType{.{ .modifiers = 1, .level_count = 2, .entries = &entries }};
    const levels = [_]Level{
        .{ .symbols = &.{@fromBackingInt(@intCast('a'))}, .uppercase_symbols = &.{@fromBackingInt(@intCast('A'))} },
        .{ .symbols = &.{@fromBackingInt(@intCast('A'))} },
    };
    const groups = [_]Group{.{ .type_index = 0, .levels = &levels }};
    const keys = [_]Key{.{ .code = 38, .groups = &groups }};
    var storage: Keymap.Storage = undefined;
    const compiled = try Keymap.init(&storage, .{
        .modifiers = &modifiers,
        .types = &types,
        .keys = &keys,
    });

    try std.testing.expectEqual(@as(?usize, 8), compiled.modifierIndex("LevelThree"));
    try std.testing.expectEqual(@as(ModifierMask, 1), compiled.effectiveModifiers(modifierBit(8)));
    try std.testing.expectEqual(core_modifier_mask, compiled.canonicalModifierMask());
    try std.testing.expectEqual(@as(?Keycode, 38), if (compiled.key(38)) |key_value| key_value.code else null);
    try std.testing.expectEqual(@as(usize, 1), compiled.layoutCount());
}

test "key group policies cover negative and overflowing layouts" {
    try std.testing.expectEqual(@as(usize, 2), groupInRange(-1, 3, .wrap));
    try std.testing.expectEqual(@as(usize, 1), groupInRange(4, 3, .wrap));
    try std.testing.expectEqual(@as(usize, 0), groupInRange(-1, 3, .saturate));
    try std.testing.expectEqual(@as(usize, 2), groupInRange(4, 3, .saturate));
    try std.testing.expectEqual(@as(usize, 1), groupInRange(9, 3, .{ .redirect = 1 }));
}

test "empty keymaps retain core modifiers and repeat-only keys have no group" {
    const keys = [_]Key{.{ .code = 38, .groups = &.{}, .repeats = true }};
    var storage: Keymap.Storage = undefined;
    const compiled = try Keymap.init(&storage, .{
        .modifiers = &core_modifiers,
        .types = &.{},
        .keys = &keys,
    });
    try std.testing.expectEqual(core_modifier_mask, compiled.canonicalModifierMask());
    try std.testing.expectEqual(core_modifier_mask, compiled.effectiveModifiers(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(usize, 0), compiled.layoutCount());
    try std.testing.expect(compiled.group(compiled.key(38).?, 0) == null);
}

test "canonical levels reject NoSymbol and invalid preserve masks" {
    const no_symbol_levels = [_]Level{.{ .symbols = &.{.no_symbol} }};
    const groups = [_]Group{.{ .type_index = 0, .levels = &no_symbol_levels }};
    const keys = [_]Key{.{ .code = 38, .groups = &groups }};
    const invalid_preserve = [_]TypeEntry{.{ .modifiers = 1, .preserve = 2, .level = 0 }};
    const types = [_]KeyType{.{
        .modifiers = 3,
        .level_count = 1,
        .entries = &invalid_preserve,
    }};
    var storage: Keymap.Storage = undefined;
    try std.testing.expectError(error.InvalidTypeEntry, Keymap.init(&storage, .{
        .modifiers = &core_modifiers,
        .types = &types,
        .keys = &keys,
    }));

    const valid_types = [_]KeyType{.{ .modifiers = 0, .level_count = 1, .entries = &.{} }};
    try std.testing.expectError(error.InvalidKeysym, Keymap.init(&storage, .{
        .modifiers = &core_modifiers,
        .types = &valid_types,
        .keys = &keys,
    }));
}

test "compiled construction requires canonical core and uppercase data" {
    var invalid_core = core_modifiers;
    invalid_core[0].name = "Shifted";
    var storage: Keymap.Storage = undefined;
    try std.testing.expectError(error.InvalidCoreModifiers, Keymap.init(&storage, .{
        .modifiers = &invalid_core,
        .types = &.{},
        .keys = &.{},
    }));

    const levels = [_]Level{.{ .symbols = &.{@fromBackingInt(@intCast('a'))} }};
    const types = [_]KeyType{.{ .modifiers = 0, .level_count = 1, .entries = &.{} }};
    const groups = [_]Group{.{ .type_index = 0, .levels = &levels }};
    const keys = [_]Key{.{ .code = 38, .groups = &groups }};
    try std.testing.expectError(error.InvalidUppercaseSymbols, Keymap.init(&storage, .{
        .modifiers = &core_modifiers,
        .types = &types,
        .keys = &keys,
    }));
}
