const xkb = @import("../../root.zig");

pub const Keycode = struct {
    name: []const u8,
    code: u32,
};

pub const Alias = struct {
    name: []const u8,
    target: []const u8,
};

pub const VirtualModifier = struct {
    name: []const u8,
    explicit_mapping: ?u32 = null,
};

pub const TypeEntry = struct {
    modifiers: u32,
    preserve: u32 = 0,
    level: usize,
};

pub const KeyType = struct {
    name: []const u8,
    modifiers: u32,
    level_count: usize,
    entries: []const TypeEntry,
};

pub const Match = enum {
    exactly,
    all,
    none,
    any,
    any_or_none,
};

pub const Interpret = struct {
    symbol: ?xkb.keysym.Keysym,
    match: Match,
    modifiers: u32,
    repeat: bool,
    level_one_only: bool,
    virtual_modifier: ?usize,
    order: usize,
};

pub const Level = struct {
    symbols: []const xkb.keysym.Keysym,
};

pub const Group = struct {
    type_name: ?[]const u8 = null,
    levels: []const Level = &.{},
    has_actions: bool = false,
};

pub const OutOfRange = union(enum) {
    wrap,
    saturate,
    redirect: usize,
};

pub const Key = struct {
    name: []const u8,
    default_type: ?[]const u8,
    groups: []const Group,
    repeat: ?bool,
    virtual_modifiers: ?u32,
    out_of_range: OutOfRange,
};

pub const ModifierMap = struct {
    modifier: usize,
    keys: []const []const u8,
};

pub const Document = struct {
    keycodes: []const Keycode,
    aliases: []const Alias,
    virtual_modifiers: []const VirtualModifier,
    types: []const KeyType,
    interprets: []const Interpret,
    keys: []const Key,
    modifier_maps: []const ModifierMap,
};
