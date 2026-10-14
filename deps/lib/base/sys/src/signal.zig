const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const process = @import("process/root.zig");
const errno = @import("errno.zig");

const linux = std.os.linux;
const posix = std.posix;
const native_os = builtin.os.tag;

pub const required_capabilities = capabilities.host(&.{ .process, .signal });

const has_process_signals = switch (native_os) {
    .windows, .wasi, .freestanding => false,
    else => true,
};

pub const RawSignal = if (has_process_signals) posix.SIG else enum(c_int) {
    HUP = 1,
    INT = 2,
    QUIT = 3,
    BUS = 7,
    KILL = 9,
    SEGV = 11,
    TSTP = 20,
    PROF = 27,
    WINCH = 28,
    TERM = 15,
};
pub const SignalInfo = if (has_process_signals) posix.siginfo_t else opaque {};
pub const SignalAction = if (has_process_signals) posix.Sigaction else struct {};
pub const AlternateStack = if (has_process_signals) posix.stack_t else struct {
    sp: ?*anyopaque = null,
    size: usize = 0,
    flags: c_uint = 0,
};
pub const AlternateStackPointer = if (has_process_signals) @TypeOf((@as(posix.stack_t, undefined)).sp) else ?*anyopaque;
pub const AlternateStackSize = if (has_process_signals) @TypeOf((@as(posix.stack_t, undefined)).size) else usize;
pub const AlternateStackError = error{
    UnsupportedPlatform,
    StackQueryFailed,
    StackInstallFailed,
};
pub const SignalActionError = error{
    UnsupportedPlatform,
    InvalidSignal,
    ActionFailed,
};
pub const SignalMaskError = error{
    UnsupportedPlatform,
    MaskFailed,
};
pub const SendError = error{
    UnsupportedPlatform,
    ProcessNotFound,
    PermissionDenied,
    SendFailed,
};
pub const ParentDeathError = error{
    UnsupportedPlatform,
    ParentChanged,
    InvalidSignal,
    ArmFailed,
};

pub const SignalPolicy = enum {
    unsupported,
    linux_syscall,
    posix_host,
};

pub const HandlerOptions = struct {
    reset: bool = false,
    restart: bool = false,
};

pub const Handler = *const fn (RawSignal) callconv(.c) void;
pub const FaultHandler = *const fn (RawSignal, *const SignalInfo, ?*anyopaque) callconv(.c) void;

const interrupt_signal: RawSignal = if (has_process_signals) posix.SIG.INT else .INT;
const termination_signals: []const RawSignal = if (has_process_signals)
    &.{ posix.SIG.TERM, posix.SIG.HUP }
else
    &.{};

pub fn supportsProcessSignals() bool {
    return has_process_signals;
}

pub fn signalPolicy() SignalPolicy {
    return switch (native_os) {
        .windows, .wasi, .freestanding => .unsupported,
        .linux => .posix_host,
        else => .posix_host,
    };
}

pub fn faultAddress(signal: RawSignal, info: *const SignalInfo) ?usize {
    if (comptime !has_process_signals) {
        return null;
    }

    if (native_os == .linux and builtin.cpu.arch == .x86_64) {
        const SI_KERNEL = 0x80;
        if (signal == .SEGV and info.code == SI_KERNEL) return null;
    }

    return switch (native_os) {
        .serenity,
        .dragonfly,
        .freebsd,
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => @intFromPtr(info.addr),
        .linux => @intFromPtr(info.fields.sigfault.addr),
        .netbsd => @intFromPtr(info.info.reason.fault.addr),
        .haiku,
        .openbsd,
        => @intFromPtr(info.data.fault.addr),
        .illumos => @intFromPtr(info.reason.fault.addr),
        else => comptime unreachable,
    };
}

pub fn installBusFaultStackGrowthHandler() bool {
    return has_process_signals and native_os != .linux;
}

pub fn segmentationFaultSignal() RawSignal {
    if (comptime !has_process_signals) return .TERM;
    return .SEGV;
}

pub fn busFaultSignal() RawSignal {
    if (comptime !has_process_signals) return .TERM;
    return .BUS;
}

pub fn isBusFaultSignal(signal: RawSignal) bool {
    if (comptime !has_process_signals) return false;
    return signal == .BUS;
}

pub fn stackFaultAction(handler: FaultHandler) SignalAction {
    if (comptime !has_process_signals) {
        return .{};
    }
    return .{
        .handler = .{ .sigaction = handler },
        .mask = emptySignalSet(),
        .flags = posix.SA.SIGINFO | posix.SA.ONSTACK,
    };
}

