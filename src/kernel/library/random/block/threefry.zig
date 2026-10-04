const random = @import("../root.zig");

const std = random.base.std;
const kernel = random.base.kernel;
const wordConstant = random.block.wordConstant;

pub const threefry_lanes: u64 = 2;
pub const threefry_default_rounds: u32 = 20;
pub const threefry_max_rounds: u32 = 32;

const threefry_parity: u32 = 0x1BD11BDA;
const threefry_rotations = [8]u5{ 13, 15, 26, 6, 17, 29, 16, 24 };

pub fn threefryBlock(rounds: u32, counter: [2]u32, key: [2]u32) [2]u32 {
    const subkeys = [3]u32{ key[0], key[1], threefry_parity ^ key[0] ^ key[1] };
    var x0 = counter[0] +% subkeys[0];
    var x1 = counter[1] +% subkeys[1];
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        x0 +%= x1;
        x1 = std.math.rotl(u32, x1, threefry_rotations[round % 8]);
        x1 ^= x0;
        if (round % 4 == 3) {
            const injection = round / 4 + 1;
            x0 +%= subkeys[injection % 3];
            x1 +%= subkeys[(injection + 1) % 3];
            x1 +%= injection;
        }
    }
    return .{ x0, x1 };
}

pub fn rotateLeftWord(k: anytype, value: kernel.Value, amount: u5) !kernel.Value {
    const left = try k.shl(value, try k.constantInt(.i32, amount));
    const right = try k.ushr(value, try k.constantInt(.i32, 32 - @as(i64, amount)));
    return k.or_(left, right);
}

pub fn threefryWords(
    k: anytype,
    rounds: u32,
    counter: kernel.Value,
    counter_fold: kernel.Value,
    seed_lo: kernel.Value,
    seed_hi: kernel.Value,
) ![threefry_lanes]kernel.Value {
    const parity = try wordConstant(k, threefry_parity);
    const subkeys = [3]kernel.Value{
        seed_lo,
        seed_hi,
        try k.xor(try k.xor(parity, seed_lo), seed_hi),
    };
    var x0 = try k.add(counter, subkeys[0]);
    var x1 = try k.add(counter_fold, subkeys[1]);
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        x0 = try k.add(x0, x1);
        x1 = try rotateLeftWord(k, x1, threefry_rotations[round % 8]);
        x1 = try k.xor(x1, x0);
        if (round % 4 == 3) {
            const injection = round / 4 + 1;
            x0 = try k.add(x0, subkeys[injection % 3]);
            x1 = try k.add(x1, subkeys[(injection + 1) % 3]);
            x1 = try k.add(x1, try k.constantInt(.i32, injection));
        }
    }
    return .{ x0, x1 };
}
