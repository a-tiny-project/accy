const std = @import("std");
const scatter = @import("root.zig");
const scatter_module = @import("scatter.zig");
const scatter_add = @import("add.zig");

test {
    @import("test_discovery").discover(scatter);
    @import("test_discovery").discover(scatter_module);
    @import("test_discovery").discover(scatter_add);
}

test "accy kernel library catalog family scatter declaration coverage" {
    std.testing.refAllDecls(scatter);
    std.testing.refAllDecls(scatter_module);
    std.testing.refAllDecls(scatter_add);
}
