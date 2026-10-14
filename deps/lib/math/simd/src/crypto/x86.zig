//! x86 lowering of the crypto operations: AES-NI and VAES for the AES
//! operations, and PCLMULQDQ and VPCLMULQDQ for carryless multiplication.
//!
//! AESENC, AESENCLAST, AESDEC and AESDECLAST transform each 16-byte block of
//! a register and then add that block's round key, which is the semantics the
//! operations take from Highway. VAES widens these four instructions to 32-
//! and 64-byte registers. AESIMC and AESKEYGENASSIST stay 16 bytes wide, so a
//! VAES lowering reaches them on wider vectors through the round instructions,
//! as Highway's AVX3_DL target does.
//!
//! PCLMULQDQ multiplies one u64 lane of each operand's 16-byte block, the
//! lane that bits 0 and 4 of its immediate select, so the immediates 0x00 and
//! 0x11 give CLMulLower and CLMulUpper. VPCLMULQDQ applies the immediate to
//! every block of a 32- or 64-byte register. The assembly follows
//! `std.crypto` in the pinned Zig standard library: the AES-NI backend of its
//! AES and the PCLMULQDQ path of its GHASH.

const std = @import("std");
const block = @import("block.zig");
const Lowering = @import("lowering.zig").Lowering;

const Block = @Vector(block.block_bytes, u8);

/// How the instructions are encoded.
const Encoding = enum {
    /// The SSE encoding, for targets without AVX.
    legacy,
    /// The VEX encoding, and EVEX for 64-byte registers. AVX targets use it so
    /// that crypto code never mixes SSE and AVX encodings.
    vex,
};

/// The encoding of an x86 lowering and the widest register it issues.
const Form = struct {
    encoding: Encoding,
    widest_bytes: usize,

    fn of(comptime with: Lowering) Form {
        const encoding: Encoding = switch (with) {
            .sse => .legacy,
            .vex128, .vex256, .evex512 => .vex,
            .portable, .arm => @compileError(@tagName(with) ++ " is not an x86 lowering"),
        };
        const form: Form = .{ .encoding = encoding, .widest_bytes = with.widestBytes() };
        comptime {
            std.debug.assert(std.math.isPowerOfTwo(form.widest_bytes));
            std.debug.assert(form.widest_bytes >= block.block_bytes);
            std.debug.assert(form.widest_bytes <= 64);
            if (form.encoding == .legacy) std.debug.assert(form.widest_bytes == block.block_bytes);
        }
        return form;
    }

    /// The bytes of one register of a vector of `D`: the whole vector, or
    /// the widest register when the vector is wider.
    fn registerBytes(comptime form: Form, comptime D: type) usize {
        return @min(form.widest_bytes, D.byte_count);
    }
};

/// The AES operations as `with` issues them, over registers of up to its
/// widest bytes. A wider vector splits into registers of that width.
pub fn Aes(comptime with: Lowering) type {
    const form = comptime Form.of(with);
    return struct {
        const Self = @This();

        pub fn aesRound(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
            return rounds(D, "aesenc", state, round_key);
        }

        pub fn aesLastRound(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
            return rounds(D, "aesenclast", state, round_key);
        }

        pub fn aesRoundInv(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
            return rounds(D, "aesdec", state, round_key);
        }

        pub fn aesLastRoundInv(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
            return rounds(D, "aesdeclast", state, round_key);
        }

        pub fn aesInvMixColumns(comptime D: type, state: D.Vector) D.Vector {
            if (comptime registerBytes(D) > block.block_bytes) {
                return block.invMixColumnsByRounds(D, Self, state);
            }
            return block.mapUnary(
                D,
                block.block_bytes,
                InverseMixColumns(form.encoding).apply,
                state,
            );
        }

        pub fn aesKeyGenAssist(comptime D: type, comptime rcon: u8, value: D.Vector) D.Vector {
            if (comptime registerBytes(D) > block.block_bytes) {
                return block.keyGenAssistByLastRound(D, rcon, Self, value);
            }
            return block.mapUnary(
                D,
                block.block_bytes,
                KeyGenAssist(form.encoding, rcon).apply,
                value,
            );
        }

        fn registerBytes(comptime D: type) usize {
            block.validate(D, u8);
            return form.registerBytes(D);
        }

        fn rounds(
            comptime D: type,
            comptime mnemonic: []const u8,
            state: D.Vector,
            round_key: D.Vector,
        ) D.Vector {
            const Instruction = Round(form.encoding, mnemonic, registerBytes(D));
            return block.mapBinary(D, Instruction.bytes, Instruction.apply, state, round_key);
        }
    };
}

