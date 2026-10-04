const std = @import("std");
const builtin = @import("builtin");
const sys = @import("timing_runner_sys");
const Io = std.Io;

const guard_io: Io = sys.thread.ThreadedIo.global_single_threaded.io();

/// Fixed state shared only by the test thread and its process-lifetime watchdog.
/// Clock samples and every transition are serialized by Guard.mutex.
const State = struct {
    phase: enum { idle, armed, expired, stopping } = .idle,
    generation: u64 = 0,
    last_ns: u64 = 0,
    deadline_ns: u64 = 0,
    test_index: usize = 0,
    repeat_index: usize = 0,

    fn sample(self: *State, now: u64) !void {
        if (now < self.last_ns) return error.ClockRegressed;
        self.last_ns = now;
    }

    fn arm(self: *State, now: u64, duration: u64, index: usize, repeat: usize) !u64 {
        if (self.phase != .idle) return error.InvalidDeadlineState;
        try self.sample(now);
        const expires = std.math.add(u64, now, duration) catch return error.DeadlineOverflow;
        const next = std.math.add(u64, self.generation, 1) catch return error.GenerationExhausted;
        if (duration == 0) return error.DisabledDeadline;
        self.deadline_ns = expires;
        self.generation = next;
        self.test_index = index;
        self.repeat_index = repeat;
        self.phase = .armed;
        return next;
    }

    fn expired(self: *State, now: u64) !bool {
        try self.sample(now);
        if (self.phase == .armed and now >= self.deadline_ns) self.phase = .expired;
        return self.phase == .expired;
    }

    fn complete(self: *State, now: u64, generation: u64) !void {
        if (self.generation != generation) return error.StaleGeneration;
        if (try self.expired(now)) return error.DeadlineExpired;
        if (self.phase != .armed) return error.InvalidDeadlineState;
        self.phase = .idle;
    }

    fn stop(self: *State) !void {
        if (self.phase != .idle) return error.InvalidDeadlineState;
        self.phase = .stopping;
    }
};

/// Tests stay on their original thread. The guard owns one thread, its default
/// virtual stack, and this fixed record, independently of std.testing lifetimes.
/// Keep this record at a stable address from start through stop.
pub const Guard = struct {
    owner_pid: sys.process.ProcessId = 0,
    duration_ns: u64 = 0,
    state: State = .{},
    clock: sys.time.AwakeClock = .{},
    mutex: sys.thread.Mutex = .{},
    condition: sys.thread.Condition = .{},
    thread: ?sys.thread.JoinHandle = null,

    pub fn start(self: *Guard, milliseconds: u64) !void {
        if (comptime builtin.os.tag != .linux) return error.UnsupportedDeadlineTarget;
        if (milliseconds == 0) return error.DisabledDeadline;
        const duration = std.math.mul(u64, milliseconds, std.time.ns_per_ms) catch
            return error.DeadlineOverflow;
        self.owner_pid = try sys.process.currentProcessId();
        if (self.owner_pid <= 0) return error.InvalidProcessOwner;
        self.duration_ns = duration;
        self.state = .{ .last_ns = (try self.clock.now()).asNanoseconds() };
        self.thread = try sys.thread.spawn(watch, .{self});
    }

    pub fn arm(self: *Guard, test_index: usize, repeat_index: usize) u64 {
        if (!self.owned()) terminateCurrent();
        self.mutex.lock();
        defer self.mutex.unlock();
        const generation = self.state.arm(self.now(), self.duration_ns, test_index, repeat_index) catch
            terminateCurrent();
        self.condition.signal();
        return generation;
    }

    pub fn complete(self: *Guard, generation: u64) void {
        if (!self.owned()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.state.complete(self.now(), generation) catch terminateCurrent();
        self.condition.signal();
    }

    pub fn stop(self: *Guard) void {
        if (!self.owned()) return;
        const thread = self.thread orelse return;
        self.mutex.lock();
        self.state.stop() catch terminateCurrent();
        self.condition.signal();
        self.mutex.unlock();
        thread.join();
        self.thread = null;
    }

    fn owned(self: *const Guard) bool {
        const current = sys.process.currentProcessId() catch terminateCurrent();
        return current == self.owner_pid;
    }

    fn now(self: *Guard) u64 {
        return (self.clock.now() catch terminateCurrent()).asNanoseconds();
    }

    fn watch(self: *Guard) void {
        if (!self.owned()) terminateCurrent();
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.state.expired(self.now()) catch terminateCurrent()) terminateCurrent();
            const timeout: Io.Timeout = switch (self.state.phase) {
                .stopping => return,
                .expired => unreachable,
                .idle => .none,
                .armed => .{ .deadline = .{
                    .clock = .awake,
                    .raw = Io.Timestamp.fromNanoseconds(@intCast(self.state.deadline_ns)),
                } },
            };
            self.condition.raw.waitTimeout(guard_io, &self.mutex.raw, timeout) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => terminateCurrent(),
            };
        }
    }
};

