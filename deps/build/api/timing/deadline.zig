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
