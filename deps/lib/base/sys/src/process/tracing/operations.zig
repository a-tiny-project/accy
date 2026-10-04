const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const ptrace = linux.PTRACE;

pub const Event = enum { fork, vfork, clone, exec, stop, signal, syscall };
pub const Observation = struct {
    pid: i32,
    state: union(enum) {
        ended: struct { code: ?u8, signal: ?u8 },
        stopped: struct { event: Event, signal: u8 },
    },
};

pub fn attach(pid: i32, syscalls: bool) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
    const options = ptrace.O.TRACEFORK | ptrace.O.TRACEVFORK | ptrace.O.TRACECLONE |
        ptrace.O.TRACEEXEC | ptrace.O.EXITKILL |
        (if (syscalls) ptrace.O.TRACESYSGOOD else @as(u32, 0));
    try operation(ptrace.SEIZE, pid, options);
}

pub fn continueTask(pid: i32, signal: u8, syscalls: bool) !void {
    try operation(if (syscalls) ptrace.SYSCALL else ptrace.CONT, pid, signal);
}
pub fn listen(pid: i32) !void {
    try operation(ptrace.LISTEN, pid, 0);
}
pub fn terminate(pid: i32) void {
    _ = linux.kill(pid, .KILL);
}

pub fn message(pid: i32) !usize {
    var result: usize = 0;
    try operation(ptrace.GETEVENTMSG, pid, @intFromPtr(&result));
    return result;
}

pub fn wait() !Observation {
    var status: i32 = 0;
    const result = linux.waitpid(-1, &status, 0x40000000);
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .INTR => return error.Interrupted,
        .CHILD => return error.NoChildren,
        else => return error.TraceWaitFailed,
    }
    const pid: i32 = @intCast(result);
    if ((status & 0xff) != 0x7f) {
        const signal: ?u8 = if ((status & 0x7f) == 0) null else @intCast(status & 0x7f);
        const code: ?u8 = if (signal == null) @intCast((status >> 8) & 0xff) else null;
        return .{ .pid = pid, .state = .{ .ended = .{ .code = code, .signal = signal } } };
    }
    const event: Event = switch (status >> 16) {
        ptrace.EVENT.FORK => .fork,
        ptrace.EVENT.VFORK => .vfork,
        ptrace.EVENT.CLONE => .clone,
        ptrace.EVENT.EXEC => .exec,
        ptrace.EVENT.STOP => .stop,
        0 => if (((status >> 8) & 0xff) == 133) .syscall else .signal,
        else => return error.UnexpectedTraceEvent,
    };
    return .{ .pid = pid, .state = .{ .stopped = .{
        .event = event,
        .signal = @intCast((status >> 8) & 0xff),
    } } };
}

fn operation(request: u32, pid: i32, data: usize) !void {
    std.debug.assert(pid > 0);
    const result = linux.ptrace(request, pid, 0, data, 0);
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        .PERM, .ACCES => error.TracingPermissionDenied,
        else => error.TraceOperationFailed,
    };
}
