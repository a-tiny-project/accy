//! CRC-32/ISO-HDLC, the check of PNG chunks, gzip members and Ethernet
//! frames.
//!
//! The CRC reads a message as a polynomial over GF(2), one coefficient per
//! bit, and returns the remainder of the message times x^32 divided by the
//! generator polynomial 0x04C11DB7, with the register started at all ones and
//! the remainder complemented. Bits enter least significant first, so bit k
//! of a register holds the coefficient of x^(31-k), and multiplying a
//! register by x shifts it right one bit.
//!
//! Multiplying a remainder by x^n modulo the generator moves it n bits along
//! the message, so a CRC can fold early bits forward instead of dividing bit
//! by bit. Where the target has carryless multiplication, an update of at
//! least 64 bytes holds the message in four registers, folds each forward
//! over the next four registers of input, folds the registers onto one
//! 128-bit block, and reduces that block to the 32-bit remainder by Barrett
//! reduction. This is the construction of Gopal et al., "Fast CRC
//! Computation for Generic Polynomials Using PCLMULQDQ Instruction" (Intel,
//! 2009). The fold constants are powers of x that the compiler computes from
//! the polynomial. Shorter updates, the last bytes of an update, and targets
//! without carryless multiplication read slicing-by-8 tables, also computed
//! at compile time.

const std = @import("std");
const builtin = @import("builtin");
const simd = @import("../root.zig");

const assert = std.debug.assert;
const clmul = simd.crypto.clmul;

/// The generator polynomial without its x^32 term, bit-reflected: bit k
/// holds the coefficient of x^(31-k).
pub const polynomial: u32 = 0xedb8_8320;

/// The register of an empty message: all ones.
const register_initial: u32 = 0xffff_ffff;

/// A CRC-32 over bytes that arrive in pieces.
pub const Crc32 = struct {
    /// The remainder of the bytes so far, before the final complement.
    register: u32,

    pub fn init() Crc32 {
        return .{ .register = register_initial };
    }

    pub fn update(self: *Crc32, bytes: []const u8) void {
        self.register = advance(self.register, bytes);
    }

    pub fn final(self: Crc32) u32 {
        return ~self.register;
    }

    /// The CRC-32 of `bytes`.
    pub fn hash(bytes: []const u8) u32 {
        return ~advance(register_initial, bytes);
    }
};

/// Whether this build folds with carryless multiplication: its lowering
/// issues the instructions, and a little-endian load puts the bytes of a lane
/// in the order a reflected register holds them.
const folds = clmul.lowering != .portable and builtin.cpu.arch.endian() == .little;

/// The fold of long updates, over the widest registers the lowering issues.
const Wide = Folding(clmul, clmul.lowering.widestBytes());

/// The fold over 16-byte registers, which every lowering issues, for updates
/// shorter than one step of `Wide`.
const Narrow = Folding(clmul, block_bytes);

/// The register after `bytes`, from `register`.
fn advance(register: u32, bytes: []const u8) u32 {
    var result = register;
    var rest = bytes;
    if (comptime folds) {
        if (!@inComptime() and rest.len >= Narrow.stride) {
            const folded = if (rest.len >= Wide.stride)
                Wide.advance(result, rest)
            else
                Narrow.advance(result, rest);
            assert(folded.consumed % block_bytes == 0);
            assert(rest.len - folded.consumed < block_bytes);
            result = folded.register;
            rest = rest[folded.consumed..];
        }
    }
    return slicing.advance(result, rest);
}

/// Bytes in one block, the 128 bits that one carryless multiplication of
/// each lane reads.
const block_bytes: usize = 16;
const block_bits: usize = block_bytes * 8;

/// One block as two u64 lanes. The lower lane holds the earlier eight bytes.
const Block = simd.FixedTag(u64, 2);

/// The register after the first `consumed` bytes of a fold's input.
const Folded = struct {
    register: u32,
    consumed: usize,
};

