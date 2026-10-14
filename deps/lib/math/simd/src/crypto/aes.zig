//! AES rounds with the semantics of x86 AES-NI, lowered per compile target.
//!
//! Highway gives its AES operations the semantics of the x86 instructions:
//! AESRound is AESENC, AESLastRound is AESENCLAST, AESRoundInv is AESDEC,
//! AESLastRoundInv is AESDECLAST, AESInvMixColumns is AESIMC and
//! AESKeyGenAssist is AESKEYGENASSIST, each applied to every 16-byte block of
//! a vector of u8 lanes. `lowering.zig` fixes the lowering at compile time
//! from the target's AES features. Every lowering takes the same time for
//! every input.

const builtin = @import("builtin");
const arm = @import("arm.zig");
const portable = @import("portable.zig");
const x86 = @import("x86.zig");
const Lowering = @import("lowering.zig").Lowering;
const loweringFor = @import("lowering.zig").loweringFor;

/// The lowering of this build.
pub const lowering: Lowering = loweringFor(.aes, builtin.cpu, builtin.zig_backend);

/// The AES operations as `with` issues them. This build's lowering must
/// cover `with`, so no build issues an instruction its CPU features do not
/// promise.
pub fn Lowered(comptime with: Lowering) type {
    if (!lowering.covers(with)) {
        @compileError("this build's " ++ @tagName(lowering) ++
            " AES lowering does not cover " ++ @tagName(with));
    }
    return switch (with) {
        .portable => portable,
        .sse, .vex128, .vex256, .evex512 => x86.Aes(with),
        .arm => arm,
    };
}

/// AESENC on every block: ShiftRows, SubBytes and MixColumns, then the round
/// key added.
pub fn aesRound(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    if (@inComptime()) return portable.aesRound(D, state, round_key);
    return Lowered(lowering).aesRound(D, state, round_key);
}

/// AESENCLAST on every block: ShiftRows and SubBytes, then the round key
/// added.
pub fn aesLastRound(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    if (@inComptime()) return portable.aesLastRound(D, state, round_key);
    return Lowered(lowering).aesLastRound(D, state, round_key);
}

/// AESDEC on every block: InvShiftRows, InvSubBytes and InvMixColumns, then
/// the round key added.
pub fn aesRoundInv(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    if (@inComptime()) return portable.aesRoundInv(D, state, round_key);
    return Lowered(lowering).aesRoundInv(D, state, round_key);
}

/// AESDECLAST on every block: InvShiftRows and InvSubBytes, then the round
/// key added.
pub fn aesLastRoundInv(comptime D: type, state: D.Vector, round_key: D.Vector) D.Vector {
    if (@inComptime()) return portable.aesLastRoundInv(D, state, round_key);
    return Lowered(lowering).aesLastRoundInv(D, state, round_key);
}

/// AESIMC on every block: InvMixColumns alone.
pub fn aesInvMixColumns(comptime D: type, state: D.Vector) D.Vector {
    if (@inComptime()) return portable.aesInvMixColumns(D, state);
    return Lowered(lowering).aesInvMixColumns(D, state);
}

/// AESKEYGENASSIST on every block: SubWord of words 1 and 3, each followed by
/// its rotation with `rcon` added to the rotated word's low byte.
pub fn aesKeyGenAssist(comptime D: type, comptime rcon: u8, value: D.Vector) D.Vector {
    if (@inComptime()) return portable.aesKeyGenAssist(D, rcon, value);
    return Lowered(lowering).aesKeyGenAssist(D, rcon, value);
}
