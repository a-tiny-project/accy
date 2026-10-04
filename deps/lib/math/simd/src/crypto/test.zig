const std = @import("std");
const builtin = @import("builtin");
const simd = @import("../root.zig");
const aes = @import("aes.zig");
const block = @import("block.zig");
const clmul = @import("clmul.zig");
const crypto = @import("root.zig");
const lowering = @import("lowering.zig");
const portable = @import("portable.zig");

const Lowering = lowering.Lowering;

test {
    _ = aes;
    _ = block;
    _ = clmul;
    _ = lowering;
    _ = portable;
}

const Portable = aes.Lowered(.portable);
const widths = [_]usize{ 16, 32, 64, 128 };
const rcons = [_]u8{ 0x00, 0x01, 0x1b, 0x36, 0x80, 0xff };

const implementations = implementationsOf(aes);

/// Each lowering this build may issue for `family`, the namespace of one
/// family of operations such as `aes.zig`, then the dispatched entry points.
fn implementationsOf(comptime family: type) []const type {
    var result: [std.meta.tags(Lowering).len + 1]type = undefined;
    var count: usize = 0;
    for (std.meta.tags(Lowering)) |with| {
        if (family.lowering.covers(with)) {
            result[count] = family.Lowered(with);
            count += 1;
        }
    }
    result[count] = crypto;
    count += 1;
    const final = result[0..count].*;
    return &final;
}

test "every little-endian static Highway target with AES lowers AES to hardware" {
    if (builtin.zig_backend == .stage2_c) return error.SkipZigTest;
    switch (simd.static_target) {
        .sse4, .avx2, .avx3, .avx3_dl, .avx3_zen4, .avx3_spr, .avx10_2 => {
            try std.testing.expect(aes.lowering.covers(.sse));
        },
        .neon, .neon_bf16 => {
            // Big-endian aarch64 selects these targets too and keeps the
            // portable lowering.
            const expected: Lowering = if (builtin.cpu.arch == .aarch64) .arm else .portable;
            try std.testing.expectEqual(expected, aes.lowering);
        },
        .neon_without_aes, .wasm, .wasm_emu256 => {
            try std.testing.expectEqual(Lowering.portable, aes.lowering);
        },
        else => {},
    }
}

test "Highway AES encryption rounds match the NIST core fixture" {
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
    inline for (implementations) |Impl| {
        try expectVector(D, mixed, Impl.aesRound(D, state, @splat(0)));
        try expectVector(D, shifted, Impl.aesLastRound(D, state, @splat(0)));
    }
}

test "Highway AES inverse rounds and inverse mixing match FIPS fixtures" {
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
    inline for (implementations) |Impl| {
        try expectVector(D, shifted, Impl.aesLastRoundInv(D, state, @splat(0)));
        try expectVector(D, mixed, Impl.aesRoundInv(D, state, @splat(0)));
        try expectVector(D, mixed, Impl.aesInvMixColumns(D, shifted));
    }
}

test "Highway AES key generation assist matches x86 semantics" {
    const D = simd.FixedTag(u8, 16);
    const value: D.Vector = .{
        0x27, 0xcf, 0x73, 0xc3, 0x27, 0xcf, 0x73, 0xc3,
        0x74, 0x01, 0x90, 0x5a, 0x74, 0x01, 0x90, 0x5a,
    };
    const expected: D.Vector = .{
        0xcc, 0x8a, 0x8f, 0x2e, 0xaa, 0x8f, 0x2e, 0xcc,
        0x92, 0x7c, 0x60, 0xbe, 0x5c, 0x60, 0xbe, 0x92,
    };
    inline for (implementations) |Impl| {
        try expectVector(D, expected, Impl.aesKeyGenAssist(D, 0x20, value));
    }
}

const Aes128Vector = struct {
    key: [16]u8,
    plaintext: [16]u8,
    ciphertext: [16]u8,
};

const Aes256Vector = struct {
    key: [32]u8,
    plaintext: [16]u8,
    ciphertext: [16]u8,
};

