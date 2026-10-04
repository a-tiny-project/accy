pub const supported = false;
pub const alignment = 4 * @sizeOf(u64);
pub const signature: u32 = 0;
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

pub fn registrationPolicy() RegistrationPolicy {
    return .unsupported;
}

pub fn currentState() RegistrationState {
    return .unsupported;
}

pub fn registered() bool {
    return false;
}

pub fn ensureRegistered() RegisterError!*Area {
    return error.UnsupportedPlatform;
}

pub fn currentArea() ?*Area {
    return null;
}

pub fn currentCpu() ?u32 {
    return null;
}

pub fn currentNode() ?u32 {
    return null;
}

pub fn currentMemoryMapConcurrencyId() ?u32 {
    return null;
}

pub fn setCriticalSection(section: *align(alignment) const CriticalSection) RegisterError!void {
    _ = section;
    return error.UnsupportedPlatform;
}

pub fn clearCriticalSection() void {}

pub fn validCpuId(cpu_id: u32) bool {
    return cpu_id != cpu_id_uninitialized and cpu_id != cpu_id_registration_failed;
}
