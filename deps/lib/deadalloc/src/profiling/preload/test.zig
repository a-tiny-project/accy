const std = @import("std");
const preload = @import("root.zig");

test "deadalloc preload package namespace" {
    std.testing.refAllDecls(preload.abi);
    std.testing.refAllDecls(preload.exports);
}
