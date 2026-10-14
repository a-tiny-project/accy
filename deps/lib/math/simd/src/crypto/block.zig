//! Block geometry that the crypto lowerings share.
//!
//! Every crypto operation transforms each 128-bit block of a vector on its
//! own: an AES operation the block's 16 u8 lanes, and carryless
//! multiplication the block's two u64 lanes. One instruction covers a
//! register of 16, 32 or 64 bytes, so a lowering splits a wider vector into
//! registers and applies the instruction to each. Two of Highway's
//! formulations reach InvMixColumns and AESKEYGENASSIST through the round
//! instructions. Lowerings use them where no dedicated instruction of the
//! register's width exists: Arm has no key-generation instruction, and VAES
//! widens only the four round instructions.

const std = @import("std");

/// Bytes in one block.
pub const block_bytes: usize = 16;

/// Rejects descriptors that are not whole 128-bit blocks of `Lane` lanes: u8
/// lanes for the AES operations and u64 lanes for carryless multiplication.
pub fn validate(comptime D: type, comptime Lane: type) void {
    if (comptime D.Lane != Lane or D.byte_count < block_bytes or
        D.byte_count % block_bytes != 0)
    {
        @compileError("this crypto operation requires whole 128-bit blocks of " ++
            @typeName(Lane) ++ " lanes");
    }
}

/// A register of `register_bytes` bytes of the lanes of `D`.
fn Register(comptime D: type, comptime register_bytes: usize) type {
    return @Vector(register_bytes / @sizeOf(D.Lane), D.Lane);
}

/// Applies `operation` to each `register_bytes`-byte register of `value`.
pub fn mapUnary(
    comptime D: type,
    comptime register_bytes: usize,
    comptime operation: fn (Register(D, register_bytes)) Register(D, register_bytes),
    value: D.Vector,
) D.Vector {
    const count = comptime registerCount(D, register_bytes);
    if (count == 1) return operation(value);
    var result = value;
    inline for (0..count) |index| {
        const register = extract(D, register_bytes, index, value);
        result = insert(D, register_bytes, index, result, operation(register));
    }
    return result;
}

/// Applies `operation` to each pair of `register_bytes`-byte registers of
/// `left` and `right` at the same offset.
pub fn mapBinary(
    comptime D: type,
    comptime register_bytes: usize,
    comptime operation: fn (
        Register(D, register_bytes),
        Register(D, register_bytes),
    ) Register(D, register_bytes),
    left: D.Vector,
    right: D.Vector,
) D.Vector {
    const count = comptime registerCount(D, register_bytes);
    if (count == 1) return operation(left, right);
    var result = left;
    inline for (0..count) |index| {
        const a = extract(D, register_bytes, index, left);
        const b = extract(D, register_bytes, index, right);
        result = insert(D, register_bytes, index, result, operation(a, b));
    }
    return result;
}

/// Highway's AESKeyGenAssist through AESLastRound of `Lowering`. Duplicating
/// words 1 and 3 of each block over words 0 and 2 places every byte the
/// instruction substitutes where ShiftRows sends it to a distinct lane. The
/// final round substitutes the bytes and adds the round constant at the two
/// lanes that rotate into bytes 4 and 12, and one byte table undoes ShiftRows
/// while it rotates the odd words.
pub fn keyGenAssistByLastRound(
    comptime D: type,
    comptime rcon: u8,
    comptime Lowering: type,
    value: D.Vector,
) D.Vector {
    validate(D, u8);
    const odd_words = @shuffle(u8, value, undefined, blockIndices(D, dup_odd_words));
    const substituted = Lowering.aesLastRound(
        D,
        odd_words,
        comptime blockConstants(D, rconAfterShiftRows(rcon)),
    );
    return @shuffle(u8, substituted, undefined, blockIndices(D, rot_word_shuffle));
}

