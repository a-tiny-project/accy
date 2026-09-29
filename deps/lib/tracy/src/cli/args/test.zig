const namespace = @import("root.zig");
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(namespace);
}
