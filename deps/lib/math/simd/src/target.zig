const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys");

pub const Mask = u64;
pub const target_count: usize = 28;

pub const Target = enum(u6) {
    avx10_2 = 3,
    avx3_spr = 4,
    avx3_zen4 = 6,
    avx3_dl = 7,
    avx3 = 8,
    avx2 = 9,
    sse4 = 11,
    ssse3 = 12,
    sse2 = 14,
    sve2_128 = 18,
    sve_256 = 19,
    sve2 = 23,
    sve = 24,
    neon_bf16 = 26,
    neon = 28,
    neon_without_aes = 29,
    rvv = 37,
    lasx = 40,
    lsx = 41,
    ppc10 = 47,
    ppc9 = 48,
    ppc8 = 49,
    z15 = 50,
    z14 = 51,
    wasm_emu256 = 58,
    wasm = 59,
    emu128 = 61,
    scalar = 62,

    pub fn bit(self: Target) Mask {
        return @as(Mask, 1) << @backingInt(self);
    }

    pub fn name(self: Target) []const u8 {
        return switch (self) {
            .avx10_2 => "AVX10_2",
            .avx3_spr => "AVX3_SPR",
            .avx3_zen4 => "AVX3_ZEN4",
            .avx3_dl => "AVX3_DL",
            .avx3 => "AVX3",
            .avx2 => "AVX2",
            .sse4 => "SSE4",
            .ssse3 => "SSSE3",
            .sse2 => "SSE2",
            .sve2_128 => "SVE2_128",
            .sve_256 => "SVE_256",
            .sve2 => "SVE2",
            .sve => "SVE",
            .neon_bf16 => "NEON_BF16",
            .neon => "NEON",
            .neon_without_aes => "NEON_WITHOUT_AES",
            .rvv => "RVV",
            .lasx => "LASX",
            .lsx => "LSX",
            .ppc10 => "PPC10",
            .ppc9 => "PPC9",
            .ppc8 => "PPC8",
            .z15 => "Z15",
            .z14 => "Z14",
            .wasm_emu256 => "WASM_EMU256",
            .wasm => "WASM",
            .emu128 => "EMU128",
            .scalar => "SCALAR",
        };
    }
};

pub const catalog = [_]Target{
    .avx10_2,
    .avx3_spr,
    .avx3_zen4,
    .avx3_dl,
    .avx3,
    .avx2,
    .sse4,
    .ssse3,
    .sse2,
    .sve2_128,
    .sve_256,
    .sve2,
    .sve,
    .neon_bf16,
    .neon,
    .neon_without_aes,
    .rvv,
    .lasx,
    .lsx,
    .ppc10,
    .ppc9,
    .ppc8,
    .z15,
    .z14,
    .wasm_emu256,
    .wasm,
    .emu128,
    .scalar,
};

pub const x86_targets = maskOf(&.{
    Target.avx10_2,
    .avx3_spr,
    .avx3_zen4,
    .avx3_dl,
    .avx3,
    .avx2,
    .sse4,
    .ssse3,
    .sse2,
});
pub const arm_targets = maskOf(&.{
    Target.sve2_128,
    .sve_256,
    .sve2,
    .sve,
    .neon_bf16,
    .neon,
    .neon_without_aes,
});
pub const riscv_targets = Target.rvv.bit();
pub const loongarch_targets = Target.lasx.bit() | Target.lsx.bit();
pub const power_targets = maskOf(&.{ Target.ppc10, .ppc9, .ppc8 });
pub const s390_targets = maskOf(&.{ Target.z15, .z14 });
pub const wasm_targets = Target.wasm_emu256.bit() | Target.wasm.bit();
pub const fallback_targets = Target.emu128.bit() | Target.scalar.bit();
pub const all_targets = maskOf(&catalog);

pub const Capabilities = struct {
    integer64: bool,
    float16: bool,
    float64: bool,
};

pub const X86Leaf = packed struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub const X86Snapshot = struct {
    leaf0: X86Leaf,
    leaf1: X86Leaf,
    leaf7_0: X86Leaf,
    leaf7_1: X86Leaf,
    leaf24: X86Leaf,
    extended0: X86Leaf,
    extended1: X86Leaf,
    xcr0: u32,
    avx3_os_support: ?bool = null,
};

const AtomicMask64 = struct {
    value: std.atomic.Value(Mask),

    fn init(value: Mask) @This() {
        return .{ .value = std.atomic.Value(Mask).init(value) };
    }

    fn load(self: *@This()) Mask {
        return self.value.load(.acquire);
    }

    fn store(self: *@This(), value: Mask) void {
        self.value.store(value, .release);
    }
};

