const std = @import("std");
const thread = @import("root.zig");

test "Highway thread namespace imports" {
    std.testing.refAllDecls(thread);
}
