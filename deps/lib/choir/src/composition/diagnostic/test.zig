const std = @import("std");
const root = @import("root.zig");
const path = @import("path.zig");

test {
    _ = root;
    std.testing.refAllDecls(path);
}
