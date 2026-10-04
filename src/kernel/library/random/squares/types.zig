const random = @import("../root.zig");

const base = random.base;
const block = random.block;

const DType = base.DType;
const squares_default_key = block.squares_default_key;

pub const squares_family_version: u32 = 1;

pub const Squares = struct {
    count: u64,
    key: u64 = squares_default_key,
    dtype: DType = .f32,
    threads: u32 = 256,
    count_axis: []const u8 = "n",

    pub fn generators(self: Squares) u64 {
        return self.count;
    }

    pub fn keyLo(self: Squares) u32 {
        return @truncate(self.key);
    }

    pub fn keyHi(self: Squares) u32 {
        return @truncate(self.key >> 32);
    }
};
