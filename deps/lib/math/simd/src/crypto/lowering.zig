//! How each family of crypto instructions reaches the hardware.
//!
//! The AES operations and carryless multiplication climb the same ladder of
//! instruction forms. Each has a 16-byte x86 instruction in the SSE encoding
//! and again in the VEX encoding, 32- and 64-byte forms behind a feature of
//! its own (VAES or VPCLMULQDQ), and a 16-byte Arm instruction. A family's
//! lowering is the widest form the target's CPU features promise. It is fixed
//! at compile time, the static model by which `target.zig` picks a Highway
//! target, so `-Dcpu` selects it and nothing dispatches at run time. Each
//! family selects on its own features, so a CPU that has one family and lacks
//! the other lowers only the first. Targets without a family's instructions,
//! the C backend, and comptime evaluation, which cannot run inline assembly,
//! use the portable lowering.

const std = @import("std");

/// A family of instructions that one set of CPU features promises.
pub const Family = enum {
    /// AESENC and its kin, widened by VAES, and Arm AESE, AESD, AESMC and
    /// AESIMC.
    aes,
    /// PCLMULQDQ, widened by VPCLMULQDQ, and Arm PMULL and PMULL2.
    clmul,

    /// The x86 feature of the family's 16-byte instructions.
    fn x86Feature(family: Family) std.Target.x86.Feature {
        return switch (family) {
            .aes => .aes,
            .clmul => .pclmul,
        };
    }

    /// The x86 feature of the family's 32- and 64-byte instructions. In the
    /// compiler's feature model it implies the 16-byte feature and AVX.
    fn x86WideFeature(family: Family) std.Target.x86.Feature {
        return switch (family) {
            .aes => .vaes,
            .clmul => .vpclmulqdq,
        };
    }

    /// The aarch64 feature of the family's instructions. The compiler's
    /// assembler accepts the 64-bit PMULL forms only with `aes`, which models
    /// FEAT_AES together with FEAT_PMULL.
    fn aarch64Feature(family: Family) std.Target.aarch64.Feature {
        return switch (family) {
            .aes, .clmul => .aes,
        };
    }
};

/// How a family's operations reach the hardware.
pub const Lowering = enum {
    /// Software without the family's instructions.
    portable,
    /// x86 SSE encoding, one 16-byte register per instruction.
    sse,
    /// x86 VEX encoding, one 16-byte register per instruction.
    vex128,
    /// x86 VEX encoding on 32-byte registers, through VAES or VPCLMULQDQ.
    vex256,
    /// x86 EVEX encoding on 64-byte registers, through VAES or VPCLMULQDQ
    /// with AVX-512.
    evex512,
    /// Arm instructions, one 16-byte register per instruction.
    arm,

    /// Whether a build whose target selects `self` for a family may also
    /// issue `other` for it. Each x86 lowering needs a subset of the CPU
    /// features of the next one: the wide feature implies the 16-byte
    /// feature and AVX, and AVX-512 adds the 64-byte registers.
    pub fn covers(self: Lowering, other: Lowering) bool {
        if (other == .portable or other == self) return true;
        return x86Rank(other) > 0 and x86Rank(other) < x86Rank(self);
    }

    /// The bytes of the widest register `self` issues one instruction on.
    /// The portable lowering works one 16-byte block at a time, as the
    /// 16-byte instruction forms do.
    pub fn widestBytes(self: Lowering) usize {
        const bytes: usize = switch (self) {
            .portable, .sse, .vex128, .arm => 16,
            .vex256 => 32,
            .evex512 => 64,
        };
        std.debug.assert(std.math.isPowerOfTwo(bytes));
        std.debug.assert(bytes >= 16);
        return bytes;
    }

    fn x86Rank(self: Lowering) u8 {
        return switch (self) {
            .portable, .arm => 0,
            .sse => 1,
            .vex128 => 2,
            .vex256 => 3,
            .evex512 => 4,
        };
    }

    /// Asserts that `cpu` has every feature the instructions of `self` need
    /// for `family`.
    fn assertIssuable(self: Lowering, family: Family, cpu: std.Target.Cpu) void {
        if (self == .portable) return;
        if (self == .arm) {
            std.debug.assert(cpu.arch == .aarch64);
            std.debug.assert(cpu.has(.aarch64, family.aarch64Feature()));
            return;
        }
        std.debug.assert(cpu.arch.isX86());
        std.debug.assert(cpu.has(.x86, family.x86Feature()));
        if (self.covers(.vex128)) std.debug.assert(cpu.has(.x86, .avx));
        if (self.covers(.vex256)) std.debug.assert(cpu.has(.x86, family.x86WideFeature()));
        if (self.covers(.evex512)) std.debug.assert(cpu.has(.x86, .avx512f));
    }
};

