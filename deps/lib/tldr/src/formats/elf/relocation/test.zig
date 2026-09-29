const std = @import("std");

const relocation = @import("root.zig");

test {
    std.testing.refAllDecls(relocation);
}
