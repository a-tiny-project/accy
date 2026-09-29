const std = @import("std");

const liveness = @import("root.zig");
const mark = @import("mark.zig");

test {
    std.testing.refAllDecls(liveness);
    std.testing.refAllDecls(mark);
}
