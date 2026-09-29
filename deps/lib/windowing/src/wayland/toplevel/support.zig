const std = @import("std");

pub fn stateArrayContains(states: []const u8, needle: u32) bool {
    if (states.len % @sizeOf(u32) != 0) return false;
    var offset: usize = 0;
    while (offset < states.len) : (offset += @sizeOf(u32)) {
        if (std.mem.readInt(u32, states[offset..][0..4], @import("builtin").cpu.arch.endian()) == needle) return true;
    }
    return false;
}

pub fn clampedI32(value: u32) i32 {
    return @intCast(@min(value, std.math.maxInt(i32)));
}
