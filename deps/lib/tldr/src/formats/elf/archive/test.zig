const std = @import("std");

const archive = @import("root.zig");
const select = @import("select.zig");

test {
    std.testing.refAllDecls(archive);
    std.testing.refAllDecls(select);
}
