const std = @import("std");
const xkb = @import("../../root.zig");
const document = @import("document.zig");

pub const Error = std.mem.Allocator.Error || xkb.keymap.ValidationError || error{InvalidSyntax};

const WorkingKey = struct {
    source: *const document.Key,
    code: u32,
    modifier_map: u32 = 0,
    virtual_modifiers: u32 = 0,
    repeats: bool = false,
};

pub fn resolve(
    allocator: std.mem.Allocator,
    source: document.Document,
) Error!*const xkb.keymap.Keymap {
    try validateNames(source);
    const working_keys = try allocator.alloc(WorkingKey, source.keys.len);
    const modifier_mask = validModifierMask(source.virtual_modifiers.len);
    for (source.keys, working_keys) |*key, *working| {
        if (key.virtual_modifiers) |mask| if (mask & ~modifier_mask != 0) {
            return error.InvalidSyntax;
        };
        working.* = .{
            .source = key,
            .code = codeForName(source, key.name) orelse return error.InvalidSyntax,
        };
    }
    for (working_keys, 0..) |key, index| {
        for (working_keys[index + 1 ..]) |other| {
            if (key.code == other.code) return error.InvalidSyntax;
        }
    }
    try applyModifierMaps(source, working_keys);
    for (working_keys) |*key| applyInterprets(source, key);

    const modifier_mappings = try virtualMappings(allocator, source, working_keys);
    const modifiers = try finishModifiers(allocator, source, modifier_mappings);
    const types = try finishTypes(allocator, source, modifier_mappings);
    const keys = try finishKeys(allocator, source, working_keys, types);
    std.mem.sort(xkb.keymap.Key, keys, {}, keyLessThan);

    const storage = try allocator.create(xkb.keymap.Keymap.Storage);
    return xkb.keymap.Keymap.init(storage, .{
        .modifiers = modifiers,
        .types = types,
        .keys = keys,
    });
}

fn validateNames(source: document.Document) Error!void {
    for (source.keycodes, 0..) |keycode, index| {
        for (source.keycodes[index + 1 ..]) |other| {
            if (std.mem.eql(u8, keycode.name, other.name) or keycode.code == other.code) {
                return error.InvalidSyntax;
            }
        }
    }
    for (source.aliases, 0..) |alias, index| {
        if (codeForDirectName(source, alias.name) != null) return error.InvalidSyntax;
        for (source.aliases[index + 1 ..]) |other| {
            if (std.mem.eql(u8, alias.name, other.name)) return error.InvalidSyntax;
        }
    }
    for (source.types, 0..) |key_type, index| {
        for (source.types[index + 1 ..]) |other| {
            if (std.mem.eql(u8, key_type.name, other.name)) return error.InvalidSyntax;
        }
    }
}

fn applyModifierMaps(source: document.Document, keys: []WorkingKey) Error!void {
    for (source.modifier_maps) |modifier_map| {
        if (modifier_map.modifier >= xkb.keymap.core_modifier_count) return error.InvalidSyntax;
        const bit = xkb.keymap.modifierBit(modifier_map.modifier);
        for (modifier_map.keys) |name| {
            const code = codeForName(source, name) orelse return error.InvalidSyntax;
            for (keys) |*key| {
                if (key.code == code) {
                    key.modifier_map |= bit;
                    break;
                }
            }
        }
    }
}

fn applyInterprets(source: document.Document, key: *WorkingKey) void {
    if (key.source.repeat) |repeat| {
        key.repeats = repeat;
    } else if (key.source.groups.len != 0 and !key.source.groups[0].has_actions and
        key.source.groups[0].levels.len != 0)
    {
        for (key.source.groups[0].levels[0].symbols) |symbol| {
            const interpret = findInterpret(source.interprets, symbol, key.modifier_map, 0);
            if (interpret == null or interpret.?.repeat) key.repeats = true;
        }
    }

    if (key.source.virtual_modifiers) |explicit| {
        key.virtual_modifiers = explicit;
        return;
    }
    for (key.source.groups, 0..) |group, group_index| {
        if (group.has_actions) continue;
        for (group.levels, 0..) |level, level_index| {
            for (level.symbols) |symbol| {
                const interpret = findInterpret(
                    source.interprets,
                    symbol,
                    key.modifier_map,
                    level_index,
                ) orelse continue;
                if ((group_index == 0 and level_index == 0) or !interpret.level_one_only) {
                    if (interpret.virtual_modifier) |index| {
                        key.virtual_modifiers |= xkb.keymap.modifierBit(index);
                    }
                }
            }
        }
    }
}

fn findInterpret(
    interprets: []const document.Interpret,
    symbol: xkb.keysym.Keysym,
    modifier_map: u32,
    level: usize,
) ?*const document.Interpret {
    var best: ?*const document.Interpret = null;
    var best_rank: usize = std.math.maxInt(usize);
    for (interprets) |*interpret| {
        if (interpret.symbol) |expected| if (expected != symbol) continue;
        const modifiers = if (interpret.level_one_only and level != 0) 0 else modifier_map;
        if (!interpretMatches(interpret.*, modifiers)) continue;
        const rank = interpretRank(interpret.*);
        if (rank < best_rank) {
            best = interpret;
            best_rank = rank;
        }
    }
    return best;
}

