const std = @import("std");
const stream = @import("root.zig");

test "stream namespace is complete" {
    std.testing.refAllDecls(stream);
}
