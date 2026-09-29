const name = @import("name.zig");
const unicode = @import("unicode.zig");
const case = @import("case.zig");
const kind = @import("kind.zig");
const generated = @import("generated/root.zig");

pub const Keysym = enum(u32) {
    no_symbol = 0,
    _,
};

pub const max: u32 = 0x1fffffff;
pub const unicode_offset: u32 = 0x01000000;
pub const unicode_max: u32 = 0x0110ffff;
pub const provenance = generated.source;

pub const fromName = name.fromName;
pub const codepoint = unicode.codepoint;
pub const lower = case.lower;
pub const upper = case.upper;
pub const isLower = case.isLower;
pub const isUpperOrTitle = case.isUpperOrTitle;
pub const isModifier = kind.isModifier;
pub const isKeypad = kind.isKeypad;
