const std = @import("std");

pub const Marsaglia = struct {
    state: u32,
    cached: u32 = 0,
    byte_index: u3 = 4,

    pub fn init(seed: u64) Marsaglia {
        const folded = @as(u32, @truncate(seed)) ^ @as(u32, @truncate(seed >> 32));
        return .{ .state = if (folded == 0) 0x6d2b_79f5 else folded };
    }

    pub fn nextU32(self: *Marsaglia) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = if (x == 0) 0x6d2b_79f5 else x;
        return self.state;
    }

    pub fn nextU64(self: *Marsaglia) u64 {
        return (@as(u64, self.nextU32()) << 32) | self.nextU32();
    }

    pub fn bounded(self: *Marsaglia, upper: usize) usize {
        std.debug.assert(upper > 0);
        return @intCast(self.nextU64() % upper);
    }

    pub fn nextByte(self: *Marsaglia) u8 {
        if (self.byte_index >= 4) {
            self.cached = self.nextU32();
            self.byte_index = 0;
        }
        const shift: u5 = @intCast(@as(u16, self.byte_index) * 8);
        const byte: u8 = @truncate(self.cached >> shift);
        self.byte_index += 1;
        return byte;
    }
};