const AtomicMask32 = struct {
    guard: std.atomic.Value(u32),
    low: u32,
    high: u32,

    fn init(value: Mask) @This() {
        return .{
            .guard = std.atomic.Value(u32).init(0),
            .low = @truncate(value),
            .high = @truncate(value >> 32),
        };
    }

    fn load(self: *@This()) Mask {
        self.acquire();
        defer self.release();
        return @as(Mask, self.high) << 32 | self.low;
    }

    fn store(self: *@This(), value: Mask) void {
        self.acquire();
        defer self.release();
        self.low = @truncate(value);
        self.high = @truncate(value >> 32);
    }

    fn acquire(self: *@This()) void {
        while (self.guard.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *@This()) void {
        self.guard.store(0, .release);
    }
};

const AtomicMask = if (@bitSizeOf(usize) >= 64) AtomicMask64 else AtomicMask32;

pub const ChosenTarget = struct {
    supported: AtomicMask = AtomicMask.init(0),

    pub fn update(self: *ChosenTarget, targets: Mask) void {
        std.debug.assert(targets != 0);
        self.supported.store(targets);
    }

    pub fn deinit(self: *ChosenTarget) void {
        self.supported.store(0);
    }

    pub fn isInitialized(self: *ChosenTarget) bool {
        return self.supported.load() != 0;
    }

    pub fn load(self: *ChosenTarget) Mask {
        return self.supported.load();
    }
};

pub const Runtime = struct {
    static: Target,
    dispatch_fallback: Target,
    disabled: AtomicMask = AtomicMask.init(0),
    mocked: AtomicMask = AtomicMask.init(0),
    chosen: ChosenTarget = .{},

    pub fn init(static: Target) Runtime {
        return .{ .static = static, .dispatch_fallback = .emu128 };
    }

    pub fn disableTargets(self: *Runtime, disabled: Mask) void {
        self.disabled.store(disabled);
        self.chosen.deinit();
    }

    pub fn setSupportedTargetsForTest(self: *Runtime, targets: Mask) void {
        self.mocked.store(targets);
        self.chosen.deinit();
    }

    pub fn supportedTargets(self: *Runtime, detected: Mask) Mask {
        var targets = self.mocked.load();
        if (targets == 0) targets = detected;
        targets &= ~self.disabled.load();
        return if (targets == 0) self.static.bit() else targets;
    }

    pub fn dispatchedTarget(
        self: *Runtime,
        detected: Mask,
        generated: Mask,
    ) Target {
        if (self.cachedDispatchedTarget(generated)) |target| return target;
        const supported = self.supportedTargets(detected);
        self.chosen.update(supported);
        return self.selectSupported(supported, generated);
    }

    fn cachedDispatchedTarget(self: *Runtime, generated: Mask) ?Target {
        const supported = self.chosen.load();
        return if (supported == 0) null else self.selectSupported(supported, generated);
    }

    fn selectSupported(self: *Runtime, supported: Mask, generated: Mask) Target {
        return bestTarget(supported & generated) orelse self.dispatch_fallback;
    }
};

pub fn Function(comptime Fn: type) type {
    switch (@typeInfo(Fn)) {
        .pointer => |pointer| if (@typeInfo(pointer.child) != .@"fn") {
            @compileError("target functions require a function pointer type");
        },
        else => @compileError("target functions require a function pointer type"),
    }
    return struct {
        target: Target,
        implementation: Fn,
    };
}

pub fn selectFunction(
    runtime: *Runtime,
    detected: Mask,
    entries: anytype,
    fallback: anytype,
) @TypeOf(fallback) {
    const Fn = @TypeOf(fallback);
    const Entry = Function(Fn);
    const slice: []const Entry = entries;
    std.debug.assert(slice.len <= target_count);
    var generated: Mask = 0;
    for (slice) |entry| generated |= entry.target.bit();
    const selected = runtime.dispatchedTarget(detected, generated);
    for (slice) |entry| if (entry.target == selected) return entry.implementation;
    return fallback;
}

pub fn maskOf(targets: []const Target) Mask {
    var mask: Mask = 0;
    for (targets) |target| mask |= target.bit();
    return mask;
}

pub fn targetFromBit(bit: Mask) ?Target {
    if (@popCount(bit) != 1) return null;
    for (catalog) |target| if (target.bit() == bit) return target;
    return null;
}

pub fn bestTarget(mask: Mask) ?Target {
    if (mask == 0) return null;
    return targetFromBit(mask & (~mask +% 1));
}

pub fn targetName(bit: Mask) []const u8 {
    return if (targetFromBit(bit)) |target| target.name() else "Unknown";
}

pub fn architectureTargets(arch: std.Target.Cpu.Arch) Mask {
    return switch (arch) {
        .x86, .x86_64 => x86_targets,
        .arm, .armeb, .thumb, .thumbeb, .aarch64, .aarch64_be => arm_targets,
        .riscv32, .riscv32be, .riscv64, .riscv64be => riscv_targets,
        .loongarch32, .loongarch64 => loongarch_targets,
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => power_targets,
        .s390x => s390_targets,
        .wasm32, .wasm64 => wasm_targets,
        else => 0,
    };
}

pub fn attainableTargets(arch: std.Target.Cpu.Arch) Mask {
    return architectureTargets(arch) | Target.emu128.bit();
}

pub const static_target: Target = compileStaticTarget();
pub const generated_targets: Mask = defaultGeneratedTargets(builtin.target.cpu.arch, static_target);
pub const per_target_targets: Mask = attainableTargets(builtin.target.cpu.arch);

pub fn defaultGeneratedTargets(arch: std.Target.Cpu.Arch, static: Target) Mask {
    const limit = static.bit() | (static.bit() - 1);
    return attainableTargets(arch) & limit;
}

pub fn capabilitiesFor(target: Target, arch: std.Target.Cpu.Arch) Capabilities {
    const float16 = switch (target) {
        .avx10_2, .avx3_spr, .sve2_128, .sve_256, .sve2, .sve, .neon_bf16 => true,
        else => false,
    };
    const float64 = switch (target) {
        .neon, .neon_bf16, .neon_without_aes => switch (arch) {
            .aarch64, .aarch64_be => true,
            else => false,
        },
        else => true,
    };
    return .{ .integer64 = true, .float16 = float16, .float64 = float64 };
}

pub fn vectorBytesFor(target: Target, scalable_bytes: usize) usize {
    return switch (target) {
        .avx10_2, .avx3_spr, .avx3_zen4, .avx3_dl, .avx3 => 64,
        .avx2, .sve_256, .lasx, .wasm_emu256 => 32,
        .sse4,
        .ssse3,
        .sse2,
        .sve2_128,
        .neon_bf16,
        .neon,
        .neon_without_aes,
        .lsx,
        .ppc10,
        .ppc9,
        .ppc8,
        .z15,
        .z14,
        .wasm,
        .emu128,
        => 16,
        .sve2, .sve, .rvv => blk: {
            std.debug.assert(scalable_bytes >= 16);
            std.debug.assert(scalable_bytes <= 65_536);
            break :blk scalable_bytes;
        },
        .scalar => 1,
    };
}

var global_runtime = Runtime.init(static_target);

pub fn disableTargets(disabled: Mask) void {
    global_runtime.disableTargets(disabled);
}

pub fn setSupportedTargetsForTest(targets: Mask) void {
    global_runtime.setSupportedTargetsForTest(targets);
}

pub fn supportedTargets() Mask {
    return global_runtime.supportedTargets(detectTargets());
}

pub fn dispatchedTarget() Target {
    return global_runtime.cachedDispatchedTarget(per_target_targets) orelse
        global_runtime.dispatchedTarget(detectTargets(), per_target_targets);
}

pub fn vectorBytes() usize {
    const target = dispatchedTarget();
    return vectorBytesFor(target, scalableVectorBytes(target));
}

pub fn haveInteger64() bool {
    return capabilitiesFor(dispatchedTarget(), builtin.target.cpu.arch).integer64;
}

pub fn haveFloat16() bool {
    const selected = dispatchedTarget();
    return capabilitiesFor(selected, builtin.target.cpu.arch).float16 or
        compileOptionalFloat16(selected);
}

pub fn haveFloat64() bool {
    return capabilitiesFor(dispatchedTarget(), builtin.target.cpu.arch).float64;
}

pub fn supportedAndGeneratedTargets(output: *[target_count]Target) []const Target {
    var remaining = supportedTargets() & generated_targets;
    var count: usize = 0;
    while (remaining != 0) {
        const target = bestTarget(remaining).?;
        output[count] = target;
        count += 1;
        remaining &= remaining - 1;
    }
    return output[0..count];
}

pub fn detectTargets() Mask {
    var targets = fallback_targets;
    targets |= switch (builtin.target.cpu.arch) {
        .x86, .x86_64 => detectX86(captureX86(), builtin.target.cpu.arch == .x86_64),
        .arm, .armeb, .thumb, .thumbeb, .aarch64, .aarch64_be => detectArm(),
        .riscv32, .riscv32be, .riscv64, .riscv64be => detectRiscV(),
        .loongarch32, .loongarch64 => detectLoongArch(),
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => detectPower(),
        .s390x => detectS390x(),
        .wasm32, .wasm64 => compileArchitectureTargets(),
        else => compileArchitectureTargets(),
    };
    return targets;
}

const X86Feature = enum(u5) {
    sse,
    sse2,
    sse3,
    ssse3,
    sse41,
    sse42,
    clmul,
    aes,
    avx,
    avx2,
    f16c,
    fma,
    lzcnt,
    bmi,
    bmi2,
    avx512f,
    avx512vl,
    avx512cd,
    avx512dq,
    avx512bw,
    avx512fp16,
    avx512bf16,
    vnni,
    vpclmulqdq,
    vbmi,
    vbmi2,
    vaes,
    popcntdq,
    bitalg,
    gfni,
    avx10,
    apx,
};

fn x86FeatureBit(feature: X86Feature) u64 {
    return @as(u64, 1) << @backingInt(feature);
}

fn x86Has(flags: u64, group: u64) bool {
    return flags & group == group;
}

const X86Groups = struct {
    const sse2 = x86FeatureBit(.sse) | x86FeatureBit(.sse2);
    const ssse3 = x86FeatureBit(.sse3) | x86FeatureBit(.ssse3) | sse2;
    const sse4 = x86FeatureBit(.sse41) | x86FeatureBit(.sse42) |
        x86FeatureBit(.clmul) | x86FeatureBit(.aes) | ssse3;
    const avx2 = x86FeatureBit(.avx) | x86FeatureBit(.avx2) |
        x86FeatureBit(.lzcnt) | x86FeatureBit(.bmi) | x86FeatureBit(.bmi2) |
        x86FeatureBit(.fma) | x86FeatureBit(.f16c) | sse4;
    const avx3 = x86FeatureBit(.avx512f) | x86FeatureBit(.avx512vl) |
        x86FeatureBit(.avx512dq) | x86FeatureBit(.avx512bw) |
        x86FeatureBit(.avx512cd) | avx2;
    const avx3_dl = x86FeatureBit(.vnni) | x86FeatureBit(.vpclmulqdq) |
        x86FeatureBit(.vbmi) | x86FeatureBit(.vbmi2) | x86FeatureBit(.vaes) |
        x86FeatureBit(.popcntdq) | x86FeatureBit(.bitalg) |
        x86FeatureBit(.gfni) | avx3;
    const zen4 = x86FeatureBit(.avx512bf16) | avx3_dl;
    const spr = x86FeatureBit(.avx512fp16) | zen4;
    const avx10 = x86FeatureBit(.avx10) | x86FeatureBit(.apx) |
        x86FeatureBit(.vpclmulqdq) | x86FeatureBit(.vaes) |
        x86FeatureBit(.gfni) | avx2;
};

fn x86Flags(snapshot: X86Snapshot) u64 {
    var flags: u64 = 0;
    const one = snapshot.leaf1;
    flags |= if (bitSet(one.edx, 25)) x86FeatureBit(.sse) else 0;
    flags |= if (bitSet(one.edx, 26)) x86FeatureBit(.sse2) else 0;
    flags |= if (bitSet(one.ecx, 0)) x86FeatureBit(.sse3) else 0;
    flags |= if (bitSet(one.ecx, 1)) x86FeatureBit(.clmul) else 0;
    flags |= if (bitSet(one.ecx, 9)) x86FeatureBit(.ssse3) else 0;
    flags |= if (bitSet(one.ecx, 12)) x86FeatureBit(.fma) else 0;
    flags |= if (bitSet(one.ecx, 19)) x86FeatureBit(.sse41) else 0;
    flags |= if (bitSet(one.ecx, 20)) x86FeatureBit(.sse42) else 0;
    flags |= if (bitSet(one.ecx, 25)) x86FeatureBit(.aes) else 0;
    flags |= if (bitSet(one.ecx, 28)) x86FeatureBit(.avx) else 0;
    flags |= if (bitSet(one.ecx, 29)) x86FeatureBit(.f16c) else 0;
    flags |= if (bitSet(snapshot.extended1.ecx, 5)) x86FeatureBit(.lzcnt) else 0;

    if (snapshot.leaf0.eax >= 7) {
        const seven = snapshot.leaf7_0;
        flags |= if (bitSet(seven.ebx, 3)) x86FeatureBit(.bmi) else 0;
        flags |= if (bitSet(seven.ebx, 5)) x86FeatureBit(.avx2) else 0;
        flags |= if (bitSet(seven.ebx, 8)) x86FeatureBit(.bmi2) else 0;
        flags |= if (bitSet(seven.ebx, 16)) x86FeatureBit(.avx512f) else 0;
        flags |= if (bitSet(seven.ebx, 17)) x86FeatureBit(.avx512dq) else 0;
        flags |= if (bitSet(seven.ebx, 28)) x86FeatureBit(.avx512cd) else 0;
        flags |= if (bitSet(seven.ebx, 30)) x86FeatureBit(.avx512bw) else 0;
        flags |= if (bitSet(seven.ebx, 31)) x86FeatureBit(.avx512vl) else 0;
        flags |= if (bitSet(seven.ecx, 1)) x86FeatureBit(.vbmi) else 0;
        flags |= if (bitSet(seven.ecx, 6)) x86FeatureBit(.vbmi2) else 0;
        flags |= if (bitSet(seven.ecx, 8)) x86FeatureBit(.gfni) else 0;
        flags |= if (bitSet(seven.ecx, 9)) x86FeatureBit(.vaes) else 0;
        flags |= if (bitSet(seven.ecx, 10)) x86FeatureBit(.vpclmulqdq) else 0;
        flags |= if (bitSet(seven.ecx, 11)) x86FeatureBit(.vnni) else 0;
        flags |= if (bitSet(seven.ecx, 12)) x86FeatureBit(.bitalg) else 0;
        flags |= if (bitSet(seven.ecx, 14)) x86FeatureBit(.popcntdq) else 0;
        flags |= if (bitSet(seven.edx, 23)) x86FeatureBit(.avx512fp16) else 0;
        flags |= if (bitSet(snapshot.leaf7_1.eax, 5)) x86FeatureBit(.avx512bf16) else 0;
        flags |= if (bitSet(snapshot.leaf7_1.edx, 19)) x86FeatureBit(.avx10) else 0;
        flags |= if (bitSet(snapshot.leaf7_1.edx, 21)) x86FeatureBit(.apx) else 0;
    }
    return flags;
}

pub fn detectX86(snapshot: X86Snapshot, is_64bit: bool) Mask {
    const flags = x86Flags(snapshot);
    const one = snapshot.leaf1;
    var targets: Mask = if (is_64bit) Target.sse2.bit() else 0;
    if (x86Has(flags, X86Groups.spr)) targets |= Target.avx3_spr.bit();
    if (x86Has(flags, X86Groups.avx3_dl)) targets |= Target.avx3_dl.bit();
    if (x86Has(flags, X86Groups.avx3)) targets |= Target.avx3.bit();
    if (x86Has(flags, X86Groups.avx2)) targets |= Target.avx2.bit();
    if (x86Has(flags, X86Groups.sse4)) targets |= Target.sse4.bit();
    if (x86Has(flags, X86Groups.ssse3)) targets |= Target.ssse3.bit();
    if (!is_64bit and x86Has(flags, X86Groups.sse2)) targets |= Target.sse2.bit();

    if (x86Has(flags, X86Groups.avx10)) {
        const version = snapshot.leaf24.ebx & 0xff;
        if (version >= 1 and bitSet(snapshot.leaf24.ebx, 18)) {
            targets |= Target.avx3_spr.bit() | Target.avx3_dl.bit() | Target.avx3.bit();
            if (version >= 2) targets |= Target.avx10_2.bit();
        }
    }

    const min_avx2 = Target.avx2.bit() | (Target.avx2.bit() - 1);
    const min_avx3 = Target.avx3.bit() | (Target.avx3.bit() - 1);
    if (!bitSet(one.ecx, 26) or !bitSet(one.ecx, 27)) {
        targets &= ~min_avx2;
    } else {
        if (!bitSet(snapshot.xcr0, 1) or !bitSet(snapshot.xcr0, 2)) {
            targets &= ~min_avx2;
        }
        const avx3_os_support = snapshot.avx3_os_support orelse
            (bitSet(snapshot.xcr0, 5) and bitSet(snapshot.xcr0, 6) and
                bitSet(snapshot.xcr0, 7));
        if (!avx3_os_support) {
            targets &= ~min_avx3;
        }
    }

    if (targets & Target.avx3_dl.bit() != 0 and x86Has(flags, X86Groups.zen4) and
        isAmd(snapshot.leaf0))
    {
        targets |= Target.avx3_zen4.bit();
    }
    return targets;
}

fn captureX86() X86Snapshot {
    const leaf0 = cpuid(0, 0);
    const leaf1 = if (leaf0.eax >= 1) cpuid(1, 0) else zeroX86Leaf();
    const leaf7_0 = if (leaf0.eax >= 7) cpuid(7, 0) else zeroX86Leaf();
    const leaf7_1 = if (leaf0.eax >= 7) cpuid(7, 1) else zeroX86Leaf();
    const leaf24 = if (leaf0.eax >= 0x24) cpuid(0x24, 0) else zeroX86Leaf();
    const extended0 = cpuid(0x8000_0000, 0);
    const extended1 = if (extended0.eax >= 0x8000_0001)
        cpuid(0x8000_0001, 0)
    else
        zeroX86Leaf();
    const have_xcr0 = bitSet(leaf1.ecx, 26) and bitSet(leaf1.ecx, 27);
    return .{
        .leaf0 = leaf0,
        .leaf1 = leaf1,
        .leaf7_0 = leaf7_0,
        .leaf7_1 = leaf7_1,
        .leaf24 = leaf24,
        .extended0 = extended0,
        .extended1 = extended1,
        .xcr0 = if (have_xcr0) readXcr0() else 0,
        .avx3_os_support = if (builtin.target.os.tag.isDarwin())
            appleAvx3OsSupport()
        else
            null,
    };
}

fn cpuid(leaf: u32, subleaf: u32) X86Leaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn readXcr0() u32 {
    return asm volatile (
        \\xor %%ecx, %%ecx
        \\xgetbv
        : [_] "={eax}" (-> u32),
        :
        : .{ .edx = true, .ecx = true });
}

fn zeroX86Leaf() X86Leaf {
    return .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 };
}

