const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");

const linux = std.os.linux;
const posix = std.posix;
const native_os = builtin.os.tag;
const system = posix.system;

pub const required_capabilities = switch (native_os) {
    .linux => capabilities.noLibc(&.{.descriptors}),
    else => capabilities.host(&.{.descriptors}),
};

pub const Descriptor = posix.fd_t;
pub const Mode = posix.mode_t;
pub const OpenFlags = posix.O;
pub const OpenError = posix.OpenError || error{UnsupportedPlatform};
pub const PipeFlags = posix.O;
pub const cwd_descriptor = posix.AT.FDCWD;

pub const PipeOptions = struct {
    close_on_exec: bool = true,
    nonblocking: bool = false,
};

pub const ReadError = error{
    UnsupportedPlatform,
    WouldBlock,
    InputOutput,
    BrokenPipe,
    ConnectionResetByPeer,
    ReadFailed,
};

pub const WriteError = error{
    UnsupportedPlatform,
    WouldBlock,
    BrokenPipe,
    WriteFailed,
};

pub const DuplicateError = error{
    UnsupportedPlatform,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    DuplicateFailed,
};

pub const PipeError = error{
    UnsupportedPlatform,
    InvalidFlags,
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
    PipeFailed,
};

pub const FlagError = error{
    UnsupportedPlatform,
    InvalidFlags,
    FlagUpdateFailed,
};

pub const ChangeDirectoryError = error{
    UnsupportedPlatform,
    InvalidDescriptor,
    NotDir,
    ChangeDirectoryFailed,
};

pub const DirectoryEmptyError = error{
    UnsupportedPlatform,
    InvalidDescriptor,
    NotDir,
    InvalidDirectoryEntry,
    DirectoryReadFailed,
    DirectoryReadCapacity,
};

pub const LockMode = enum {
    shared,
    exclusive,
};

pub const LockError = error{
    UnsupportedPlatform,
    InvalidDescriptor,
    LockFailed,
};

pub const Identity = struct {
    device_major: u32,
    device_minor: u32,
    inode: u64,
    regular: bool,
};

pub const FileKind = enum {
    regular,
    directory,
    symbolic_link,
    other,
};

pub const Status = struct {
    identity: Identity,
    kind: FileKind,
    allocated_bytes: u64,
    modified_ns: i128,
    links: u64,
};

pub const FilesystemSpace = struct {
    total_bytes: u64,
    free_bytes: u64,
    available_bytes: u64,
};

const darwin_mount_path_bytes_max: usize = 1024;
const directory_read_attempts_max: u8 = 4;

pub const DarwinMountIdentity = struct {
    filesystem_id: [2]i32,
    mounted_on_length: u16,
    mounted_on: [darwin_mount_path_bytes_max]u8,

    pub fn path(identity_value: *const DarwinMountIdentity) []const u8 {
        std.debug.assert(identity_value.mounted_on_length > 0);
        std.debug.assert(identity_value.mounted_on_length < darwin_mount_path_bytes_max);
        return identity_value.mounted_on[0..identity_value.mounted_on_length];
    }
};

pub const MountIdentity = union(enum) {
    linux: u64,
    darwin: DarwinMountIdentity,

    pub fn eql(a: MountIdentity, b: MountIdentity) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .linux => |mount_id| mount_id == b.linux,
            .darwin => |identity_value| std.mem.eql(
                i32,
                &identity_value.filesystem_id,
                &b.darwin.filesystem_id,
            ) and std.mem.eql(u8, identity_value.path(), b.darwin.path()),
        };
    }
};

const DeviceParts = struct {
    major: u32,
    minor: u32,
};

pub const IdentityError = error{
    UnsupportedPlatform,
    InvalidDescriptor,
    IdentityUnavailable,
};

pub const StatusError = error{
    UnsupportedPlatform,
    InvalidDescriptor,
    FileNotFound,
    NotDir,
    SymLinkLoop,
    NameTooLong,
    BadPathName,
    StatusUnavailable,
    Overflow,
};

pub const FilesystemSpaceError = error{
    UnsupportedPlatform,
    InvalidDescriptor,
    SpaceUnavailable,
    Overflow,
};

pub const MountIdentityError = error{
    UnsupportedPlatform,
    InvalidDescriptor,
    MountIdentityUnavailable,
};

pub const SocketPairError = error{
    UnsupportedPlatform,
    AddressFamilyUnsupported,
    ProtocolUnsupportedBySystem,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolUnsupportedByAddressFamily,
    SocketModeUnsupported,
    SocketPairFailed,
};

pub const SocketPairOptions = struct {
    close_on_exec: bool = true,
};

pub const DescriptorPolicy = enum {
    unsupported,
    linux_syscall,
    posix_host,
};

const is_darwin = switch (native_os) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
    else => false,
};
const socket_flags_unsupported = is_darwin or native_os == .haiku;

const LinuxFilesystemStatus = extern struct {
    filesystem_type: i64,
    block_size: i64,
    blocks: i64,
    blocks_free: i64,
    blocks_available: i64,
    files: i64,
    files_free: i64,
    filesystem_id: [2]i32,
    name_length: i64,
    fragment_size: i64,
    flags: i64,
    spare: [4]i64,
};

const DarwinFilesystemStatus = extern struct {
    block_size: u32,
    io_size: i32,
    blocks: u64,
    blocks_free: u64,
    blocks_available: u64,
    files: u64,
    files_free: u64,
    filesystem_id: [2]i32,
    owner: u32,
    filesystem_type: u32,
    flags: u32,
    filesystem_subtype: u32,
    type_name: [16]u8,
    mounted_on: [1024]u8,
    mounted_from: [1024]u8,
    flags_extended: u32,
    reserved: [7]u32,
};

const DarwinFilesystemSystem = struct {
    extern "c" fn fstatfs(
        descriptor: Descriptor,
        observed: *DarwinFilesystemStatus,
    ) c_int;

    extern "c" fn @"fstatfs$INODE64"(
        descriptor: Descriptor,
        observed: *DarwinFilesystemStatus,
    ) c_int;
};

comptime {
    if (native_os == .linux and supportedFilesystemSpaceArchitecture()) {
        std.debug.assert(@sizeOf(LinuxFilesystemStatus) == 120);
        std.debug.assert(@offsetOf(LinuxFilesystemStatus, "block_size") == 8);
        std.debug.assert(@offsetOf(LinuxFilesystemStatus, "blocks") == 16);
        std.debug.assert(@offsetOf(LinuxFilesystemStatus, "blocks_free") == 24);
        std.debug.assert(@offsetOf(LinuxFilesystemStatus, "blocks_available") == 32);
        std.debug.assert(@offsetOf(LinuxFilesystemStatus, "fragment_size") == 72);
    }

    if (is_darwin and supportedFilesystemSpaceArchitecture()) {
        std.debug.assert(@sizeOf(DarwinFilesystemStatus) == 2168);
        std.debug.assert(@offsetOf(DarwinFilesystemStatus, "block_size") == 0);
        std.debug.assert(@offsetOf(DarwinFilesystemStatus, "blocks") == 8);
        std.debug.assert(@offsetOf(DarwinFilesystemStatus, "blocks_free") == 16);
        std.debug.assert(@offsetOf(DarwinFilesystemStatus, "blocks_available") == 24);
        std.debug.assert(@offsetOf(DarwinFilesystemStatus, "filesystem_id") == 48);
        std.debug.assert(@offsetOf(DarwinFilesystemStatus, "mounted_on") == 88);
        std.debug.assert(@offsetOf(DarwinFilesystemStatus, "flags_extended") == 2136);
    }
}