const aes128_vectors = [_]Aes128Vector{
    // FIPS-197 Appendix B.
    .{
        .key = hex("2b7e151628aed2a6abf7158809cf4f3c"),
        .plaintext = hex("3243f6a8885a308d313198a2e0370734"),
        .ciphertext = hex("3925841d02dc09fbdc118597196a0b32"),
    },
    // FIPS-197 Appendix C.1.
    .{
        .key = hex("000102030405060708090a0b0c0d0e0f"),
        .plaintext = hex("00112233445566778899aabbccddeeff"),
        .ciphertext = hex("69c4e0d86a7b0430d8cdb78070b4c55a"),
    },
    // SP 800-38A F.1.1, the first ECB-AES128 block.
    .{
        .key = hex("2b7e151628aed2a6abf7158809cf4f3c"),
        .plaintext = hex("6bc1bee22e409f96e93d7e117393172a"),
        .ciphertext = hex("3ad77bb40d7a3660a89ecaf32466ef97"),
    },
};

const aes256_vectors = [_]Aes256Vector{
    // FIPS-197 Appendix C.3.
    .{
        .key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
        .plaintext = hex("00112233445566778899aabbccddeeff"),
        .ciphertext = hex("8ea2b7ca516745bfeafc49904b496089"),
    },
    // SP 800-38A F.1.5, the first ECB-AES256 block.
    .{
        .key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
        .plaintext = hex("6bc1bee22e409f96e93d7e117393172a"),
        .ciphertext = hex("f3eed1bdb5d2a03c064b5a7e3db181f8"),
    },
};

test "every AES lowering enciphers and deciphers the FIPS-197 and SP 800-38A vectors" {
    inline for (implementations) |Impl| {
        inline for (widths) |lanes| {
            const D = simd.FixedTag(u8, lanes);
            try expectAes128Vectors(Impl, D);
            try expectAes256Vectors(Impl, D);
        }
    }
}

test "AES-128 and AES-256 from every AES lowering match std.crypto on random blocks" {
    const D = simd.FixedTag(u8, 16);
    var prng = std.Random.DefaultPrng.init(0x5349_4d44_4145_5331);
    const random = prng.random();
    for (0..16) |_| {
        var key: [32]u8 = undefined;
        var plaintext: [16]u8 = undefined;
        random.bytes(&key);
        random.bytes(&plaintext);
        var expected128: [16]u8 = undefined;
        var expected256: [16]u8 = undefined;
        std.crypto.core.aes.Aes128.initEnc(key[0..16].*).encrypt(&expected128, &plaintext);
        std.crypto.core.aes.Aes256.initEnc(key).encrypt(&expected256, &plaintext);
        inline for (implementations) |Impl| {
            const keys128 = expandKey128(Impl, D, key[0..16].*);
            const keys256 = expandKey256(Impl, D, key[0..16].*, key[16..32].*);
            const ciphertext128 = encipher(Impl, D, 10, &keys128, plaintext);
            const ciphertext256 = encipher(Impl, D, 14, &keys256, plaintext);
            try expectVector(D, expected128, ciphertext128);
            try expectVector(D, expected256, ciphertext256);
            try expectVector(D, plaintext, decipher(Impl, D, 10, &keys128, ciphertext128));
            try expectVector(D, plaintext, decipher(Impl, D, 14, &keys256, ciphertext256));
        }
    }
}

test "every hardware AES lowering agrees with the portable lowering byte for byte" {
    var prng = std.Random.DefaultPrng.init(0x5349_4d44_4145_5332);
    const random = prng.random();
    inline for (implementations) |Impl| {
        if (comptime Impl != Portable) {
            inline for (widths) |lanes| {
                const D = simd.FixedTag(u8, lanes);
                try expectAgreement(Impl, D, @splat(0), @splat(0));
                try expectAgreement(Impl, D, @splat(0xff), @splat(0xff));
                for (0..64) |_| {
                    var state: [lanes]u8 = undefined;
                    var key: [lanes]u8 = undefined;
                    random.bytes(&state);
                    random.bytes(&key);
                    try expectAgreement(Impl, D, state, key);
                }
            }
        }
    }
}

