const std = @import("std");
const linkage = @import("root.zig");

test {
    std.testing.refAllDecls(linkage);
}