fn isAmd(leaf0: X86Leaf) bool {
    return leaf0.eax >= 1 and leaf0.ebx == 0x6874_7541 and
        leaf0.ecx == 0x444d_4163 and leaf0.edx == 0x6974_6e65;
}

fn bitSet(value: u32, bit: u5) bool {
    return value & (@as(u32, 1) << bit) != 0;
}

fn detectArm() Mask {
    const arch = builtin.target.cpu.arch;
    const is_64bit = arch == .aarch64 or arch == .aarch64_be;
    if (builtin.target.os.tag.isDarwin() and is_64bit) return detectAppleArm();
    const caps = readAuxCaps() orelse return compileArchitectureTargets();
    if (is_64bit) return detectAarch64Caps(caps.hw, caps.hw2, detectedSveBytes(caps.hw));
    return detectArm32Caps(caps.hw);
}

fn detectArm32Caps(hw: usize) Mask {
    const required = (@as(usize, 1) << 12) | (@as(usize, 1) << 16);
    return if (hw & required == required) Target.neon_without_aes.bit() else 0;
}

pub fn detectAarch64Caps(hw: usize, hw2: usize, sve_bytes: usize) Mask {
    const aes = @as(usize, 1) << 3;
    const asimdhp = @as(usize, 1) << 10;
    const asimddp = @as(usize, 1) << 20;
    const sve_cap = @as(usize, 1) << 22;
    const sve2_cap = @as(usize, 1) << 1;
    const sve_aes = @as(usize, 1) << 2;
    const sve_i8mm = @as(usize, 1) << 9;
    const sve_bf16 = @as(usize, 1) << 12;
    const bf16 = @as(usize, 1) << 14;
    var targets = Target.neon_without_aes.bit();
    if (hw & aes != 0) {
        targets |= Target.neon.bit();
        if (hw & (asimdhp | asimddp) == asimdhp | asimddp and hw2 & bf16 != 0) {
            targets |= Target.neon_bf16.bit();
        }
    }
    if (hw & sve_cap != 0) targets |= Target.sve.bit();
    if (hw2 & (sve2_cap | sve_aes) == sve2_cap | sve_aes) targets |= Target.sve2.bit();
    if (targets & (Target.sve.bit() | Target.sve2.bit()) != 0) {
        if (sve_bytes == 32) targets |= Target.sve_256.bit();
        if (sve_bytes == 16 and targets & Target.sve2.bit() != 0 and
            hw2 & (sve_i8mm | sve_bf16) == sve_i8mm | sve_bf16)
        {
            targets |= Target.sve2_128.bit();
        }
    }
    return targets;
}