pub fn descriptorPolicy() DescriptorPolicy {
    return switch (native_os) {
        .windows, .wasi, .freestanding => .unsupported,
        .linux => .linux_syscall,
        else => .posix_host,
    };
}

test "descriptor capability follows platform ABI" {
    const expected: capabilities.CapabilityTier = if (native_os == .linux) .no_libc else .host;
    try std.testing.expectEqual(expected, required_capabilities.tier);
}

test "Darwin device identity preserves major and minor fields" {
    const parts = darwinDeviceParts(0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0x12), parts.major);
    try std.testing.expectEqual(@as(u32, 0x34_5678), parts.minor);
}

pub fn close(descriptor: Descriptor) void {
    switch (descriptorPolicy()) {
        .unsupported => {},
        .linux_syscall => closeLinux(descriptor),
        .posix_host => closePosix(descriptor),
    }
}

pub fn standardInput() Descriptor {
    return posix.STDIN_FILENO;
}

pub fn standardOutput() Descriptor {
    return posix.STDOUT_FILENO;
}

pub fn standardError() Descriptor {
    return posix.STDERR_FILENO;
}

pub fn openAt(
    directory: Descriptor,
    path: []const u8,
    flags: OpenFlags,
    mode: Mode,
) OpenError!Descriptor {
    if (comptime descriptorPolicy() == .unsupported) return error.UnsupportedPlatform;
    return posix.openat(directory, path, flags, mode);
}

pub fn openAtZ(
    directory: Descriptor,
    path: [*:0]const u8,
    flags: OpenFlags,
    mode: Mode,
) OpenError!Descriptor {
    if (comptime descriptorPolicy() == .unsupported) return error.UnsupportedPlatform;
    return posix.openatZ(directory, path, flags, mode);
}

pub fn changeWorkingDirectory(descriptor: Descriptor) ChangeDirectoryError!void {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => changeWorkingDirectoryLinux(descriptor),
        .posix_host => changeWorkingDirectoryPosix(descriptor),
    };
}

pub fn setCloseOnExec(descriptor: Descriptor) FlagError!void {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => setCloseOnExecLinux(descriptor),
        .posix_host => setCloseOnExecPosix(descriptor),
    };
}

pub fn setInheritOnExec(descriptor: Descriptor) FlagError!void {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => setInheritOnExecLinux(descriptor),
        .posix_host => setInheritOnExecPosix(descriptor),
    };
}

pub fn lock(
    descriptor: Descriptor,
    mode: LockMode,
    blocking: bool,
) LockError!bool {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => lockLinux(descriptor, mode, blocking),
        .posix_host => lockPosix(descriptor, mode, blocking),
    };
}

pub fn identity(descriptor: Descriptor) IdentityError!Identity {
    return switch (comptime native_os) {
        .linux => identityLinux(descriptor),
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => identityDarwin(descriptor),
        else => error.UnsupportedPlatform,
    };
}

pub fn status(descriptor: Descriptor) StatusError!Status {
    if (comptime native_os == .linux) {
        return statusLinux(descriptor, "", linux.AT.EMPTY_PATH);
    }
    if (comptime is_darwin) return statusDarwin(descriptor);
    return error.UnsupportedPlatform;
}

pub fn statusAt(directory: Descriptor, name: []const u8) StatusError!Status {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) {
        return error.BadPathName;
    }
    const name_z = std.posix.toPosixPath(name) catch return error.NameTooLong;
    if (comptime native_os == .linux) {
        return statusLinux(directory, &name_z, linux.AT.SYMLINK_NOFOLLOW);
    }
    if (comptime is_darwin) return statusAtDarwin(directory, &name_z);
    return error.UnsupportedPlatform;
}

pub fn filesystemSpace(descriptor: Descriptor) FilesystemSpaceError!FilesystemSpace {
    if (comptime native_os == .linux) return filesystemSpaceLinux(descriptor);
    if (comptime is_darwin) return filesystemSpaceDarwin(descriptor);
    return error.UnsupportedPlatform;
}

pub fn mountIdentity(descriptor: Descriptor) MountIdentityError!MountIdentity {
    if (comptime native_os == .linux) return mountIdentityLinux(descriptor);
    if (comptime is_darwin) return mountIdentityDarwin(descriptor);
    return error.UnsupportedPlatform;
}

pub fn directoryEmpty(descriptor: Descriptor) DirectoryEmptyError!bool {
    return switch (comptime native_os) {
        .linux => directoryEmptyLinux(descriptor),
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => directoryEmptyDarwin(descriptor),
        else => error.UnsupportedPlatform,
    };
}

fn changeWorkingDirectoryLinux(descriptor: Descriptor) ChangeDirectoryError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    return switch (linux.errno(linux.fchdir(descriptor))) {
        .SUCCESS => {},
        .BADF => error.InvalidDescriptor,
        .NOTDIR => error.NotDir,
        else => error.ChangeDirectoryFailed,
    };
}

fn changeWorkingDirectoryPosix(descriptor: Descriptor) ChangeDirectoryError!void {
    if (!@hasDecl(system, "fchdir") or @TypeOf(system.fchdir) == void) {
        return error.UnsupportedPlatform;
    }
    return switch (posix.errno(system.fchdir(descriptor))) {
        .SUCCESS => {},
        .BADF => error.InvalidDescriptor,
        .NOTDIR => error.NotDir,
        else => error.ChangeDirectoryFailed,
    };
}

fn directoryEmptyLinux(descriptor: Descriptor) DirectoryEmptyError!bool {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    var buffer: [1024]u8 align(@alignOf(linux.dirent64)) = undefined;
    for (0..directory_read_attempts_max) |_| {
        const result = linux.getdents64(descriptor, &buffer, buffer.len);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            .BADF => return error.InvalidDescriptor,
            .NOTDIR => return error.NotDir,
            else => return error.DirectoryReadFailed,
        }
        if (result == 0) return true;
        var index: usize = 0;
        while (index < result) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&buffer[index]);
            const header = @offsetOf(linux.dirent64, "name");
            if (entry.reclen <= header or entry.reclen > result - index) {
                return error.InvalidDirectoryEntry;
            }
            const padded: [*]const u8 = @ptrCast(&entry.name);
            const name = std.mem.sliceTo(padded[0 .. entry.reclen - header], 0);
            if (!dotDirectoryEntry(name) and entry.ino != 0) return false;
            index += entry.reclen;
        }
    }
    return error.DirectoryReadCapacity;
}

fn directoryEmptyDarwin(descriptor: Descriptor) DirectoryEmptyError!bool {
    if (comptime !is_darwin) return error.UnsupportedPlatform;
    var buffer: [2048]u8 align(@alignOf(std.c.dirent)) = undefined;
    var base: i64 = 0;
    for (0..directory_read_attempts_max) |_| {
        const result = system.getdirentries(descriptor, &buffer, buffer.len, &base);
        switch (posix.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            .BADF => return error.InvalidDescriptor,
            .NOTDIR => return error.NotDir,
            else => return error.DirectoryReadFailed,
        }
        if (result == 0) return true;
        const count: usize = @intCast(result);
        var index: usize = 0;
        while (index < count) {
            const entry: *align(1) const std.c.dirent = @ptrCast(&buffer[index]);
            if (entry.reclen == 0 or entry.reclen > count - index) {
                return error.InvalidDirectoryEntry;
            }
            const name = entry.name[0..entry.namlen];
            if (!dotDirectoryEntry(name) and entry.ino != 0) return false;
            index += entry.reclen;
        }
    }
    return error.DirectoryReadCapacity;
}

