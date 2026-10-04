const std = @import("std");
const selection = @import("root.zig");

test {
    @import("test_discovery").discover(selection);
}

test "accy kernel logical selection declaration coverage" {
    std.testing.refAllDecls(selection);
}