pub fn siginfoAction(handler: FaultHandler) SignalAction {
    if (comptime !has_process_signals) {
        return .{};
    }
    return .{
        .handler = .{ .sigaction = handler },
        .mask = emptySignalSet(),
        .flags = posix.SA.SIGINFO,
    };
}

pub fn handlerAction(handler: Handler, options: HandlerOptions) SignalAction {
    if (comptime !has_process_signals) return .{};
    var flags: c_uint = 0;
    if (options.reset) flags |= posix.SA.RESETHAND;
    if (options.restart) flags |= posix.SA.RESTART;
    return .{
        .handler = .{ .handler = handler },
        .mask = emptySignalSet(),
        .flags = flags,
    };
}

/// The action that ignores its signal.
pub fn ignoreAction() SignalAction {
    if (comptime !has_process_signals) return .{};
    return .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = emptySignalSet(),
        .flags = 0,
    };
}

/// Whether an action leaves its signal ignored, as a process started under
/// `nohup` inherits for HUP. An ignored signal stays ignored across exec.
pub fn ignores(action: *const SignalAction) bool {
    if (comptime !has_process_signals) return false;
    if ((action.flags & posix.SA.SIGINFO) != 0) return false;
    return action.handler.handler == posix.SIG.IGN;
}

/// Reads a signal's action without changing it.
pub fn readAction(signal: RawSignal, current: *SignalAction) SignalActionError!void {
    return switch (comptime signalPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => signalActionErrorFromLinuxErrno(
            linux.errno(linux.sigaction(signal, null, current)),
        ),
        .posix_host => posix.sigaction(signal, null, current),
    };
}

pub fn installAction(signal: RawSignal, action: *const SignalAction, previous: ?*SignalAction) SignalActionError!void {
    return switch (comptime signalPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => installActionLinux(signal, action, previous),
        .posix_host => installActionPosix(signal, action, previous),
    };
}

pub fn dispatchPreviousAction(
    action: SignalAction,
    signal: RawSignal,
    info: *const SignalInfo,
    context: ?*anyopaque,
) void {
    if (comptime !has_process_signals) {
        return;
    }
    if ((action.flags & posix.SA.SIGINFO) != 0) {
        if (action.handler.sigaction) |handler| handler(signal, info, context);
    } else if (action.handler.handler) |handler| {
        const raw = @intFromPtr(handler);
        if (raw > 1 and raw != std.math.maxInt(usize)) handler(signal);
    }
}

pub fn alternateStackPointer(ptr: [*]u8) AlternateStackPointer {
    return @ptrCast(ptr);
}

pub fn alternateStackSize(len: usize) AlternateStackSize {
    return @intCast(len);
}

pub fn alternateStack(ptr: [*]u8, len: usize) AlternateStack {
    return .{
        .sp = alternateStackPointer(ptr),
        .size = alternateStackSize(len),
        .flags = 0,
    };
}

/// Returns the request that puts `previous` back after `current` was
/// installed over it. Darwin refuses a record smaller than MINSIGSTKSZ,
/// a disable request included, and reports an absent stack with size
/// zero. An absent `previous` so becomes a disable request that names
/// `current`, which Darwin and Linux both accept.
pub fn restoringAlternateStack(previous: AlternateStack, current: AlternateStack) AlternateStack {
    if (alternateStackIsInstalled(previous)) return previous;
    var disabled = current;
    if (comptime has_process_signals) disabled.flags = posix.system.SS.DISABLE;
    return disabled;
}

pub fn readAlternateStack() AlternateStackError!AlternateStack {
    return switch (comptime signalPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => readAlternateStackLinux(),
        .posix_host => readAlternateStackPosix(),
    };
}

pub fn alternateStackIsInstalled(stack: AlternateStack) bool {
    if (comptime !has_process_signals) return false;
    return (stack.flags & posix.system.SS.DISABLE) == 0 and @intFromPtr(stack.sp) != 0;
}

pub fn installAlternateStack(stack: *const AlternateStack) AlternateStackError!void {
    return switch (comptime signalPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => installAlternateStackLinux(stack),
        .posix_host => installAlternateStackPosix(stack),
    };
}

pub fn installTerminationHandlers(handler: Handler) void {
    if (comptime !has_process_signals) return;
    for (termination_signals) |signal| {
        installHandler(signal, handler, posix.SA.RESETHAND | posix.SA.NODEFER);
    }
}