fn dotDirectoryEntry(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

fn identityLinux(descriptor: Descriptor) IdentityError!Identity {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    var stat = std.mem.zeroes(linux.Statx);
    const result = linux.statx(
        descriptor,
        "",
        linux.AT.EMPTY_PATH,
        linux.STATX.BASIC_STATS,
        &stat,
    );
    return switch (linux.errno(result)) {
        .SUCCESS => .{
            .device_major = stat.dev_major,
            .device_minor = stat.dev_minor,
            .inode = stat.ino,
            .regular = linux.S.ISREG(stat.mode),
        },
        .BADF => error.InvalidDescriptor,
        else => error.IdentityUnavailable,
    };
}

fn identityDarwin(descriptor: Descriptor) IdentityError!Identity {
    if (comptime !is_darwin) return error.UnsupportedPlatform;
    var stat = std.mem.zeroes(posix.Stat);
    return switch (posix.errno(system.fstat(descriptor, &stat))) {
        .SUCCESS => value: {
            const device: u32 = @bitCast(stat.dev);
            const parts = darwinDeviceParts(device);
            break :value .{
                .device_major = parts.major,
                .device_minor = parts.minor,
                .inode = @intCast(stat.ino),
                .regular = posix.S.ISREG(@intCast(stat.mode)),
            };
        },
        .BADF => error.InvalidDescriptor,
        else => error.IdentityUnavailable,
    };
}

fn statusLinux(
    directory: Descriptor,
    name: [*:0]const u8,
    flags: u32,
) StatusError!Status {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    while (true) {
        var observed = std.mem.zeroes(linux.Statx);
        const result = linux.statx(
            directory,
            name,
            flags,
            linux.STATX.BASIC_STATS,
            &observed,
        );
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (!observed.mask.TYPE or !observed.mask.MTIME or
                    !observed.mask.INO or !observed.mask.BLOCKS or
                    !observed.mask.NLINK)
                {
                    return error.StatusUnavailable;
                }
                const allocated_bytes = std.math.mul(
                    u64,
                    observed.blocks,
                    512,
                ) catch return error.Overflow;
                return .{
                    .identity = .{
                        .device_major = observed.dev_major,
                        .device_minor = observed.dev_minor,
                        .inode = observed.ino,
                        .regular = linux.S.ISREG(observed.mode),
                    },
                    .kind = kindLinux(observed.mode),
                    .allocated_bytes = allocated_bytes,
                    .modified_ns = @as(i128, observed.mtime.sec) * std.time.ns_per_s +
                        observed.mtime.nsec,
                    .links = observed.nlink,
                };
            },
            .INTR => {},
            .BADF => return error.InvalidDescriptor,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            else => return error.StatusUnavailable,
        }
    }
}

fn statusDarwin(descriptor: Descriptor) StatusError!Status {
    if (comptime !is_darwin) return error.UnsupportedPlatform;
    while (true) {
        var observed = std.mem.zeroes(posix.Stat);
        switch (posix.errno(system.fstat(descriptor, &observed))) {
            .SUCCESS => return statusFromDarwin(observed),
            .INTR => {},
            .BADF => return error.InvalidDescriptor,
            else => return error.StatusUnavailable,
        }
    }
}

fn statusAtDarwin(directory: Descriptor, name: [*:0]const u8) StatusError!Status {
    if (comptime !is_darwin) return error.UnsupportedPlatform;
    while (true) {
        var observed = std.mem.zeroes(posix.Stat);
        const result = system.fstatat(
            directory,
            name,
            &observed,
            posix.AT.SYMLINK_NOFOLLOW,
        );
        switch (posix.errno(result)) {
            .SUCCESS => return statusFromDarwin(observed),
            .INTR => {},
            .BADF => return error.InvalidDescriptor,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            else => return error.StatusUnavailable,
        }
    }
}

fn statusFromDarwin(observed: posix.Stat) StatusError!Status {
    if (comptime !is_darwin) return error.UnsupportedPlatform;
    if (observed.blocks < 0) return error.StatusUnavailable;
    const allocated_bytes = std.math.mul(
        u64,
        @intCast(observed.blocks),
        512,
    ) catch return error.Overflow;
    const device: u32 = @bitCast(observed.dev);
    const parts = darwinDeviceParts(device);
    const modified = observed.mtime();
    return .{
        .identity = .{
            .device_major = parts.major,
            .device_minor = parts.minor,
            .inode = @intCast(observed.ino),
            .regular = posix.S.ISREG(@intCast(observed.mode)),
        },
        .kind = kindDarwin(observed.mode),
        .allocated_bytes = allocated_bytes,
        .modified_ns = @as(i128, modified.sec) * std.time.ns_per_s + modified.nsec,
        .links = @intCast(observed.nlink),
    };
}

fn filesystemSpaceLinux(descriptor: Descriptor) FilesystemSpaceError!FilesystemSpace {
    if (comptime native_os != .linux or !supportedFilesystemSpaceArchitecture()) {
        return error.UnsupportedPlatform;
    }
    while (true) {
        var observed = std.mem.zeroes(LinuxFilesystemStatus);
        const result = linux.syscall2(
            .fstatfs,
            @as(u32, @bitCast(descriptor)),
            @intFromPtr(&observed),
        );
        switch (linux.errno(result)) {
            .SUCCESS => return filesystemSpaceFromLinux(observed),
            .INTR => {},
            .BADF => return error.InvalidDescriptor,
            else => return error.SpaceUnavailable,
        }
    }
}

fn filesystemSpaceFromLinux(
    observed: LinuxFilesystemStatus,
) FilesystemSpaceError!FilesystemSpace {
    const block_size = if (observed.fragment_size > 0)
        observed.fragment_size
    else
        observed.block_size;
    if (block_size <= 0 or observed.blocks < 0 or observed.blocks_free < 0 or
        observed.blocks_available < 0)
    {
        return error.SpaceUnavailable;
    }
    return scaleFilesystemSpace(
        @intCast(block_size),
        @intCast(observed.blocks),
        @intCast(observed.blocks_free),
        @intCast(observed.blocks_available),
    );
}

fn filesystemSpaceDarwin(descriptor: Descriptor) FilesystemSpaceError!FilesystemSpace {
    if (comptime !is_darwin or !supportedFilesystemSpaceArchitecture()) {
        return error.UnsupportedPlatform;
    }
    while (true) {
        var observed = std.mem.zeroes(DarwinFilesystemStatus);
        const result = switch (comptime builtin.cpu.arch) {
            .aarch64 => DarwinFilesystemSystem.fstatfs(descriptor, &observed),
            .x86_64 => DarwinFilesystemSystem.@"fstatfs$INODE64"(descriptor, &observed),
            else => unreachable,
        };
        switch (posix.errno(result)) {
            .SUCCESS => return scaleFilesystemSpace(
                observed.block_size,
                observed.blocks,
                observed.blocks_free,
                observed.blocks_available,
            ),
            .INTR => {},
            .BADF => return error.InvalidDescriptor,
            else => return error.SpaceUnavailable,
        }
    }
}

