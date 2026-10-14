const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const observe_mod = @import("observer.zig");

pub const required_capabilities = capabilities.noLibc(&.{.memory_mapping});
pub const observe = observe_mod;

pub const MapError = error{
    AccessDenied,
    OutOfMemory,
    PermissionDenied,
    UnsupportedPlatform,
    MapFailed,
};

pub const ProtectError = error{
    AccessDenied,
    InvalidMapping,
    OutOfMemory,
    PermissionDenied,
    UnsupportedPlatform,
    ProtectFailed,
};

pub const DiscardError = error{
    AccessDenied,
    OutOfMemory,
    PermissionDenied,
    UnsupportedPlatform,
    DiscardFailed,
};

pub const DecommitError = MapError || ProtectError;

pub const Protection = struct {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
};

/// The producer, rather than a runtime entitlement guess, establishes this policy.
/// The Mac mode is limited to a startup-linked, non-hardened executable. On arm64
/// it needs a macOS 11.4 or newer deployment target and publishes through the
/// MAP_JIT write callback. On x86_64 it publishes as Linux does: a private
/// read-write mapping, then read+execute, which a non-hardened process may do.
/// Hardened processes, late-loaded callbacks, and allowlist/freeze-late policies
/// require a separate contract.
pub const ExecutablePolicy = enum {
    unverified,
    linux,
    macos_non_hardened,
    unsupported_hardened,
};

pub const PublicationError = MapError || ProtectError || error{
    InvalidExecutableExtent,
    InvalidPublication,
    InvalidPatch,
    UnsupportedPublicationPolicy,
    PublicationFailed,
};

/// A resolved relocation. The producer uses its target patcher to form these
/// bytes before entering the publication scope.
pub const ExecutablePatch = struct {
    offset: usize,
    bytes: [8]u8,
    len: u8,
};

/// One reservation, its used code extent, and its publication phase. A caller
/// may use reservationAddress for relocation, but may call only after publish.
pub const ExecutableMapping = struct {
    mapping: []align(std.heap.page_size_min) u8,
    used: usize,
    policy: ExecutablePolicy,
    phase: Phase = .building,

    const Phase = enum { building, writing, callable, failed, closed };
    const Self = @This();

    pub fn init(used: usize, policy: ExecutablePolicy) PublicationError!Self {
        try validateExecutablePolicy(policy);
        if (used == 0) return error.InvalidExecutableExtent;
        const aligned = pageAlign(used) orelse return error.InvalidExecutableExtent;
        const mapping = if (comptime appleJit())
            try mapJit(aligned)
        else
            try mapAnonymous(used, .{ .read = true, .write = true });
        return .{ .mapping = mapping, .used = used, .policy = policy };
    }

    pub fn reservationAddress(self: *const Self) usize {
        std.debug.assert(self.phase == .building);
        return @intFromPtr(self.mapping.ptr);
    }

    pub fn mappedBytes(self: *const Self) usize {
        std.debug.assert(self.phase != .closed);
        return self.mapping.len;
    }

    pub fn callableAddress(self: *const Self) PublicationError!usize {
        if (self.phase != .callable) return error.InvalidPublication;
        return @intFromPtr(self.mapping.ptr);
    }

    pub fn publish(self: *Self, source: []const u8, patches: []const ExecutablePatch) PublicationError!void {
        if (self.phase != .building) return error.InvalidPublication;
        var context = PublicationContext{
            .owner = self,
            .address = @intFromPtr(self.mapping.ptr),
            .mapped_len = self.mapping.len,
            .source = source,
            .patches = patches,
        };
        try validatePublication(&context, .building);
        self.phase = .writing;
        errdefer self.phase = .failed;
        const status = if (comptime appleJit() and macosCallbackAvailable())
            pthread_jit_write_with_callback_np(writeExecutable, &context)
        else if (comptime appleJit())
            return error.UnsupportedPublicationPolicy
        else
            writeExecutable(&context);
        if (status != 0) return error.PublicationFailed;
        if (comptime !appleJit()) {
            try protect(self.mapping, .{ .read = true, .execute = true });
        }
        invalidateExecutable(self.mapping.ptr, self.used);
        self.phase = .callable;
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.phase != .closed and self.phase != .writing);
        unmap(self.mapping);
        self.phase = .closed;
    }
};

const PublicationContext = struct {
    owner: *ExecutableMapping,
    address: usize,
    mapped_len: usize,
    source: []const u8,
    patches: []const ExecutablePatch,
};

/// Purely checks host, architecture and deployment support for a declared publication policy.
/// Runtime owners may call this before allocating their own state; it creates no mapping.
pub fn validateExecutablePolicy(policy: ExecutablePolicy) error{UnsupportedPublicationPolicy}!void {
    switch (policy) {
        .linux => if (builtin.os.tag != .linux or
            (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64))
            return error.UnsupportedPublicationPolicy,
        .macos_non_hardened => {
            if (builtin.os.tag != .macos) return error.UnsupportedPublicationPolicy;
            switch (builtin.cpu.arch) {
                .aarch64 => if (!macosCallbackAvailable()) return error.UnsupportedPublicationPolicy,
                .x86_64 => {},
                else => return error.UnsupportedPublicationPolicy,
            }
        },
        .unverified, .unsupported_hardened => return error.UnsupportedPublicationPolicy,
    }
}