fn detectAppleArm() Mask {
    var targets = Target.neon_without_aes.bit();
    if (!appleFeature("hw.optional.arm.FEAT_AES")) return targets;
    targets |= Target.neon.bit();
    if ((appleFeature("hw.optional.AdvSIMD_HPFPCvt") or
        appleFeature("hw.optional.arm.AdvSIMD_HPFPCvt")) and
        appleFeature("hw.optional.arm.FEAT_DotProd") and
        appleFeature("hw.optional.arm.FEAT_BF16") and
        appleFeature("hw.optional.arm.FEAT_I8MM"))
    {
        targets |= Target.neon_bf16.bit();
    }
    return targets;
}

fn appleFeature(comptime name: [:0]const u8) bool {
    var result: c_int = 0;
    const byte_len = sys.process.systemControl(name, &result) catch return false;
    return byte_len == @sizeOf(c_int) and result != 0;
}

fn appleAvx3OsSupport() bool {
    var release_storage: [128]u8 = undefined;
    const release = sys.process.kernelRelease(&release_storage) catch return false;
    if (!darwinSupportsAvx3(release, true)) return false;
    return appleFeature("hw.optional.avx512f");
}

fn darwinSupportsAvx3(release: []const u8, has_avx512: bool) bool {
    var index: usize = 0;
    const major = parseDecimal(release, &index) orelse return false;
    if (index >= release.len or release[index] != '.') return false;
    index += 1;
    const minor = parseDecimal(release, &index) orelse return false;
    return (major > 21 or (major == 21 and minor >= 3)) and has_avx512;
}