fn mountIdentityLinux(descriptor: Descriptor) MountIdentityError!MountIdentity {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    while (true) {
        var observed = std.mem.zeroes(linux.Statx);
        const result = linux.statx(
            descriptor,
            "",
            linux.AT.EMPTY_PATH,
            .{ .MNT_ID = true },
            &observed,
        );
        switch (linux.errno(result)) {
            .SUCCESS => return mountIdentityFromLinux(observed),
            .INTR => {},
            .BADF => return error.InvalidDescriptor,
            else => return error.MountIdentityUnavailable,
        }
    }
}

fn mountIdentityFromLinux(observed: linux.Statx) MountIdentityError!MountIdentity {
    if (!observed.mask.MNT_ID) return error.MountIdentityUnavailable;
    return .{ .linux = observed.mnt_id };
}

fn mountIdentityDarwin(descriptor: Descriptor) MountIdentityError!MountIdentity {
    if (comptime !is_darwin or !supportedFilesystemSpaceArchitecture()) {
        return error.UnsupportedPlatform;
    }
    while (true) {
        var observed = std.mem.zeroes(DarwinFilesystemStatus);
        const result = switch (comptime builtin.cpu.arch) {
            .aarch64 => DarwinFilesystemSystem.fstatfs(descriptor, &observed),
            .x86_64 => DarwinFilesystemSystem.@"fstatfs$INODE64"(descriptor, &observed),
            else => unreachable,
        };
        switch (posix.errno(result)) {
            .SUCCESS => return mountIdentityFromDarwin(observed),
            .INTR => {},
            .BADF => return error.InvalidDescriptor,
            else => return error.MountIdentityUnavailable,
        }
    }
}

fn mountIdentityFromDarwin(
    observed: DarwinFilesystemStatus,
) MountIdentityError!MountIdentity {
    const unavailable_filesystem_id = [2]i32{ -1, -1 };
    if (std.mem.eql(i32, &observed.filesystem_id, &unavailable_filesystem_id)) {
        return error.MountIdentityUnavailable;
    }
    const mounted_on_length = std.mem.indexOfScalar(u8, &observed.mounted_on, 0) orelse
        return error.MountIdentityUnavailable;
    if (mounted_on_length == 0) return error.MountIdentityUnavailable;

    var result: DarwinMountIdentity = .{
        .filesystem_id = observed.filesystem_id,
        .mounted_on_length = @intCast(mounted_on_length),
        .mounted_on = @splat(0),
    };
    @memcpy(result.mounted_on[0..mounted_on_length], observed.mounted_on[0..mounted_on_length]);
    return .{ .darwin = result };
}

fn scaleFilesystemSpace(
    block_size: u64,
    total_blocks: u64,
    free_blocks: u64,
    available_blocks: u64,
) FilesystemSpaceError!FilesystemSpace {
    if (block_size == 0) return error.SpaceUnavailable;
    return .{
        .total_bytes = std.math.mul(u64, total_blocks, block_size) catch return error.Overflow,
        .free_bytes = std.math.mul(u64, free_blocks, block_size) catch return error.Overflow,
        .available_bytes = std.math.mul(
            u64,
            available_blocks,
            block_size,
        ) catch return error.Overflow,
    };
}

fn supportedFilesystemSpaceArchitecture() bool {
    return builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64;
}

fn kindLinux(mode: u16) FileKind {
    if (linux.S.ISREG(mode)) return .regular;
    if (linux.S.ISDIR(mode)) return .directory;
    if (linux.S.ISLNK(mode)) return .symbolic_link;
    return .other;
}

fn kindDarwin(mode: posix.mode_t) FileKind {
    if (posix.S.ISREG(@intCast(mode))) return .regular;
    if (posix.S.ISDIR(@intCast(mode))) return .directory;
    if (posix.S.ISLNK(@intCast(mode))) return .symbolic_link;
    return .other;
}

fn darwinDeviceParts(device: u32) DeviceParts {
    return .{
        .major = device >> 24,
        .minor = device & 0x00ff_ffff,
    };
}

pub fn setNonBlocking(descriptor: Descriptor) FlagError!void {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => setNonBlockingLinux(descriptor),
        .posix_host => setNonBlockingPosix(descriptor),
    };
}

pub fn closeOnExec(descriptor: Descriptor) FlagError!bool {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => closeOnExecLinux(descriptor),
        .posix_host => closeOnExecPosix(descriptor),
    };
}

pub fn nonBlocking(descriptor: Descriptor) FlagError!bool {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => nonBlockingLinux(descriptor),
        .posix_host => nonBlockingPosix(descriptor),
    };
}

pub fn isOpen(descriptor: Descriptor) bool {
    return switch (descriptorPolicy()) {
        .unsupported => false,
        .linux_syscall => isOpenLinux(descriptor),
        .posix_host => isOpenPosix(descriptor),
    };
}

pub fn read(descriptor: Descriptor, buffer: []u8) ReadError!usize {
    if (buffer.len == 0) return 0;

    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => readLinux(descriptor, buffer),
        .posix_host => readPosix(descriptor, buffer),
    };
}

pub fn write(descriptor: Descriptor, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;

    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => writeLinux(descriptor, bytes),
        .posix_host => writePosix(descriptor, bytes),
    };
}

pub fn duplicate(descriptor: Descriptor) DuplicateError!Descriptor {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => duplicateLinux(descriptor),
        .posix_host => duplicatePosix(descriptor),
    };
}

pub fn duplicateAtLeast(
    descriptor: Descriptor,
    minimum: Descriptor,
) DuplicateError!Descriptor {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => duplicateAtLeastLinux(descriptor, minimum),
        .posix_host => duplicateAtLeastPosix(descriptor, minimum),
    };
}

pub fn duplicateTo(source: Descriptor, target: Descriptor) DuplicateError!void {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => duplicateToLinux(source, target),
        .posix_host => duplicateToPosix(source, target),
    };
}

pub fn pipe(flags: PipeFlags) PipeError![2]Descriptor {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => pipeLinux(flags),
        .posix_host => pipePosix(flags),
    };
}

pub fn pipeWithOptions(options: PipeOptions) PipeError![2]Descriptor {
    return pipe(pipeFlags(options));
}

pub fn socketPairUnixStream(options: SocketPairOptions) SocketPairError![2]Descriptor {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => socketPairUnixStreamLinux(options),
        .posix_host => socketPairUnixStreamPosix(options),
    };
}

fn closeLinux(descriptor: Descriptor) void {
    if (comptime native_os != .linux) return;
    _ = linux.close(descriptor);
}

fn closePosix(descriptor: Descriptor) void {
    if (@hasDecl(system, "close")) {
        _ = system.close(descriptor);
    }
}

fn setCloseOnExecLinux(descriptor: Descriptor) FlagError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    var operations: LinuxDescriptorFlagOperations = .{};
    return setCloseOnExecWith(&operations, descriptor, linux.FD_CLOEXEC);
}

fn setInheritOnExecLinux(descriptor: Descriptor) FlagError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    var operations: LinuxDescriptorFlagOperations = .{};
    return clearCloseOnExecWith(&operations, descriptor, linux.FD_CLOEXEC);
}