/// Whether this build publishes through Apple silicon's MAP_JIT write callback rather than by
/// writing a private mapping and then protecting it read+execute.
fn appleJit() bool {
    return builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
}

/// The policy this host's own witnesses declare, and whether it publishes here at all.
const host_policy: ExecutablePolicy = if (builtin.os.tag == .linux) .linux else .macos_non_hardened;

fn hostPublishes() bool {
    validateExecutablePolicy(host_policy) catch return false;
    return true;
}

fn macosCallbackAvailable() bool {
    if (comptime builtin.os.tag == .macos) {
        return builtin.os.version_range.semver.min.order(.{ .major = 11, .minor = 4, .patch = 0 }) != .lt;
    }
    return false;
}

fn nonoverlapping(address: usize, size: usize, other: usize, other_size: usize) bool {
    if (size == 0 or other_size == 0) return true;
    const end = std.math.add(usize, address, size) catch return false;
    const other_end = std.math.add(usize, other, other_size) catch return false;
    return end <= other or other_end <= address;
}

fn validatePublication(context: *const PublicationContext, phase: ExecutableMapping.Phase) PublicationError!void {
    const owner = context.owner;
    validateExecutablePolicy(owner.policy) catch return error.InvalidPublication;
    if (owner.phase != phase or context.address != @intFromPtr(owner.mapping.ptr) or
        context.mapped_len != owner.mapping.len or owner.used == 0 or
        owner.used > owner.mapping.len or context.source.len != owner.used)
        return error.InvalidPublication;
    if (!nonoverlapping(context.address, context.mapped_len, @intFromPtr(context.source.ptr), context.source.len) or
        !nonoverlapping(context.address, context.mapped_len, @intFromPtr(context.patches.ptr), std.mem.sliceAsBytes(context.patches).len))
        return error.InvalidPublication;
    for (context.patches) |patch| {
        if (patch.len == 0 or patch.len > 8 or patch.offset > owner.used or
            patch.len > owner.used - patch.offset) return error.InvalidPatch;
    }
}

/// The one fixed writer accepted by Apple's callback API. It performs no
/// allocation, lookup, recursion, or caller-supplied function invocation.
fn writeExecutable(raw: ?*anyopaque) callconv(.c) c_int {
    const context: *PublicationContext = @ptrCast(@alignCast(raw orelse return 1));
    validatePublication(context, .writing) catch return 1;
    const target = context.owner.mapping[0..context.owner.used];
    @memcpy(target, context.source);
    for (context.patches) |patch| {
        @memcpy(target[patch.offset..][0..patch.len], patch.bytes[0..patch.len]);
    }
    return 0;
}

extern "c" fn pthread_jit_write_with_callback_np(
    callback: *const fn (?*anyopaque) callconv(.c) c_int,
    context: ?*anyopaque,
) c_int;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

// Equivalent to Apple's PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP(writeExecutable).
// The final Mach-O image must retain this callback and trailing null entry.
var jit_callback_allowlist: [2]?*const fn (?*anyopaque) callconv(.c) c_int = .{ writeExecutable, null };

comptime {
    if (appleJit()) {
        @export(&jit_callback_allowlist, .{
            .name = "tiny_jit_write_callback_allowlist",
            .section = "__DATA_CONST,__pth_jit_func",
        });
    }
}

fn mapJit(aligned: usize) MapError![]align(std.heap.page_size_min) u8 {
    if (comptime builtin.os.tag == .macos) {
        var flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        flags.JIT = true;
        const mapping = std.posix.mmap(null, aligned, .{ .READ = true, .WRITE = true, .EXEC = true }, flags, -1, 0) catch |err| {
            recordMap(.anonymous, 0, aligned, @returnAddress(), false);
            return mapErrorFromMMap(err);
        };
        recordMap(.anonymous, @intFromPtr(mapping.ptr), mapping.len, @returnAddress(), true);
        return mapping;
    } else unreachable;
}

fn invalidateExecutable(address: [*]u8, used: usize) void {
    if (builtin.os.tag == .macos) {
        sys_icache_invalidate(@ptrCast(address), used);
    } else if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) {
        invalidateAarch64(address, used);
    }
}

fn invalidateAarch64(address: [*]u8, used: usize) void {
    if (comptime builtin.cpu.arch == .aarch64) {
        const ctr = asm volatile ("mrs %[value], ctr_el0"
            : [value] "=r" (-> usize),
        );
        const data_line: usize = @as(usize, 4) << @as(u6, @intCast((ctr >> 16) & 15));
        const instruction_line: usize = @as(usize, 4) << @as(u6, @intCast(ctr & 15));
        const first = @intFromPtr(address);
        const end = first + used;
        var cursor = first & ~(data_line - 1);
        while (cursor < end) : (cursor += data_line) {
            asm volatile ("dc cvau, %[line]"
                :
                : [line] "r" (cursor),
                : .{ .memory = true });
        }
        asm volatile ("dsb ish" ::: .{ .memory = true });
        cursor = first & ~(instruction_line - 1);
        while (cursor < end) : (cursor += instruction_line) {
            asm volatile ("ic ivau, %[line]"
                :
                : [line] "r" (cursor),
                : .{ .memory = true });
        }
        asm volatile ("dsb ish" ::: .{ .memory = true });
        asm volatile ("isb" ::: .{ .memory = true });
    } else unreachable;
}

var page_allocator_context: u8 = 0;