/// Highway's AVX3_DL InvMixColumns through two rounds of `Lowering` with zero
/// keys. The inverse round's InvShiftRows and InvSubBytes cancel the final
/// round's ShiftRows and SubBytes, because SubBytes commutes with every byte
/// permutation, which leaves InvMixColumns alone.
pub fn invMixColumnsByRounds(
    comptime D: type,
    comptime Lowering: type,
    state: D.Vector,
) D.Vector {
    validate(D, u8);
    const zero: D.Vector = @splat(0);
    return Lowering.aesRoundInv(D, Lowering.aesLastRound(D, state, zero), zero);
}

const dup_odd_words = [block_bytes]i32{
    4,  5,  6,  7,  4,  5,  6,  7,
    12, 13, 14, 15, 12, 13, 14, 15,
};
const rot_word_shuffle = [block_bytes]i32{
    0, 13, 10, 7,  1, 14, 11, 4,
    8, 5,  2,  15, 9, 6,  3,  12,
};

fn rconAfterShiftRows(comptime rcon: u8) [block_bytes]u8 {
    var constants: [block_bytes]u8 = @splat(0);
    constants[1] = rcon;
    constants[9] = rcon;
    return constants;
}

fn registerCount(comptime D: type, comptime register_bytes: usize) usize {
    validate(D, D.Lane);
    std.debug.assert(register_bytes % block_bytes == 0);
    std.debug.assert(D.byte_count % register_bytes == 0);
    return D.byte_count / register_bytes;
}

/// Register `index` of `value`. A shuffle keeps the split in vector
/// registers, where the pinned compiler lowers a bit cast of a u8 vector to
/// an array of registers one byte at a time.
fn extract(
    comptime D: type,
    comptime register_bytes: usize,
    comptime index: usize,
    value: D.Vector,
) Register(D, register_bytes) {
    const register_lanes = @typeInfo(Register(D, register_bytes)).vector.len;
    return @shuffle(D.Lane, value, undefined, extractIndices(register_lanes, index));
}

/// `value` with register `index` replaced by `register`.
fn insert(
    comptime D: type,
    comptime register_bytes: usize,
    comptime index: usize,
    value: D.Vector,
    register: Register(D, register_bytes),
) D.Vector {
    const register_lanes = @typeInfo(Register(D, register_bytes)).vector.len;
    return @shuffle(D.Lane, value, register, insertIndices(D, register_lanes, index));
}

fn extractIndices(comptime register_lanes: usize, comptime index: usize) [register_lanes]i32 {
    @setEvalBranchQuota(4 * register_lanes + 1_000);
    var indices: [register_lanes]i32 = undefined;
    for (&indices, 0..) |*lane_index, lane| {
        lane_index.* = @intCast(index * register_lanes + lane);
    }
    return indices;
}

fn insertIndices(
    comptime D: type,
    comptime register_lanes: usize,
    comptime index: usize,
) [D.lane_count]i32 {
    @setEvalBranchQuota(4 * D.lane_count + 1_000);
    const start = index * register_lanes;
    std.debug.assert(start + register_lanes <= D.lane_count);
    var indices: [D.lane_count]i32 = undefined;
    for (&indices, 0..) |*lane_index, lane| {
        const replaced = lane >= start and lane < start + register_lanes;
        // A negative index selects lane ~index of the second operand.
        lane_index.* = if (replaced) ~@as(i32, @intCast(lane - start)) else @intCast(lane);
    }
    return indices;
}

fn blockIndices(comptime D: type, comptime pattern: [block_bytes]i32) [D.lane_count]i32 {
    @setEvalBranchQuota(4 * D.lane_count + 1_000);
    var indices: [D.lane_count]i32 = undefined;
    for (&indices, 0..) |*index, lane| {
        const within = pattern[lane % block_bytes];
        std.debug.assert(within >= 0);
        std.debug.assert(within < block_bytes);
        index.* = @as(i32, @intCast(lane - lane % block_bytes)) + within;
    }
    return indices;
}

fn blockConstants(comptime D: type, comptime pattern: [block_bytes]u8) D.Vector {
    @setEvalBranchQuota(4 * D.lane_count + 1_000);
    var constants: [D.lane_count]u8 = undefined;
    for (&constants, 0..) |*constant, lane| constant.* = pattern[lane % block_bytes];
    return constants;
}