fn setCloseOnExecPosix(descriptor: Descriptor) FlagError!void {
    if (!@hasDecl(system, "fcntl") or @TypeOf(system.fcntl) == void) {
        return error.UnsupportedPlatform;
    }
    var operations: PosixDescriptorFlagOperations = .{};
    return setCloseOnExecWith(&operations, descriptor, posix.FD_CLOEXEC);
}

fn setInheritOnExecPosix(descriptor: Descriptor) FlagError!void {
    if (!@hasDecl(system, "fcntl") or @TypeOf(system.fcntl) == void) {
        return error.UnsupportedPlatform;
    }
    var operations: PosixDescriptorFlagOperations = .{};
    return clearCloseOnExecWith(&operations, descriptor, posix.FD_CLOEXEC);
}

const DescriptorFlagResult = union(enum) {
    success: usize,
    interrupted,
    invalid,
    failed,
};

const LinuxDescriptorFlagOperations = struct {
    fn get(_: *@This(), descriptor: Descriptor) DescriptorFlagResult {
        const rc = linux.fcntl(descriptor, linux.F.GETFD, 0);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .success = rc },
            .INTR => .interrupted,
            .INVAL => .invalid,
            else => .failed,
        };
    }

    fn set(_: *@This(), descriptor: Descriptor, flags: usize) DescriptorFlagResult {
        const rc = linux.fcntl(descriptor, linux.F.SETFD, flags);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .success = rc },
            .INTR => .interrupted,
            .INVAL => .invalid,
            else => .failed,
        };
    }
};

const PosixDescriptorFlagOperations = struct {
    fn get(_: *@This(), descriptor: Descriptor) DescriptorFlagResult {
        const rc = system.fcntl(descriptor, posix.F.GETFD, @as(usize, 0));
        return switch (posix.errno(rc)) {
            .SUCCESS => .{ .success = @intCast(rc) },
            .INTR => .interrupted,
            .INVAL => .invalid,
            else => .failed,
        };
    }

    fn set(_: *@This(), descriptor: Descriptor, flags: usize) DescriptorFlagResult {
        const rc = system.fcntl(descriptor, posix.F.SETFD, flags);
        return switch (posix.errno(rc)) {
            .SUCCESS => .{ .success = @intCast(rc) },
            .INTR => .interrupted,
            .INVAL => .invalid,
            else => .failed,
        };
    }
};

fn setCloseOnExecWith(
    operations: anytype,
    descriptor: Descriptor,
    close_on_exec: usize,
) FlagError!void {
    const flags = while (true) {
        switch (operations.get(descriptor)) {
            .success => |value| break value,
            .interrupted => continue,
            .invalid, .failed => return error.FlagUpdateFailed,
        }
    };
    const updated = flags | close_on_exec;

    while (true) {
        switch (operations.set(descriptor, updated)) {
            .success => return,
            .interrupted => continue,
            .invalid => return error.InvalidFlags,
            .failed => return error.FlagUpdateFailed,
        }
    }
}

fn clearCloseOnExecWith(
    operations: anytype,
    descriptor: Descriptor,
    close_on_exec: usize,
) FlagError!void {
    const flags = while (true) {
        switch (operations.get(descriptor)) {
            .success => |value| break value,
            .interrupted => continue,
            .invalid, .failed => return error.FlagUpdateFailed,
        }
    };
    const updated = flags & ~close_on_exec;
    while (true) {
        switch (operations.set(descriptor, updated)) {
            .success => return,
            .interrupted => continue,
            .invalid => return error.InvalidFlags,
            .failed => return error.FlagUpdateFailed,
        }
    }
}

fn lockLinux(
    descriptor: Descriptor,
    mode: LockMode,
    blocking: bool,
) LockError!bool {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    var operation: i32 = switch (mode) {
        .shared => posix.LOCK.SH,
        .exclusive => posix.LOCK.EX,
    };
    if (!blocking) operation |= posix.LOCK.NB;
    while (true) switch (linux.errno(linux.flock(descriptor, operation))) {
        .SUCCESS => return true,
        .INTR => continue,
        .AGAIN => return false,
        .BADF => return error.InvalidDescriptor,
        else => return error.LockFailed,
    };
}

fn lockPosix(
    descriptor: Descriptor,
    mode: LockMode,
    blocking: bool,
) LockError!bool {
    if (!@hasDecl(system, "flock") or @TypeOf(system.flock) == void) {
        return error.UnsupportedPlatform;
    }
    var operation: i32 = switch (mode) {
        .shared => posix.LOCK.SH,
        .exclusive => posix.LOCK.EX,
    };
    if (!blocking) operation |= posix.LOCK.NB;
    while (true) switch (posix.errno(system.flock(descriptor, operation))) {
        .SUCCESS => return true,
        .INTR => continue,
        .AGAIN => return false,
        .BADF => return error.InvalidDescriptor,
        else => return error.LockFailed,
    };
}

fn setNonBlockingLinux(descriptor: Descriptor) FlagError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    var flags: usize = while (true) {
        const rc = linux.fcntl(descriptor, linux.F.GETFL, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            else => return error.FlagUpdateFailed,
        }
    };
    flags |= @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));

    while (true) {
        const rc = linux.fcntl(descriptor, linux.F.SETFL, flags);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .INVAL => return error.InvalidFlags,
            else => return error.FlagUpdateFailed,
        }
    }
}

fn setNonBlockingPosix(descriptor: Descriptor) FlagError!void {
    if (!@hasDecl(system, "fcntl") or @TypeOf(system.fcntl) == void) {
        return error.UnsupportedPlatform;
    }

    var flags: usize = while (true) {
        const rc = system.fcntl(descriptor, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            else => return error.FlagUpdateFailed,
        }
    };
    flags |= @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));

    while (true) {
        const rc = system.fcntl(descriptor, posix.F.SETFL, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .INVAL => return error.InvalidFlags,
            else => return error.FlagUpdateFailed,
        }
    }
}

fn closeOnExecLinux(descriptor: Descriptor) FlagError!bool {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    while (true) {
        const rc = linux.fcntl(descriptor, linux.F.GETFD, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc & linux.FD_CLOEXEC != 0,
            .INTR => continue,
            else => return error.FlagUpdateFailed,
        }
    }
}

fn closeOnExecPosix(descriptor: Descriptor) FlagError!bool {
    if (!@hasDecl(system, "fcntl") or @TypeOf(system.fcntl) == void) {
        return error.UnsupportedPlatform;
    }
    while (true) {
        const rc = system.fcntl(descriptor, posix.F.GETFD, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return @as(usize, @intCast(rc)) & posix.FD_CLOEXEC != 0,
            .INTR => continue,
            else => return error.FlagUpdateFailed,
        }
    }
}

fn nonBlockingLinux(descriptor: Descriptor) FlagError!bool {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    while (true) {
        const rc = linux.fcntl(descriptor, linux.F.GETFL, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const nonblocking: u32 = @bitCast(linux.O{ .NONBLOCK = true });
                return rc & nonblocking != 0;
            },
            .INTR => continue,
            else => return error.FlagUpdateFailed,
        }
    }
}

fn nonBlockingPosix(descriptor: Descriptor) FlagError!bool {
    if (!@hasDecl(system, "fcntl") or @TypeOf(system.fcntl) == void) {
        return error.UnsupportedPlatform;
    }
    while (true) {
        const rc = system.fcntl(descriptor, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const nonblocking: u32 = @bitCast(posix.O{ .NONBLOCK = true });
                return @as(usize, @intCast(rc)) & nonblocking != 0;
            },
            .INTR => continue,
            else => return error.FlagUpdateFailed,
        }
    }
}

