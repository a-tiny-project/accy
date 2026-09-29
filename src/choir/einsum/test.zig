const std = @import("std");
const einsum = @import("root.zig");

test {
    @import("test_discovery").discover(einsum);
}

test "accy choir einsum declaration coverage" {
    std.testing.refAllDecls(einsum);
}
