const std = @import("std");
const root = @import("root.zig");
const text_suite = @import("text/test.zig");

test "keymap namespace" {
    std.testing.refAllDecls(root);
    std.testing.refAllDecls(text_suite);
}
