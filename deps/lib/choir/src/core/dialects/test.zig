const std = @import("std");
const dialects = @import("root.zig");

test {
    std.testing.refAllDecls(dialects);
}
