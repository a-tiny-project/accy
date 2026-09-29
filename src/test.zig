const std = @import("std");
const accy = @import("root.zig");
const test_support = @import("fixture/root.zig");

test "accy package namespace" {
    try std.testing.expect(!@hasDecl(accy, "testing"));
}

test {
    _ = @import("preparation/test.zig");
    _ = @import("integration/test.zig");
    _ = @import("kernel/test.zig");
    _ = @import("target/test.zig");
    _ = @import("tensor/test.zig");
    @import("test_discovery").discover(accy.axis);
    @import("test_discovery").discover(accy.target);
    @import("test_discovery").discover(accy.tensor);
    @import("test_discovery").discover(accy.kernel);
    @import("test_discovery").discover(test_support);
    @import("test_discovery").discover(accy.choir);
    @import("test_discovery").discover(accy.validation.gating);
}

test "accy test declaration coverage" {
    std.testing.refAllDecls(accy.axis);
    std.testing.refAllDecls(accy.target);
    std.testing.refAllDecls(accy.tensor);
    std.testing.refAllDecls(accy.kernel);
    std.testing.refAllDecls(test_support);
    std.testing.refAllDecls(accy.choir);
    std.testing.refAllDecls(accy.validation.gating);
}
