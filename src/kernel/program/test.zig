const std = @import("std");
const program = @import("root.zig");

test {
    _ = @import("builder/test.zig");
    @import("test_discovery").discover(program);
}

test "accy kernel program declaration coverage" {
    std.testing.refAllDecls(program);
}
