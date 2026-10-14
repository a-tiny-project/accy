const std = @import("std");
const builtin = @import("builtin");

const capabilities = @import("capabilities.zig");
const process = @import("process/root.zig");
const signal_mod = @import("signal.zig");
const linux = std.os.linux;

pub const required_capabilities = capabilities.host(&.{ .process, .signal, .time });

const supported = builtin.os.tag == .linux;

pub const TimerId = i32;
pub const Signal = signal_mod.RawSignal;
pub const ThreadId = process.ThreadId;
pub const invalid_timer_id: TimerId = -1;
pub const sigev_thread_id: c_int = 4;
pub const sample_signal: Signal = .PROF;

pub const SignalValue = extern union {
    int: c_int,
    ptr: ?*anyopaque,
};

const sigevent_pad_size = (64 - @sizeOf(SignalValue) - @sizeOf(c_int) - @sizeOf(c_int)) / @sizeOf(c_int);

pub const SignalEventData = extern union {
    pad: [sigevent_pad_size]c_int,
    tid: linux.pid_t,
};

pub const SignalEvent = extern struct {
    value: SignalValue,
    signo: c_int,
    notify: c_int,
    data: SignalEventData,
};

pub const Timer = struct {
    id: TimerId = invalid_timer_id,

    pub fn createForCurrentThread(signal: Signal) !Timer {
        if (!supportsThreadCpuTimers()) return error.UnsupportedPlatform;
        return createForThread(signal, try process.currentThreadId());
    }

    pub fn createForThread(signal: Signal, thread_id: ThreadId) !Timer {
        var event = threadSignalEvent(signal, thread_id);
        var id: TimerId = invalid_timer_id;
        try timerCreate(.THREAD_CPUTIME_ID, &event, &id);
        return .{ .id = id };
    }

    pub fn close(self: *Timer) void {
        if (self.id == invalid_timer_id) return;
        deleteTimer(self.id);
        self.id = invalid_timer_id;
    }

    pub fn startInterval(self: Timer, time_ns: u64) !void {
        if (self.id == invalid_timer_id) return error.UninitializedTimer;
        var spec = intervalSpec(time_ns);
        try timerSetTime(self.id, &spec);
    }

    pub fn startOneShot(self: Timer, time_ns: u64) !void {
        if (self.id == invalid_timer_id) return error.UninitializedTimer;
        var spec = oneShotSpec(time_ns);
        try timerSetTime(self.id, &spec);
    }

    pub fn stop(self: Timer) !void {
        if (self.id == invalid_timer_id) return error.UninitializedTimer;
        var spec = zeroSpec();
        try timerSetTime(self.id, &spec);
    }
};

pub fn supportsThreadCpuTimers() bool {
    return supported;
}

pub fn threadSignalEvent(signal: Signal, thread_id: ThreadId) SignalEvent {
    return .{
        .value = .{ .int = 0 },
        .signo = @intCast(@backingInt(signal)),
        .notify = sigev_thread_id,
        .data = .{ .tid = thread_id },
    };
}

pub fn intervalSpec(time_ns: u64) linux.itimerspec {
    const value = timespecFromNs(time_ns);
    return .{ .it_interval = value, .it_value = value };
}

pub fn oneShotSpec(time_ns: u64) linux.itimerspec {
    return .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = timespecFromNs(time_ns),
    };
}

fn zeroSpec() linux.itimerspec {
    return .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 0 },
    };
}

fn timespecFromNs(time_ns: u64) linux.timespec {
    const sec = time_ns / std.time.ns_per_s;
    const nsec = time_ns % std.time.ns_per_s;
    return .{
        .sec = @intCast(@min(sec, @as(u64, @intCast(std.math.maxInt(isize))))),
        .nsec = @intCast(nsec),
    };
}

fn timerCreate(clock_id: linux.clockid_t, event: *const SignalEvent, id: *TimerId) !void {
    if (!supportsThreadCpuTimers()) return error.UnsupportedPlatform;
    const rc = linux.syscall3(.timer_create, @backingInt(clock_id), @intFromPtr(event), @intFromPtr(id));
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .AGAIN => return error.ProcessResources,
        .INVAL => return error.InvalidTimerConfiguration,
        .NOMEM => return error.SystemResources,
        .PERM, .ACCES => return error.PermissionDenied,
        else => return error.TimerCreateFailed,
    }
}

fn timerSetTime(id: TimerId, spec: *const linux.itimerspec) !void {
    if (!supportsThreadCpuTimers()) return error.UnsupportedPlatform;
    const rc = linux.syscall4(.timer_settime, @as(usize, @bitCast(@as(isize, id))), 0, @intFromPtr(spec), 0);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .INVAL => return error.InvalidTimer,
        else => return error.TimerSetTimeFailed,
    }
}

fn deleteTimer(id: TimerId) void {
    if (!supportsThreadCpuTimers()) return;
    switch (linux.errno(linux.syscall1(.timer_delete, @as(usize, @bitCast(@as(isize, id)))))) {
        .SUCCESS => {},
        else => unreachable,
    }
}
