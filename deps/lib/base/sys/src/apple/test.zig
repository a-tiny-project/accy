const std = @import("std");
const subject = @import("root.zig");

test {
    std.testing.refAllDecls(subject);
}