test "AES entry points evaluate at comptime through the portable lowering" {
    const D = simd.FixedTag(u8, 16);
    const state: D.Vector = comptime blocksOf(D, &.{hex("00112233445566778899aabbccddeeff")});
    const key: D.Vector = comptime blocksOf(D, &.{hex("000102030405060708090a0b0c0d0e0f")});
    const folded = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        const round = crypto.aesRound(D, state, key);
        const inverse = crypto.aesRoundInv(D, round, key);
        const assisted = crypto.aesKeyGenAssist(D, 0x1b, inverse);
        break :blk crypto.aesInvMixColumns(D, crypto.aesLastRoundInv(
            D,
            crypto.aesLastRound(D, assisted, key),
            key,
        ));
    };
    var runtime_state = state;
    _ = &runtime_state;
    const round = crypto.aesRound(D, runtime_state, key);
    const inverse = crypto.aesRoundInv(D, round, key);
    const assisted = crypto.aesKeyGenAssist(D, 0x1b, inverse);
    const unfolded = crypto.aesInvMixColumns(D, crypto.aesLastRoundInv(
        D,
        crypto.aesLastRound(D, assisted, key),
        key,
    ));
    try expectVector(D, folded, unfolded);
}

fn expectAgreement(comptime Impl: type, comptime D: type, state: D.Vector, key: D.Vector) !void {
    try expectVector(D, Portable.aesRound(D, state, key), Impl.aesRound(D, state, key));
    try expectVector(D, Portable.aesLastRound(D, state, key), Impl.aesLastRound(D, state, key));
    try expectVector(D, Portable.aesRoundInv(D, state, key), Impl.aesRoundInv(D, state, key));
    try expectVector(
        D,
        Portable.aesLastRoundInv(D, state, key),
        Impl.aesLastRoundInv(D, state, key),
    );
    try expectVector(D, Portable.aesInvMixColumns(D, state), Impl.aesInvMixColumns(D, state));
    inline for (rcons) |rcon| {
        try expectVector(
            D,
            Portable.aesKeyGenAssist(D, rcon, state),
            Impl.aesKeyGenAssist(D, rcon, state),
        );
    }
}

fn expectAes128Vectors(comptime Impl: type, comptime D: type) !void {
    var keys: [aes128_vectors.len][16]u8 = undefined;
    var plaintexts: [aes128_vectors.len][16]u8 = undefined;
    var ciphertexts: [aes128_vectors.len][16]u8 = undefined;
    for (aes128_vectors, &keys, &plaintexts, &ciphertexts) |vector, *key, *plaintext, *ciphertext| {
        key.* = vector.key;
        plaintext.* = vector.plaintext;
        ciphertext.* = vector.ciphertext;
    }
    const round_keys = expandKey128(Impl, D, blocksOf(D, &keys));
    // FIPS-197 Appendix A.1 expands the Appendix B key to this last round key.
    const last_key: [D.lane_count]u8 = round_keys[10];
    try std.testing.expectEqualSlices(
        u8,
        &hex("d014f9a8c9ee2589e13f0cc8b6630ca6"),
        last_key[0..16],
    );
    const ciphertext = encipher(Impl, D, 10, &round_keys, blocksOf(D, &plaintexts));
    try expectVector(D, blocksOf(D, &ciphertexts), ciphertext);
    try expectVector(D, blocksOf(D, &plaintexts), decipher(Impl, D, 10, &round_keys, ciphertext));
}

fn expectAes256Vectors(comptime Impl: type, comptime D: type) !void {
    var low_keys: [aes256_vectors.len][16]u8 = undefined;
    var high_keys: [aes256_vectors.len][16]u8 = undefined;
    var plaintexts: [aes256_vectors.len][16]u8 = undefined;
    var ciphertexts: [aes256_vectors.len][16]u8 = undefined;
    for (aes256_vectors, 0..) |vector, index| {
        low_keys[index] = vector.key[0..16].*;
        high_keys[index] = vector.key[16..32].*;
        plaintexts[index] = vector.plaintext;
        ciphertexts[index] = vector.ciphertext;
    }
    const round_keys = expandKey256(Impl, D, blocksOf(D, &low_keys), blocksOf(D, &high_keys));
    const ciphertext = encipher(Impl, D, 14, &round_keys, blocksOf(D, &plaintexts));
    try expectVector(D, blocksOf(D, &ciphertexts), ciphertext);
    try expectVector(D, blocksOf(D, &plaintexts), decipher(Impl, D, 14, &round_keys, ciphertext));
}

