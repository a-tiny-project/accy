const std = @import("std");
const builtin = @import("builtin");

const capabilities = @import("capabilities.zig");
const fd = @import("fd.zig");
const ioccom = @import("ioccom.zig");
const linux = std.os.linux;
const native_os = builtin.os.tag;
const posix = std.posix;

extern fn posix_openpt(flags: c_int) c_int;

pub const required_capabilities = switch (native_os) {
    .linux => capabilities.noLibc(&.{ .descriptors, .terminal }),
    else => capabilities.host(&.{ .descriptors, .terminal }),
};

pub const Pair = struct {
    master: fd.Descriptor,
    slave: fd.Descriptor,

    pub fn close(self: Pair) void {
        fd.close(self.slave);
        fd.close(self.master);
    }
};

pub fn open() !Pair {
    return switch (native_os) {
        .linux => openLinux(),
        .freebsd => openFreeBsd(),
        .ios, .macos, .tvos, .visionos, .watchos => openDarwin(),
        else => error.UnsupportedPlatform,
    };
}

pub fn isSupported() bool {
    return native_os == .linux or native_os == .freebsd or isDarwin();
}

fn openLinux() !Pair {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    const master = try openLinuxMaster();
    errdefer fd.close(master);

    var unlocked: c_int = 0;
    try controlLinux(master, linux.T.IOCSPTLCK, @intFromPtr(&unlocked));

    const flags: u32 = @bitCast(linux.O{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
        .NOCTTY = true,
    });
    const slave = while (true) {
        const result = linux.ioctl(master, linux.T.IOCGPTPEER, flags);
        switch (linux.errno(result)) {
            .SUCCESS => break @as(fd.Descriptor, @intCast(result)),
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .ACCES, .PERM => return error.AccessDenied,
            .INVAL, .IO, .NOTTY => return error.InvalidPseudoTerminal,
            else => return error.OpenSlaveFailed,
        }
    };

    return .{ .master = master, .slave = slave };
}

fn openLinuxMaster() !fd.Descriptor {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    while (true) {
        const result = linux.open("/dev/ptmx", .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
            .NOCTTY = true,
        }, 0);
        switch (linux.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .NOENT => return error.FileNotFound,
            else => return error.OpenMasterFailed,
        }
    }
}

fn controlLinux(descriptor: fd.Descriptor, request: u32, argument: usize) !void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    while (true) {
        const result = linux.ioctl(descriptor, request, argument);
        switch (linux.errno(result)) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .INVAL, .NOTTY => return error.InvalidPseudoTerminal,
            else => return error.ControlFailed,
        }
    }
}

fn openDarwin() !Pair {
    if (comptime !isDarwin()) return error.UnsupportedPlatform;

    const master = try openPosixMaster();
    errdefer fd.close(master);

    // TIOCPTYGRANT, TIOCPTYUNLK and TIOCPTYGNAME from <sys/ttycom.h>.
    try controlPosix(master, @bitCast(ioccom.none('t', 84)), 0);
    try controlPosix(master, @bitCast(ioccom.none('t', 82)), 0);

    var slave_path: [128]u8 = @splat(0);
    const name_request = ioccom.read('t', 83, slave_path.len);
    try controlPosix(master, @bitCast(name_request), @intFromPtr(&slave_path));
    const path_len = std.mem.indexOfScalar(u8, &slave_path, 0) orelse return error.InvalidSlaveName;
    const slave = try openPosixPath(slave_path[0..path_len :0]);

    return .{ .master = master, .slave = slave };
}

fn openFreeBsd() !Pair {
    if (comptime native_os != .freebsd) return error.UnsupportedPlatform;

    const flags: u32 = @bitCast(posix.O{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
        .NOCTTY = true,
    });
    const master = while (true) {
        const result = posix_openpt(@bitCast(flags));
        switch (posix.errno(result)) {
            .SUCCESS => break @as(fd.Descriptor, @intCast(result)),
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => return error.OpenMasterFailed,
        }
    };
    errdefer fd.close(master);

    var number: c_int = undefined;
    try controlPosix(master, @bitCast(@as(u32, 0x4004740f)), @intFromPtr(&number));

    var path_buffer: [64]u8 = undefined;
    const slave_path = std.fmt.bufPrintSentinel(&path_buffer, "/dev/pts/{d}", .{number}, 0) catch return error.InvalidSlaveName;
    const slave = try openPosixPath(slave_path);

    return .{ .master = master, .slave = slave };
}

fn openPosixMaster() !fd.Descriptor {
    return openPosixPath("/dev/ptmx");
}

fn openPosixPath(path: [:0]const u8) !fd.Descriptor {
    return posix.openat(posix.AT.FDCWD, path, .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
        .NOCTTY = true,
    }, 0) catch |err| switch (err) {
        error.PermissionDenied => error.AccessDenied,
        else => err,
    };
}

fn controlPosix(descriptor: fd.Descriptor, request: c_int, argument: usize) !void {
    while (true) {
        const result = posix.system.ioctl(descriptor, request, argument);
        switch (posix.errno(result)) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .INVAL, .NOTTY => return error.InvalidPseudoTerminal,
            else => return error.ControlFailed,
        }
    }
}

fn isDarwin() bool {
    return switch (native_os) {
        .ios, .macos, .tvos, .visionos, .watchos => true,
        else => false,
    };
}

fn expectCloseOnExec(descriptor: fd.Descriptor) !void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    const result = linux.fcntl(descriptor, linux.F.GETFD, 0);
    switch (linux.errno(result)) {
        .SUCCESS => try std.testing.expect(result & linux.FD_CLOEXEC != 0),
        else => return error.FlagQueryFailed,
    }
}
