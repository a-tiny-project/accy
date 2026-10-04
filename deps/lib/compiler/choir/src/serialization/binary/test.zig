const std = @import("std");
const binary = @import("root.zig");

test {
    std.testing.refAllDecls(binary);
}