pub fn installInterruptHandler(handler: Handler) void {
    if (comptime !has_process_signals) return;
    installHandler(interrupt_signal, handler, 0);
}

pub fn restoreTerminationDefaults() void {
    if (comptime !has_process_signals) return;
    for (termination_signals) |signal| {
        restoreDefault(signal);
    }
}

pub fn restoreInterruptDefault() void {
    if (comptime !has_process_signals) return;
    restoreDefault(interrupt_signal);
}

/// Writes one byte to `descriptor` from a signal handler, to wake a waiter
/// that polls it. The write is the only call, and on libc targets the
/// interrupted code's errno survives it. A full pipe or any other failure is
/// ignored: the byte only wakes, it carries nothing.
pub fn notifyFromHandler(descriptor: posix.fd_t) void {
    if (comptime !has_process_signals) return;
    const saved = errno.currentHostInterop();
    defer errno.setHostInterop(saved);
    const byte = [1]u8{1};
    _ = posix.system.write(descriptor, &byte, byte.len);
}

pub fn raise(signal: RawSignal) void {
    switch (comptime signalPolicy()) {
        .unsupported => {},
        .linux_syscall => raiseLinux(signal),
        .posix_host => raisePosix(signal),
    }
}

pub fn send(
    process_id: process.ProcessId,
    signal: RawSignal,
    group: bool,
) SendError!void {
    if (process_id <= 1) return error.ProcessNotFound;
    const target = if (group) -process_id else process_id;
    return switch (comptime native_os) {
        .windows, .wasi, .freestanding => error.UnsupportedPlatform,
        .linux => switch (linux.errno(linux.kill(target, signal))) {
            .SUCCESS => {},
            .SRCH => error.ProcessNotFound,
            .ACCES, .PERM => error.PermissionDenied,
            else => error.SendFailed,
        },
        else => posix.kill(target, signal) catch |err| switch (err) {
            error.ProcessNotFound => error.ProcessNotFound,
            error.PermissionDenied => error.PermissionDenied,
            else => error.SendFailed,
        },
    };
}

pub fn bindParentDeathSignal(
    expected_parent: process.ProcessId,
    signal: RawSignal,
) ParentDeathError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    if (expected_parent <= 1 or
        (process.parentProcessId() catch return error.UnsupportedPlatform) != expected_parent)
    {
        return error.ParentChanged;
    }
    const result = linux.prctl(
        @backingInt(linux.PR.SET_PDEATHSIG),
        @backingInt(signal),
        0,
        0,
        0,
    );
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .INVAL => return error.InvalidSignal,
        else => return error.ArmFailed,
    }
    if ((process.parentProcessId() catch return error.UnsupportedPlatform) != expected_parent) {
        return error.ParentChanged;
    }
}

pub const InterruptMask = if (!has_process_signals) struct {
    pub fn begin() !@This() {
        return .{};
    }

    pub fn restore(self: *@This()) void {
        _ = self;
    }
} else struct {
    old_mask: posix.sigset_t,
    active: bool = true,

    pub fn begin() !@This() {
        var mask = emptySignalSet();
        addSignalToSet(&mask, interrupt_signal);

        var old_mask: posix.sigset_t = undefined;
        try applySignalMask(posix.SIG.BLOCK, &mask, &old_mask);
        return .{ .old_mask = old_mask };
    }

    pub fn restore(self: *@This()) void {
        if (!self.active) return;
        applySignalMask(posix.SIG.SETMASK, &self.old_mask, null) catch {};
        self.active = false;
    }
};

pub const BlockMask = if (!has_process_signals) struct {
    pub fn begin(_: []const RawSignal) !@This() {
        return .{};
    }

    pub fn restore(_: *@This()) void {}
} else struct {
    old_mask: posix.sigset_t,
    active: bool = true,

    pub fn begin(signals: []const RawSignal) !@This() {
        var mask = emptySignalSet();
        for (signals) |signal| addSignalToSet(&mask, signal);
        var old_mask: posix.sigset_t = undefined;
        try applySignalMask(posix.SIG.BLOCK, &mask, &old_mask);
        return .{ .old_mask = old_mask };
    }

    pub fn restore(self: *@This()) void {
        if (!self.active) return;
        applySignalMask(posix.SIG.SETMASK, &self.old_mask, null) catch {};
        self.active = false;
    }
};

pub fn unblock(signals: []const RawSignal) SignalMaskError!void {
    if (comptime !has_process_signals) return error.UnsupportedPlatform;
    var mask = emptySignalSet();
    for (signals) |signal| addSignalToSet(&mask, signal);
    try applySignalMask(posix.SIG.UNBLOCK, &mask, null);
}

