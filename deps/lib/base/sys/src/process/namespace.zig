//! Linux descendant containment gives a caller one kill that reaches a whole
//! process tree: a child is forked as the init process of a new PID namespace,
//! the *PID namespace init*, so killing or exiting it ends everything below it.
//! The caller's filesystem namespace is left as it was, so its mounts stay
//! shared with the child.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../root.zig");
const process = @import("root.zig");

const linux = std.os.linux;

/// Forks a child that is process id 1 inside a new PID namespace and a new user
/// namespace, preserving the caller's real and effective user and group
/// identity through an identity map, while on the parent side the call yields
/// the child's process id as the host numbers it. Killing or exiting that child
/// kills the namespace's descendants, including processes that create new
/// sessions. The child arms the parent-death signal, which delivers `SIGKILL`
/// to a child when its parent exits, and no-new-privileges, which stops a later
/// exec from gaining privileges, such as through a setuid binary, while the
/// parent waits for both over a socket pair before the call returns. The child
/// keeps every mount the caller had, procfs among them, so a numeric path under
/// `/proc` read inside the child resolves against the caller's process
/// numbering, and only a program whose behavior under that mismatch is known
/// belongs beneath this call. The child carries the same restriction any forked
/// child carries: it reaches an exec or an exit while touching none of the
/// runtime locks it inherited. A caller whose real and effective identity
/// differ fails with `NamespaceIdentityUnavailable`, and a host outside Linux
/// on x86-64 and aarch64 fails with `UnsupportedPlatform`.
pub fn forkContained() !process.ForkResult {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
    if (comptime builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) {
        return error.UnsupportedPlatform;
    }
    const uid = linux.getuid();
    const gid = linux.getgid();
    if (uid != linux.geteuid() or gid != linux.getegid()) {
        return error.NamespaceIdentityUnavailable;
    }
    var channel: [2]sys.fd.Descriptor = undefined;
    const channel_result = linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC,
        0,
        &channel,
    );
    if (linux.errno(channel_result) != .SUCCESS) {
        return error.NamespaceChannelFailed;
    }
    defer closeDescriptor(&channel[0]);
    defer closeDescriptor(&channel[1]);
    const flags = linux.CLONE.NEWUSER | linux.CLONE.NEWPID | @backingInt(linux.SIG.CHLD);
    const result = linux.clone2(flags, 0);
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .PERM, .ACCES => return error.NamespacePermissionDenied,
        .AGAIN, .NOMEM, .NOSPC => return error.SystemResources,
        else => return error.NamespaceCreationFailed,
    }
    if (result == 0) {
        closeDescriptor(&channel[0]);
        childReady(channel[1]) catch process.exit(127);
        std.debug.assert(linux.getpid() == 1);
        std.debug.assert(linux.getuid() == uid);
        std.debug.assert(linux.getgid() == gid);
        return .child;
    }
    closeDescriptor(&channel[1]);
    const child: process.ProcessId = @intCast(result);
    std.debug.assert(child > 1);
    errdefer {
        process.forceKillChildId(child);
        _ = process.waitDirect(child) catch {};
    }
    try receiveReady(channel[0]);
    try mapIdentity(child, "uid_map", uid);
    try writeControl(child, "setgroups", "deny");
    try mapIdentity(child, "gid_map", gid);
    try sendReady(channel[0]);
    return .{ .parent = child };
}

fn childReady(channel: sys.fd.Descriptor) !void {
    std.debug.assert(channel >= 0);
    const death_signal = linux.prctl(
        @backingInt(linux.PR.SET_PDEATHSIG),
        @backingInt(linux.SIG.KILL),
        0,
        0,
        0,
    );
    if (linux.errno(death_signal) != .SUCCESS) {
        return error.NamespaceParentDeathFailed;
    }
    if (linux.errno(linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS) {
        return error.NamespacePrivilegesFailed;
    }
    try sendReady(channel);
    try receiveReady(channel);
}

fn receiveReady(descriptor: sys.fd.Descriptor) !void {
    std.debug.assert(descriptor >= 0);
    var marker: [1]u8 = undefined;
    if (try sys.fd.read(descriptor, &marker) != 1 or marker[0] != 1) {
        return error.NamespaceLaunchFailed;
    }
}

fn sendReady(descriptor: sys.fd.Descriptor) !void {
    std.debug.assert(descriptor >= 0);
    const marker = [1]u8{1};
    const sent = linux.sendto(
        descriptor,
        &marker,
        marker.len,
        linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT,
        null,
        0,
    );
    if (sent != 1) {
        return error.NamespaceLaunchFailed;
    }
}

fn mapIdentity(child: process.ProcessId, comptime name: []const u8, identity: u32) !void {
    std.debug.assert(child > 1);
    var bytes: [32]u8 = undefined;
    const mapping = try std.fmt.bufPrint(&bytes, "{d} {d} 1\n", .{ identity, identity });
    std.debug.assert(mapping.len <= 24);
    try writeControl(child, name, mapping);
}

fn writeControl(child: process.ProcessId, comptime name: []const u8, bytes: []const u8) !void {
    std.debug.assert(child > 1);
    std.debug.assert(bytes.len > 0);
    std.debug.assert(bytes.len <= 32);
    var path: [64]u8 = undefined;
    const name_z = try std.fmt.bufPrintSentinel(&path, "/proc/{d}/{s}", .{ child, name }, 0);
    const descriptor = try sys.fd.openAtZ(std.posix.AT.FDCWD, name_z, .{
        .ACCMODE = .WRONLY,
        .CLOEXEC = true,
    }, 0);
    defer sys.fd.close(descriptor);
    if (try sys.fd.write(descriptor, bytes) != bytes.len) return error.NamespaceMappingFailed;
}

fn closeDescriptor(descriptor: *sys.fd.Descriptor) void {
    if (descriptor.* >= 0) sys.fd.close(descriptor.*);
    descriptor.* = -1;
}

fn parentDeathWitness(ready: sys.fd.Descriptor) !void {
    switch (try forkContained()) {
        .parent => |child| {
            sys.fd.close(ready);
            _ = try process.waitDirect(child);
        },
        .child => {
            switch (try process.fork()) {
                .parent => {},
                .child => {
                    if (linux.errno(linux.setsid()) != .SUCCESS) process.exit(91);
                    if (try sys.fd.write(ready, &.{1}) != 1) process.exit(92);
                },
            }
            sys.time.sleepMilliseconds(6000);
            process.exit(0);
        },
    }
}