fn isOpenLinux(descriptor: Descriptor) bool {
    if (comptime native_os != .linux) return false;
    while (true) {
        const rc = linux.fcntl(descriptor, linux.F.GETFD, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => return true,
            .INTR => continue,
            .BADF => return false,
            else => return false,
        }
    }
}

fn isOpenPosix(descriptor: Descriptor) bool {
    if (!@hasDecl(system, "fcntl") or @TypeOf(system.fcntl) == void) return false;
    while (true) {
        const rc = system.fcntl(descriptor, posix.F.GETFD, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return true,
            .INTR => continue,
            .BADF => return false,
            else => return false,
        }
    }
}

fn readLinux(descriptor: Descriptor, buffer: []u8) ReadError!usize {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    while (true) {
        const rc = linux.read(descriptor, buffer.ptr, buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => return error.ReadFailed,
        }
    }
}

fn readPosix(descriptor: Descriptor, buffer: []u8) ReadError!usize {
    if (@hasDecl(system, "read")) {
        while (true) {
            const rc = system.read(descriptor, buffer.ptr, buffer.len);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .IO => return error.InputOutput,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                else => return error.ReadFailed,
            }
        }
    }

    return error.UnsupportedPlatform;
}

fn writeLinux(descriptor: Descriptor, bytes: []const u8) WriteError!usize {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    while (true) {
        const rc = linux.write(descriptor, bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            else => return error.WriteFailed,
        }
    }
}

fn writePosix(descriptor: Descriptor, bytes: []const u8) WriteError!usize {
    if (@hasDecl(system, "write")) {
        while (true) {
            const rc = system.write(descriptor, bytes.ptr, bytes.len);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .PIPE => return error.BrokenPipe,
                else => return error.WriteFailed,
            }
        }
    }

    return error.UnsupportedPlatform;
}

fn duplicateLinux(descriptor: Descriptor) DuplicateError!Descriptor {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    while (true) {
        const rc = linux.dup(descriptor);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.DuplicateFailed,
        }
    }
}

fn duplicatePosix(descriptor: Descriptor) DuplicateError!Descriptor {
    if (@hasDecl(system, "dup") and @TypeOf(system.dup) != void) {
        while (true) {
            const rc = system.dup(descriptor);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.DuplicateFailed,
            }
        }
    }

    return error.UnsupportedPlatform;
}

fn duplicateAtLeastLinux(
    descriptor: Descriptor,
    minimum: Descriptor,
) DuplicateError!Descriptor {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    if (minimum < 0) return error.DuplicateFailed;
    while (true) {
        const rc = linux.fcntl(descriptor, linux.F.DUPFD_CLOEXEC, @intCast(minimum));
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.DuplicateFailed,
        }
    }
}

fn duplicateAtLeastPosix(
    descriptor: Descriptor,
    minimum: Descriptor,
) DuplicateError!Descriptor {
    if (!@hasDecl(system, "fcntl") or @TypeOf(system.fcntl) == void) {
        return error.UnsupportedPlatform;
    }
    if (minimum < 0) return error.DuplicateFailed;
    while (true) {
        const rc = system.fcntl(
            descriptor,
            posix.F.DUPFD_CLOEXEC,
            @as(usize, @intCast(minimum)),
        );
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.DuplicateFailed,
        }
    }
}

fn duplicateToLinux(source: Descriptor, target: Descriptor) DuplicateError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    while (true) {
        const rc = linux.dup2(source, target);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                std.debug.assert(rc == @as(usize, @intCast(target)));
                return;
            },
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.DuplicateFailed,
        }
    }
}

fn duplicateToPosix(source: Descriptor, target: Descriptor) DuplicateError!void {
    if (@hasDecl(system, "dup2") and @TypeOf(system.dup2) != void) {
        while (true) {
            const rc = system.dup2(source, target);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    std.debug.assert(rc == target);
                    return;
                },
                .INTR => continue,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.DuplicateFailed,
            }
        }
    }
    return error.UnsupportedPlatform;
}

fn pipeLinux(flags: PipeFlags) PipeError![2]Descriptor {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    var descriptors: [2]Descriptor = undefined;
    while (true) {
        switch (linux.errno(linux.pipe2(&descriptors, linuxPipeFlags(flags)))) {
            .SUCCESS => return descriptors,
            .INTR => continue,
            .INVAL => return error.InvalidFlags,
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.PipeFailed,
        }
    }
}

fn pipePosix(flags: PipeFlags) PipeError![2]Descriptor {
    var descriptors: [2]Descriptor = undefined;
    if (@hasDecl(system, "pipe2") and @TypeOf(system.pipe2) != void) {
        while (true) {
            switch (posix.errno(system.pipe2(&descriptors, flags))) {
                .SUCCESS => return descriptors,
                .INTR => continue,
                .INVAL => return error.InvalidFlags,
                .NFILE => return error.SystemFdQuotaExceeded,
                .MFILE => return error.ProcessFdQuotaExceeded,
                else => return error.PipeFailed,
            }
        }
    }

    if (@hasDecl(system, "pipe") and @TypeOf(system.pipe) != void) {
        while (true) {
            switch (posix.errno(system.pipe(&descriptors))) {
                .SUCCESS => break,
                .INTR => continue,
                .NFILE => return error.SystemFdQuotaExceeded,
                .MFILE => return error.ProcessFdQuotaExceeded,
                else => return error.PipeFailed,
            }
        }
        errdefer {
            close(descriptors[0]);
            close(descriptors[1]);
        }
        try applyPipeFlags(descriptors, flags);
        return descriptors;
    }

    return error.UnsupportedPlatform;
}

fn socketPairUnixStreamLinux(options: SocketPairOptions) SocketPairError![2]Descriptor {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    const close_flag: u32 = if (options.close_on_exec) linux.SOCK.CLOEXEC else 0;
    const socket_type: u32 = linux.SOCK.STREAM | close_flag;
    var descriptors: [2]Descriptor = undefined;
    while (true) {
        const rc = linux.socketpair(linux.AF.UNIX, socket_type, 0, &descriptors);
        switch (linux.errno(rc)) {
            .SUCCESS => return descriptors,
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => return error.SocketPairFailed,
        }
    }
}

fn socketPairUnixStreamPosix(options: SocketPairOptions) SocketPairError![2]Descriptor {
    if (!@hasDecl(system, "socketpair") or @TypeOf(system.socketpair) == void) {
        return error.UnsupportedPlatform;
    }

    const close_flag: u32 = if (options.close_on_exec and !socket_flags_unsupported) posix.SOCK.CLOEXEC else 0;
    const socket_type: u32 = posix.SOCK.STREAM | close_flag;

    var descriptors: [2]Descriptor = undefined;
    while (true) {
        const rc = system.socketpair(posix.AF.UNIX, socket_type, 0, &descriptors);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (options.close_on_exec and socket_flags_unsupported) {
                    errdefer {
                        close(descriptors[0]);
                        close(descriptors[1]);
                    }
                    setCloseOnExec(descriptors[0]) catch return error.SocketPairFailed;
                    setCloseOnExec(descriptors[1]) catch return error.SocketPairFailed;
                }
                return descriptors;
            },
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => return error.SocketPairFailed,
        }
    }
}

