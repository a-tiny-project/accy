//! CPU scheduling priority of the calling thread and the children it spawns.

const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;
const native_os = builtin.os.tag;

/// The largest niceness POSIX schedulers accept. Larger is lower priority.
pub const niceness_max: u8 = 19;

pub const PriorityError = error{
    UnsupportedPlatform,
    Unexpected,
};

/// Returns the calling thread's niceness, from -20 to 19.
/// Linux keeps niceness per thread; Darwin keeps it per process.
pub fn currentNiceness() PriorityError!i8 {
    switch (native_os) {
        .linux => {
            // The raw syscall returns 20 - niceness, so a success is 1 to 40.
            const rc = linux.syscall2(.getpriority, process_scope, 0);
            if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
            const encoded: isize = @bitCast(rc);
            if (encoded < 1 or encoded > 40) return error.Unexpected;
            return @intCast(20 - encoded);
        },
        .macos => {
            // -1 is a valid niceness, so only a changed errno reports failure.
            std.c._errno().* = 0;
            const value = darwin.getpriority(process_scope, 0);
            if (std.c._errno().* != 0) return error.Unexpected;
            if (value < -20 or value > niceness_max) return error.Unexpected;
            return @intCast(value);
        },
        else => return error.UnsupportedPlatform,
    }
}

/// Lowers the calling thread's CPU priority to `niceness`, which threads and
/// children it later creates inherit. Threads that already exist keep theirs
/// on Linux, so call it before the process starts any.
/// It never raises priority: at or above `niceness` already, it changes
/// nothing. Raising needs a privilege an unprivileged caller lacks, so the
/// call cannot fail for want of one.
pub fn lowerPriority(niceness: u8) PriorityError!void {
    std.debug.assert(niceness <= niceness_max);
    const current = try currentNiceness();
    if (current >= niceness) return;
    switch (native_os) {
        .linux => {
            const rc = linux.syscall3(.setpriority, process_scope, 0, niceness);
            if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
        },
        .macos => {
            if (darwin.setpriority(process_scope, 0, niceness) != 0) return error.Unexpected;
        },
        else => return error.UnsupportedPlatform,
    }
    std.debug.assert(try currentNiceness() == niceness);
}

/// `PRIO_PROCESS` on Linux and Darwin. With id 0 it names the caller: the
/// calling thread on Linux, the process on Darwin.
const process_scope = 0;

const darwin = struct {
    extern "c" fn getpriority(which: c_int, who: c_uint) c_int;
    extern "c" fn setpriority(which: c_int, who: c_uint, priority: c_int) c_int;
};

fn lowerAndFork(outcome: *anyerror!void) void {
    outcome.* = lowerAndForkChecked();
}

fn lowerAndForkChecked() !void {
    const before = try currentNiceness();
    // A runner below niceness 0 has no unsigned target here, and one already
    // at the floor of priority has nothing left to lower.
    if (before < 0 or before == niceness_max) return error.SkipZigTest;
    const target: u8 = @intCast(@min(@as(i16, before) + 3, niceness_max));
    try lowerPriority(target);
    try std.testing.expectEqual(@as(i8, @intCast(target)), try currentNiceness());
    // A request above the current priority changes nothing.
    try lowerPriority(@intCast(@max(before, 0)));
    try std.testing.expectEqual(@as(i8, @intCast(target)), try currentNiceness());
    // A child forked after the call runs at the lowered priority. It reports
    // its niceness as its exit status.
    const forked = linux.fork();
    if (linux.errno(forked) != .SUCCESS) return error.ForkFailed;
    if (forked == 0) {
        const observed = currentNiceness() catch linux.exit(255);
        linux.exit(observed);
    }
    var raw_status: i32 = 0;
    const waited = linux.wait4(@intCast(forked), &raw_status, 0, null);
    if (linux.errno(waited) != .SUCCESS) return error.WaitFailed;
    const status: u32 = @bitCast(raw_status);
    try std.testing.expect(linux.W.IFEXITED(status));
    try std.testing.expectEqual(target, linux.W.EXITSTATUS(status));
}
