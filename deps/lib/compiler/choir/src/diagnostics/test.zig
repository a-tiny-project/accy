const std = @import("std");
const diagnostics = @import("root.zig");

test {
    std.testing.refAllDecls(diagnostics);
    _ = @import("engine.zig");
}
