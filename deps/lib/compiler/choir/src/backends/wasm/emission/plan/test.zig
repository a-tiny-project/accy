const std = @import("std");
const plan = @import("root.zig");

test {
    std.testing.refAllDecls(plan);
}
