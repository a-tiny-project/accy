const random = @import("../../root.zig");

const base = random.base;
const block = random.block;

const DType = base.DType;
const philox_default_rounds = block.philox_default_rounds;

pub const philox_fold_family_version: u32 = 1;

pub const PhiloxFold = struct {
    count: u64,
    samples: u32 = 1,
    rounds: u32 = philox_default_rounds,
    seed: u64 = 0,
    dtype: DType = .f32,
    threads: u32 = 256,
    count_axis: []const u8 = "n",

    pub fn seedLo(self: PhiloxFold) u32 {
        return @truncate(self.seed);
    }

    pub fn seedHi(self: PhiloxFold) u32 {
        return @truncate(self.seed >> 32);
    }
};
