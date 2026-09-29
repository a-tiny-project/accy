const std = @import("std");
const hypothesis = @import("root.zig");

test "hypothesis package namespace" {
    try std.testing.expect(!@hasDecl(hypothesis, "testing"));
    std.testing.refAllDecls(hypothesis);
}
