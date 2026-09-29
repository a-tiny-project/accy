const std = @import("std");
const contract = @import("root.zig");

test {
    @import("test_discovery").discover(contract.zig);
    @import("test_discovery").discover(contract);
}

test "accy validation contract declaration coverage" {
    std.testing.refAllDecls(contract.zig);
    std.testing.refAllDecls(contract);
}