/// The AES-128 key schedule through AESKEYGENASSIST, as Intel's AES-NI white
/// paper derives it: each round key XORs the prefix sums of the previous
/// key's words with the rotated, substituted last word plus the round
/// constant.
fn expandKey128(comptime Impl: type, comptime D: type, key: D.Vector) [11]D.Vector {
    const round_constants = [_]u8{ 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 };
    var keys: [11]D.Vector = undefined;
    keys[0] = key;
    inline for (round_constants, 1..) |rcon, index| {
        const assisted = Impl.aesKeyGenAssist(D, rcon, keys[index - 1]);
        keys[index] = prefixWords(D, keys[index - 1]) ^ broadcastWord(D, 3, assisted);
    }
    return keys;
}

/// The AES-256 key schedule through AESKEYGENASSIST. Even round keys take
/// the rotated word with the round constant, and odd round keys take the
/// substituted word alone.
fn expandKey256(comptime Impl: type, comptime D: type, low: D.Vector, high: D.Vector) [15]D.Vector {
    const round_constants = [_]u8{ 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40 };
    var keys: [15]D.Vector = undefined;
    keys[0] = low;
    keys[1] = high;
    inline for (2..15) |index| {
        const previous = keys[index - 1];
        const word = if (index % 2 == 0)
            broadcastWord(D, 3, Impl.aesKeyGenAssist(D, round_constants[index / 2 - 1], previous))
        else
            broadcastWord(D, 2, Impl.aesKeyGenAssist(D, 0, previous));
        keys[index] = prefixWords(D, keys[index - 2]) ^ word;
    }
    return keys;
}

fn encipher(
    comptime Impl: type,
    comptime D: type,
    comptime rounds: usize,
    keys: *const [rounds + 1]D.Vector,
    plaintext: D.Vector,
) D.Vector {
    var state = plaintext ^ keys[0];
    inline for (1..rounds) |round| state = Impl.aesRound(D, state, keys[round]);
    return Impl.aesLastRound(D, state, keys[rounds]);
}

/// FIPS-197's equivalent inverse cipher, which applies InvMixColumns to the
/// middle round keys so that AESDEC can add them after its own.
fn decipher(
    comptime Impl: type,
    comptime D: type,
    comptime rounds: usize,
    keys: *const [rounds + 1]D.Vector,
    ciphertext: D.Vector,
) D.Vector {
    var state = ciphertext ^ keys[rounds];
    inline for (1..rounds) |round| {
        state = Impl.aesRoundInv(D, state, Impl.aesInvMixColumns(D, keys[rounds - round]));
    }
    return Impl.aesLastRoundInv(D, state, keys[0]);
}

fn prefixWords(comptime D: type, value: D.Vector) D.Vector {
    var words: [D.lane_count / 4]u32 = @bitCast(value);
    var index: usize = 0;
    while (index < words.len) : (index += 4) {
        words[index + 1] ^= words[index];
        words[index + 2] ^= words[index + 1];
        words[index + 3] ^= words[index + 2];
    }
    return @bitCast(words);
}

fn broadcastWord(comptime D: type, comptime word: usize, value: D.Vector) D.Vector {
    var words: [D.lane_count / 4]u32 = @bitCast(value);
    var index: usize = 0;
    while (index < words.len) : (index += 4) {
        words[index..][0..4].* = @splat(words[index + word]);
    }
    return @bitCast(words);
}

fn blocksOf(comptime D: type, blocks: []const [16]u8) D.Vector {
    std.debug.assert(blocks.len > 0);
    var bytes: [D.lane_count]u8 = undefined;
    for (0..D.lane_count / 16) |index| {
        bytes[index * 16 ..][0..16].* = blocks[index % blocks.len];
    }
    return bytes;
}