/// Folding through `Implementation`, a namespace with `clMulLower` and
/// `clMulUpper`, over registers of `register_bytes`.
fn Folding(comptime Implementation: type, comptime register_bytes: usize) type {
    comptime {
        assert(std.math.isPowerOfTwo(register_bytes));
        assert(register_bytes >= block_bytes);
        assert(register_bytes <= 64);
    }
    return struct {
        const Register: type = simd.FixedTag(u64, register_bytes / @sizeOf(u64));
        /// Registers that fold side by side. Each fold waits on the latency of
        /// its own products, and four registers keep the multiplier busy
        /// while it waits.
        const register_count = 4;
        const blocks_per_register = register_bytes / block_bytes;
        const block_count = register_count * blocks_per_register;
        /// Bytes that each step of the main loop reads.
        const stride = register_count * register_bytes;
        const stride_pair: Register.Vector = repeated(Register, foldPair(stride * 8));
        const block_pair: Block.Vector = foldPair(block_bits);

        /// Folds the longest prefix of `bytes` that is a whole number of
        /// blocks, starting from `register`. `bytes` holds at least `stride`
        /// bytes.
        fn advance(register: u32, bytes: []const u8) Folded {
            comptime assert(builtin.cpu.arch.endian() == .little);
            assert(bytes.len >= stride);
            var registers: [register_count]Register.Vector = undefined;
            inline for (&registers, 0..) |*each, index| {
                each.* = load(Register, bytes[index * register_bytes ..]);
            }
            // The register is the remainder of the bytes before these, which
            // a CRC adds to the first 32 bits it reads.
            registers[0][0] ^= register;
            var offset: usize = stride;
            while (bytes.len - offset >= stride) : (offset += stride) {
                inline for (&registers, 0..) |*each, index| {
                    each.* = fold(Implementation, Register, each.*, stride_pair) ^
                        load(Register, bytes[offset + index * register_bytes ..]);
                }
            }
            var block = combine(registers);
            while (bytes.len - offset >= block_bytes) : (offset += block_bytes) {
                block = fold(Implementation, Block, block, block_pair) ^
                    load(Block, bytes[offset..]);
            }
            assert(offset % block_bytes == 0);
            assert(bytes.len - offset < block_bytes);
            return .{ .register = reduce(Implementation, block), .consumed = offset };
        }

        /// One block congruent to the registers: each block folded forward
        /// past the blocks after it, onto the last block.
        fn combine(registers: [register_count]Register.Vector) Block.Vector {
            var result = blockOf(Register, registers[register_count - 1], blocks_per_register - 1);
            inline for (0..block_count - 1) |index| {
                const distance = (block_count - 1 - index) * block_bits;
                const block = blockOf(
                    Register,
                    registers[index / blocks_per_register],
                    index % blocks_per_register,
                );
                result ^= fold(Implementation, Block, block, comptime foldPair(distance));
            }
            return result;
        }
    };
}

/// `value` folded forward through `Implementation` by the distance that
/// `pair` encodes.
fn fold(
    comptime Implementation: type,
    comptime D: type,
    value: D.Vector,
    pair: D.Vector,
) D.Vector {
    return Implementation.clMulLower(D, value, pair) ^ Implementation.clMulUpper(D, value, pair);
}

/// Block `index` of a register of `D`.
fn blockOf(comptime D: type, value: D.Vector, comptime index: usize) Block.Vector {
    comptime assert(index < D.lane_count / 2);
    return @shuffle(u64, value, undefined, [2]i32{ 2 * index, 2 * index + 1 });
}

/// The register of a message whose last 128 bits are `block`: the block
/// times x^32, folded through `Implementation` to 64 bits and then 32 bits,
/// with Barrett reduction taking off the last multiple of the generator.
fn reduce(comptime Implementation: type, block: Block.Vector) u32 {
    const lower = Implementation.clMulLower;
    const low_words: Block.Vector = @splat(0xffff_ffff);
    const by_96: Block.Vector = .{ comptime foldConstant(96), 0 };
    const by_64: Block.Vector = .{ comptime foldConstant(64), 0 };
    var value = lower(Block, block, by_96) ^ Block.Vector{ block[1], 0 };
    const shifted: Block.Vector = .{ (value[0] >> 32) | (value[1] << 32), value[1] >> 32 };
    value = lower(Block, value & low_words, by_64) ^ shifted;
    // What remains to divide is a 64-bit value: the message times x^32.
    assert(value[1] == 0);
    const quotient = lower(Block, value & low_words, .{ barrett_quotient, 0 });
    const product = lower(Block, quotient & low_words, .{ barrett_generator, 0 });
    const remainder = value ^ product;
    // Subtracting the multiple of the generator clears the low 32 bits,
    // where a reflected value holds its highest powers of x.
    assert(remainder[1] == 0);
    assert(@as(u32, @truncate(remainder[0])) == 0);
    return @truncate(remainder[0] >> 32);
}

/// The first bytes of `bytes` as the u64 lanes of `D`, in one unaligned
/// load. The load reads the lanes through a pointer, because the pinned
/// compiler assembles a bit cast from bytes to wider lanes one byte at a
/// time.
fn load(comptime D: type, bytes: []const u8) D.Vector {
    assert(bytes.len >= D.byte_count);
    const lanes: *align(1) const D.Vector = @ptrCast(bytes[0..D.byte_count]);
    return lanes.*;
}

