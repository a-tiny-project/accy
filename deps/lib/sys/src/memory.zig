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

test "page size query matches the host" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectEqual(std.heap.pageSize(), pageSize());
}

test "page size detection finds variable Linux page alignments" {
    try std.testing.expectEqual(@as(usize, 4 * 1024), detectPageSize(4 * 1024, 64 * 1024, PageAlignmentProbeFixture{ .expected = 4 * 1024 }));
    try std.testing.expectEqual(@as(usize, 16 * 1024), detectPageSize(4 * 1024, 64 * 1024, PageAlignmentProbeFixture{ .expected = 16 * 1024 }));
    try std.testing.expectEqual(@as(usize, 64 * 1024), detectPageSize(4 * 1024, 64 * 1024, PageAlignmentProbeFixture{ .expected = 64 * 1024 }));
    try std.testing.expectEqual(@as(usize, 64 * 1024), detectPageSize(4 * 1024, 64 * 1024, PageAlignmentProbeFixture{ .expected = 4 * 1024, .fail = true }));
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
    var flags: Map = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
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

test "anonymous mapping can be written and unmapped" {
    const mapping = try mapAnonymous(17, .{ .read = true, .write = true });
    defer unmap(mapping);

    try std.testing.expect(mapping.len >= pageSize());
    mapping[0] = 0x42;
    mapping[16] = 0x24;
    try std.testing.expectEqual(@as(u8, 0x42), mapping[0]);
    try std.testing.expectEqual(@as(u8, 0x24), mapping[16]);
}

test "private file mapping can read bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "mapped.bin",
        .data = "mapped",
    });

    var file = try tmp.dir.openFile(std.Options.debug_io, "mapped.bin", .{});
    defer file.close(std.Options.debug_io);

    const mapping = mapPrivateFile(file.handle, 6, .{ .read = true }, 0) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer unmap(mapping);

    try std.testing.expectEqualStrings("mapped", mapping[0..6]);
}

test "linux file mapping decodes raw syscall failures" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    try std.testing.expectError(
        error.MapFailed,
        mapPrivateFile(-1, pageSize(), .{ .read = true }, 0),
    );
    try std.testing.expectError(
        error.MapFailed,
        mapSharedFile(-1, pageSize(), .{ .read = true }, 0),
    );
}

test "shared file mapping can write bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.Options.debug_io, "mapped.bin", .{ .read = true });
    defer file.close(std.Options.debug_io);
    try file.setLength(std.Options.debug_io, 6);

    const mapping = mapSharedFile(file.handle, 6, .{ .read = true, .write = true }, 0) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    @memcpy(mapping[0..6], "mapped");
    unmap(mapping);

    const bytes = try tmp.dir.readFileAlloc(std.Options.debug_io, "mapped.bin", std.testing.allocator, .limited(7));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("mapped", bytes);
}

test "reserved address space can be committed discarded and decommitted" {
    const mapping = try reserveAddressSpace(2 * pageSize());
    defer unmap(mapping);

    const page = mapping[0..pageSize()];
    try protect(page, .{ .read = true, .write = true });
    page[0] = 0x5a;
    try std.testing.expectEqual(@as(u8, 0x5a), page[0]);

    try discard(page);
    try decommit(page);
}

test "fixed reservation claims only an unmapped address" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const page = pageSize();
    const original = try reserveAddressSpace(2 * page);
    const occupied: []align(std.heap.page_size_min) u8 = @alignCast(original[0..page]);
    const vacant: []align(std.heap.page_size_min) u8 = @alignCast(original[page..][0..page]);
    unmap(vacant);
    defer unmap(occupied);
    try std.testing.expectError(error.MapFailed, reserveAddressSpaceAt(occupied.ptr, page));
    const claimed = try reserveAddressSpaceAt(vacant.ptr, page);
    defer unmap(claimed);
    try std.testing.expectEqual(vacant.ptr, claimed.ptr);
}

test "discard to zero clears an anonymous page" {
    if (!anonymousMappingSupported()) return error.SkipZigTest;
    const mapping = try mapAnonymous(pageSize(), .{ .read = true, .write = true });
    defer unmap(mapping);
    @memset(mapping, 0xa5);
    if (builtin.os.tag == .linux) {
        try discardToZero(mapping);
        try std.testing.expect(std.mem.allEqual(u8, mapping, 0));
    } else {
        try std.testing.expectError(error.UnsupportedPlatform, discardToZero(mapping));
        try std.testing.expect(std.mem.allEqual(u8, mapping, 0xa5));
    }
}

test "huge page advice keeps an anonymous mapping usable" {
    if (!anonymousMappingSupported()) return error.SkipZigTest;
    const mapping = try mapAnonymous(4 * 1024 * 1024, .{ .read = true, .write = true });
    defer unmap(mapping);

    adviseHugePages(mapping) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    mapping[0] = 0x11;
    mapping[mapping.len - 1] = 0x22;
    try std.testing.expectEqual(@as(u8, 0x11), mapping[0]);
    try std.testing.expectEqual(@as(u8, 0x22), mapping[mapping.len - 1]);
    try avoidHugePages(mapping);
    try std.testing.expectEqual(@as(u8, 0x11), mapping[0]);
    try std.testing.expectEqual(@as(u8, 0x22), mapping[mapping.len - 1]);
    try adviseHugePages(mapping[0..0]);
    try avoidHugePages(mapping[0..0]);
}

test "linux huge page advice rejects an unmapped range" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const mapping = try mapAnonymous(pageSize(), .{ .read = true, .write = true });
    unmap(mapping);

    try std.testing.expectError(error.InvalidMapping, adviseHugePages(mapping));
    try std.testing.expectError(error.InvalidMapping, avoidHugePages(mapping));
}

test "huge page advice reports its range without a mapping event" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const mapping = try mapAnonymous(pageSize(), .{ .read = true, .write = true });
    defer unmap(mapping);
    const Capture = struct {
        event: ?observe.Event = null,
        count: u8 = 0,

        fn accept(context: *anyopaque, event: observe.Event) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.event = event;
            self.count += 1;
        }
    };
    var capture: Capture = .{};
    const sink: observe.Sink = .{ .context = &capture, .record = Capture.accept };
    var session = try observe.install(&sink);
    defer session.deinit();
    try avoidHugePages(mapping);
    try std.testing.expectEqual(@as(u8, 1), capture.count);
    const event = capture.event.?;
    try std.testing.expectEqual(observe.Operation.advise, event.operation);
    try std.testing.expectEqual(observe.Source.small_pages, event.source);
    try std.testing.expectEqual(@intFromPtr(mapping.ptr), event.address);
    try std.testing.expectEqual(mapping.len, event.len);
    try std.testing.expect(event.succeeded);
}

test "owned page allocator supports page and larger alignments" {
    if (!anonymousMappingSupported()) return error.SkipZigTest;
    const ordinary = try page_allocator.alloc(u8, 33);
    try std.testing.expect(std.mem.isAligned(
        @intFromPtr(ordinary.ptr),
        pageSize(),
    ));
    page_allocator.free(ordinary);

    const large_alignment = comptime std.mem.Alignment.fromByteUnits(
        std.heap.page_size_max * 4,
    );
    const aligned = try page_allocator.alignedAlloc(
        u8,
        large_alignment,
        pageSize() + 1,
    );
    try std.testing.expect(std.mem.isAligned(
        @intFromPtr(aligned.ptr),
        large_alignment.toByteUnits(),
    ));
    page_allocator.free(aligned);
}
