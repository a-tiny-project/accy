const std = @import("std");
const section = @import("root.zig");

test {
    std.testing.refAllDecls(section);
}
