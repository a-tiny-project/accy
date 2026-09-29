const std = @import("std");
const wayland = @import("../root.zig");
const object = @import("object.zig");

pub fn retire(
    ids: *wayland.ids.Pool,
    objects: *object.Table,
    id: u32,
    expected: object.Entry,
    state: object.State,
) void {
    const actual = objects.requireLive(id) catch unreachable;
    std.debug.assert(actual.interface == expected.interface);
    std.debug.assert(actual.version == expected.version);
    std.debug.assert(actual.origin == expected.origin);
    objects.retire(id, state) catch unreachable;
    if (expected.origin == .client) ids.retire(id) catch unreachable;
}
