const std = @import("std");
const payload = @import("root.zig");

test {
    std.testing.refAllDecls(payload);
}
