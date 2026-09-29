const std = @import("std");
const dialects = @import("root.zig");
const arith = @import("arith/test.zig");
const fixture = @import("fixture/root.zig");
const gpu = @import("gpu/test.zig");

test {
    try std.testing.expect(!@hasDecl(dialects, "test_dialect"));
    try std.testing.expect(!@hasDecl(dialects, "TestDialect"));
    std.testing.refAllDecls(dialects);
    _ = arith;
    _ = fixture;
    _ = gpu;
}
