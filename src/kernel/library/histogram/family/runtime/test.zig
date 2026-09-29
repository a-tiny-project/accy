const std = @import("std");
const runtime = @import("root.zig");

test {
    @import("test_discovery").discover(@import("arguments.zig"));
    @import("test_discovery").discover(@import("artifact.zig"));
    @import("test_discovery").discover(@import("body.zig"));
    @import("test_discovery").discover(runtime);
}

test "accy kernel library histogram family runtime declaration coverage" {
    std.testing.refAllDecls(@import("arguments.zig"));
    std.testing.refAllDecls(@import("artifact.zig"));
    std.testing.refAllDecls(@import("body.zig"));
    std.testing.refAllDecls(runtime);
}
