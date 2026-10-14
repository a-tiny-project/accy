const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;
const libc = if (builtin.link_libc) struct {
    extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
} else struct {};

pub const supported = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;
pub const alignment = 4 * @sizeOf(u64);
pub const signature: u32 = switch (builtin.cpu.arch) {
    .x86_64 => 0x53053053,
    else => 0,
};
pub const cpu_id_uninitialized: u32 = @bitCast(@as(i32, -1));
pub const cpu_id_registration_failed: u32 = @bitCast(@as(i32, -2));

pub const Flags = struct {
    pub const unregister: u32 = 1 << 0;
};

pub const CriticalSectionFlags = struct {
    pub const no_restart_on_preempt: u32 = 1 << 0;
    pub const no_restart_on_signal: u32 = 1 << 1;
    pub const no_restart_on_migrate: u32 = 1 << 2;
};

pub const CriticalSection = extern struct {
    version: u32 = 0,
    flags: u32 = 0,
    start_ip: u64 = 0,
    post_commit_offset: u64 = 0,
    abort_ip: u64 = 0,
    end: [0]u8 align(alignment) = .{},
};

pub const Area = extern struct {
    cpu_id_start: u32 = cpu_id_uninitialized,
    cpu_id: u32 = cpu_id_uninitialized,
    rseq_cs: u64 = 0,
    flags: u32 = 0,
    node_id: u32 = 0,
    mm_cid: u32 = 0,
    end: [0]u8 align(alignment) = .{},
};

pub const RegistrationState = enum {
    unregistered,
    direct_registered,
    libc_registered,
    unsupported,
    system_outdated,
    already_registered,
    kernel_rejected_area,
    permission_denied,
    failed,
};

pub const RegistrationPolicy = enum {
    unsupported,
    direct_syscall,
    direct_syscall_with_libc_owner_detection,
};

pub const RegisterError = error{
    UnsupportedPlatform,
    SystemOutdated,
    AlreadyRegistered,
    KernelRejectedArea,
    PermissionDenied,
    RegistrationFailed,
};

threadlocal var area: Area align(alignment) = .{};
threadlocal var state: RegistrationState = .unregistered;

pub fn registrationPolicy() RegistrationPolicy {
    if (comptime !supported) return .unsupported;
    if (comptime builtin.link_libc) return .direct_syscall_with_libc_owner_detection;
    return .direct_syscall;
}

pub fn currentState() RegistrationState {
    return state;
}

pub fn registered() bool {
    return state == .direct_registered or state == .libc_registered;
}

pub fn ensureRegistered() RegisterError!*Area {
    switch (state) {
        .direct_registered => return &area,
        .libc_registered => if (libcCurrentArea()) |current| return current else {
            failRegistration(.failed);
            return error.RegistrationFailed;
        },
        .unsupported => return error.UnsupportedPlatform,
        .system_outdated => return error.SystemOutdated,
        .already_registered => return error.AlreadyRegistered,
        .kernel_rejected_area => return error.KernelRejectedArea,
        .permission_denied => return error.PermissionDenied,
        .failed => return error.RegistrationFailed,
        .unregistered => {},
    }

    if (comptime !supported) {
        state = .unsupported;
        return error.UnsupportedPlatform;
    }

    if (libcCurrentArea()) |current| {
        state = .libc_registered;
        return current;
    }

    area = .{};
    const rc = linux.syscall4(.rseq, @intFromPtr(&area), @sizeOf(Area), 0, signature);
    switch (linux.errno(rc)) {
        .SUCCESS => {
            state = .direct_registered;
            return &area;
        },
        .NOSYS => {
            failRegistration(.system_outdated);
            return error.SystemOutdated;
        },
        .BUSY => {
            if (libcCurrentArea()) |current| {
                state = .libc_registered;
                return current;
            }
            failRegistration(.already_registered);
            return error.AlreadyRegistered;
        },
        .INVAL, .FAULT => {
            failRegistration(.kernel_rejected_area);
            return error.KernelRejectedArea;
        },
        .PERM, .ACCES => {
            failRegistration(.permission_denied);
            return error.PermissionDenied;
        },
        else => {
            failRegistration(.failed);
            return error.RegistrationFailed;
        },
    }
}

pub fn currentArea() ?*Area {
    return switch (state) {
        .direct_registered => &area,
        .libc_registered => libcCurrentArea(),
        else => null,
    };
}

pub fn currentCpu() ?u32 {
    const current = ensureRegistered() catch return null;
    const cpu_id = current.cpu_id;
    if (!validCpuId(cpu_id)) return null;
    return cpu_id;
}

pub fn currentNode() ?u32 {
    const current = ensureRegistered() catch return null;
    return current.node_id;
}

pub fn currentMemoryMapConcurrencyId() ?u32 {
    const current = ensureRegistered() catch return null;
    return current.mm_cid;
}

pub fn setCriticalSection(section: *align(alignment) const CriticalSection) RegisterError!void {
    const current = try ensureRegistered();
    @atomicStore(u64, &current.rseq_cs, @intFromPtr(section), .release);
}

pub fn clearCriticalSection() void {
    const current = currentArea() orelse return;
    @atomicStore(u64, &current.rseq_cs, 0, .release);
}

pub fn validCpuId(cpu_id: u32) bool {
    return cpu_id != cpu_id_uninitialized and cpu_id != cpu_id_registration_failed;
}

fn failRegistration(next_state: RegistrationState) void {
    area.cpu_id_start = cpu_id_registration_failed;
    area.cpu_id = cpu_id_registration_failed;
    state = next_state;
}

fn libcCurrentArea() ?*Area {
    if (comptime !supported) return null;
    if (comptime !builtin.link_libc) return null;

    const symbols = libcOwnerSymbols() orelse return null;
    return existingLibcOwnedArea(symbols, threadPointer());
}

const LibcOwnerSymbols = struct {
    size: *const c_uint,
    offset: *const isize,
};

fn libcOwnerSymbols() ?LibcOwnerSymbols {
    const size_raw = libc.dlsym(null, "__rseq_size") orelse return null;
    const offset_raw = libc.dlsym(null, "__rseq_offset") orelse return null;
    return .{
        .size = @ptrCast(@alignCast(size_raw)),
        .offset = @ptrCast(@alignCast(offset_raw)),
    };
}

fn existingLibcOwnedArea(symbols: LibcOwnerSymbols, thread_pointer: usize) ?*Area {
    if (symbols.size.* < @sizeOf(Area)) return null;
    const address = offsetAddress(thread_pointer, symbols.offset.*);
    const current: *Area = @ptrFromInt(address);
    if (!validCpuId(current.cpu_id)) return null;
    return current;
}

fn threadPointer() usize {
    return asm volatile ("movq %%fs:0, %[value]"
        : [value] "=&r" (-> usize),
    );
}

fn offsetAddress(base: usize, offset: isize) usize {
    if (offset >= 0) return base + @as(usize, @intCast(offset));
    return base - @as(usize, @intCast(-offset));
}
