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

/// A write exclusively borrows these bytes and this descriptor. The region must
/// not alias the document, its byte slices, writer storage or the failure sink.
/// The document remains immutable until the write returns. The in_use flag
/// diagnoses reentry; the caller must enforce exclusive ownership. A rejected
/// reentry leaves last_failure untouched, including when it is also the sink.
pub const Workspace = struct {
    bytes: []u8,
    max_depth: u32,
    in_use: bool = false,
    last_failure: ?RenderFailure = null,
};

pub const RenderLimit = enum {
    render_depth,
    workspace_depth,
    workspace_bytes,
    workspace_alignment,
    workspace_use,
};

pub const DocContext = enum { offending_child, root, reconstructed_root };

/// Shallow document context borrows the original children and bytes; it never
/// points at the renderer's local root or frames. Quantities are in active nodes
/// for depth, bytes for storage/alignment, and simultaneous uses for workspace_use.
pub const RenderFailure = struct {
    limit: RenderLimit,
    value: u64,
    use: u64,
    request: u64,
    reached_depth: ?u64 = null,
    storage: ?struct { capacity: u64, required: u64, deficit: u64 } = null,
    doc: Doc,
    context: DocContext = .root,
    supplied_workspace: bool,
};