fn linuxPipeFlags(flags: PipeFlags) linux.O {
    return @bitCast(@as(u32, @bitCast(flags)));
}

fn applyPipeFlags(descriptors: [2]Descriptor, flags: PipeFlags) PipeError!void {
    if (@as(u32, @bitCast(flags)) == 0) return;

    if (flags.CLOEXEC) {
        setCloseOnExec(descriptors[0]) catch return error.PipeFailed;
        setCloseOnExec(descriptors[1]) catch return error.PipeFailed;
    }

    var status_flags = flags;
    status_flags.CLOEXEC = false;
    const status_flag_bits: u32 = @bitCast(status_flags);
    if (status_flag_bits == 0) return;

    try setStatusFlagsForPipe(descriptors[0], status_flag_bits);
    try setStatusFlagsForPipe(descriptors[1], status_flag_bits);
}

fn pipeFlags(options: PipeOptions) PipeFlags {
    return .{
        .CLOEXEC = options.close_on_exec,
        .NONBLOCK = options.nonblocking,
    };
}

fn setStatusFlagsForPipe(descriptor: Descriptor, flags: u32) PipeError!void {
    return switch (descriptorPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => setStatusFlagsForPipeLinux(descriptor, flags),
        .posix_host => setStatusFlagsForPipePosix(descriptor, flags),
    };
}

fn setStatusFlagsForPipeLinux(descriptor: Descriptor, flags: u32) PipeError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    switch (linux.errno(linux.fcntl(descriptor, linux.F.SETFL, flags))) {
        .SUCCESS => {},
        .INVAL => return error.InvalidFlags,
        else => return error.PipeFailed,
    }
}

fn setStatusFlagsForPipePosix(descriptor: Descriptor, flags: u32) PipeError!void {
    if (!@hasDecl(system, "fcntl") or @TypeOf(system.fcntl) == void) {
        return error.UnsupportedPlatform;
    }

    switch (posix.errno(system.fcntl(descriptor, posix.F.SETFL, flags))) {
        .SUCCESS => {},
        .INVAL => return error.InvalidFlags,
        else => return error.PipeFailed,
    }
}

test "descriptor policy is explicit" {
    const expected: DescriptorPolicy = switch (native_os) {
        .windows, .wasi, .freestanding => .unsupported,
        .linux => .linux_syscall,
        else => .posix_host,
    };
    try std.testing.expectEqual(expected, descriptorPolicy());
}

test "descriptor status measures allocation and does not follow links" {
    if (comptime native_os != .linux and !is_darwin) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file = try temporary.dir.createFile(std.testing.io, "target", .{ .read = true });
    defer file.close(std.testing.io);
    var payload: [4096]u8 = @splat(0x5a);
    try file.writeStreamingAll(std.testing.io, &payload);
    try temporary.dir.symLink(std.testing.io, "target", "linked", .{});

    const target = try statusAt(temporary.dir.handle, "target");
    const linked = try statusAt(temporary.dir.handle, "linked");
    try std.testing.expectEqual(FileKind.regular, target.kind);
    try std.testing.expect(target.allocated_bytes >= payload.len);
    try std.testing.expectEqual(FileKind.symbolic_link, linked.kind);
    try std.testing.expect(linked.identity.inode != target.identity.inode);
}

test "filesystem space scales block counts with checked arithmetic" {
    const observed = try scaleFilesystemSpace(4096, 10, 4, 3);
    try std.testing.expectEqual(@as(u64, 40_960), observed.total_bytes);
    try std.testing.expectEqual(@as(u64, 16_384), observed.free_bytes);
    try std.testing.expectEqual(@as(u64, 12_288), observed.available_bytes);
    try std.testing.expectError(
        error.SpaceUnavailable,
        scaleFilesystemSpace(0, 10, 4, 3),
    );
    try std.testing.expectError(
        error.Overflow,
        scaleFilesystemSpace(2, std.math.maxInt(u64), 4, 3),
    );
}

test "filesystem space reports an open directory descriptor" {
    if (comptime native_os != .linux and !is_darwin) return error.SkipZigTest;
    if (comptime !supportedFilesystemSpaceArchitecture()) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const observed = try filesystemSpace(temporary.dir.handle);
    try std.testing.expect(observed.total_bytes > 0);
    try std.testing.expect(observed.free_bytes <= observed.total_bytes);
    try std.testing.expect(observed.available_bytes <= observed.free_bytes);
    try std.testing.expectError(error.InvalidDescriptor, filesystemSpace(-1));
}

test "mount identity is bound to an open descriptor" {
    if (comptime native_os != .linux and !is_darwin) return error.SkipZigTest;
    if (comptime is_darwin and !supportedFilesystemSpaceArchitecture()) {
        return error.SkipZigTest;
    }
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file = try temporary.dir.createFile(std.testing.io, "member", .{ .read = true });
    defer file.close(std.testing.io);

    const directory_identity = try mountIdentity(temporary.dir.handle);
    const file_identity = try mountIdentity(file.handle);
    try std.testing.expect(directory_identity.eql(file_identity));
    try std.testing.expectError(error.InvalidDescriptor, mountIdentity(-1));

    if (comptime native_os == .linux) {
        var proc = std.Io.Dir.openDirAbsolute(std.testing.io, "/proc", .{}) catch
            return error.SkipZigTest;
        defer proc.close(std.testing.io);
        try std.testing.expect(!directory_identity.eql(try mountIdentity(proc.handle)));
    }
}

test "Linux mount identity separates same-device mount identifiers" {
    if (comptime native_os != .linux) return error.SkipZigTest;
    var first = std.mem.zeroes(linux.Statx);
    first.mask.MNT_ID = true;
    first.dev_major = 8;
    first.dev_minor = 1;
    first.mnt_id = 41;
    var second = first;
    second.mnt_id = 42;

    try std.testing.expect(!(try mountIdentityFromLinux(first)).eql(
        try mountIdentityFromLinux(second),
    ));
    first.mask.MNT_ID = false;
    try std.testing.expectError(
        error.MountIdentityUnavailable,
        mountIdentityFromLinux(first),
    );
}

test "Darwin mount identity includes the exact mounted-on path" {
    var first_status = std.mem.zeroes(DarwinFilesystemStatus);
    first_status.filesystem_id = .{ 7, 9 };
    @memcpy(first_status.mounted_on[0..5], "/site");
    const first = try mountIdentityFromDarwin(first_status);

    var second_status = first_status;
    @memcpy(second_status.mounted_on[0..5], "/else");
    const second = try mountIdentityFromDarwin(second_status);
    try std.testing.expect(!first.eql(second));

    second_status = first_status;
    second_status.filesystem_id = .{ 7, 10 };
    try std.testing.expect(!first.eql(try mountIdentityFromDarwin(second_status)));

    first_status.filesystem_id = .{ -1, -1 };
    try std.testing.expectError(
        error.MountIdentityUnavailable,
        mountIdentityFromDarwin(first_status),
    );
    first_status.filesystem_id = .{ 7, 9 };
    first_status.mounted_on = @splat(0);
    try std.testing.expectError(
        error.MountIdentityUnavailable,
        mountIdentityFromDarwin(first_status),
    );
    first_status.mounted_on = @splat('x');
    try std.testing.expectError(
        error.MountIdentityUnavailable,
        mountIdentityFromDarwin(first_status),
    );
}