fn expectVector(comptime D: type, expected: D.Vector, actual: D.Vector) !void {
    const expected_bytes: [D.lane_count]u8 = expected;
    const actual_bytes: [D.lane_count]u8 = actual;
    try std.testing.expectEqualSlices(u8, &expected_bytes, &actual_bytes);
}

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var bytes: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
    return bytes;
}

const PortableClMul = clmul.Lowered(.portable);
const clmul_widths = [_]usize{ 2, 4, 8, 16 };

const clmul_implementations = implementationsOf(clmul);

/// A pair of 128-bit blocks and their carryless products, each as two u64
/// lanes with the lower lane first.
const ProductCase = struct {
    a: [2]u64,
    b: [2]u64,
    lower: [2]u64,
    upper: [2]u64,
};

const product_cases = [_]ProductCase{
    // The PCLMULQDQ example in Gueron and Kounavis's Intel white paper on
    // carry-less multiplication and GCM: immediates 0x00 and 0x11 applied to
    // 0x7b5b54657374566563746f725d53475d and
    // 0x48692853686179295b477565726f6e5d.
    .{
        .a = .{ 0x6374_6f72_5d53_475d, 0x7b5b_5465_7374_5665 },
        .b = .{ 0x5b47_7565_726f_6e5d, 0x4869_2853_6861_7929 },
        .lower = .{ 0x9296_33d5_d36f_0451, 0x1d4d_84c8_5c34_40c0 },
        .upper = .{ 0xd66e_e03e_410f_d4ed, 0x1d1e_1f2c_592e_7c45 },
    },
    // A square over GF(2) moves each bit of its factor to twice its
    // position, because every cross term appears twice and cancels.
    .{
        .a = .{ 0xffff_ffff_ffff_ffff, 0x8000_0000_0000_0001 },
        .b = .{ 0xffff_ffff_ffff_ffff, 0x8000_0000_0000_0001 },
        .lower = .{ 0x5555_5555_5555_5555, 0x5555_5555_5555_5555 },
        .upper = .{ 0x0000_0000_0000_0001, 0x4000_0000_0000_0000 },
    },
    // x^63 times x^63 is x^126, and (x + 1)(x^2 + 1) is x^3 + x^2 + x + 1,
    // where integer multiplication would carry.
    .{
        .a = .{ 0x8000_0000_0000_0000, 0x0000_0000_0000_0003 },
        .b = .{ 0x8000_0000_0000_0000, 0x0000_0000_0000_0005 },
        .lower = .{ 0x0000_0000_0000_0000, 0x4000_0000_0000_0000 },
        .upper = .{ 0x0000_0000_0000_000f, 0x0000_0000_0000_0000 },
    },
    // Zero annihilates and one is the identity.
    .{
        .a = .{ 0x0000_0000_0000_0000, 0x0000_0000_0000_0001 },
        .b = .{ 0xdead_beef_0123_4567, 0xfedc_ba98_7654_3210 },
        .lower = .{ 0x0000_0000_0000_0000, 0x0000_0000_0000_0000 },
        .upper = .{ 0xfedc_ba98_7654_3210, 0x0000_0000_0000_0000 },
    },
};

/// GHASH blocks under a key and their digest, from McGrew and Viega's GCM
/// specification. The blocks are the padded additional data, the padded
/// ciphertext, and the block of their bit lengths.
const GhashVector = struct {
    key: [16]u8,
    blocks: []const u8,
    expected: [16]u8,
};

