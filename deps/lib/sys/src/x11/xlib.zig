const std = @import("std");

const sys = @import("../root.zig");
const display_mod = @import("display.zig");

pub const Error = error{
    RuntimeUnavailable,
    SymbolMissing,
    InvalidDisplay,
};

pub const Display = opaque {};

const XOpenDisplayFn = *const fn (display_name: ?[*:0]const u8) callconv(.c) ?*Display;
const XCloseDisplayFn = *const fn (display: *Display) callconv(.c) c_int;

pub const Connection = struct {
    library: sys.dynamic.Library,
    display: *Display,
    close_fn: XCloseDisplayFn,

    pub fn close(self: *Connection) void {
        _ = self.close_fn(self.display);
        self.library.close();
        self.* = undefined;
    }
};

pub fn openTarget(target: display_mod.Target) Error!Connection {
    var name_buffer: [32]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&name_buffer, ":{d}.{d}", .{ target.display, target.screen }, 0) catch return error.InvalidDisplay;
    return openName(name);
}

pub fn openDefault() Error!Connection {
    return openName(null);
}

fn openName(name: ?[:0]const u8) Error!Connection {
    var library = sys.dynamic.openX11Library() catch return error.RuntimeUnavailable;
    errdefer library.close();

    const open_fn = library.lookup(XOpenDisplayFn, "XOpenDisplay") orelse return error.SymbolMissing;
    const close_fn = library.lookup(XCloseDisplayFn, "XCloseDisplay") orelse return error.SymbolMissing;
    const display = open_fn(if (name) |actual| actual.ptr else null) orelse return error.RuntimeUnavailable;
    return .{
        .library = library,
        .display = display,
        .close_fn = close_fn,
    };
}

test "xlib dynamic candidate list is host-scoped" {
    const candidates = sys.dynamic.x11LibraryCandidates();
    try std.testing.expect(candidates.len >= 1);
    if (comptime @import("builtin").os.tag == .linux) {
        try std.testing.expect(sys.dynamic.hasHostCandidate(candidates));
    }
}
