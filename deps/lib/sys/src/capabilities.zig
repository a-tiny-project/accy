const std = @import("std");
const builtin = @import("builtin");

pub const current = Capabilities.fromBuiltin();

pub const JitDebugSupport = struct {
    supported: bool,
    reason: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

pub const CapabilityTier = enum {
    pure,
    no_libc,
    host,
};

pub const Capability = enum {
    allocator,
    descriptors,
    dynamic_loading,
    environment,
    filesystem,
    libc_interop,
    memory_mapping,
    networking,
    process,
    random,
    signal,
    standard_streams,
    terminal,
    threads,
    time,
    audio,
    event_loop,
    performance_counters,
    platform_frameworks,
    tls,
    virtualization,
};

pub const capability_count = @typeInfo(Capability).@"enum".field_names.len;

pub const CapabilitySet = struct {
    bits: [capability_count]bool = @as([capability_count]bool, @splat(false)),

    pub const empty: CapabilitySet = .{};

    pub fn of(comptime values: []const Capability) CapabilitySet {
        var set: CapabilitySet = .{};
        inline for (values) |value| set.add(value);
        return set;
    }

    pub fn add(self: *CapabilitySet, capability: Capability) void {
        self.bits[indexOf(capability)] = true;
    }

    pub fn with(self: CapabilitySet, capability: Capability) CapabilitySet {
        var next = self;
        next.add(capability);
        return next;
    }

    pub fn contains(self: CapabilitySet, capability: Capability) bool {
        return self.bits[indexOf(capability)];
    }

    pub fn containsAll(self: CapabilitySet, required: CapabilitySet) bool {
        inline for (
            @typeInfo(Capability).@"enum".field_names,
            @typeInfo(Capability).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            const capability: Capability = @fromBackingInt(@intCast(field.value));
            if (required.contains(capability) and !self.contains(capability)) return false;
        }
        return true;
    }

    pub fn count(self: CapabilitySet) usize {
        var result: usize = 0;
        inline for (
            @typeInfo(Capability).@"enum".field_names,
            @typeInfo(Capability).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            const capability: Capability = @fromBackingInt(@intCast(field.value));
            if (self.contains(capability)) result += 1;
        }
        return result;
    }

    pub fn isEmpty(self: CapabilitySet) bool {
        return self.count() == 0;
    }

    pub fn names(self: CapabilitySet, storage: *[capability_count][]const u8) []const []const u8 {
        var len: usize = 0;
        inline for (
            @typeInfo(Capability).@"enum".field_names,
            @typeInfo(Capability).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            const capability: Capability = @fromBackingInt(@intCast(field.value));
            if (self.contains(capability)) {
                storage[len] = field.name;
                len += 1;
            }
        }
        return storage[0..len];
    }

    fn indexOf(capability: Capability) usize {
        return @backingInt(capability);
    }
};

pub const Requirement = struct {
    tier: CapabilityTier = .pure,
    capabilities: CapabilitySet = .{},

    pub fn requires(self: Requirement, capability: Capability) bool {
        return self.capabilities.contains(capability);
    }

    pub fn containsAll(self: Requirement, required: Requirement) bool {
        if (@backingInt(self.tier) < @backingInt(required.tier)) return false;
        return self.capabilities.containsAll(required.capabilities);
    }

    pub fn requiresPlatformEnvironment(self: Requirement) bool {
        return self.tier != .pure or !self.capabilities.isEmpty();
    }
};

pub fn pure() Requirement {
    return .{};
}

pub fn noLibc(comptime values: []const Capability) Requirement {
    return .{ .tier = .no_libc, .capabilities = CapabilitySet.of(values) };
}

pub fn host(comptime values: []const Capability) Requirement {
    return .{ .tier = .host, .capabilities = CapabilitySet.of(values) };
}

pub fn require(comptime tier: CapabilityTier, comptime values: []const Capability) Requirement {
    return .{ .tier = tier, .capabilities = CapabilitySet.of(values) };
}

pub const Capabilities = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    abi: std.Target.Abi = .none,
    single_threaded: bool = false,

    pub fn fromBuiltin() Capabilities {
        return .{
            .os = builtin.os.tag,
            .arch = builtin.cpu.arch,
            .abi = builtin.abi,
            .single_threaded = builtin.single_threaded,
        };
    }

    pub fn isWasm(self: Capabilities) bool {
        return self.arch.isWasm();
    }

    pub fn archName(self: Capabilities) []const u8 {
        return @tagName(self.arch);
    }

    pub fn endianName(self: Capabilities) []const u8 {
        return @tagName(self.arch.endian());
    }

    pub fn pointerWidthBits(self: Capabilities) u16 {
        return std.Target.ptrBitWidth_arch_abi(self.arch, self.abi);
    }

    pub fn isFreestanding(self: Capabilities) bool {
        return self.os == .freestanding;
    }

    pub fn isLinux(self: Capabilities) bool {
        return self.os == .linux;
    }

    pub fn isBrowserish(self: Capabilities) bool {
        return self.isWasm() and self.isFreestanding();
    }

    pub fn supportsThreads(self: Capabilities) bool {
        return !self.single_threaded;
    }

    pub fn supportsX86_64Execution(self: Capabilities) bool {
        return self.arch == .x86_64;
    }

    pub fn supportsAarch64Execution(self: Capabilities) bool {
        return self.arch == .aarch64;
    }

    pub fn supportsAppleMetal(self: Capabilities) bool {
        return self.os == .macos;
    }

    pub fn supportsMoltenVk(self: Capabilities) bool {
        return self.os == .macos;
    }

    pub fn jitDebugSupport(self: Capabilities) JitDebugSupport {
        if (self.os != .linux and self.os != .macos) {
            return .{
                .supported = false,
                .reason = "JIT debug registration is only available on Linux/macOS",
            };
        }
        if (self.arch != .x86_64 and self.arch != .aarch64) {
            return .{
                .supported = false,
                .reason = "JIT debug registration is only available on x86_64/aarch64",
            };
        }
        const note: ?[]const u8 = if (self.os == .macos)
            "lldb requires `settings set plugin.jit-loader.gdb.enable on` to load JIT debug objects"
        else
            null;
        return .{ .supported = true, .note = note };
    }

    pub fn supportsJitDebugInfo(self: Capabilities) bool {
        return self.jitDebugSupport().supported;
    }
};

