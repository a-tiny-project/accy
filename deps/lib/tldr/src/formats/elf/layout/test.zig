const std = @import("std");

const layout = @import("root.zig");

test {
    std.testing.refAllDecls(layout);
}