const ghash_vectors = [_]GhashVector{
    // Test case 2: one ciphertext block and the length block.
    .{
        .key = hex("66e94bd4ef8a2c3b884cfa59ca342b2e"),
        .blocks = &hex("0388dace60b6a392f328c2b971b2fe78" ++
            "00000000000000000000000000000080"),
        .expected = hex("f38cbb1ad69223dcc3457ae5b6b0f885"),
    },
    // Test case 4: 20 bytes of additional data, 60 bytes of ciphertext, and
    // the length block.
    .{
        .key = hex("b83b533708bf535d0aa6e52980d53b78"),
        .blocks = &hex("feedfacedeadbeeffeedfacedeadbeef" ++
            "abaddad2000000000000000000000000" ++
            "42831ec2217774244b7221b784d0d49c" ++
            "e3aa212f2c02a4e035c17e2329aca12e" ++
            "21d514b25466931c7d8f6a5aac84aa05" ++
            "1ba30b396a0aac973d58e09100000000" ++
            "00000000000000a000000000000001e0"),
        .expected = hex("698e57f70e6ecc7fd9463b7260a9ae5f"),
    },
};

test "every little-endian static Highway target with CLMUL lowers it to hardware" {
    if (builtin.zig_backend == .stage2_c) return error.SkipZigTest;
    switch (simd.static_target) {
        .sse4, .avx2, .avx3 => try std.testing.expect(clmul.lowering.covers(.sse)),
        .avx3_dl, .avx3_zen4, .avx3_spr, .avx10_2 => {
            // These targets require VPCLMULQDQ.
            try std.testing.expect(clmul.lowering.covers(.vex256));
        },
        .neon, .neon_bf16 => {
            const expected: Lowering = if (builtin.cpu.arch == .aarch64) .arm else .portable;
            try std.testing.expectEqual(expected, clmul.lowering);
        },
        .neon_without_aes, .wasm, .wasm_emu256 => {
            try std.testing.expectEqual(Lowering.portable, clmul.lowering);
        },
        else => {},
    }
}

test "every carryless multiplication lowering returns the known products in every block" {
    inline for (clmul_implementations) |Impl| {
        inline for (clmul_widths) |lanes| {
            const D = simd.FixedTag(u64, lanes);
            // Rotating the cases through the blocks catches a lowering that
            // reads or writes another block's lanes.
            for (0..product_cases.len) |offset| {
                const a = productLanes(D, "a", offset);
                const b = productLanes(D, "b", offset);
                try expectLanes(D, productLanes(D, "lower", offset), Impl.clMulLower(D, a, b));
                try expectLanes(D, productLanes(D, "upper", offset), Impl.clMulUpper(D, a, b));
            }
        }
    }
}

test "GHASH through every carryless multiplication lowering matches the GCM test vectors" {
    inline for (clmul_implementations) |Impl| {
        inline for (clmul_widths) |lanes| {
            const D = simd.FixedTag(u64, lanes);
            for (ghash_vectors) |vector| {
                const keys: [lanes / 2][16]u8 = @splat(vector.key);
                const messages: [lanes / 2][]const u8 = @splat(vector.blocks);
                for (ghash(Impl, D, &keys, &messages)) |digest| {
                    try std.testing.expectEqualSlices(u8, &vector.expected, &digest);
                }
            }
        }
    }
}

test "GHASH through every carryless multiplication lowering matches std.crypto" {
    var prng = std.Random.DefaultPrng.init(0x5349_4d44_434c_4d31);
    const random = prng.random();
    inline for (clmul_implementations) |Impl| {
        inline for (clmul_widths) |lanes| {
            const D = simd.FixedTag(u64, lanes);
            // Each block hashes its own key and message.
            var keys: [lanes / 2][16]u8 = undefined;
            var storage: [lanes / 2][5 * 16]u8 = undefined;
            var messages: [lanes / 2][]const u8 = undefined;
            for (0..4) |_| {
                for (&keys, &storage, &messages) |*key, *bytes, *message| {
                    random.bytes(key);
                    random.bytes(bytes);
                    message.* = bytes;
                }
                const digests = ghash(Impl, D, &keys, &messages);
                for (keys, messages, digests) |key, message, digest| {
                    var expected: [16]u8 = undefined;
                    std.crypto.onetimeauth.Ghash.create(&expected, message, &key);
                    try std.testing.expectEqualSlices(u8, &expected, &digest);
                }
            }
        }
    }
}