/// No stderr, allocator, exit-handler or test lock can delay the force signal.
/// Never signal a remembered owner PID, a process group or the build parent.
fn terminateCurrent() noreturn {
    const current = sys.process.currentProcessId() catch @trap();
    if (current <= 0) @trap();
    sys.process.signalChildId(current, .kill) catch @trap();
    @trap();
}

test "deadline completion before expiry preserves the next shared generation" {
    var state: State = .{};
    const first = try state.arm(10, 5, 3, 0);
    try state.complete(14, first);
    const second = try state.arm(14, 8, 4, 1);
    try std.testing.expectError(error.StaleGeneration, state.complete(15, first));
    try std.testing.expect(!try state.expired(15));
    try std.testing.expectEqual(@as(u64, 22), state.deadline_ns);
    try state.complete(21, second);
    try state.stop();
    try std.testing.expectEqual(.stopping, state.phase);
}

test "deadline equality and late completion are terminal" {
    for ([_]u64{ 15, 16 }) |finish| {
        var state: State = .{};
        const generation = try state.arm(10, 5, 0, 0);
        try std.testing.expectError(error.DeadlineExpired, state.complete(finish, generation));
        try std.testing.expectError(error.InvalidDeadlineState, state.stop());
        try std.testing.expectError(error.InvalidDeadlineState, state.arm(17, 5, 1, 0));
    }
}

test "deadline refuses regression overflow disabled and exhausted generations" {
    var state: State = .{ .last_ns = 10 };
    try std.testing.expectError(error.ClockRegressed, state.arm(9, 5, 0, 0));
    try std.testing.expectError(error.DisabledDeadline, state.arm(10, 0, 0, 0));
    try std.testing.expectError(error.DeadlineOverflow, state.arm(10, std.math.maxInt(u64), 0, 0));
    state.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationExhausted, state.arm(10, 5, 0, 0));
    state = .{};
    _ = try state.arm(10, 5, 0, 0);
    try std.testing.expectError(error.ClockRegressed, state.expired(9));
    try std.testing.expectError(error.InvalidDeadlineState, state.stop());
}

test "deadline setup refuses unavailable clocks and invalid durations" {
    if (comptime builtin.os.tag != .linux) {
        var guard: Guard = .{};
        try std.testing.expectError(error.UnsupportedDeadlineTarget, guard.start(1));
        return;
    }
    const MissingClock = struct {
        fn read(_: ?*anyopaque) sys.time.ClockError!sys.time.AwakeInstant {
            return error.ClockUnavailable;
        }
    };
    var guard: Guard = .{ .clock = .{ .read_fn = MissingClock.read } };
    try std.testing.expectError(error.DisabledDeadline, guard.start(0));
    try std.testing.expectError(error.DeadlineOverflow, guard.start(std.math.maxInt(u64)));
    try std.testing.expectError(error.ClockUnavailable, guard.start(1));
    try std.testing.expect(guard.thread == null);
}

test "deadline watchdog disarms joins and leaves main thread unchanged" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const caller = sys.thread.currentId();
    var guard: Guard = .{};
    try guard.start(2000);
    defer guard.stop();
    const first = guard.arm(0, 0);
    guard.complete(first);
    const second = guard.arm(1, 0);
    guard.complete(second);
    guard.stop();
    try std.testing.expect(guard.thread == null);
    try std.testing.expectEqual(caller, sys.thread.currentId());
}

test "fork child bypasses inherited guard mutex and cannot stop the parent" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var guard: Guard = .{};
    try guard.start(2000);
    defer guard.stop();
    const generation = guard.arm(0, 0);
    guard.mutex.lock();
    const child = sys.process.fork() catch |err| {
        guard.mutex.unlock();
        guard.complete(generation);
        return err;
    };
    switch (child) {
        .child => {
            guard.complete(generation);
            guard.stop();
            sys.process.exit(0);
        },
        .parent => |pid| {
            guard.mutex.unlock();
            const term = try sys.process.waitDirect(pid);
            guard.complete(generation);
            try std.testing.expectEqual(sys.process.Termination{ .exited = 0 }, term);
            try std.testing.expect(guard.thread != null);
        },
    }
}