test "execution capability predicates use architecture" {
    try std.testing.expect((Capabilities{ .os = .linux, .arch = .x86_64 }).supportsX86_64Execution());
    try std.testing.expect(!(Capabilities{ .os = .linux, .arch = .aarch64 }).supportsX86_64Execution());
    try std.testing.expect((Capabilities{ .os = .linux, .arch = .aarch64 }).supportsAarch64Execution());
    try std.testing.expectEqualStrings("x86_64", (Capabilities{ .os = .linux, .arch = .x86_64 }).archName());
    try std.testing.expectEqualStrings("little", (Capabilities{ .os = .linux, .arch = .x86_64 }).endianName());
    try std.testing.expectEqual(@as(u16, 64), (Capabilities{ .os = .linux, .arch = .x86_64 }).pointerWidthBits());
}

test "host shape predicates derive from target fields" {
    const browser = Capabilities{ .os = .freestanding, .arch = .wasm32, .single_threaded = true };
    try std.testing.expect(browser.isWasm());
    try std.testing.expect(browser.isFreestanding());
    try std.testing.expect(browser.isBrowserish());
    try std.testing.expect((Capabilities{ .os = .linux, .arch = .x86_64 }).isLinux());
    try std.testing.expect(!browser.supportsThreads());
}

test "JIT debug support is constrained by OS and architecture" {
    try std.testing.expect((Capabilities{ .os = .linux, .arch = .x86_64 }).supportsJitDebugInfo());
    try std.testing.expect((Capabilities{ .os = .macos, .arch = .aarch64 }).supportsJitDebugInfo());

    const windows_support = (Capabilities{ .os = .windows, .arch = .x86_64 }).jitDebugSupport();
    try std.testing.expect(!windows_support.supported);
    try std.testing.expect(windows_support.reason != null);

    const unsupported_arch = (Capabilities{ .os = .linux, .arch = .riscv64 }).jitDebugSupport();
    try std.testing.expect(!unsupported_arch.supported);
    try std.testing.expect(unsupported_arch.reason != null);
}

test "Apple platform predicates are explicit" {
    try std.testing.expect((Capabilities{ .os = .macos, .arch = .aarch64 }).supportsAppleMetal());
    try std.testing.expect(!(Capabilities{ .os = .linux, .arch = .x86_64 }).supportsAppleMetal());
    try std.testing.expect((Capabilities{ .os = .macos, .arch = .x86_64 }).supportsMoltenVk());
}

test "capability sets are comptime service labels" {
    const io = CapabilitySet.of(&.{ .filesystem, .standard_streams });
    try std.testing.expect(io.contains(.filesystem));
    try std.testing.expect(io.contains(.standard_streams));
    try std.testing.expect(!io.contains(.process));
    try std.testing.expectEqual(@as(usize, 2), io.count());

    var storage: [capability_count][]const u8 = undefined;
    const names = io.names(&storage);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("filesystem", names[0]);
    try std.testing.expectEqualStrings("standard_streams", names[1]);
}

test "capability requirements record tiers and contained services" {
    const host_files = host(&.{ .filesystem, .dynamic_loading });
    const no_libc_streams = noLibc(&.{.standard_streams});
    const empty = pure();

    try std.testing.expectEqual(CapabilityTier.host, host_files.tier);
    try std.testing.expect(host_files.requires(.filesystem));
    try std.testing.expect(host_files.requires(.dynamic_loading));
    try std.testing.expect(!host_files.requires(.networking));
    try std.testing.expect(host_files.requiresPlatformEnvironment());

    try std.testing.expectEqual(CapabilityTier.no_libc, no_libc_streams.tier);
    try std.testing.expect(no_libc_streams.requires(.standard_streams));
    try std.testing.expect(host_files.containsAll(no_libc_streams) == false);
    try std.testing.expect(!empty.requiresPlatformEnvironment());
}