fn parseDecimal(text: []const u8, index: *usize) ?u32 {
    const begin = index.*;
    var value: u64 = 0;
    while (index.* < text.len and text[index.*] >= '0' and text[index.*] <= '9') {
        const digit: u64 = text[index.*] - '0';
        if (value > (std.math.maxInt(u32) - digit) / 10) return null;
        value = value * 10 + digit;
        index.* += 1;
    }
    return if (index.* == begin) null else @intCast(value);
}

fn detectedSveBytes(hw: usize) usize {
    const sve_cap = @as(usize, 1) << 22;
    if (hw & sve_cap == 0) return 0;
    return sveVectorBytes();
}

fn sveVectorBytes() usize {
    return asm volatile (
        \\.arch_extension sve
        \\cntb %[bytes]
        : [bytes] "=r" (-> usize),
    );
}

fn detectRiscV() Mask {
    if (builtin.target.os.tag != .linux) return compileArchitectureTargets();
    const hw = sys.process.auxiliaryValue(.hardware_capabilities) catch 0;
    const vector = @as(usize, 1) << ('V' - 'A');
    if (hw & vector == 0) return 0;
    var vtype: isize = undefined;
    const bytes = asm volatile (
        \\.option push
        \\.option arch, +v
        \\vsetvli %[bytes], zero, e8, m1, ta, ma
        \\csrr %[vtype], vtype
        \\.option pop
        : [bytes] "=r" (-> usize),
          [vtype] "=r" (vtype),
    );
    return detectRiscVCaps(hw, vtype, bytes);
}

