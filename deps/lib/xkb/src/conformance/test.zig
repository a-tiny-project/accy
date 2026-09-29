const std = @import("std");
const root = @import("root.zig");

test "conformance namespace" {
    std.testing.refAllDecls(root.oracle);
}
