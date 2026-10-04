const std = @import("std");
const factor = @import("factor.zig");
const product = @import("product.zig");

test {
    @import("test_discovery").discover(factor);
    @import("test_discovery").discover(product);
}

test "accy kernel library catalog artifact specialized linalg declaration coverage" {
    std.testing.refAllDecls(factor);
    std.testing.refAllDecls(product);
}
