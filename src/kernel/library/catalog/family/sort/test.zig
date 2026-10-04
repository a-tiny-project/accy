const std = @import("std");
const bitonic = @import("bitonic.zig");
const radix = @import("radix.zig");
const sort = @import("root.zig");
const top = @import("top.zig");

test {
    @import("test_discovery").discover(bitonic);
    @import("test_discovery").discover(radix);
    @import("test_discovery").discover(sort);
    @import("test_discovery").discover(top);
}

test "accy kernel library catalog family sort declaration coverage" {
    std.testing.refAllDecls(bitonic);
    std.testing.refAllDecls(radix);
    std.testing.refAllDecls(sort);
    std.testing.refAllDecls(top);
}
