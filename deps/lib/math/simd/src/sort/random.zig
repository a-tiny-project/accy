const std = @import("std");

pub const State = struct {
    words: [3]u64,

    pub fn init(first: u64, second: u64) State {
        return .{ .words = .{ first, second, 1 } };
    }

    pub fn next(self: *State) u64 {
        return randomBits(&self.words);
    }
};

pub fn randomBits(state: *[3]u64) u64 {
    const a = state[0];
    const b = state[1];
    const w = state[2] +% 1;
    const next = a ^ w;
    state[0] = (b +% (b << 3)) ^ (b >> 11);
    state[1] = std.math.rotl(u64, b, 24) +% next;
    state[2] = w;
    return next;
}

pub fn chunkIndex(num_chunks: u32, bits: u32) usize {
    std.debug.assert(num_chunks >= 1);
    const product = @as(u64, bits) * num_chunks;
    const index: usize = @intCast(product >> 32);
    std.debug.assert(index < num_chunks);
    return index;
}
