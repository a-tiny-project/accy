const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.pure();

pub const Mode = enum {
    native,
    client,
};

pub const WindowEdge = enum {
    top,
    right,
    bottom,
    left,
    top_left,
    top_right,
    bottom_right,
    bottom_left,
};

pub const Hit = union(enum) {
    normal,
    title_drag,
    window_edge: WindowEdge,
};

pub const HitTestFn = *const fn (
    x: f32,
    y: f32,
    context: ?*anyopaque,
) Hit;

pub const ConfigureResult = union(enum) {
    enabled,
    unavailable: [*:0]const u8,
};