pub const page_allocator: std.mem.Allocator = .{
    .ptr = &page_allocator_context,
    .vtable = &page_allocator_vtable,
};

const page_allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = pageAllocatorAlloc,
    .resize = pageAllocatorResize,
    .remap = pageAllocatorRemap,
    .free = pageAllocatorFree,
};

fn pageAllocatorAlloc(
    _: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    _: usize,
) ?[*]u8 {
    const page_size = pageSize();
    const aligned_len = pageAlign(len) orelse return null;
    const alignment_bytes = alignment.toByteUnits();
    if (alignment_bytes <= page_size) {
        const mapping = mapAnonymous(
            aligned_len,
            .{ .read = true, .write = true },
        ) catch return null;
        return mapping.ptr;
    }
    const mapping_len = std.math.add(
        usize,
        aligned_len,
        alignment_bytes,
    ) catch return null;
    const mapping = mapAnonymous(
        mapping_len,
        .{ .read = true, .write = true },
    ) catch return null;
    const base_address = @intFromPtr(mapping.ptr);
    const aligned_address = std.mem.alignForward(
        usize,
        base_address,
        alignment_bytes,
    );
    const prefix_len = aligned_address - base_address;
    if (prefix_len != 0) unmap(mapping[0..prefix_len]);
    const allocation_end = aligned_address + aligned_len;
    const mapping_end = base_address + mapping.len;
    if (allocation_end < mapping_end) {
        const suffix: [*]align(std.heap.page_size_min) u8 =
            @ptrFromInt(allocation_end);
        unmap(suffix[0 .. mapping_end - allocation_end]);
    }
    return @ptrFromInt(aligned_address);
}

fn pageAllocatorResize(
    _: *anyopaque,
    memory: []u8,
    _: std.mem.Alignment,
    new_len: usize,
    _: usize,
) bool {
    const old_aligned_len = pageAlign(memory.len) orelse return false;
    const new_aligned_len = pageAlign(new_len) orelse return false;
    if (new_aligned_len > old_aligned_len) return false;
    if (new_aligned_len < old_aligned_len) {
        const suffix: [*]align(std.heap.page_size_min) u8 = @ptrCast(
            @alignCast(memory.ptr + new_aligned_len),
        );
        unmap(suffix[0 .. old_aligned_len - new_aligned_len]);
    }
    return true;
}

fn pageAllocatorRemap(
    context: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    if (!pageAllocatorResize(
        context,
        memory,
        alignment,
        new_len,
        return_address,
    )) return null;
    return memory.ptr;
}

fn pageAllocatorFree(
    _: *anyopaque,
    memory: []u8,
    _: std.mem.Alignment,
    _: usize,
) void {
    const aligned_len = pageAlign(memory.len) orelse unreachable;
    const mapping: [*]align(std.heap.page_size_min) u8 =
        @ptrCast(@alignCast(memory.ptr));
    unmap(mapping[0..aligned_len]);
}

const MappingOptions = struct {
    shared: bool = false,
    no_reserve: bool = false,
    fixed: bool = false,
    no_replace: bool = false,
    address: ?[*]align(std.heap.page_size_min) u8 = null,
};

const FileMappingOptions = struct {
    fixed: bool = false,
    address: ?[*]align(std.heap.page_size_min) u8 = null,
    offset: usize = 0,
};

const PageSizeCache = struct {
    var value: std.atomic.Value(usize) = .init(0);
};

pub fn pageSize() usize {
    if (comptime builtin.os.tag != .linux) return std.heap.pageSize();
    if (std.heap.page_size_min == std.heap.page_size_max) return std.heap.page_size_min;

    const cached = PageSizeCache.value.load(.unordered);
    if (cached != 0) return cached;
    const detected = detectLinuxPageSize();
    PageSizeCache.value.store(detected, .unordered);
    return detected;
}

const LinuxPageAlignmentProbe = struct {
    base_address: usize,

    fn alignment(self: @This(), candidate: usize) PageAlignment {
        const address: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(self.base_address + candidate);
        const result = std.os.linux.mprotect(address, std.heap.page_size_min, .{});
        return switch (std.os.linux.errno(result)) {
            .SUCCESS => .aligned,
            .INVAL => .unaligned,
            else => .failed,
        };
    }
};

fn detectLinuxPageSize() usize {
    if (comptime builtin.os.tag != .linux) return std.heap.page_size_max;

    const linux = std.os.linux;
    const probe_len = std.heap.page_size_max * 2;
    const mapped = linux.mmap(
        null,
        probe_len,
        .{},
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    if (linux.errno(mapped) != .SUCCESS) return std.heap.page_size_max;
    const base: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(mapped);
    defer _ = linux.munmap(base, probe_len);

    return detectPageSize(
        std.heap.page_size_min,
        std.heap.page_size_max,
        LinuxPageAlignmentProbe{ .base_address = mapped },
    );
}

const PageAlignment = enum {
    aligned,
    unaligned,
    failed,
};

fn detectPageSize(minimum: usize, maximum: usize, probe: anytype) usize {
    var candidate = minimum;
    while (candidate < maximum) : (candidate *= 2) {
        switch (probe.alignment(candidate)) {
            .aligned => return candidate,
            .unaligned => {},
            .failed => return maximum,
        }
    }
    return maximum;
}

const PageAlignmentProbeFixture = struct {
    expected: usize,
    fail: bool = false,

    fn alignment(self: @This(), candidate: usize) PageAlignment {
        if (self.fail) return .failed;
        return if (candidate < self.expected) .unaligned else .aligned;
    }
};

pub fn pageAlign(byte_count: usize) ?usize {
    const page_size = pageSize();
    const mask = page_size - 1;
    if (byte_count > std.math.maxInt(usize) - mask) return null;
    return (byte_count + mask) & ~mask;
}

pub fn anonymousMappingSupported() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
        else => false,
    };
}

