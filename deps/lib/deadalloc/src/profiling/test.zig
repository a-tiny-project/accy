const std = @import("std");
const profiling = @import("root.zig");

test {
    std.testing.refAllDecls(profiling);
}
