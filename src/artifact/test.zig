const std = @import("std");
const artifact = @import("root.zig");

test {
    @import("test_discovery").discover(artifact);
}

test "accy artifact declaration coverage" {
    std.testing.refAllDecls(artifact);
}
