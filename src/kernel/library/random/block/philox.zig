const random = @import("../root.zig");

const kernel = random.base.kernel;
const wordConstant = random.block.wordConstant;

pub const philox_lanes: u64 = 4;
pub const philox_default_rounds: u32 = 10;
pub const philox_max_rounds: u32 = 16;

const philox_m0: u32 = 0xD2511F53;
const philox_m1: u32 = 0xCD9E8D57;
const philox_w0: u32 = 0x9E3779B9;
const philox_w1: u32 = 0xBB67AE85;

pub fn philoxBlock(rounds: u32, counter: [4]u32, key: [2]u32) [4]u32 {
    var state = counter;
    var bumped = key;
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        if (round > 0) {
            bumped[0] +%= philox_w0;
            bumped[1] +%= philox_w1;
        }
        const product0 = @as(u64, philox_m0) * @as(u64, state[0]);
        const product1 = @as(u64, philox_m1) * @as(u64, state[2]);
        const hi0: u32 = @truncate(product0 >> 32);
        const lo0: u32 = @truncate(product0);
        const hi1: u32 = @truncate(product1 >> 32);
        const lo1: u32 = @truncate(product1);
        state = .{ hi1 ^ state[1] ^ bumped[0], lo1, hi0 ^ state[3] ^ bumped[1], lo0 };
    }
    return state;
}

pub fn philoxWords(
    k: anytype,
    rounds: u32,
    counter: kernel.Value,
    counter_fold: kernel.Value,
    seed_lo: kernel.Value,
    seed_hi: kernel.Value,
) ![philox_lanes]kernel.Value {
    const zero = try k.constantInt(.i32, 0);
    const m0 = try wordConstant(k, philox_m0);
    const m1 = try wordConstant(k, philox_m1);
    const w0 = try wordConstant(k, philox_w0);
    const w1 = try wordConstant(k, philox_w1);
    var state = [philox_lanes]kernel.Value{ counter, counter_fold, zero, zero };
    var key = [2]kernel.Value{ seed_lo, seed_hi };
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        if (round > 0) {
            key[0] = try k.add(key[0], w0);
            key[1] = try k.add(key[1], w1);
        }
        const hi0 = try k.umulhi(m0, state[0]);
        const lo0 = try k.mul(m0, state[0]);
        const hi1 = try k.umulhi(m1, state[2]);
        const lo1 = try k.mul(m1, state[2]);
        state = .{
            try k.xor(try k.xor(hi1, state[1]), key[0]),
            lo1,
            try k.xor(try k.xor(hi0, state[3]), key[1]),
            lo0,
        };
    }
    return state;
}
