const std = @import("std");

const header = @import("root.zig");

test {
    std.testing.refAllDecls(header);
}
