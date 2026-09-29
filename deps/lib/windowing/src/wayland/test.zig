const std = @import("std");
const builtin = @import("builtin");
const wayland = @import("root.zig");

const presentation = wayland.presentation;
const session = wayland.session;
const toplevel = wayland.toplevel;
const seat = wayland.seat;
const present = wayland.present;
const window = @import("window/root.zig");

test "Wayland backend declarations compile on Linux" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    std.testing.refAllDecls(presentation);
    std.testing.refAllDecls(session);
    std.testing.refAllDecls(toplevel);
    std.testing.refAllDecls(seat);
    std.testing.refAllDecls(present);
    std.testing.refAllDecls(window);
    _ = @import("session/test.zig");
    _ = @import("toplevel/test.zig");
    _ = @import("seat/test.zig");
    _ = @import("present/test.zig");
    _ = @import("present/dmabuf.zig");
    _ = @import("window/test.zig");
}