fn interpretMatches(interpret: document.Interpret, modifiers: u32) bool {
    return switch (interpret.match) {
        .none => interpret.modifiers & modifiers == 0,
        .any_or_none => modifiers == 0 or interpret.modifiers & modifiers != 0,
        .any => interpret.modifiers & modifiers != 0,
        .all => interpret.modifiers & modifiers == interpret.modifiers,
        .exactly => interpret.modifiers == modifiers,
    };
}

fn interpretRank(interpret: document.Interpret) usize {
    const symbol_rank: usize = if (interpret.symbol != null) 0 else 1;
    const match_rank: usize = switch (interpret.match) {
        .exactly => 0,
        .all => 1,
        .none => 2,
        .any => 3,
        .any_or_none => 4,
    };
    return symbol_rank * 10_000_000 + match_rank * 1_000_000 + interpret.order;
}

fn virtualMappings(
    allocator: std.mem.Allocator,
    source: document.Document,
    keys: []const WorkingKey,
) Error![]u32 {
    const mappings = try allocator.alloc(u32, source.virtual_modifiers.len);
    for (source.virtual_modifiers, mappings) |modifier, *mapping| {
        mapping.* = (modifier.explicit_mapping orelse 0) & xkb.keymap.core_modifier_mask;
    }
    for (keys) |key| {
        for (mappings, 0..) |*mapping, offset| {
            const index = xkb.keymap.core_modifier_count + offset;
            if (key.virtual_modifiers & xkb.keymap.modifierBit(index) != 0) {
                mapping.* |= key.modifier_map;
            }
        }
    }
    return mappings;
}

fn finishModifiers(
    allocator: std.mem.Allocator,
    source: document.Document,
    mappings: []const u32,
) Error![]xkb.keymap.Modifier {
    const modifiers = try allocator.alloc(
        xkb.keymap.Modifier,
        xkb.keymap.core_modifier_count + source.virtual_modifiers.len,
    );
    @memcpy(modifiers[0..xkb.keymap.core_modifier_count], &xkb.keymap.core_modifiers);
    for (source.virtual_modifiers, mappings, modifiers[xkb.keymap.core_modifier_count..]) |
        modifier,
        mapping,
        *finished,
    | {
        finished.* = .{
            .name = try allocator.dupe(u8, modifier.name),
            .mapping = mapping,
            .kind = .virtual,
        };
    }
    return modifiers;
}

