//! Portable lowering of the crypto operations, in software with masks in
//! place of branches and no table lookups, so it takes the same time for
//! every input. The AES operations run byte at a time with the semantics of
//! x86 AES-NI, computing each S-box entry as a GF(2^8) inverse followed by
//! the affine map. Carryless multiplication adds a shifted copy of one factor
//! for each set bit of the other, 64 steps per product. Targets without a
//! family's instructions use it, comptime evaluation uses it, and the
//! hardware lowerings are tested against it.

const std = @import("std");
const block = @import("block.zig");

/// AESENC on every block: ShiftRows, SubBytes and MixColumns, then the round
/// key added.
pub fn aesRound(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    block.validate(D, u8);
    return addRoundKey(D, mixColumns(D, shiftSubBytes(D, state, false), false), round_key);
}

/// AESENCLAST on every block: ShiftRows and SubBytes, then the round key
/// added.
pub fn aesLastRound(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    block.validate(D, u8);
    return addRoundKey(D, shiftSubBytes(D, state, false), round_key);
}

/// AESDEC on every block: InvShiftRows, InvSubBytes and InvMixColumns, then
/// the round key added.
pub fn aesRoundInv(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    block.validate(D, u8);
    return addRoundKey(D, mixColumns(D, shiftSubBytes(D, state, true), true), round_key);
}

/// AESDECLAST on every block: InvShiftRows and InvSubBytes, then the round
/// key added.
pub fn aesLastRoundInv(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    block.validate(D, u8);
    return addRoundKey(D, shiftSubBytes(D, state, true), round_key);
}

/// AESIMC on every block: InvMixColumns alone.
pub fn aesInvMixColumns(comptime D: type, state: D.Vector) D.Vector {
    block.validate(D, u8);
    return mixColumns(D, state, true);
}

/// AESKEYGENASSIST on every block: SubWord of words 1 and 3, each followed by
/// its rotation with `rcon` added to the rotated word's low byte.
pub fn aesKeyGenAssist(comptime D: type, comptime rcon: u8, value: D.Vector) D.Vector {
    block.validate(D, u8);
    const input: [D.lane_count]u8 = value;
    var result: [D.lane_count]u8 = undefined;
    const indices = [16]usize{ 4, 5, 6, 7, 5, 6, 7, 4, 12, 13, 14, 15, 13, 14, 15, 12 };
    inline for (0..D.lane_count / 16) |block_index| {
        inline for (0..16) |index| {
            const source = block_index * 16 + indices[index];
            const constant: u8 = if (index == 4 or index == 12) rcon else 0;
            result[block_index * 16 + index] = sbox(input[source]) ^ constant;
        }
    }
    return result;
}

/// The carryless product of the lower u64 lanes of each 128-bit block.
pub fn clMulLower(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return clMul(D, a, b, 0);
}

/// The carryless product of the upper u64 lanes of each 128-bit block.
pub fn clMulUpper(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return clMul(D, a, b, 1);
}

fn clMul(
    comptime D: type,
    a: D.Vector,
    b: D.Vector,
    comptime selected_lane: usize,
) D.Vector {
    block.validate(D, u64);
    const a_lanes: [D.lane_count]u64 = a;
    const b_lanes: [D.lane_count]u64 = b;
    var result: [D.lane_count]u64 = undefined;
    inline for (0..D.lane_count / 2) |block_index| {
        const index = block_index * 2 + selected_lane;
        const product = carrylessProduct(a_lanes[index], b_lanes[index]);
        result[block_index * 2] = @truncate(product);
        result[block_index * 2 + 1] = @truncate(product >> 64);
    }
    return result;
}

fn carrylessProduct(a: u64, b: u64) u128 {
    var product: u128 = 0;
    inline for (0..64) |bit| {
        const selected = 0 -% @as(u128, (b >> bit) & 1);
        product ^= (@as(u128, a) << bit) & selected;
    }
    return product;
}

fn addRoundKey(comptime D: type, state: D.Vector, key: D.Vector) D.Vector {
    return state ^ key;
}

