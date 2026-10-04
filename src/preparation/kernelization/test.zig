const std = @import("std");
const kernelization = @import("root.zig");

test {
    @import("test_discovery").discover(kernelization);
}

test "accy preparation kernelization declaration coverage" {
    std.testing.refAllDecls(kernelization);
}
