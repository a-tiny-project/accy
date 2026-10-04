pub const default_width: usize = 80;

pub const LayoutOptions = struct {
    width: usize = default_width,
    indent_step: usize = 2,
    color: ColorMode = .none,
};

pub const ColorMode = enum {
    none,
    ansi,
};

pub const Style = enum {
    plain,
    title,
    keyword,
    name,
    value,
    string,
    number,
    type_name,
    attribute,
    block_label,
    source,
    punctuation,
    muted,
    accent,
    warning,
    danger,
};

pub const Doc = union(enum) {
    empty,
    text: []const u8,
    concat: []const Doc,
    line: []const u8,
    hardline,
    nest: Nested,
    group: *const Doc,
    styled: Styled,
};

pub const Nested = struct {
    amount: usize,
    doc: *const Doc,
};

pub const Styled = struct {
    style: Style,
    doc: *const Doc,
};

pub const WriteState = struct {
    column: usize = 0,
    indent: usize = 0,
};

pub const softline: Doc = .{ .line = " " };
pub const softbreak: Doc = .{ .line = "" };
pub const hardline: Doc = .hardline;
