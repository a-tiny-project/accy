const std = @import("std");

pub fn main() void {
    const sentinel: u8 = 2;
    std.mem.doNotOptimizeAway(sentinel);
}
