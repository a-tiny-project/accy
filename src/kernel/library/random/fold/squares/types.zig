const random = @import("../../root.zig");

const base = random.base;
const block = random.block;

const DType = base.DType;
const squares_default_key = block.squares_default_key;

pub const SquaresFold = struct {
    count: u64,
    samples: u32 = 1,
    key: u64 = squares_default_key,
    dtype: DType = .f32,
    threads: u32 = 256,
    count_axis: []const u8 = "n",

    pub fn keyLo(self: SquaresFold) u32 {
        return @truncate(self.key);
    }

    pub fn keyHi(self: SquaresFold) u32 {
        return @truncate(self.key >> 32);
    }
};

pub const squares_fold_family_version: u32 = 1;
