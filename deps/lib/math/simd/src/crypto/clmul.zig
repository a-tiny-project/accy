//! Carryless multiplication with the semantics of Highway's CLMulLower and
//! CLMulUpper, lowered per compile target.
//!
//! Each 128-bit block of the operands holds two u64 lanes. CLMulLower reads
//! the lower lane of a block of each operand as a polynomial over GF(2), one
//! coefficient per bit, and returns their 128-bit product in that block, low
//! half in the lower lane. Partial products combine by exclusive-or, so no
//! carry crosses a bit. CLMulUpper does the same with the upper lanes. These
//! are PCLMULQDQ with the immediates 0x00 and 0x11, VPCLMULQDQ on wider
//! registers, and Arm PMULL and PMULL2. `lowering.zig` fixes the lowering at
//! compile time from the target's carryless-multiplication features. Every
//! lowering takes the same time for every input.

const std = @import("std");
const builtin = @import("builtin");
const arm = @import("arm.zig");
const portable = @import("portable.zig");
const x86 = @import("x86.zig");
const Lowering = @import("lowering.zig").Lowering;
const loweringFor = @import("lowering.zig").loweringFor;

/// The lowering of this build.
pub const lowering: Lowering = loweringFor(.clmul, builtin.cpu, builtin.zig_backend);

/// Carryless multiplication as `with` issues it. This build's lowering must
/// cover `with`, so no build issues an instruction its CPU features do not
/// promise.
pub fn Lowered(comptime with: Lowering) type {
    if (!lowering.covers(with)) {
        @compileError("this build's " ++ @tagName(lowering) ++
            " carryless multiplication lowering does not cover " ++ @tagName(with));
    }
    return switch (with) {
        .portable => portable,
        .sse, .vex128, .vex256, .evex512 => x86.ClMul(with),
        .arm => arm,
    };
}

/// The carryless product of the lower u64 lanes of each 128-bit block.
pub fn clMulLower(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    if (@inComptime()) return portable.clMulLower(D, a, b);
    return Lowered(lowering).clMulLower(D, a, b);
}

/// The carryless product of the upper u64 lanes of each 128-bit block.
pub fn clMulUpper(comptime D: type, a: D.Vector, b: D.Vector) D.Vector {
    if (@inComptime()) return portable.clMulUpper(D, a, b);
    return Lowered(lowering).clMulUpper(D, a, b);
}
