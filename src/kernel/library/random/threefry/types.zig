const random = @import("../root.zig");

const base = random.base;
const block = random.block;

const DType = base.DType;
const threefry_lanes = block.threefry_lanes;
const threefry_default_rounds = block.threefry_default_rounds;
const ceilDiv = block.ceilDiv;

pub const Threefry = struct {
    count: u64,
    rounds: u32 = threefry_default_rounds,
    seed: u64 = 0,
    dtype: DType = .f32,
    threads: u32 = 256,
    count_axis: []const u8 = "n",

    pub fn generators(self: Threefry) u64 {
        return ceilDiv(self.count, threefry_lanes);
    }

    pub fn seedLo(self: Threefry) u32 {
        return @truncate(self.seed);
    }

    pub fn seedHi(self: Threefry) u32 {
        return @truncate(self.seed >> 32);
    }
};

pub const threefry_family_version: u32 = 1;
