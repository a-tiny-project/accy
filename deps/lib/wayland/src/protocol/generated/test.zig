const std = @import("std");
const generated = @import("root.zig");

test "generated protocol namespace is complete" {
    std.testing.refAllDecls(generated);
}
