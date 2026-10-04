const std = @import("std");
const function = @import("root.zig");
const instruction = @import("instruction/test.zig");

test {
    std.testing.refAllDecls(function);
    _ = instruction;
}