fn installActionLinux(signal: RawSignal, action: *const SignalAction, previous: ?*SignalAction) SignalActionError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    return signalActionErrorFromLinuxErrno(linux.errno(linux.sigaction(signal, action, previous)));
}

fn installActionPosix(signal: RawSignal, action: *const SignalAction, previous: ?*SignalAction) SignalActionError!void {
    if (comptime !has_process_signals) return error.UnsupportedPlatform;
    posix.sigaction(signal, action, previous);
}

fn readAlternateStackLinux() AlternateStackError!AlternateStack {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    var stack: AlternateStack = undefined;
    switch (linux.errno(linux.sigaltstack(null, &stack))) {
        .SUCCESS => return stack,
        else => return error.StackQueryFailed,
    }
}

fn readAlternateStackPosix() AlternateStackError!AlternateStack {
    if (comptime !has_process_signals) return error.UnsupportedPlatform;
    var stack: AlternateStack = undefined;
    posix.sigaltstack(null, &stack) catch return error.StackQueryFailed;
    return stack;
}

fn installAlternateStackLinux(stack: *const AlternateStack) AlternateStackError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    return alternateStackErrorFromLinuxErrno(linux.errno(linux.sigaltstack(stack, null)));
}

fn installAlternateStackPosix(stack: *const AlternateStack) AlternateStackError!void {
    if (comptime !has_process_signals) return error.UnsupportedPlatform;
    posix.sigaltstack(stack, null) catch return error.StackInstallFailed;
}

fn raiseLinux(signal: RawSignal) void {
    if (comptime native_os != .linux) return;
    const filled = linux.sigfillset();
    var original: posix.sigset_t = undefined;
    applySignalMask(posix.SIG.BLOCK, &filled, &original) catch return;
    const rc = linux.tkill(process.currentThreadId() catch return, signal);
    applySignalMask(posix.SIG.SETMASK, &original, null) catch {};
    _ = linux.errno(rc);
}

fn raisePosix(signal: RawSignal) void {
    if (comptime !has_process_signals) return;
    posix.raise(signal) catch {};
}

fn emptySignalSet() posix.sigset_t {
    return posix.sigemptyset();
}

fn addSignalToSet(set: *posix.sigset_t, signal: RawSignal) void {
    posix.sigaddset(set, signal);
}

fn applySignalMask(flags: u32, set: ?*const posix.sigset_t, old_set: ?*posix.sigset_t) SignalMaskError!void {
    return switch (comptime signalPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => signalMaskLinux(flags, set, old_set),
        .posix_host => signalMaskPosix(flags, set, old_set),
    };
}

fn signalMaskLinux(flags: u32, set: ?*const posix.sigset_t, old_set: ?*posix.sigset_t) SignalMaskError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    switch (linux.errno(linux.sigprocmask(flags, set, old_set))) {
        .SUCCESS => {},
        else => return error.MaskFailed,
    }
}

fn signalMaskPosix(flags: u32, set: ?*const posix.sigset_t, old_set: ?*posix.sigset_t) SignalMaskError!void {
    if (comptime !has_process_signals) return error.UnsupportedPlatform;
    posix.sigprocmask(flags, set, old_set);
}

fn signalActionErrorFromLinuxErrno(err: linux.E) SignalActionError!void {
    return switch (err) {
        .SUCCESS => {},
        .INVAL => error.InvalidSignal,
        else => error.ActionFailed,
    };
}

fn alternateStackErrorFromLinuxErrno(err: linux.E) AlternateStackError!void {
    return switch (err) {
        .SUCCESS => {},
        else => error.StackInstallFailed,
    };
}

fn installHandler(signal: RawSignal, handler: Handler, flags: c_uint) void {
    if (comptime !has_process_signals) return;
    var act = posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = switch (native_os) {
            .macos => 0,
            else => emptySignalSet(),
        },
        .flags = flags,
    };
    installAction(signal, &act, null) catch {};
}

/// Restores the default action for `signal`, so it ends the process as the kernel would.
pub fn restoreDefault(signal: RawSignal) void {
    if (comptime !has_process_signals) return;
    var act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = switch (native_os) {
            .macos => 0,
            else => emptySignalSet(),
        },
        .flags = 0,
    };
    installAction(signal, &act, null) catch {};
}

fn ignoredTestHandler(_: RawSignal) callconv(.c) void {}
