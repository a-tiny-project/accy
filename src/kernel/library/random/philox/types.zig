const random = @import("../root.zig");

const base = random.base;
const block = random.block;

const DType = base.DType;
const philox_lanes = block.philox_lanes;
const philox_default_rounds = block.philox_default_rounds;
const ceilDiv = block.ceilDiv;

pub const Philox = struct {
    count: u64,
    rounds: u32 = philox_default_rounds,
    seed: u64 = 0,
    dtype: DType = .f32,
    threads: u32 = 256,
    count_axis: []const u8 = "n",

    pub fn generators(self: Philox) u64 {
        return ceilDiv(self.count, philox_lanes);
    }

    pub fn seedLo(self: Philox) u32 {
        return @truncate(self.seed);
    }

    pub fn seedHi(self: Philox) u32 {
        return @truncate(self.seed >> 32);
    }
};

pub const philox_family_version: u32 = 1;