fn detectRiscVCaps(hw: usize, vtype: isize, bytes: usize) Mask {
    const vector = @as(usize, 1) << ('V' - 'A');
    return if (hw & vector != 0 and vtype >= 0 and bytes >= 16)
        Target.rvv.bit()
    else
        0;
}

fn detectLoongArch() Mask {
    if (builtin.target.os.tag != .linux) return compileArchitectureTargets();
    const hw = sys.process.auxiliaryValue(.hardware_capabilities) catch 0;
    return detectLoongArchCaps(hw);
}

fn detectLoongArchCaps(hw: usize) Mask {
    var targets: Mask = 0;
    if (hw & (@as(usize, 1) << 4) != 0) targets |= Target.lsx.bit();
    if (hw & (@as(usize, 1) << 5) != 0) targets |= Target.lasx.bit();
    return targets;
}

fn detectPower() Mask {
    const caps = readAuxCaps() orelse return compileArchitectureTargets();
    return detectPowerCaps(caps.hw, caps.hw2);
}

fn detectPowerCaps(hw: usize, hw2: usize) Mask {
    const vsx = @as(usize, 0x1000_0000) | 0x80;
    if (hw & vsx != vsx) return 0;
    const ppc8 = @as(usize, 0x8000_0000) | 0x0200_0000;
    const ppc9 = ppc8 | 0x0080_0000;
    const ppc10 = ppc9 | 0x0004_0000;
    var targets: Mask = 0;
    if (hw2 & ppc8 == ppc8) targets |= Target.ppc8.bit();
    if (hw2 & ppc9 == ppc9) targets |= Target.ppc9.bit();
    if (hw2 & ppc10 == ppc10) targets |= Target.ppc10.bit();
    return targets;
}

