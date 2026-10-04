const std = @import("std");
const artifact = @import("artifact.zig");
const cpu = @import("cpu/root.zig");
const composition = @import("root.zig");

test {
    _ = @import("cpu/test.zig");
    @import("test_discovery").discover(composition);
    @import("test_discovery").discover(artifact);
    @import("test_discovery").discover(cpu);
    @import("test_discovery").discover(composition.element);
}

test "accy executable composition declaration coverage" {
    std.testing.refAllDecls(composition);
    std.testing.refAllDecls(artifact);
    std.testing.refAllDecls(cpu);
    std.testing.refAllDecls(composition.element);
}