test "every hardware carryless multiplication lowering agrees with the portable product" {
    var prng = std.Random.DefaultPrng.init(0x5349_4d44_434c_4d32);
    const random = prng.random();
    inline for (clmul_implementations) |Impl| {
        if (comptime Impl != PortableClMul) {
            inline for (clmul_widths) |lanes| {
                const D = simd.FixedTag(u64, lanes);
                try expectProductAgreement(Impl, D, @splat(0), @splat(0));
                try expectProductAgreement(Impl, D, @splat(~@as(u64, 0)), @splat(~@as(u64, 0)));
                for (0..64) |_| {
                    var a: [lanes]u64 = undefined;
                    var b: [lanes]u64 = undefined;
                    for (&a, &b) |*left, *right| {
                        left.* = random.int(u64);
                        right.* = random.int(u64);
                    }
                    try expectProductAgreement(Impl, D, a, b);
                }
            }
        }
    }
}

test "carryless multiplication evaluates at comptime through the portable lowering" {
    const D = simd.FixedTag(u64, 4);
    const a: D.Vector = .{ 0x6374_6f72_5d53_475d, 0x7b5b_5465_7374_5665, 3, ~@as(u64, 0) };
    const b: D.Vector = .{ 0x5b47_7565_726f_6e5d, 0x4869_2853_6861_7929, 5, ~@as(u64, 0) };
    const folded_lower = comptime crypto.clMulLower(D, a, b);
    const folded_upper = comptime crypto.clMulUpper(D, a, b);
    var runtime_a = a;
    _ = &runtime_a;
    try expectLanes(D, folded_lower, crypto.clMulLower(D, runtime_a, b));
    try expectLanes(D, folded_upper, crypto.clMulUpper(D, runtime_a, b));
}

fn expectProductAgreement(comptime Impl: type, comptime D: type, a: D.Vector, b: D.Vector) !void {
    try expectLanes(D, PortableClMul.clMulLower(D, a, b), Impl.clMulLower(D, a, b));
    try expectLanes(D, PortableClMul.clMulUpper(D, a, b), Impl.clMulUpper(D, a, b));
}

/// The lanes of `field` from the product cases, case `offset + k` in block k.
fn productLanes(comptime D: type, comptime field: []const u8, offset: usize) D.Vector {
    var lanes: [D.lane_count]u64 = undefined;
    for (0..D.lane_count / 2) |block_index| {
        const case = product_cases[(block_index + offset) % product_cases.len];
        lanes[block_index * 2 ..][0..2].* = @field(case, field);
    }
    return lanes;
}

/// GHASH of `messages` under `keys`, one instance in each 128-bit block of
/// `D`, through the carryless products of `Impl`. Block k hashes message k
/// under key k, and every message holds the same number of whole blocks.
fn ghash(
    comptime Impl: type,
    comptime D: type,
    keys: *const [D.lane_count / 2][16]u8,
    messages: *const [D.lane_count / 2][]const u8,
) [D.lane_count / 2][16]u8 {
    var key_lanes: [D.lane_count]u64 = undefined;
    for (keys, 0..) |key, instance| {
        key_lanes[instance * 2 ..][0..2].* = doubledKey(ghashLanes(key));
    }
    const block_count = messages[0].len / 16;
    var accumulator: D.Vector = @splat(0);
    for (0..block_count) |index| {
        var block_lanes: [D.lane_count]u64 = undefined;
        for (messages, 0..) |message, instance| {
            std.debug.assert(message.len == block_count * 16);
            block_lanes[instance * 2 ..][0..2].* = ghashLanes(message[index * 16 ..][0..16].*);
        }
        accumulator = ghashMultiply(Impl, D, accumulator ^ @as(D.Vector, block_lanes), key_lanes);
    }
    const accumulator_lanes: [D.lane_count]u64 = accumulator;
    var digests: [D.lane_count / 2][16]u8 = undefined;
    for (&digests, 0..) |*digest, instance| {
        digest.* = ghashBytes(accumulator_lanes[instance * 2 ..][0..2].*);
    }
    return digests;
}

