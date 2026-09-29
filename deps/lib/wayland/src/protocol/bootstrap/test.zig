const std = @import("std");
const bootstrap = @import("root.zig");

test "core bootstrap namespace is complete" {
    std.testing.refAllDecls(bootstrap);
}
