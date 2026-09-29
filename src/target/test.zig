//! Integration suites for Accy's lowering into each Choir GPU target.

const std = @import("std");
const target = @import("root.zig");

test {
    _ = @import("cpu/test.zig");
    _ = @import("metal/test.zig");
    _ = @import("nvptx/test.zig");
    _ = @import("webgpu/test.zig");
    @import("test_discovery").discover(target);
}

test "accy target declaration coverage" {
    std.testing.refAllDecls(target);
}
