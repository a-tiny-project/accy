const std = @import("std");
const revision = @import("root.zig");

test {
    std.testing.refAllDecls(revision.record);
    std.testing.refAllDecls(revision.receipt);
    std.testing.refAllDecls(revision.store);
}
