const std = @import("std");
const disassemble = @import("root.zig");

test {
    std.testing.refAllDecls(disassemble);
    _ = @import("format.zig");
}
