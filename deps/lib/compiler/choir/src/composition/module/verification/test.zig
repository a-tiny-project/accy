const std = @import("std");
const verification = @import("root.zig");

test {
    std.testing.refAllDecls(verification);
}
