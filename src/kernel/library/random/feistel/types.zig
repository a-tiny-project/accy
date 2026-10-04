const random = @import("../root.zig");

const base = random.base;

const std = base.std;
const DType = base.DType;

pub const feistel_default_rounds: u32 = 6;
pub const feistel_max_rounds: u32 = 16;
pub const feistel_family_version: u32 = 1;
pub const feistel_max_domain_bits: u6 = 30;

pub const Feistel = struct {
    count: u64,
    rounds: u32 = feistel_default_rounds,
    seed: u64 = 0,
    dtype: DType = .i32,
    threads: u32 = 256,
    count_axis: []const u8 = "n",

    pub fn seedLo(self: Feistel) u32 {
        return @truncate(self.seed);
    }

    pub fn seedHi(self: Feistel) u32 {
        return @truncate(self.seed >> 32);
    }

    pub fn domainBits(self: Feistel) ?u6 {
        return feistelDomainBits(self.count);
    }

    pub fn halfBits(self: Feistel) ?u6 {
        const bits = self.domainBits() orelse return null;
        return @intCast(bits / 2);
    }
};

pub fn feistelDomainBits(count: u64) ?u6 {
    if (count < 4) return null;
    if (!std.math.isPowerOfTwo(count)) return null;
    const bits: u6 = @intCast(std.math.log2_int(u64, count));
    if (bits > feistel_max_domain_bits) return null;
    if (bits % 2 != 0) return null;
    return bits;
}

pub fn feistelInstanceValid(instance: Feistel) bool {
    if (instance.dtype != .i32) return false;
    if (instance.threads == 0) return false;
    if (instance.rounds == 0 or instance.rounds > feistel_max_rounds) return false;
    return instance.domainBits() != null;
}
