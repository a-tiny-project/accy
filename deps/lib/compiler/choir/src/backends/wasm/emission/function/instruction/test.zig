const std = @import("std");
const instruction = @import("root.zig");
const arithmetic = @import("arithmetic/test.zig");

test {
    std.testing.refAllDecls(instruction);
    _ = arithmetic;
}