const AuxCaps = struct {
    hw: usize,
    hw2: usize,
};

fn readAuxCaps() ?AuxCaps {
    return switch (builtin.target.os.tag) {
        .linux => .{
            .hw = sys.process.auxiliaryValue(.hardware_capabilities) catch 0,
            .hw2 = sys.process.auxiliaryValue(.hardware_capabilities_2) catch 0,
        },
        .freebsd, .openbsd => .{
            .hw = bsdAuxValue(25),
            .hw2 = bsdAuxValue(26),
        },
        else => null,
    };
}

fn bsdAuxValue(identifier: c_int) usize {
    var value: usize = 0;
    const rc = elf_aux_info(identifier, &value, @sizeOf(usize));
    return if (rc == 0) value else 0;
}

extern "c" fn elf_aux_info(aux: c_int, buffer: ?*anyopaque, length: c_int) c_int;

fn detectS390x() Mask {
    if (builtin.target.os.tag != .linux) return compileArchitectureTargets();
    const hw = sys.process.auxiliaryValue(.hardware_capabilities) catch 0;
    return detectS390Caps(hw);
}

fn detectS390Caps(hw: usize) Mask {
    const z14 = @as(usize, 2048 | 8192);
    const z15 = z14 | 32768;
    var targets: Mask = 0;
    if (hw & z14 == z14) targets |= Target.z14.bit();
    if (hw & z15 == z15) targets |= Target.z15.bit();
    return targets;
}

fn scalableVectorBytes(target: Target) usize {
    return switch (target) {
        .sve, .sve2 => switch (builtin.target.cpu.arch) {
            .aarch64, .aarch64_be => sveVectorBytes(),
            else => 16,
        },
        .rvv => switch (builtin.target.cpu.arch) {
            .riscv32, .riscv32be, .riscv64, .riscv64be => rvvVectorBytes(),
            else => 16,
        },
        else => 16,
    };
}

fn rvvVectorBytes() usize {
    var vtype: isize = undefined;
    return asm volatile (
        \\.option push
        \\.option arch, +v
        \\vsetvli %[bytes], zero, e8, m1, ta, ma
        \\csrr %[vtype], vtype
        \\.option pop
        : [bytes] "=r" (-> usize),
          [vtype] "=r" (vtype),
    );
}

fn compileArchitectureTargets() Mask {
    return switch (compileStaticTarget()) {
        .emu128, .scalar => 0,
        else => |target| target.bit(),
    };
}