/// The lowering a build for `cpu` through `backend` selects for `family`: the
/// widest instructions of the family the CPU features promise, or the
/// portable lowering.
pub fn loweringFor(
    family: Family,
    cpu: std.Target.Cpu,
    backend: std.builtin.CompilerBackend,
) Lowering {
    // The C backend cannot pass vectors to inline assembly.
    if (backend == .stage2_c) return .portable;
    const selected: Lowering = switch (cpu.arch) {
        .x86, .x86_64 => if (!cpu.has(.x86, family.x86Feature()))
            .portable
        else if (!cpu.has(.x86, .avx))
            .sse
        else if (!cpu.has(.x86, family.x86WideFeature()))
            .vex128
            // The self-hosted x86_64 backend cannot hold 64-byte vectors in ZMM
            // registers.
        else if (cpu.has(.x86, .avx512f) and backend != .stage2_x86_64)
            .evex512
        else
            .vex256,
        // Big-endian aarch64 keeps the portable lowering, as std.crypto does.
        .aarch64 => if (cpu.has(.aarch64, family.aarch64Feature())) .arm else .portable,
        else => .portable,
    };
    selected.assertIssuable(family, cpu);
    return selected;
}

/// A CPU, the compiler backend, and the lowering each family selects for
/// that build.
const LoweringCase = struct {
    cpu: std.Target.Cpu,
    backend: std.builtin.CompilerBackend = .stage2_llvm,
    aes: Lowering,
    clmul: Lowering,
};

test "each family's lowering follows its own x86 features, AVX and AVX-512" {
    const x86_cpus = std.Target.x86.cpu;
    const cases = [_]LoweringCase{
        .{ .cpu = x86_cpus.x86_64.toCpu(.x86_64), .aes = .portable, .clmul = .portable },
        .{ .cpu = x86_cpus.x86_64_v4.toCpu(.x86_64), .aes = .portable, .clmul = .portable },
        .{ .cpu = x86_cpus.goldmont.toCpu(.x86_64), .aes = .sse, .clmul = .sse },
        .{ .cpu = x86_cpus.goldmont.toCpu(.x86), .aes = .sse, .clmul = .sse },
        .{ .cpu = x86_cpus.cascadelake.toCpu(.x86_64), .aes = .vex128, .clmul = .vex128 },
        .{ .cpu = x86_cpus.alderlake.toCpu(.x86_64), .aes = .vex256, .clmul = .vex256 },
        .{ .cpu = x86_cpus.znver3.toCpu(.x86_64), .aes = .vex256, .clmul = .vex256 },
        .{ .cpu = x86_cpus.znver4.toCpu(.x86_64), .aes = .evex512, .clmul = .evex512 },
        .{ .cpu = x86_cpus.znver4.toCpu(.x86), .aes = .evex512, .clmul = .evex512 },
        .{
            .cpu = x86_cpus.znver4.toCpu(.x86_64),
            .backend = .stage2_x86_64,
            .aes = .vex256,
            .clmul = .vex256,
        },
        .{
            .cpu = x86_cpus.znver4.toCpu(.x86_64),
            .backend = .stage2_c,
            .aes = .portable,
            .clmul = .portable,
        },
        // One family's features without the other's. The compiler's westmere
        // model has PCLMULQDQ and lacks AES-NI, as some Westmere parts do.
        .{ .cpu = x86_cpus.westmere.toCpu(.x86_64), .aes = .portable, .clmul = .sse },
        .{
            .cpu = withX86Features(&x86_cpus.x86_64, &.{.aes}),
            .aes = .sse,
            .clmul = .portable,
        },
        .{
            .cpu = withX86Features(&x86_cpus.x86_64_v3, &.{.pclmul}),
            .aes = .portable,
            .clmul = .vex128,
        },
        .{
            .cpu = withX86Features(&x86_cpus.cascadelake, &.{.vpclmulqdq}),
            .aes = .vex128,
            .clmul = .evex512,
        },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.aes, loweringFor(.aes, case.cpu, case.backend));
        try std.testing.expectEqual(case.clmul, loweringFor(.clmul, case.cpu, case.backend));
    }
}

