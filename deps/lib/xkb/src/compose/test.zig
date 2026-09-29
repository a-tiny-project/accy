const std = @import("std");
const root = @import("root.zig");
const workspace_suite = @import("workspace/test.zig");

test "compose namespace" {
    std.testing.refAllDecls(root);
    std.testing.refAllDecls(workspace_suite);
}
