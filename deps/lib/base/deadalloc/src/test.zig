const std = @import("std");
const deadalloc = @import("root.zig");

test {
    std.testing.refAllDecls(deadalloc);
}