test "both families lower to Arm on little-endian aarch64 with AES and nowhere else" {
    const arm_cpus = std.Target.aarch64.cpu;
    const cases = [_]LoweringCase{
        .{ .cpu = arm_cpus.apple_m1.toCpu(.aarch64), .aes = .arm, .clmul = .arm },
        .{ .cpu = arm_cpus.apple_m1.toCpu(.aarch64_be), .aes = .portable, .clmul = .portable },
        .{ .cpu = arm_cpus.generic.toCpu(.aarch64), .aes = .portable, .clmul = .portable },
        .{
            .cpu = arm_cpus.apple_m1.toCpu(.aarch64),
            .backend = .stage2_c,
            .aes = .portable,
            .clmul = .portable,
        },
        .{
            .cpu = std.Target.wasm.cpu.bleeding_edge.toCpu(.wasm32),
            .aes = .portable,
            .clmul = .portable,
        },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.aes, loweringFor(.aes, case.cpu, case.backend));
        try std.testing.expectEqual(case.clmul, loweringFor(.clmul, case.cpu, case.backend));
    }
}

test "x86 lowerings nest and the Arm lowering covers only itself" {
    for (std.meta.tags(Lowering)) |each| {
        try std.testing.expect(each.covers(.portable));
        try std.testing.expect(each.covers(each));
    }
    try std.testing.expect(Lowering.evex512.covers(.vex256));
    try std.testing.expect(Lowering.evex512.covers(.sse));
    try std.testing.expect(Lowering.vex128.covers(.sse));
    try std.testing.expect(!Lowering.vex128.covers(.vex256));
    try std.testing.expect(!Lowering.vex256.covers(.evex512));
    try std.testing.expect(!Lowering.portable.covers(.sse));
    try std.testing.expect(!Lowering.arm.covers(.sse));
    try std.testing.expect(!Lowering.evex512.covers(.arm));
}

test "a lowering never issues a register narrower than one it covers" {
    for (std.meta.tags(Lowering)) |self| {
        try std.testing.expect(std.math.isPowerOfTwo(self.widestBytes()));
        try std.testing.expect(self.widestBytes() >= 16);
        for (std.meta.tags(Lowering)) |other| {
            if (self.covers(other)) {
                try std.testing.expect(self.widestBytes() >= other.widestBytes());
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 64), Lowering.evex512.widestBytes());
}

/// `model` built for x86_64 with `added` features and everything they imply.
fn withX86Features(
    model: *const std.Target.Cpu.Model,
    added: []const std.Target.x86.Feature,
) std.Target.Cpu {
    var cpu = model.toCpu(.x86_64);
    for (added) |feature| cpu.features.addFeature(@backingInt(feature));
    cpu.features.populateDependencies(cpu.arch.allFeaturesList());
    return cpu;
}
