const std = @import("std");

pub fn aesRound(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    validateAes(D);
    return addRoundKey(D, mixColumns(D, shiftSubBytes(D, state, false), false), round_key);
}

pub fn aesLastRound(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    validateAes(D);
    return addRoundKey(D, shiftSubBytes(D, state, false), round_key);
}

pub fn aesRoundInv(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    validateAes(D);
    return addRoundKey(D, mixColumns(D, shiftSubBytes(D, state, true), true), round_key);
}

pub fn aesLastRoundInv(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    validateAes(D);
    return addRoundKey(D, shiftSubBytes(D, state, true), round_key);
}

pub fn aesInvMixColumns(comptime D: type, state: D.Vector) D.Vector {
    validateAes(D);
    return mixColumns(D, state, true);
}

pub fn aesKeyGenAssist(comptime D: type, comptime rcon: u8, value: D.Vector) D.Vector {
    validateAes(D);
    const input: [D.lane_count]u8 = value;
    var result: [D.lane_count]u8 = undefined;
    const indices = [16]usize{ 4, 5, 6, 7, 5, 6, 7, 4, 12, 13, 14, 15, 13, 14, 15, 12 };
    inline for (0..D.lane_count / 16) |block| {
        inline for (0..16) |index| {
            const source = block * 16 + indices[index];
            const constant: u8 = if (index == 4 or index == 12) rcon else 0;
            result[block * 16 + index] = sbox(input[source]) ^ constant;
        }
    }
    return result;
}

pub fn clMulLower(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return clMul(D, a, b, 0);
}

pub fn clMulUpper(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    return clMul(D, a, b, 1);
}

fn addRoundKey(comptime D: type, state: D.Vector, key: D.Vector) D.Vector {
    return state ^ key;
}

fn shiftSubBytes(comptime D: type, state: D.Vector, comptime inverse: bool) D.Vector {
    const input: [D.lane_count]u8 = state;
    var result: [D.lane_count]u8 = undefined;
    inline for (0..D.lane_count / 16) |block| {
        inline for (0..4) |column| {
            inline for (0..4) |row| {
                const source_column = if (inverse)
                    (column + 4 - row) & 3
                else
                    (column + row) & 3;
                const source = block * 16 + source_column * 4 + row;
                result[block * 16 + column * 4 + row] = if (inverse)
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

fn clMul(
    comptime D: type,
    a: D.Vector,
    b: D.Vector,
    comptime selected_lane: usize,
) D.Vector {
    if (comptime D.Lane != u64 or D.lane_count < 2 or D.lane_count & 1 != 0) {
        @compileError("carryless multiplication requires an even number of u64 lanes");
    }
    const a_lanes: [D.lane_count]u64 = a;
    const b_lanes: [D.lane_count]u64 = b;
    var result: [D.lane_count]u64 = undefined;
    inline for (0..D.lane_count / 2) |block| {
        const index = block * 2 + selected_lane;
        const product = carrylessProduct(a_lanes[index], b_lanes[index]);
        result[block * 2] = @truncate(product);
        result[block * 2 + 1] = @truncate(product >> 64);
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

fn validateAes(comptime D: type) void {
    if (comptime D.Lane != u8 or D.lane_count < 16 or D.lane_count % 16 != 0) {
        @compileError("AES operations require whole 128-bit blocks of u8 lanes");
    }
}

test "Highway AES encryption rounds match the NIST core fixture" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u8, 16);
    const state: D.Vector = .{
        0x40, 0xbf, 0xab, 0xf4, 0x06, 0xee, 0x4d, 0x30,
        0x42, 0xca, 0x6b, 0x99, 0x7a, 0x5c, 0x58, 0x16,
    };
    const mixed: D.Vector = .{
        0x52, 0x9f, 0x16, 0xc2, 0x97, 0x86, 0x15, 0xca,
        0xe0, 0x1a, 0xae, 0x54, 0xba, 0x1a, 0x26, 0x59,
    };
    const shifted: D.Vector = .{
        0x09, 0x28, 0x7f, 0x47, 0x6f, 0x74, 0x6a, 0xbf,
        0x2c, 0x4a, 0x62, 0x04, 0xda, 0x08, 0xe3, 0xee,
    };
    try std.testing.expect(@reduce(.And, aesRound(D, state, @splat(0)) == mixed));
    try std.testing.expect(@reduce(.And, aesLastRound(D, state, @splat(0)) == shifted));
}

test "Highway AES inverse rounds and inverse mixing match FIPS fixtures" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u8, 16);
    const state: D.Vector = .{
        0x7a, 0xd5, 0xfd, 0xa7, 0x89, 0xef, 0x4e, 0x27,
        0x2b, 0xca, 0x10, 0x0b, 0x3d, 0x9f, 0xf5, 0x9f,
    };
    const shifted: D.Vector = .{
        0xbd, 0x6e, 0x7c, 0x3d, 0xf2, 0xb5, 0x77, 0x9e,
        0x0b, 0x61, 0x21, 0x6e, 0x8b, 0x10, 0xb6, 0x89,
    };
    const mixed: D.Vector = .{
        0x47, 0x73, 0xb9, 0x1f, 0xf7, 0x2f, 0x35, 0x43,
        0x61, 0xcb, 0x01, 0x8e, 0xa1, 0xe6, 0xcf, 0x2c,
    };
    try std.testing.expect(@reduce(.And, aesLastRoundInv(D, state, @splat(0)) == shifted));
    try std.testing.expect(@reduce(.And, aesRoundInv(D, state, @splat(0)) == mixed));
    try std.testing.expect(@reduce(.And, aesInvMixColumns(D, shifted) == mixed));
}

test "Highway AES key generation assist matches x86 semantics" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u8, 16);
    const value: D.Vector = .{
        0x27, 0xcf, 0x73, 0xc3, 0x27, 0xcf, 0x73, 0xc3,
        0x74, 0x01, 0x90, 0x5a, 0x74, 0x01, 0x90, 0x5a,
    };
    const expected: D.Vector = .{
        0xcc, 0x8a, 0x8f, 0x2e, 0xaa, 0x8f, 0x2e, 0xcc,
        0x92, 0x7c, 0x60, 0xbe, 0x5c, 0x60, 0xbe, 0x92,
    };
    try std.testing.expect(@reduce(.And, aesKeyGenAssist(D, 0x20, value) == expected));
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

test "Highway carryless multiplication selects lower and upper block lanes" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u64, 4);
    const a: D.Vector = .{ 2, 4, 5, 7 };
    const b: D.Vector = .{ 3, 9, 11, 13 };
    try std.testing.expect(@reduce(.And, clMulLower(D, a, b) ==
        @as(D.Vector, .{ 6, 0, 0x27, 0 })));
    try std.testing.expect(@reduce(.And, clMulUpper(D, a, b) ==
        @as(D.Vector, .{ 0x24, 0, 0x23, 0 })));
}
