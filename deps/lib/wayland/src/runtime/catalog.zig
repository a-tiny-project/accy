const std = @import("std");
const wayland = @import("../root.zig");

pub const Catalog = struct {
    interfaces: []const wayland.protocol.schema.Interface,

    pub fn standard() Catalog {
        return .{ .interfaces = &wayland.protocol.interfaces };
    }

    pub fn find(self: Catalog, name: []const u8) ?*const wayland.protocol.schema.Interface {
        return wayland.protocol.schema.findInterface(self.interfaces, name);
    }

    pub fn require(self: Catalog, name: []const u8) error{UnknownInterface}!*const wayland.protocol.schema.Interface {
        return self.find(name) orelse error.UnknownInterface;
    }

    pub fn canonical(
        self: Catalog,
        interface: *const wayland.protocol.schema.Interface,
    ) error{UnknownInterface}!*const wayland.protocol.schema.Interface {
        return self.require(interface.name);
    }
};

test "standard catalog provides session-stable interface identity" {
    const catalog = Catalog.standard();
    const first = try catalog.require("wl_keyboard");
    const second = try catalog.canonical(&wayland.protocol.core.wl_keyboard.metadata);
    try std.testing.expect(first == second);
    try std.testing.expectEqual(@as(u32, 10), first.version);
    const xdg_surface = try catalog.require("xdg_surface");
    try std.testing.expectEqualStrings("xdg_surface", xdg_surface.name);
    try std.testing.expect(xdg_surface == try catalog.canonical(&wayland.protocol.desktop.xdg_surface.metadata));
}