/// Carryless multiplication as `with` issues it, over registers of up to its
/// widest bytes. A wider vector splits into registers of that width.
pub fn ClMul(comptime with: Lowering) type {
    const form = comptime Form.of(with);
    return struct {
        pub fn clMulLower(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
            return products(D, 0x00, a, b);
        }

        pub fn clMulUpper(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
            return products(D, 0x11, a, b);
        }

        fn products(
            comptime D: type,
            comptime immediate: u8,
            a: D.Vector,
            b: D.Vector,
        ) D.Vector {
            block.validate(D, u64);
            const Instruction = Product(form.encoding, immediate, form.registerBytes(D));
            return block.mapBinary(D, Instruction.bytes, Instruction.apply, a, b);
        }
    };
}

/// One round instruction, `mnemonic`, over a register of `register_bytes`.
fn Round(
    comptime encoding: Encoding,
    comptime mnemonic: []const u8,
    comptime register_bytes: usize,
) type {
    const Register = @Vector(register_bytes, u8);
    return struct {
        const bytes = register_bytes;

        fn apply(state: Register, round_key: Register) Register {
            return switch (encoding) {
                .legacy => asm (mnemonic ++ " %[round_key], %[result]"
                    : [result] "=x" (-> Register),
                    : [_] "0" (state),
                      [round_key] "x" (round_key),
                ),
                .vex => asm ("v" ++ mnemonic ++ " %[round_key], %[state], %[result]"
                    : [result] "=x" (-> Register),
                    : [state] "x" (state),
                      [round_key] "x" (round_key),
                ),
            };
        }
    };
}

/// AESIMC over one block.
fn InverseMixColumns(comptime encoding: Encoding) type {
    const prefix = if (encoding == .vex) "v" else "";
    return struct {
        fn apply(state: Block) Block {
            return asm (prefix ++ "aesimc %[state], %[result]"
                : [result] "=x" (-> Block),
                : [state] "x" (state),
            );
        }
    };
}

/// AESKEYGENASSIST with the immediate `rcon` over one block.
fn KeyGenAssist(comptime encoding: Encoding, comptime rcon: u8) type {
    const prefix = if (encoding == .vex) "v" else "";
    return struct {
        fn apply(value: Block) Block {
            return asm (prefix ++ "aeskeygenassist %[rcon], %[value], %[result]"
                : [result] "=x" (-> Block),
                : [value] "x" (value),
                  [rcon] "n" (rcon),
            );
        }
    };
}

/// PCLMULQDQ with `immediate` over a register of `register_bytes`. The
/// immediates this lowering issues select the same lane of both operands,
/// so the order of the source operands does not change the product.
fn Product(
    comptime encoding: Encoding,
    comptime immediate: u8,
    comptime register_bytes: usize,
) type {
    const Register = @Vector(register_bytes / @sizeOf(u64), u64);
    return struct {
        const bytes = register_bytes;

        fn apply(a: Register, b: Register) Register {
            return switch (encoding) {
                .legacy => asm ("pclmulqdq %[immediate], %[b], %[result]"
                    : [result] "=x" (-> Register),
                    : [_] "0" (a),
                      [b] "x" (b),
                      [immediate] "n" (immediate),
                ),
                .vex => asm ("vpclmulqdq %[immediate], %[b], %[a], %[result]"
                    : [result] "=x" (-> Register),
                    : [a] "x" (a),
                      [b] "x" (b),
                      [immediate] "n" (immediate),
                ),
            };
        }
    };
}
