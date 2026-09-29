const std = @import("std");
const encoding = @import("root.zig");

test {
    std.testing.refAllDecls(encoding);
    _ = @import("instruction.zig");
}