fn finishTypes(
    allocator: std.mem.Allocator,
    source: document.Document,
    mappings: []const u32,
) Error![]xkb.keymap.KeyType {
    const types = try allocator.alloc(xkb.keymap.KeyType, source.types.len);
    const valid_mask = validModifierMask(source.virtual_modifiers.len);
    for (source.types, types) |key_type, *finished| {
        if (key_type.modifiers & ~valid_mask != 0 or key_type.level_count == 0) {
            return error.InvalidSyntax;
        }
        var entries: std.ArrayListUnmanaged(xkb.keymap.TypeEntry) = .empty;
        for (key_type.entries) |entry| {
            if (entry.modifiers & ~valid_mask != 0 or
                entry.preserve & ~valid_mask != 0 or
                entry.level >= key_type.level_count)
            {
                return error.InvalidSyntax;
            }
            const raw_modifiers = entry.modifiers & key_type.modifiers;
            const raw_preserve = entry.preserve & raw_modifiers;
            if (raw_modifiers != 0 and hasUnboundVirtual(raw_modifiers, mappings)) continue;
            const effective_modifiers = effectiveMask(raw_modifiers, mappings);
            var duplicate = false;
            for (entries.items) |existing| {
                if (existing.modifiers == effective_modifiers) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            try entries.append(allocator, .{
                .modifiers = effective_modifiers,
                .preserve = effectiveMask(raw_preserve, mappings),
                .level = entry.level,
            });
        }
        finished.* = .{
            .modifiers = effectiveMask(key_type.modifiers, mappings),
            .level_count = key_type.level_count,
            .entries = try entries.toOwnedSlice(allocator),
        };
    }
    return types;
}

fn finishKeys(
    allocator: std.mem.Allocator,
    source: document.Document,
    working_keys: []const WorkingKey,
    types: []const xkb.keymap.KeyType,
) Error![]xkb.keymap.Key {
    const keys = try allocator.alloc(xkb.keymap.Key, working_keys.len);
    for (working_keys, keys) |working, *finished| {
        const groups = try allocator.alloc(xkb.keymap.Group, working.source.groups.len);
        for (working.source.groups, groups) |group, *finished_group| {
            const type_name = group.type_name orelse working.source.default_type orelse
                inferType(group.levels);
            const type_index = typeIndex(source.types, type_name) orelse return error.InvalidSyntax;
            const key_type = types[type_index];
            if (group.levels.len > key_type.level_count) return error.InvalidSyntax;
            const levels = try allocator.alloc(xkb.keymap.Level, key_type.level_count);
            for (levels, 0..) |*level, index| {
                const symbols = if (index < group.levels.len) group.levels[index].symbols else &.{};
                level.* = .{
                    .symbols = symbols,
                    .uppercase_symbols = try uppercaseSymbols(allocator, symbols),
                };
            }
            finished_group.* = .{
                .type_index = type_index,
                .levels = levels,
            };
        }
        finished.* = .{
            .code = working.code,
            .groups = groups,
            .out_of_range = switch (working.source.out_of_range) {
                .wrap => .wrap,
                .saturate => .saturate,
                .redirect => |group| .{ .redirect = group },
            },
            .repeats = working.repeats,
        };
    }
    return keys;
}

fn uppercaseSymbols(
    allocator: std.mem.Allocator,
    symbols: []const xkb.keysym.Keysym,
) Error!?[]xkb.keysym.Keysym {
    var changed = false;
    for (symbols) |symbol| changed = changed or xkb.keysym.upper(symbol) != symbol;
    if (!changed) return null;
    const uppercase = try allocator.alloc(xkb.keysym.Keysym, symbols.len);
    for (symbols, uppercase) |symbol, *output| output.* = xkb.keysym.upper(symbol);
    return uppercase;
}

fn inferType(levels: []const document.Level) []const u8 {
    if (levels.len <= 1) return "ONE_LEVEL";
    const first = firstSymbol(levels[0]);
    const second = firstSymbol(levels[1]);
    if (levels.len == 2) {
        if (isLower(first) and isUpper(second)) return "ALPHABETIC";
        if (isKeypad(first) or isKeypad(second)) return "KEYPAD";
        return "TWO_LEVEL";
    }
    if (levels.len <= 4) {
        if (isLower(first) and isUpper(second)) {
            const third = firstSymbol(levels[2]);
            const fourth = if (levels.len == 4) firstSymbol(levels[3]) else null;
            if (isLower(third) and isUpper(fourth)) return "FOUR_LEVEL_ALPHABETIC";
            return "FOUR_LEVEL_SEMIALPHABETIC";
        }
        if (isKeypad(first) or isKeypad(second)) return "FOUR_LEVEL_KEYPAD";
        return "FOUR_LEVEL";
    }
    return "";
}

fn firstSymbol(level: document.Level) ?xkb.keysym.Keysym {
    return if (level.symbols.len == 0) null else level.symbols[0];
}

fn isLower(symbol: ?xkb.keysym.Keysym) bool {
    return if (symbol) |value| xkb.keysym.isLower(value) else false;
}

fn isUpper(symbol: ?xkb.keysym.Keysym) bool {
    return if (symbol) |value| xkb.keysym.isUpperOrTitle(value) else false;
}

fn isKeypad(symbol: ?xkb.keysym.Keysym) bool {
    return if (symbol) |value| xkb.keysym.isKeypad(value) else false;
}

fn effectiveMask(raw: u32, mappings: []const u32) u32 {
    var result = raw & xkb.keymap.core_modifier_mask;
    for (mappings, 0..) |mapping, offset| {
        const index = xkb.keymap.core_modifier_count + offset;
        if (raw & xkb.keymap.modifierBit(index) != 0) result |= mapping;
    }
    return result;
}

fn hasUnboundVirtual(raw: u32, mappings: []const u32) bool {
    for (mappings, 0..) |mapping, offset| {
        const index = xkb.keymap.core_modifier_count + offset;
        if (raw & xkb.keymap.modifierBit(index) != 0 and mapping == 0) return true;
    }
    return false;
}

fn validModifierMask(virtual_count: usize) u32 {
    const count = xkb.keymap.core_modifier_count + virtual_count;
    return if (count == @bitSizeOf(u32)) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(count)) - 1;
}

fn typeIndex(types: []const document.KeyType, name: []const u8) ?usize {
    for (types, 0..) |key_type, index| {
        if (std.mem.eql(u8, key_type.name, name)) return index;
    }
    return null;
}

fn codeForName(source: document.Document, name: []const u8) ?u32 {
    var current = name;
    var depth: usize = 0;
    while (depth <= source.aliases.len) : (depth += 1) {
        if (codeForDirectName(source, current)) |code| return code;
        var found = false;
        for (source.aliases) |alias| {
            if (std.mem.eql(u8, alias.name, current)) {
                current = alias.target;
                found = true;
                break;
            }
        }
        if (!found) return null;
    }
    return null;
}

fn codeForDirectName(source: document.Document, name: []const u8) ?u32 {
    for (source.keycodes) |keycode| {
        if (std.mem.eql(u8, keycode.name, name)) return keycode.code;
    }
    return null;
}

fn keyLessThan(_: void, left: xkb.keymap.Key, right: xkb.keymap.Key) bool {
    return left.code < right.code;
}