const MountInfoEntry = struct {
    mount_id: []const u8,
    device: []const u8,
    path: []const u8,
};

const SameDeviceMountBoundary = enum {
    absent,
    separated,
    collapsed,
};

fn parseMountInfoEntry(line: []const u8) ?MountInfoEntry {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const mount_id = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    const device = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    const path = fields.next() orelse return null;
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, '\\') != null) {
        return null;
    }
    return .{ .mount_id = mount_id, .device = device, .path = path };
}

fn observeSameDeviceMountBoundary(mountinfo: []const u8) SameDeviceMountBoundary {
    var first_lines = std.mem.splitScalar(u8, mountinfo, '\n');
    while (first_lines.next()) |first_line| {
        const first = parseMountInfoEntry(first_line) orelse continue;
        var second_lines = std.mem.splitScalar(u8, mountinfo, '\n');
        while (second_lines.next()) |second_line| {
            const second = parseMountInfoEntry(second_line) orelse continue;
            if (std.mem.eql(u8, first.mount_id, second.mount_id) or
                !std.mem.eql(u8, first.device, second.device) or
                std.mem.eql(u8, first.path, second.path)) continue;

            var first_dir = std.Io.Dir.openDirAbsolute(
                std.testing.io,
                first.path,
                .{},
            ) catch continue;
            defer first_dir.close(std.testing.io);
            var second_dir = std.Io.Dir.openDirAbsolute(
                std.testing.io,
                second.path,
                .{},
            ) catch continue;
            defer second_dir.close(std.testing.io);
            const first_status = status(first_dir.handle) catch continue;
            const second_status = status(second_dir.handle) catch continue;
            if (first_status.identity.device_major != second_status.identity.device_major or
                first_status.identity.device_minor != second_status.identity.device_minor) continue;

            const first_identity = mountIdentity(first_dir.handle) catch continue;
            const second_identity = mountIdentity(second_dir.handle) catch continue;
            return if (first_identity.eql(second_identity)) .collapsed else .separated;
        }
    }
    return .absent;
}

test "Linux runtime separates visible same-device mounts" {
    if (comptime native_os != .linux) return error.SkipZigTest;
    var mountinfo_file = std.Io.Dir.openFileAbsolute(
        std.testing.io,
        "/proc/self/mountinfo",
        .{},
    ) catch return error.SkipZigTest;
    defer mountinfo_file.close(std.testing.io);
    var storage: [128 * 1024]u8 = undefined;
    var length: usize = 0;
    while (length < storage.len) {
        const read_count = try read(mountinfo_file.handle, storage[length..]);
        if (read_count == 0) break;
        length += read_count;
    }
    if (length == storage.len) return error.SkipZigTest;

    const observed = observeSameDeviceMountBoundary(storage[0..length]);
    if (observed == .absent) return error.SkipZigTest;
    try std.testing.expectEqual(SameDeviceMountBoundary.separated, observed);
}

const DescriptorFlagRetryFixture = struct {
    get_results: []const DescriptorFlagResult,
    set_results: []const DescriptorFlagResult,
    get_index: usize = 0,
    set_index: usize = 0,
    updated: usize = 0,

    fn get(self: *@This(), _: Descriptor) DescriptorFlagResult {
        const result = self.get_results[self.get_index];
        self.get_index += 1;
        return result;
    }

    fn set(self: *@This(), _: Descriptor, flags: usize) DescriptorFlagResult {
        self.updated = flags;
        const result = self.set_results[self.set_index];
        self.set_index += 1;
        return result;
    }
};

test "close on exec preserves descriptor flags and retries interruptions" {
    const get_results = [_]DescriptorFlagResult{
        .interrupted,
        .{ .success = 0x40 },
    };
    const set_results = [_]DescriptorFlagResult{
        .interrupted,
        .{ .success = 0 },
    };
    var operations: DescriptorFlagRetryFixture = .{
        .get_results = &get_results,
        .set_results = &set_results,
    };

    try setCloseOnExecWith(&operations, 7, 0x01);

    try std.testing.expectEqual(@as(usize, 2), operations.get_index);
    try std.testing.expectEqual(@as(usize, 2), operations.set_index);
    try std.testing.expectEqual(@as(usize, 0x41), operations.updated);
}

const DescriptorFlagFailureFixture = struct {
    get_result: DescriptorFlagResult,
    set_result: DescriptorFlagResult,

    fn get(self: *@This(), _: Descriptor) DescriptorFlagResult {
        return self.get_result;
    }

    fn set(self: *@This(), _: Descriptor, _: usize) DescriptorFlagResult {
        return self.set_result;
    }
};

test "close on exec reports descriptor and update failures" {
    var invalid_descriptor: DescriptorFlagFailureFixture = .{
        .get_result = .failed,
        .set_result = .{ .success = 0 },
    };
    try std.testing.expectError(
        error.FlagUpdateFailed,
        setCloseOnExecWith(&invalid_descriptor, -1, 0x01),
    );

    var invalid_update: DescriptorFlagFailureFixture = .{
        .get_result = .{ .success = 0x40 },
        .set_result = .invalid,
    };
    try std.testing.expectError(
        error.InvalidFlags,
        setCloseOnExecWith(&invalid_update, 7, 0x01),
    );
}

test "pipe read write round trip" {
    const descriptors = pipe(.{ .CLOEXEC = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(descriptors[0]);
    defer close(descriptors[1]);

    try std.testing.expectEqual(@as(usize, 5), try write(descriptors[1], "hello"));

    var buffer: [8]u8 = undefined;
    const count = try read(descriptors[0], &buffer);
    try std.testing.expectEqualStrings("hello", buffer[0..count]);
}

test "duplicate descriptor writes to the same pipe" {
    const descriptors = pipe(.{ .CLOEXEC = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(descriptors[0]);
    defer close(descriptors[1]);

    const copied = duplicate(descriptors[1]) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(copied);

    try std.testing.expectEqual(@as(usize, 4), try write(copied, "copy"));

    var buffer: [8]u8 = undefined;
    const count = try read(descriptors[0], &buffer);
    try std.testing.expectEqualStrings("copy", buffer[0..count]);
}

test "duplicate at least preserves a high inherited lease range" {
    const descriptors = pipe(.{ .CLOEXEC = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(descriptors[0]);
    defer close(descriptors[1]);
    const copied = duplicateAtLeast(descriptors[1], 128) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(copied);
    try std.testing.expect(copied >= 128);
    try std.testing.expect(try closeOnExec(copied));
}

test "duplicate to replaces one exact descriptor" {
    const descriptors = pipe(.{ .CLOEXEC = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(descriptors[0]);
    defer close(descriptors[1]);
    const target = try duplicate(descriptors[0]);
    close(target);
    try duplicateTo(descriptors[1], target);
    defer close(target);
    try std.testing.expectEqual(@as(usize, 5), try write(target, "exact"));
    var buffer: [8]u8 = undefined;
    const count = try read(descriptors[0], &buffer);
    try std.testing.expectEqualStrings("exact", buffer[0..count]);
}

test "Unix stream socket pair read write round trip" {
    const descriptors = socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(descriptors[0]);
    defer close(descriptors[1]);

    try std.testing.expectEqual(@as(usize, 4), try write(descriptors[0], "ping"));

    var buffer: [8]u8 = undefined;
    const count = try read(descriptors[1], &buffer);
    try std.testing.expectEqualStrings("ping", buffer[0..count]);
}
