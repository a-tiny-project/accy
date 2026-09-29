const std = @import("std");
const regalloc = @import("root.zig");

test {
    std.testing.refAllDecls(regalloc);
}
