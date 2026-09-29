const std = @import("std");
const support = @import("support.zig");

const stateArrayContains = support.stateArrayContains;

test "xdg state arrays identify maximized and focused states" {
    var states: [12]u8 = undefined;
    std.mem.writeInt(u32, states[0..4], 1, @import("builtin").cpu.arch.endian());
    std.mem.writeInt(u32, states[4..8], 4, @import("builtin").cpu.arch.endian());
    std.mem.writeInt(u32, states[8..12], 8, @import("builtin").cpu.arch.endian());
    try std.testing.expect(stateArrayContains(&states, 1));
    try std.testing.expect(stateArrayContains(&states, 4));
    try std.testing.expect(!stateArrayContains(&states, 2));
}
