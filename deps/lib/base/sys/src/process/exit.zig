//! Waits for an unreaped child to exit or for a wake descriptor to turn
//! readable, without a polling sleep. Linux watches the child through a pidfd
//! (5.3 or later) and darwin through a kqueue's EVFILT_PROC/NOTE_EXIT. Where
//! neither opens, and where the caller has no wake descriptor, every wait is
//! bounded instead: it returns within `bound_ms`, so a caller that checks its
//! child after each wait behaves as a 10 ms poll did.

const std = @import("std");
const builtin = @import("builtin");
const inspect = @import("inspect/root.zig");
const time = @import("../time.zig");
const fd = @import("../fd.zig");

const posix = std.posix;
const native_os = builtin.os.tag;
const darwin = native_os.isDarwin();

pub const bound_ms: i32 = 10;

pub const Wake = enum {
    /// The child exited. It stays unreaped for its owner.
    exited,
    /// The wake descriptor turned readable.
    woken,
    /// The bound passed with neither.
    bounded,
};

pub const ExitWait = struct {
    /// A pidfd on Linux, a kqueue on darwin, or null when neither opened.
    descriptor: ?posix.fd_t,
    state: State,

    const State = enum { watching, exit_pending, exit_reported };

    /// Watches `pid`, an unreaped child of the caller, which keeps its pid
    /// from reuse while it is watched. Any failure leaves the wait bounded.
    pub fn open(pid: inspect.ProcessId) ExitWait {
        std.debug.assert(pid > 1);
        if (comptime native_os == .linux) {
            const descriptor = inspect.exitDescriptor(pid) catch null;
            return .{ .descriptor = descriptor, .state = .watching };
        }
        if (comptime darwin) return openKqueue(pid);
        return .{ .descriptor = null, .state = .watching };
    }

    pub fn close(self: *ExitWait) void {
        if (self.descriptor) |descriptor| fd.close(descriptor);
        self.* = undefined;
    }

    /// Blocks until the child exits or `wake` turns readable. The child's
    /// exit is reported once; later waits are bounded, so a caller that has
    /// not yet seen the exit through its own wait checks again soon. Without
    /// a wake descriptor the wait is bounded, because a signal that only sets
    /// a flag could otherwise go unseen until the child exits.
    pub fn wait(self: *ExitWait, wake: ?posix.fd_t) Wake {
        switch (self.state) {
            .exit_pending => {
                self.state = .exit_reported;
                return .exited;
            },
            .exit_reported => return bounded(wake),
            .watching => {},
        }
        const watched = self.descriptor orelse return bounded(wake);
        const woken = wake orelse return bounded(wake);
        const result = if (comptime native_os == .linux)
            waitLinux(watched, woken)
        else if (comptime darwin)
            waitKqueue(watched, woken)
        else
            bounded(wake);
        if (result == .exited) self.state = .exit_reported;
        return result;
    }

    fn openKqueue(pid: inspect.ProcessId) ExitWait {
        if (comptime !darwin) unreachable;
        const queue = std.c.kqueue();
        if (queue < 0) return .{ .descriptor = null, .state = .watching };
        const change = [1]std.c.Kevent{.{
            .ident = @intCast(pid),
            .filter = std.c.EVFILT.PROC,
            .flags = std.c.EV.ADD,
            .fflags = std.c.NOTE.EXIT,
            .data = 0,
            .udata = 0,
        }};
        var none: [0]std.c.Kevent = .{};
        if (std.c.kevent(queue, &change, 1, &none, 0, null) == 0) {
            return .{ .descriptor = queue, .state = .watching };
        }
        const exited = std.c.errno(@as(c_int, -1)) == .SRCH;
        fd.close(queue);
        // A child that exited before the watch reports its exit at once.
        return .{ .descriptor = null, .state = if (exited) .exit_pending else .watching };
    }
};

fn waitLinux(pidfd: posix.fd_t, wake: posix.fd_t) Wake {
    var descriptors = [2]posix.pollfd{
        .{ .fd = pidfd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = wake, .events = posix.POLL.IN, .revents = 0 },
    };
    // poll restarts after a handled signal, whose handler wrote `wake`.
    _ = posix.poll(&descriptors, -1) catch return bounded(wake);
    if (descriptors[0].revents != 0) return .exited;
    std.debug.assert(descriptors[1].revents != 0);
    return .woken;
}

fn waitKqueue(queue: posix.fd_t, wake: posix.fd_t) Wake {
    if (comptime !darwin) unreachable;
    const change = [1]std.c.Kevent{.{
        .ident = @intCast(wake),
        .filter = std.c.EVFILT.READ,
        .flags = std.c.EV.ADD,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    var events: [2]std.c.Kevent = undefined;
    while (true) {
        const count = std.c.kevent(queue, &change, 1, &events, events.len, null);
        if (count < 0) {
            if (std.c.errno(count) == .INTR) continue;
            return bounded(wake);
        }
        for (events[0..@intCast(count)]) |event| {
            if (event.filter == std.c.EVFILT.PROC) return .exited;
        }
        if (count > 0) return .woken;
    }
}

fn bounded(wake: ?posix.fd_t) Wake {
    const descriptor = wake orelse {
        time.sleepMilliseconds(@intCast(bound_ms));
        return .bounded;
    };
    var descriptors = [1]posix.pollfd{
        .{ .fd = descriptor, .events = posix.POLL.IN, .revents = 0 },
    };
    const count = posix.poll(&descriptors, bound_ms) catch {
        time.sleepMilliseconds(@intCast(bound_ms));
        return .bounded;
    };
    return if (count > 0) .woken else .bounded;
}

const control = @import("control.zig");

fn spawnReader() !control.Child {
    return control.spawn(std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "read line" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}
