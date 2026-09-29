const std = @import("std");
const root = @import("root.zig");

test "state namespace" {
    std.testing.refAllDecls(root);
}
