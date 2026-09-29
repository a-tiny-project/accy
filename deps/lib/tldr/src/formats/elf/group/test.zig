const std = @import("std");

const discard = @import("discard.zig");
const group = @import("root.zig");
const membership = @import("membership.zig");

test {
    std.testing.refAllDecls(discard);
    std.testing.refAllDecls(group);
    std.testing.refAllDecls(membership);
}
