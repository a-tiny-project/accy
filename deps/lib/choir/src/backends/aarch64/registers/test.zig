const std = @import("std");
const registers = @import("root.zig");

test {
    std.testing.refAllDecls(registers);
    _ = @import("model.zig");
}