fn shiftSubBytes(comptime D: type, state: D.Vector, comptime inverse: bool) D.Vector {
    const input: [D.lane_count]u8 = state;
    var result: [D.lane_count]u8 = undefined;
    inline for (0..D.lane_count / 16) |block_index| {
        inline for (0..4) |column| {
            inline for (0..4) |row| {
                const source_column = if (inverse)
                    (column + 4 - row) & 3
                else
                    (column + row) & 3;
                const source = block_index * 16 + source_column * 4 + row;
                result[block_index * 16 + column * 4 + row] = if (inverse)
                    inverseSbox(input[source])
                else
                    sbox(input[source]);
            }
        }
    }
    return result;
}

fn mixColumns(comptime D: type, state: D.Vector, comptime inverse: bool) D.Vector {
    const input: [D.lane_count]u8 = state;
    var result: [D.lane_count]u8 = undefined;
    inline for (0..D.lane_count / 4) |column| {
        const offset = column * 4;
        const a0 = input[offset];
        const a1 = input[offset + 1];
        const a2 = input[offset + 2];
        const a3 = input[offset + 3];
        if (inverse) {
            result[offset] = gfMul(a0, 14) ^ gfMul(a1, 11) ^ gfMul(a2, 13) ^ gfMul(a3, 9);
            result[offset + 1] = gfMul(a0, 9) ^ gfMul(a1, 14) ^ gfMul(a2, 11) ^ gfMul(a3, 13);
            result[offset + 2] = gfMul(a0, 13) ^ gfMul(a1, 9) ^ gfMul(a2, 14) ^ gfMul(a3, 11);
            result[offset + 3] = gfMul(a0, 11) ^ gfMul(a1, 13) ^ gfMul(a2, 9) ^ gfMul(a3, 14);
        } else {
            result[offset] = gfMul(a0, 2) ^ gfMul(a1, 3) ^ a2 ^ a3;
            result[offset + 1] = a0 ^ gfMul(a1, 2) ^ gfMul(a2, 3) ^ a3;
            result[offset + 2] = a0 ^ a1 ^ gfMul(a2, 2) ^ gfMul(a3, 3);
            result[offset + 3] = gfMul(a0, 3) ^ a1 ^ a2 ^ gfMul(a3, 2);
        }
    }
    return result;
}

fn sbox(value: u8) u8 {
    const inverse = gfInverse(value);
    return inverse ^ rotateByte(inverse, 1) ^ rotateByte(inverse, 2) ^
        rotateByte(inverse, 3) ^ rotateByte(inverse, 4) ^ 0x63;
}

fn inverseSbox(value: u8) u8 {
    return gfInverse(rotateByte(value, 1) ^ rotateByte(value, 3) ^
        rotateByte(value, 6) ^ 0x05);
}

fn gfInverse(value: u8) u8 {
    var result: u8 = 1;
    var base = value;
    inline for (0..8) |bit| {
        if ((254 >> bit) & 1 != 0) result = gfMul(result, base);
        base = gfMul(base, base);
    }
    return result;
}

fn gfMul(a: u8, b: u8) u8 {
    var product: u8 = 0;
    var multiplicand = a;
    var multiplier = b;
    inline for (0..8) |_| {
        const selected = 0 -% (multiplier & 1);
        product ^= multiplicand & selected;
        const high = multiplicand >> 7;
        multiplicand = (multiplicand << 1) ^ (0x1b & (0 -% high));
        multiplier >>= 1;
    }
    return product;
}

fn rotateByte(value: u8, comptime amount: u3) u8 {
    return std.math.rotl(u8, value, amount);
}

test "Highway AES S-box permutations cover all byte values" {
    var seen: [256]bool = @splat(false);
    for (0..256) |index| {
        const value: u8 = @intCast(index);
        const substituted = sbox(value);
        try std.testing.expectEqual(value, inverseSbox(substituted));
        seen[substituted] = true;
    }
    for (seen) |value| try std.testing.expect(value);
}