/// `pair` in every block of `D`.
fn repeated(comptime D: type, pair: Block.Vector) D.Vector {
    comptime assert(D.lane_count % 2 == 0);
    var lanes: [D.lane_count]u64 = undefined;
    for (0..D.lane_count / 2) |index| {
        lanes[2 * index] = pair[0];
        lanes[2 * index + 1] = pair[1];
    }
    return lanes;
}

/// The multipliers that fold a block forward by `distance` bits. The lower
/// lane holds the earlier 64 bits, which sit 64 bits further from the
/// block's end than the upper lane's.
fn foldPair(comptime distance: usize) Block.Vector {
    comptime assert(distance >= block_bits);
    comptime assert(distance % block_bits == 0);
    // One quota covers both powers, which share this evaluation.
    @setEvalBranchQuota(power_branches * (2 * distance + 64));
    return .{ foldConstant(distance + 32), foldConstant(distance - 32) };
}

/// x^exponent modulo the generator as a multiplier of reflected u64 lanes.
/// The carryless product of two reflected lanes holds x times the product of
/// their polynomials, so the 32-bit power sits one bit up.
fn foldConstant(comptime exponent: usize) u64 {
    const result = @as(u64, comptime power(exponent)) << 1;
    comptime assert(result >> 33 == 0);
    return result;
}

/// x^exponent modulo the generator, reflected.
fn power(comptime exponent: usize) u32 {
    @setEvalBranchQuota(power_branches * (exponent + 32));
    var result: u32 = 1 << 31;
    for (0..exponent) |_| result = timesX(result);
    // The generator does not divide x, so no power of x is a multiple of it.
    assert(result != 0);
    return result;
}

/// Backward branches the compiler counts for each power of x, with margin.
const power_branches = 16;

/// `register` times x modulo the generator: one bit of a CRC.
fn timesX(register: u32) u32 {
    return (register >> 1) ^ (polynomial & (0 -% (register & 1)));
}

/// The generator with its x^32 term, 33 bits, reflected.
const barrett_generator: u64 = (@as(u64, polynomial) << 1) | 1;

/// The quotient of x^64 by the generator, 33 bits, reflected: the Barrett
/// constant that estimates how many times the generator divides a 64-bit
/// remainder.
const barrett_quotient: u64 = quotient: {
    const generator: u128 = (1 << 32) | @as(u128, @bitReverse(polynomial));
    var remainder: u128 = 1 << 64;
    var result: u33 = 0;
    var degree: usize = 64;
    while (degree >= 32) : (degree -= 1) {
        if ((remainder >> degree) & 1 != 0) {
            result |= @as(u33, 1) << @intCast(degree - 32);
            remainder ^= generator << @intCast(degree - 32);
        }
    }
    assert(remainder >> 32 == 0);
    break :quotient @bitReverse(result);
};

/// Slicing-by-8: the register after eight bytes is the exclusive-or of eight
/// table entries, one per byte, where table t holds the register of each
/// byte value followed by t zero bytes.
const slicing = struct {
    const slice_bytes = 8;
    const tables: [slice_bytes][256]u32 = build();

    fn build() [slice_bytes][256]u32 {
        @setEvalBranchQuota(32 * 256 * slice_bytes);
        var result: [slice_bytes][256]u32 = undefined;
        for (&result[0], 0..) |*entry, byte| {
            var register: u32 = byte;
            for (0..8) |_| register = timesX(register);
            entry.* = register;
        }
        for (1..slice_bytes) |table| {
            for (&result[table], result[table - 1]) |*entry, previous| {
                entry.* = (previous >> 8) ^ result[0][@as(u8, @truncate(previous))];
            }
        }
        // Entries of the byte table in zlib's crc32.c.
        assert(result[0][1] == 0x7707_3096);
        assert(result[0][128] == polynomial);
        return result;
    }

    fn advance(register: u32, bytes: []const u8) u32 {
        var result = register;
        var offset: usize = 0;
        while (bytes.len - offset >= slice_bytes) : (offset += slice_bytes) {
            const word = std.mem.readInt(u64, bytes[offset..][0..slice_bytes], .little) ^ result;
            var next: u32 = 0;
            inline for (0..slice_bytes) |index| {
                next ^= tables[slice_bytes - 1 - index][@as(u8, @truncate(word >> (8 * index)))];
            }
            result = next;
        }
        assert(bytes.len - offset < slice_bytes);
        for (bytes[offset..]) |byte| {
            result = (result >> 8) ^ tables[0][@as(u8, @truncate(result)) ^ byte];
        }
        return result;
    }
};

/// The register after `bytes` one bit at a time: the definition, with no
/// table and no fold.
fn bitwise(register: u32, bytes: []const u8) u32 {
    var result = register;
    for (bytes) |byte| {
        result ^= byte;
        for (0..8) |_| result = timesX(result);
    }
    return result;
}