pub fn mapAnonymous(byte_count: usize, protection: Protection) MapError![]align(std.heap.page_size_min) u8 {
    const return_address = @returnAddress();
    const aligned_len = pageAlign(@max(byte_count, 1)) orelse {
        recordMap(.anonymous, 0, byte_count, return_address, false);
        return error.OutOfMemory;
    };
    const mapping = mapAnonymousWithOptions(
        aligned_len,
        protection,
        .{},
    ) catch |err| {
        recordMap(.anonymous, 0, aligned_len, return_address, false);
        return err;
    };
    recordMap(
        .anonymous,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
    return mapping;
}

/// Maps zeroed pages that a forked or cloned child shares with its parent,
/// so a write on either side is seen by the other.
pub fn mapSharedAnonymous(byte_count: usize, protection: Protection) MapError![]align(std.heap.page_size_min) u8 {
    const return_address = @returnAddress();
    const aligned_len = pageAlign(@max(byte_count, 1)) orelse {
        recordMap(.anonymous, 0, byte_count, return_address, false);
        return error.OutOfMemory;
    };
    const mapping = mapAnonymousWithOptions(
        aligned_len,
        protection,
        .{ .shared = true },
    ) catch |err| {
        recordMap(.anonymous, 0, aligned_len, return_address, false);
        return err;
    };
    recordMap(
        .anonymous,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
    return mapping;
}

pub fn reserveAddressSpace(byte_count: usize) MapError![]align(std.heap.page_size_min) u8 {
    const return_address = @returnAddress();
    const aligned_len = pageAlign(@max(byte_count, 1)) orelse {
        recordMap(.reserve, 0, byte_count, return_address, false);
        return error.OutOfMemory;
    };
    const mapping = mapAnonymousWithOptions(
        aligned_len,
        .{},
        .{ .no_reserve = true },
    ) catch |err| {
        recordMap(.reserve, 0, aligned_len, return_address, false);
        return err;
    };
    recordMap(
        .reserve,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
    return mapping;
}

/// Reserves an exact vacant address without replacing an existing mapping.
/// A kernel that treats FIXED_NOREPLACE as a hint is refused as well.
pub fn reserveAddressSpaceAt(
    address: [*]align(std.heap.page_size_min) u8,
    byte_count: usize,
) MapError![]align(std.heap.page_size_min) u8 {
    const return_address = @returnAddress();
    const aligned_len = pageAlign(@max(byte_count, 1)) orelse {
        recordMap(.reserve, @intFromPtr(address), byte_count, return_address, false);
        return error.OutOfMemory;
    };
    const mapping = mapAnonymousWithOptions(
        aligned_len,
        .{},
        .{ .no_reserve = true, .no_replace = true, .address = address },
    ) catch |err| {
        recordMap(.reserve, @intFromPtr(address), aligned_len, return_address, false);
        return err;
    };
    if (mapping.ptr != address) {
        unmap(mapping);
        recordMap(.reserve, @intFromPtr(address), aligned_len, return_address, false);
        return error.MapFailed;
    }
    recordMap(.reserve, @intFromPtr(address), mapping.len, return_address, true);
    return mapping;
}

pub fn mapAnonymousFixed(
    address: [*]align(std.heap.page_size_min) u8,
    byte_count: usize,
    protection: Protection,
) MapError![]align(std.heap.page_size_min) u8 {
    const return_address = @returnAddress();
    const requested_address = @intFromPtr(address);
    const aligned_len = pageAlign(@max(byte_count, 1)) orelse {
        recordMap(
            .anonymous_fixed,
            requested_address,
            byte_count,
            return_address,
            false,
        );
        return error.OutOfMemory;
    };
    const mapping = mapAnonymousWithOptions(
        aligned_len,
        protection,
        .{ .fixed = true, .address = address },
    ) catch |err| {
        recordMap(
            .anonymous_fixed,
            requested_address,
            aligned_len,
            return_address,
            false,
        );
        return err;
    };
    recordMap(
        .anonymous_fixed,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
    return mapping;
}

pub fn mapPrivateFile(
    descriptor: std.posix.fd_t,
    byte_count: usize,
    protection: Protection,
    offset: usize,
) MapError![]align(std.heap.page_size_min) u8 {
    const return_address = @returnAddress();
    if (byte_count == 0) {
        recordMap(.private_file, 0, 0, return_address, false);
        return error.MapFailed;
    }
    const aligned_len = pageAlign(byte_count) orelse {
        recordMap(.private_file, 0, byte_count, return_address, false);
        return error.OutOfMemory;
    };
    const mapping = mapPrivateFileWithOptions(
        descriptor,
        aligned_len,
        protection,
        .{ .offset = offset },
    ) catch |err| {
        recordMap(.private_file, 0, aligned_len, return_address, false);
        return err;
    };
    recordMap(
        .private_file,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
    return mapping;
}

pub fn mapSharedFile(
    descriptor: std.posix.fd_t,
    byte_count: usize,
    protection: Protection,
    offset: usize,
) MapError![]align(std.heap.page_size_min) u8 {
    const return_address = @returnAddress();
    if (byte_count == 0) {
        recordMap(.shared_file, 0, 0, return_address, false);
        return error.MapFailed;
    }
    const aligned_len = pageAlign(byte_count) orelse {
        recordMap(.shared_file, 0, byte_count, return_address, false);
        return error.OutOfMemory;
    };
    const mapping = mapSharedFileWithOptions(
        descriptor,
        aligned_len,
        protection,
        .{ .offset = offset },
    ) catch |err| {
        recordMap(.shared_file, 0, aligned_len, return_address, false);
        return err;
    };
    recordMap(
        .shared_file,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
    return mapping;
}

pub fn mapPrivateFileFixed(
    descriptor: std.posix.fd_t,
    address: [*]align(std.heap.page_size_min) u8,
    byte_count: usize,
    protection: Protection,
    offset: usize,
) MapError![]align(std.heap.page_size_min) u8 {
    const return_address = @returnAddress();
    const requested_address = @intFromPtr(address);
    if (byte_count == 0) {
        recordMap(
            .private_file_fixed,
            requested_address,
            0,
            return_address,
            false,
        );
        return error.MapFailed;
    }
    const aligned_len = pageAlign(byte_count) orelse {
        recordMap(
            .private_file_fixed,
            requested_address,
            byte_count,
            return_address,
            false,
        );
        return error.OutOfMemory;
    };
    const mapping = mapPrivateFileWithOptions(descriptor, aligned_len, protection, .{
        .fixed = true,
        .address = address,
        .offset = offset,
    }) catch |err| {
        recordMap(
            .private_file_fixed,
            requested_address,
            aligned_len,
            return_address,
            false,
        );
        return err;
    };
    recordMap(
        .private_file_fixed,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
    return mapping;
}

fn mapAnonymousWithOptions(
    aligned_len: usize,
    protection: Protection,
    options: MappingOptions,
) MapError![]align(std.heap.page_size_min) u8 {
    switch (builtin.os.tag) {
        .linux => return mapAnonymousLinux(aligned_len, protection, options),
        .macos, .ios, .tvos, .watchos, .freebsd, .openbsd, .netbsd, .dragonfly => return mapAnonymousPosix(aligned_len, protection, options),
        else => return error.UnsupportedPlatform,
    }
}

fn mapPrivateFileWithOptions(
    descriptor: std.posix.fd_t,
    aligned_len: usize,
    protection: Protection,
    options: FileMappingOptions,
) MapError![]align(std.heap.page_size_min) u8 {
    switch (builtin.os.tag) {
        .linux => return mapPrivateFileLinux(descriptor, aligned_len, protection, options),
        .macos, .ios, .tvos, .watchos, .freebsd, .openbsd, .netbsd, .dragonfly => return mapPrivateFilePosix(descriptor, aligned_len, protection, options),
        else => return error.UnsupportedPlatform,
    }
}

fn mapSharedFileWithOptions(
    descriptor: std.posix.fd_t,
    aligned_len: usize,
    protection: Protection,
    options: FileMappingOptions,
) MapError![]align(std.heap.page_size_min) u8 {
    switch (builtin.os.tag) {
        .linux => return mapSharedFileLinux(descriptor, aligned_len, protection, options),
        .macos, .ios, .tvos, .watchos, .freebsd, .openbsd, .netbsd, .dragonfly => return mapSharedFilePosix(descriptor, aligned_len, protection, options),
        else => return error.UnsupportedPlatform,
    }
}

pub fn unmap(mapping: []align(std.heap.page_size_min) u8) void {
    const return_address = @returnAddress();
    switch (builtin.os.tag) {
        .linux => unmapLinux(mapping),
        .macos, .ios, .tvos, .watchos, .freebsd, .openbsd, .netbsd, .dragonfly => unmapPosix(mapping),
        else => unreachable,
    }
    recordOperation(
        .unmap,
        .unmap,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
}

pub fn protect(mapping: []align(std.heap.page_size_min) u8, protection: Protection) ProtectError!void {
    const return_address = @returnAddress();
    const result: ProtectError!void = switch (builtin.os.tag) {
        .linux => protectLinux(mapping, protection),
        .macos, .ios, .tvos, .watchos, .freebsd, .openbsd, .netbsd, .dragonfly => protectPosix(mapping, protection),
        else => error.UnsupportedPlatform,
    };
    result catch |err| {
        recordOperation(
            .protect,
            .protect,
            @intFromPtr(mapping.ptr),
            mapping.len,
            return_address,
            false,
        );
        return err;
    };
    recordOperation(
        .protect,
        .protect,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
}

pub fn discard(mapping: []align(std.heap.page_size_min) u8) DiscardError!void {
    if (mapping.len == 0) return;
    const return_address = @returnAddress();
    const result: DiscardError!void = switch (builtin.os.tag) {
        .linux => discardLinux(mapping),
        .macos, .ios, .tvos, .watchos, .freebsd, .openbsd, .netbsd, .dragonfly => discardPosix(mapping),
        else => error.UnsupportedPlatform,
    };
    result catch |err| {
        recordOperation(
            .discard,
            .discard,
            @intFromPtr(mapping.ptr),
            mapping.len,
            return_address,
            false,
        );
        return err;
    };
    recordOperation(
        .discard,
        .discard,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
}

/// Restores zero pages in a private anonymous mapping. Linux MADV_DONTNEED
/// makes this guarantee for that mapping kind; other platforms use the caller's
/// explicit-zero fallback.
pub fn discardToZero(mapping: []align(std.heap.page_size_min) u8) DiscardError!void {
    if (mapping.len == 0) return;
    const return_address = @returnAddress();
    const result: DiscardError!bool = switch (builtin.os.tag) {
        .linux => adviseLinux(mapping, std.os.linux.MADV.DONTNEED),
        else => error.UnsupportedPlatform,
    };
    const applied = result catch |err| {
        recordOperation(.discard, .discard, @intFromPtr(mapping.ptr), mapping.len, return_address, false);
        return err;
    };
    recordOperation(.discard, .discard, @intFromPtr(mapping.ptr), mapping.len, return_address, applied);
    if (!applied) return error.UnsupportedPlatform;
}

pub fn decommit(mapping: []align(std.heap.page_size_min) u8) DecommitError!void {
    if (mapping.len == 0) return;
    const return_address = @returnAddress();
    const result: DecommitError!void = switch (builtin.os.tag) {
        .linux => decommitLinux(mapping),
        .macos, .ios, .tvos, .watchos, .freebsd, .openbsd, .netbsd, .dragonfly => decommitPosix(mapping),
        else => error.UnsupportedPlatform,
    };
    result catch |err| {
        recordOperation(
            .decommit,
            .decommit,
            @intFromPtr(mapping.ptr),
            mapping.len,
            return_address,
            false,
        );
        return err;
    };
    recordOperation(
        .decommit,
        .decommit,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
}

pub const AdviseError = error{
    AccessDenied,
    InvalidMapping,
    OutOfMemory,
    PermissionDenied,
    UnsupportedPlatform,
    AdviseFailed,
};

/// Asks for huge pages to cut the cost of address translation on a large hot
/// mapping by marking `mapping` as a candidate for huge-page backing with the
/// `MADV_HUGEPAGE` advice. Whether a huge page appears behind the range, and
/// when, rests with the kernel: its huge-page mode, how fragmented physical
/// memory is, and how the range is aligned each bear on the outcome. Code whose
/// budget rests on the backing confirms it afterwards by touching the pages and
/// reading the range's `AnonHugePages` line in `/proc/self/smaps`. An empty
/// mapping returns without a syscall, while a host other than Linux and a Linux
/// kernel without this advice return `UnsupportedPlatform`, and a range that is
/// no longer mapped returns `InvalidMapping`.
pub fn adviseHugePages(mapping: []align(std.heap.page_size_min) u8) AdviseError!void {
    return advisePageSize(mapping, true);
}

/// Excludes a mapping that has to stay on base pages, such as one measuring
/// page-level behavior, by marking `mapping` with the `MADV_NOHUGEPAGE`
/// advice, which keeps the kernel from promoting the range to huge pages. The
/// advice lands on a newly mapped anonymous range before anything touches it,
/// because a page promoted already stays promoted. The bounds and the failures
/// match `adviseHugePages`, because both go through one advice path.
pub fn avoidHugePages(mapping: []align(std.heap.page_size_min) u8) AdviseError!void {
    return advisePageSize(mapping, false);
}

fn advisePageSize(
    mapping: []align(std.heap.page_size_min) u8,
    huge: bool,
) AdviseError!void {
    const source: observe.Source = if (huge) .huge_pages else .small_pages;
    if (mapping.len == 0) return;
    const return_address = @returnAddress();
    const result: AdviseError!void = switch (builtin.os.tag) {
        .linux => advisePageSizeLinux(mapping, huge),
        else => error.UnsupportedPlatform,
    };
    result catch |err| {
        recordOperation(
            .advise,
            source,
            @intFromPtr(mapping.ptr),
            mapping.len,
            return_address,
            false,
        );
        return err;
    };
    recordOperation(
        .advise,
        source,
        @intFromPtr(mapping.ptr),
        mapping.len,
        return_address,
        true,
    );
}

fn recordMap(
    source: observe.Source,
    address: usize,
    len: usize,
    return_address: usize,
    succeeded: bool,
) void {
    recordOperation(
        .map,
        source,
        address,
        len,
        return_address,
        succeeded,
    );
}

fn recordOperation(
    operation: observe.Operation,
    source: observe.Source,
    address: usize,
    len: usize,
    return_address: usize,
    succeeded: bool,
) void {
    observe.record(.{
        .operation = operation,
        .source = source,
        .address = address,
        .len = len,
        .return_address = return_address,
        .succeeded = succeeded,
    });
}

fn mapAnonymousLinux(aligned_len: usize, protection: Protection, options: MappingOptions) MapError![]align(std.heap.page_size_min) u8 {
    const linux = std.os.linux;
    const flags = try anonymousMapFlags(linux.MAP, options);
    const rc = linux.mmap(
        if (options.address) |address| @ptrCast(address) else null,
        aligned_len,
        linuxProtection(protection),
        flags,
        -1,
        0,
    );
    const err = linux.errno(rc);
    if (err == .SUCCESS) {
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
        return ptr[0..aligned_len];
    }
    return mapErrorFromErrno(err);
}

fn mapPrivateFileLinux(
    descriptor: std.posix.fd_t,
    aligned_len: usize,
    protection: Protection,
    options: FileMappingOptions,
) MapError![]align(std.heap.page_size_min) u8 {
    const linux = std.os.linux;
    const flags = try privateFileMapFlags(linux.MAP, options);
    const offset = std.math.cast(i64, options.offset) orelse return error.MapFailed;
    const rc = linux.mmap(
        if (options.address) |address| @ptrCast(address) else null,
        aligned_len,
        linuxProtection(protection),
        flags,
        descriptor,
        offset,
    );
    const err = linux.errno(rc);
    if (err == .SUCCESS) {
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
        return ptr[0..aligned_len];
    }
    return mapErrorFromErrno(err);
}

fn mapSharedFileLinux(
    descriptor: std.posix.fd_t,
    aligned_len: usize,
    protection: Protection,
    options: FileMappingOptions,
) MapError![]align(std.heap.page_size_min) u8 {
    const linux = std.os.linux;
    const flags = try sharedFileMapFlags(linux.MAP, options);
    const offset = std.math.cast(i64, options.offset) orelse return error.MapFailed;
    const rc = linux.mmap(
        if (options.address) |address| @ptrCast(address) else null,
        aligned_len,
        linuxProtection(protection),
        flags,
        descriptor,
        offset,
    );
    const err = linux.errno(rc);
    if (err == .SUCCESS) {
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
        return ptr[0..aligned_len];
    }
    return mapErrorFromErrno(err);
}

fn unmapLinux(mapping: []align(std.heap.page_size_min) u8) void {
    const rc = std.os.linux.munmap(mapping.ptr, mapping.len);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return,
        .INVAL, .NOMEM => unreachable,
        else => unreachable,
    }
}

fn protectLinux(mapping: []align(std.heap.page_size_min) u8, protection: Protection) ProtectError!void {
    const rc = std.os.linux.mprotect(mapping.ptr, mapping.len, linuxProtection(protection));
    const err = std.os.linux.errno(rc);
    if (err == .SUCCESS) return;
    return protectErrorFromErrno(err);
}

fn linuxProtection(protection: Protection) std.os.linux.PROT {
    return .{
        .READ = protection.read,
        .WRITE = protection.write,
        .EXEC = protection.execute,
    };
}

fn mapAnonymousPosix(aligned_len: usize, protection: Protection, options: MappingOptions) MapError![]align(std.heap.page_size_min) u8 {
    const flags = try anonymousMapFlags(std.posix.MAP, options);
    return std.posix.mmap(
        options.address,
        aligned_len,
        posixProtection(protection),
        flags,
        -1,
        0,
    ) catch |err| return mapErrorFromMMap(err);
}

fn mapPrivateFilePosix(
    descriptor: std.posix.fd_t,
    aligned_len: usize,
    protection: Protection,
    options: FileMappingOptions,
) MapError![]align(std.heap.page_size_min) u8 {
    const flags = try privateFileMapFlags(std.posix.MAP, options);
    return std.posix.mmap(
        options.address,
        aligned_len,
        posixProtection(protection),
        flags,
        descriptor,
        options.offset,
    ) catch |err| return mapErrorFromMMap(err);
}

fn mapSharedFilePosix(
    descriptor: std.posix.fd_t,
    aligned_len: usize,
    protection: Protection,
    options: FileMappingOptions,
) MapError![]align(std.heap.page_size_min) u8 {
    const flags = try sharedFileMapFlags(std.posix.MAP, options);
    return std.posix.mmap(
        options.address,
        aligned_len,
        posixProtection(protection),
        flags,
        descriptor,
        options.offset,
    ) catch |err| return mapErrorFromMMap(err);
}

fn unmapPosix(mapping: []align(std.heap.page_size_min) u8) void {
    std.posix.munmap(mapping);
}

fn protectPosix(mapping: []align(std.heap.page_size_min) u8, protection: Protection) ProtectError!void {
    const err = std.posix.errno(std.posix.system.mprotect(
        @ptrCast(mapping.ptr),
        mapping.len,
        posixProtection(protection),
    ));
    if (err == .SUCCESS) return;
    return protectErrorFromErrno(err);
}

fn posixProtection(protection: Protection) std.posix.PROT {
    return .{
        .READ = protection.read,
        .WRITE = protection.write,
        .EXEC = protection.execute,
    };
}

fn discardLinux(mapping: []align(std.heap.page_size_min) u8) DiscardError!void {
    if (comptime @hasDecl(std.os.linux.MADV, "FREE")) {
        if (try adviseLinux(mapping, std.os.linux.MADV.FREE)) return;
    }

    if (comptime @hasDecl(std.os.linux.MADV, "DONTNEED")) {
        if (try adviseLinux(mapping, std.os.linux.MADV.DONTNEED)) return;
        return error.UnsupportedPlatform;
    }

    return error.UnsupportedPlatform;
}

fn discardPosix(mapping: []align(std.heap.page_size_min) u8) DiscardError!void {
    if (comptime @hasDecl(std.posix.MADV, "FREE")) {
        if (try advisePosix(mapping, std.posix.MADV.FREE)) return;
    }

    if (comptime @hasDecl(std.posix.MADV, "DONTNEED")) {
        if (try advisePosix(mapping, std.posix.MADV.DONTNEED)) return;
        return error.UnsupportedPlatform;
    }

    return error.UnsupportedPlatform;
}

fn adviseLinux(mapping: []align(std.heap.page_size_min) u8, advice: u32) DiscardError!bool {
    const err = std.os.linux.errno(std.os.linux.madvise(mapping.ptr, mapping.len, advice));
    return switch (err) {
        .SUCCESS => true,
        .INVAL, .NOSYS => false,
        .PERM => error.PermissionDenied,
        .ACCES => error.AccessDenied,
        .NOMEM => error.OutOfMemory,
        else => error.DiscardFailed,
    };
}

fn advisePosix(mapping: []align(std.heap.page_size_min) u8, advice: u32) DiscardError!bool {
    std.posix.madvise(mapping.ptr, mapping.len, advice) catch |err| switch (err) {
        error.InvalidSyscall, error.MadviseUnavailable => return false,
        error.PermissionDenied => return error.PermissionDenied,
        error.AccessDenied => return error.AccessDenied,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DiscardFailed,
    };
    return true;
}

fn advisePageSizeLinux(
    mapping: []align(std.heap.page_size_min) u8,
    huge: bool,
) AdviseError!void {
    const linux = std.os.linux;
    if (comptime !@hasDecl(linux.MADV, "HUGEPAGE")) return error.UnsupportedPlatform;
    const advice: u32 = if (huge) linux.MADV.HUGEPAGE else linux.MADV.NOHUGEPAGE;
    const err = linux.errno(linux.madvise(mapping.ptr, mapping.len, advice));
    return switch (err) {
        .SUCCESS => {},
        .INVAL, .NOSYS => error.UnsupportedPlatform,
        .NOMEM => error.InvalidMapping,
        .AGAIN => error.OutOfMemory,
        .PERM => error.PermissionDenied,
        .ACCES => error.AccessDenied,
        else => error.AdviseFailed,
    };
}

fn decommitLinux(mapping: []align(std.heap.page_size_min) u8) DecommitError!void {
    const remapped = mapAnonymousLinux(mapping.len, .{}, .{
        .no_reserve = true,
        .fixed = true,
        .address = mapping.ptr,
    }) catch |err| switch (err) {
        error.UnsupportedPlatform => return protectLinux(mapping, .{}),
        else => return err,
    };
    std.debug.assert(remapped.ptr == mapping.ptr);
}

fn decommitPosix(mapping: []align(std.heap.page_size_min) u8) DecommitError!void {
    const remapped = mapAnonymousPosix(mapping.len, .{}, .{
        .no_reserve = true,
        .fixed = true,
        .address = mapping.ptr,
    }) catch |err| switch (err) {
        error.UnsupportedPlatform => return protectPosix(mapping, .{}),
        else => return err,
    };
    std.debug.assert(remapped.ptr == mapping.ptr);
}

fn anonymousMapFlags(comptime Map: type, options: MappingOptions) MapError!Map {
    var flags: Map = .{ .TYPE = if (options.shared) .SHARED else .PRIVATE, .ANONYMOUS = true };
    if (options.no_reserve) {
        if (comptime @hasField(Map, "NORESERVE")) flags.NORESERVE = true;
    }
    if (options.no_replace) {
        if (comptime @hasField(Map, "FIXED_NOREPLACE")) {
            flags.FIXED_NOREPLACE = true;
        } else {
            return error.UnsupportedPlatform;
        }
    } else if (options.fixed) {
        if (comptime @hasField(Map, "FIXED")) {
            flags.FIXED = true;
        } else {
            return error.UnsupportedPlatform;
        }
    }
    return flags;
}

fn privateFileMapFlags(comptime Map: type, options: FileMappingOptions) MapError!Map {
    var flags: Map = .{ .TYPE = .PRIVATE };
    if (options.fixed) {
        if (comptime @hasField(Map, "FIXED")) {
            flags.FIXED = true;
        } else {
            return error.UnsupportedPlatform;
        }
    }
    return flags;
}

fn sharedFileMapFlags(comptime Map: type, options: FileMappingOptions) MapError!Map {
    var flags: Map = .{ .TYPE = .SHARED };
    if (options.fixed) {
        if (comptime @hasField(Map, "FIXED")) {
            flags.FIXED = true;
        } else {
            return error.UnsupportedPlatform;
        }
    }
    return flags;
}

fn mapErrorFromErrno(err: std.posix.E) MapError {
    return switch (err) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOMEM => error.OutOfMemory,
        else => error.MapFailed,
    };
}

fn mapErrorFromMMap(err: std.posix.MMapError) MapError {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.OutOfMemory => error.OutOfMemory,
        error.MemoryMappingNotSupported => error.UnsupportedPlatform,
        else => error.MapFailed,
    };
}

fn protectErrorFromErrno(err: std.posix.E) ProtectError {
    return switch (err) {
        .ACCES => error.AccessDenied,
        .INVAL => error.InvalidMapping,
        .PERM => error.PermissionDenied,
        .NOMEM => error.OutOfMemory,
        else => error.ProtectFailed,
    };
}

/// The one probe the huge-page tests share: whether this kernel takes the
/// advice on a live anonymous mapping. A kernel built without transparent huge
/// pages refuses it there.
fn hugePageAdviceSupported() !bool {
    const probe = try mapAnonymous(pageSize(), .{ .read = true, .write = true });
    defer unmap(probe);
    adviseHugePages(probe) catch |err| switch (err) {
        error.UnsupportedPlatform => return false,
        else => return err,
    };
    return true;
}
