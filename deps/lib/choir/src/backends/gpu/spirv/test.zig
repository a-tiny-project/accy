const std = @import("std");
const spirv = @import("root.zig");

test {
    _ = @import("emitter/test.zig");
}

test "spirv declaration coverage" {
    std.testing.refAllDecls(spirv.emitter);
    std.testing.refAllDecls(spirv.dialect);
    std.testing.refAllDecls(spirv.conversion);
    std.testing.refAllDecls(spirv);
}
