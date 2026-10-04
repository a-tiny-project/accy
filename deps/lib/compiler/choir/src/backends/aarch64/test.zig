const std = @import("std");
const aarch64 = @import("root.zig");

test {
    std.testing.refAllDecls(aarch64);
    _ = @import("registers/test.zig");
    _ = @import("encoding/test.zig");
    _ = @import("disassemble/test.zig");
    _ = @import("execution.zig");
    _ = @import("invoke.zig");
    _ = @import("object.zig");
}
