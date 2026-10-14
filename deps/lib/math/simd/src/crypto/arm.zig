//! Arm lowering of the crypto operations: FEAT_AES for the AES operations,
//! and the 64-bit PMULL and PMULL2 of FEAT_PMULL for carryless
//! multiplication.
//!
//! AESE and AESD add their key before ShiftRows and SubBytes, while the x86
//! semantics these operations follow add the round key last. As Highway's
//! NEON target does, each round issues AESE or AESD with a zero key, followed
//! directly by AESMC or AESIMC so that cores which fuse the pair can, and adds
//! the round key afterward. Arm has no key-generation instruction, so
//! AESKeyGenAssist takes Highway's formulation through AESLastRound.
//!
//! PMULL multiplies the lower u64 lanes of two registers and PMULL2 the upper
//! ones, each into a 128-bit product with its low half in the lower lane, as
//! Highway's NEON CLMulLower and CLMulUpper and std.crypto's GHASH issue them.

const block = @import("block.zig");

const Block = @Vector(block.block_bytes, u8);
const Pair = @Vector(2, u64);

pub fn aesRound(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    block.validate(D, u8);
    return block.mapUnary(D, block.block_bytes, encryptMixed, state) ^ round_key;
}

pub fn aesLastRound(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    block.validate(D, u8);
    return block.mapUnary(D, block.block_bytes, encrypt, state) ^ round_key;
}

pub fn aesRoundInv(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    block.validate(D, u8);
    return block.mapUnary(D, block.block_bytes, decryptMixed, state) ^ round_key;
}

pub fn aesLastRoundInv(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    block.validate(D, u8);
    return block.mapUnary(D, block.block_bytes, decrypt, state) ^ round_key;
}

pub fn aesInvMixColumns(comptime D: type, state: D.Vector) D.Vector {
    block.validate(D, u8);
    return block.mapUnary(D, block.block_bytes, inverseMixColumns, state);
}

pub fn aesKeyGenAssist(comptime D: type, comptime rcon: u8, value: D.Vector) D.Vector {
    return block.keyGenAssistByLastRound(D, rcon, @This(), value);
}

pub fn clMulLower(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    block.validate(D, u64);
    return block.mapBinary(D, block.block_bytes, productLower, a, b);
}

pub fn clMulUpper(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    block.validate(D, u64);
    return block.mapBinary(D, block.block_bytes, productUpper, a, b);
}

const zero: Block = @splat(0);

fn encryptMixed(state: Block) Block {
    return asm (
        \\aese %[result].16b, %[zero].16b
        \\aesmc %[result].16b, %[result].16b
        : [result] "=w" (-> Block),
        : [_] "0" (state),
          [zero] "w" (zero),
    );
}

fn encrypt(state: Block) Block {
    return asm ("aese %[result].16b, %[zero].16b"
        : [result] "=w" (-> Block),
        : [_] "0" (state),
          [zero] "w" (zero),
    );
}

fn decryptMixed(state: Block) Block {
    return asm (
        \\aesd %[result].16b, %[zero].16b
        \\aesimc %[result].16b, %[result].16b
        : [result] "=w" (-> Block),
        : [_] "0" (state),
          [zero] "w" (zero),
    );
}

fn decrypt(state: Block) Block {
    return asm ("aesd %[result].16b, %[zero].16b"
        : [result] "=w" (-> Block),
        : [_] "0" (state),
          [zero] "w" (zero),
    );
}

fn inverseMixColumns(state: Block) Block {
    return asm ("aesimc %[result].16b, %[state].16b"
        : [result] "=w" (-> Block),
        : [state] "w" (state),
    );
}

fn productLower(a: Pair, b: Pair) Pair {
    return asm ("pmull %[result].1q, %[a].1d, %[b].1d"
        : [result] "=w" (-> Pair),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

fn productUpper(a: Pair, b: Pair) Pair {
    return asm ("pmull2 %[result].1q, %[a].2d, %[b].2d"
        : [result] "=w" (-> Pair),
        : [a] "w" (a),
          [b] "w" (b),
    );
}
