const std = @import("std");
const root = @import("root.zig");

test "Compose scratch namespace" {
    std.testing.refAllDecls(root);
}
