const random = @import("../root.zig");

const base = random.base;
const block = random.block;

const DType = base.DType;
const philox_default_rounds = block.philox_default_rounds;

pub const PhiloxKeySplit = struct {
    count: u64,
    rounds: u32 = philox_default_rounds,
    threads: u32 = 256,
    count_axis: []const u8 = "n",

    pub fn generators(self: PhiloxKeySplit) u64 {
        return self.count;
    }
};

pub const PhiloxKeyUniform = struct {
    count: u64,
    rounds: u32 = philox_default_rounds,
    dtype: DType = .f32,
    threads: u32 = 256,
    count_axis: []const u8 = "n",

    pub fn generators(self: PhiloxKeyUniform) u64 {
        return self.count;
    }
};

pub const PhiloxKeyCounterUniform = struct {
    count: u64,
    rounds: u32 = philox_default_rounds,
    dtype: DType = .f32,
    threads: u32 = 256,
    count_axis: []const u8 = "n",

    pub fn generators(self: PhiloxKeyCounterUniform) u64 {
        return self.count;
    }
};

pub const philox_key_split_family_version: u32 = 1;
pub const philox_key_uniform_family_version: u32 = 1;
pub const philox_key_counter_uniform_family_version: u32 = 1;
