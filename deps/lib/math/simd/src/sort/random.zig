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

test "Highway sort generator matches the pinned scalar sequence" {
    var state = State.init(0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210);
    const expected = [_]u64{
        0x0123_4567_89ab_cded,
        0xf5dd_54cb_7bfb_0815,
        0x6675_5555_5ccc_aa8e,
        0x0b26_15d8_aefd_dd8f,
        0xc17b_aab2_58dc_5d77,
        0x13bd_47fb_1cc9_b171,
    };
    for (expected) |value| try std.testing.expectEqual(value, state.next());
}

test "Highway random chunk mapping covers endpoints and remains in range" {
    try std.testing.expectEqual(@as(usize, 0), chunkIndex(1, 0));
    try std.testing.expectEqual(@as(usize, 0), chunkIndex(7, 0));
    try std.testing.expectEqual(@as(usize, 6), chunkIndex(7, std.math.maxInt(u32)));
    var state = State.init(7, 11);
    for (1..1000) |count| {
        const bits: u32 = @truncate(state.next());
        try std.testing.expect(chunkIndex(@intCast(count), bits) < count);
    }
}
