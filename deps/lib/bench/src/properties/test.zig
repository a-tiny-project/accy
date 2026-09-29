const std = @import("std");
const properties = @import("root.zig");

test {
    std.testing.refAllDecls(properties);
}
