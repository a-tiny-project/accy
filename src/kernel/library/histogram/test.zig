const std = @import("std");
const histogram = @import("family/root.zig");

test {
    _ = @import("family/test.zig");
    @import("test_discovery").discover(histogram);
}

test "accy kernel library histogram declaration coverage" {
    std.testing.refAllDecls(histogram);
}
