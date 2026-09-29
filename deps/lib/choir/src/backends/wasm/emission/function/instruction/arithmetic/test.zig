const std = @import("std");
const arithmetic = @import("root.zig");

test {
    std.testing.refAllDecls(arithmetic);
}
