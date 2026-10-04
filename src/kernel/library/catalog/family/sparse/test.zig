const std = @import("std");
const candidate = @import("candidate.zig");
const descriptor = @import("descriptor.zig");
const selection = @import("selection.zig");
const sparse = @import("root.zig");
const structure = @import("structure/root.zig");
const threads = @import("threads.zig");

test {
    _ = @import("structure/test.zig");
    @import("test_discovery").discover(sparse);
    @import("test_discovery").discover(candidate);
    @import("test_discovery").discover(descriptor);
    @import("test_discovery").discover(selection);
    @import("test_discovery").discover(structure);
    @import("test_discovery").discover(threads);
}

test "accy kernel library catalog family sparse declaration coverage" {
    std.testing.refAllDecls(sparse);
    std.testing.refAllDecls(candidate);
    std.testing.refAllDecls(descriptor);
    std.testing.refAllDecls(selection);
    std.testing.refAllDecls(structure);
    std.testing.refAllDecls(threads);
}
