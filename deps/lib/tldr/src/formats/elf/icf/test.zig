const std = @import("std");

const folder = @import("fold.zig");
const icf = @import("root.zig");

test {
    std.testing.refAllDecls(folder);
    std.testing.refAllDecls(icf);
}
