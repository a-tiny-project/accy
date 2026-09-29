const std = @import("std");
const runtime = @import("root.zig");

test "gpu metal runtime declaration coverage" {
    std.testing.refAllDecls(runtime);
}