fn compileOptionalFloat16(target: Target) bool {
    return switch (builtin.target.cpu.arch) {
        .aarch64, .aarch64_be => switch (target) {
            .neon, .neon_without_aes => std.Target.aarch64.featureSetHas(
                builtin.target.cpu.features,
                .fullfp16,
            ),
            else => false,
        },
        .arm, .armeb, .thumb, .thumbeb => switch (target) {
            .neon, .neon_without_aes => std.Target.arm.featureSetHas(
                builtin.target.cpu.features,
                .fullfp16,
            ),
            else => false,
        },
        .riscv32, .riscv32be, .riscv64, .riscv64be => target == .rvv and
            std.Target.riscv.featureSetHas(builtin.target.cpu.features, .zvfh),
        else => false,
    };
}

fn compileStaticTarget() Target {
    return switch (builtin.target.cpu.arch) {
        .x86, .x86_64 => compileX86Target(),
        .aarch64, .aarch64_be => compileAarch64Target(),
        .arm, .armeb, .thumb, .thumbeb => compileArmTarget(),
        .riscv32, .riscv32be, .riscv64, .riscv64be => if (std.Target.riscv.featureSetHas(
            builtin.target.cpu.features,
            .v,
        )) .rvv else .emu128,
        .loongarch32, .loongarch64 => if (std.Target.loongarch.featureSetHas(
            builtin.target.cpu.features,
            .lasx,
        )) .lasx else if (std.Target.loongarch.featureSetHas(
            builtin.target.cpu.features,
            .lsx,
        )) .lsx else .emu128,
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => compilePowerTarget(),
        .s390x => if (std.Target.s390x.featureSetHas(
            builtin.target.cpu.features,
            .vector_enhancements_2,
        )) .z15 else if (std.Target.s390x.featureSetHas(
            builtin.target.cpu.features,
            .vector_enhancements_1,
        )) .z14 else .emu128,
        .wasm32, .wasm64 => if (std.Target.wasm.featureSetHas(
            builtin.target.cpu.features,
            .simd128,
        )) .wasm else .emu128,
        else => .emu128,
    };
}

fn compileX86Target() Target {
    const features = builtin.target.cpu.features;
    const has = std.Target.x86.featureSetHas;
    const sse4 = has(features, .sse4_1) and has(features, .sse4_2) and
        has(features, .pclmul) and has(features, .aes);
    const avx2 = sse4 and has(features, .avx2) and has(features, .bmi2) and
        has(features, .fma) and has(features, .f16c);
    const avx3 = avx2 and has(features, .avx512f) and has(features, .avx512vl) and
        has(features, .avx512dq) and has(features, .avx512bw);
    const avx3_dl = avx3 and has(features, .avx512vnni) and
        has(features, .vpclmulqdq) and has(features, .avx512vbmi) and
        has(features, .avx512vbmi2) and has(features, .vaes) and
        has(features, .avx512vpopcntdq) and has(features, .avx512bitalg);
    const avx3_spr = avx3_dl and has(features, .avx512fp16) and
        has(features, .avx512bf16);
    if (avx3_spr and has(features, .avx10_2)) return .avx10_2;
    if (avx3_spr) return .avx3_spr;
    if (avx3_dl) return .avx3_dl;
    if (avx3) return .avx3;
    if (avx2) return .avx2;
    if (sse4) return .sse4;
    if (has(features, .ssse3)) return .ssse3;
    if (has(features, .sse2)) return .sse2;
    return .emu128;
}

fn compileAarch64Target() Target {
    const features = builtin.target.cpu.features;
    const has = std.Target.aarch64.featureSetHas;
    if (has(features, .sve2)) return .sve2;
    if (has(features, .sve)) return .sve;
    if (has(features, .neon)) {
        if (has(features, .aes) and has(features, .fullfp16) and
            has(features, .dotprod) and has(features, .bf16) and
            has(features, .i8mm)) return .neon_bf16;
        if (has(features, .aes)) return .neon;
        return .neon_without_aes;
    }
    return .emu128;
}

fn compileArmTarget() Target {
    return if (std.Target.arm.featureSetHas(
        builtin.target.cpu.features,
        .neon,
    )) .neon_without_aes else .emu128;
}

fn compilePowerTarget() Target {
    const features = builtin.target.cpu.features;
    const has = std.Target.powerpc.featureSetHas;
    if (has(features, .power10_vector)) return .ppc10;
    if (has(features, .power9_vector)) return .ppc9;
    if (has(features, .power8_vector) and has(features, .altivec) and
        has(features, .vsx) and has(features, .crypto)) return .ppc8;
    return .emu128;
}

fn dispatchSse(_: u32) u32 {
    return 4;
}

fn dispatchAvx2(_: u32) u32 {
    return 2;
}

fn dispatchFallback(_: u32) u32 {
    return 0;
}
