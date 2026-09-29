const std = @import("std");
const rewrite = @import("root.zig");

test {
    std.testing.refAllDecls(rewrite);
    _ = @import("pattern.zig");
    _ = @import("rewriter.zig");
    _ = @import("set.zig");
    _ = @import("index.zig");
    _ = @import("type.zig");
    _ = @import("canonicalization.zig");
}
