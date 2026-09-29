const std = @import("std");
const phase = @import("root.zig");

test "alloc phase package namespace" {
    std.testing.refAllDecls(phase);
}

test {
    _ = @import("capacity/test.zig");
    _ = @import("properties/input.zig");
}
