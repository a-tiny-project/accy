const std = @import("std");
const prefix = @import("prefix.zig");
const scan = @import("root.zig");

test {
    @import("test_discovery").discover(prefix);
    @import("test_discovery").discover(scan);
}

test "accy kernel library catalog family scan declaration coverage" {
    std.testing.refAllDecls(prefix);
    std.testing.refAllDecls(scan);
}