/// The product of each block of `x` and `h` in GHASH's field: four
/// carryless products, then the two-product reduction modulo
/// x^128 + x^127 + x^126 + x^121 + 1 that std.crypto's GHASH applies to the
/// doubled key.
fn ghashMultiply(comptime Impl: type, comptime D: type, x: D.Vector, h: D.Vector) D.Vector {
    const swapped_h = swapHalves(D, h);
    const middle = Impl.clMulLower(D, x, swapped_h) ^ Impl.clMulUpper(D, x, swapped_h);
    const low = Impl.clMulLower(D, x, h) ^ shiftUp(D, middle);
    const high = Impl.clMulUpper(D, x, h) ^ shiftDown(D, middle);
    const polynomial: D.Vector = everyBlock(D, .{ 0xc200_0000_0000_0000, 0 });
    const folded = swapHalves(D, low) ^ Impl.clMulLower(D, low, polynomial);
    return swapHalves(D, folded) ^ Impl.clMulLower(D, folded, polynomial) ^ high;
}

/// GCM's key doubled in GHASH's field, as std.crypto's GHASH prepares it for
/// products that skip the shift the bit-reflected field otherwise needs.
fn doubledKey(lanes: [2]u64) [2]u64 {
    const key = @as(u128, lanes[1]) << 64 | lanes[0];
    const carry = ((@as(u128, 0xc2) << 120) | 1) & (@as(u128, 0) -% (key >> 127));
    const doubled = (key << 1) ^ carry;
    return .{ @truncate(doubled), @truncate(doubled >> 64) };
}

/// The two lanes of the 128-bit integer that GCM reads from `bytes` in
/// big-endian order, the low half first.
fn ghashLanes(bytes: [16]u8) [2]u64 {
    return .{
        std.mem.readInt(u64, bytes[8..16], .big),
        std.mem.readInt(u64, bytes[0..8], .big),
    };
}

fn ghashBytes(lanes: [2]u64) [16]u8 {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], lanes[1], .big);
    std.mem.writeInt(u64, bytes[8..16], lanes[0], .big);
    return bytes;
}

/// Each block of `value` with its two lanes exchanged.
fn swapHalves(comptime D: type, value: D.Vector) D.Vector {
    return @shuffle(u64, value, undefined, blockPattern(D, .{ 1, 0 }));
}

/// Each block of `value` shifted up by 64 bits: its lower lane moved to the
/// upper lane and zero below.
fn shiftUp(comptime D: type, value: D.Vector) D.Vector {
    const zero: D.Vector = @splat(0);
    return @shuffle(u64, value, zero, blockPattern(D, .{ -1, 0 }));
}

/// Each block of `value` shifted down by 64 bits: its upper lane moved to
/// the lower lane and zero above.
fn shiftDown(comptime D: type, value: D.Vector) D.Vector {
    const zero: D.Vector = @splat(0);
    return @shuffle(u64, value, zero, blockPattern(D, .{ 1, -1 }));
}

/// Shuffle indices that apply `pattern` to every block: a nonnegative entry
/// selects that lane of the same block, and -1 selects lane 0 of the second
/// operand.
fn blockPattern(comptime D: type, comptime pattern: [2]i32) [D.lane_count]i32 {
    var indices: [D.lane_count]i32 = undefined;
    for (0..D.lane_count / 2) |block_index| {
        for (pattern, 0..) |entry, lane| {
            const base: i32 = @intCast(block_index * 2);
            indices[block_index * 2 + lane] = if (entry < 0) -1 else base + entry;
        }
    }
    return indices;
}

fn everyBlock(comptime D: type, lanes: [2]u64) D.Vector {
    var result: [D.lane_count]u64 = undefined;
    for (0..D.lane_count / 2) |block_index| result[block_index * 2 ..][0..2].* = lanes;
    return result;
}

fn expectLanes(comptime D: type, expected: D.Vector, actual: D.Vector) !void {
    const expected_lanes: [D.lane_count]u64 = expected;
    const actual_lanes: [D.lane_count]u64 = actual;
    try std.testing.expectEqualSlices(u64, &expected_lanes, &actual_lanes);
}
