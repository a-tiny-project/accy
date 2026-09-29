const std = @import("std");
const gpu = @import("root.zig");

test "gpu dialect declaration coverage" {
    std.testing.refAllDecls(gpu.dialect);
    std.testing.refAllDecls(gpu.tags);
    std.testing.refAllDecls(gpu.stage);
    std.testing.refAllDecls(gpu.kernel);
    std.testing.refAllDecls(gpu);
}
