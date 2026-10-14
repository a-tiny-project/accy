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

/// The line that names a test whose deadline expired, and where it goes.
///
/// The kill must never wait on this line, so the write goes to a private description of
/// the stderr FIFO, opened nonblocking: the flag lives on that description and leaves the
/// shared stderr blocking. A FIFO takes a line of at most PIPE_BUF bytes whole or refuses
/// it. Any other stderr, and any failure here, leaves the kill unnamed.
const Report = struct {
    /// The private description, or -1 for no report.
    descriptor: i32 = -1,
    /// Set by the watchdog once SIGPIPE is blocked for its thread, so a write to a FIFO
    /// with no reader cannot end the process before the deadline's own signal does.
    armed: bool = false,
    line: [line_bytes]u8 = undefined,
    len: usize = 0,

    /// POSIX's least PIPE_BUF is 512, and Linux's is 4096.
    const line_bytes = 512;
    const prefix = "\ntest deadline: ";
    const cut = "...";

    fn open(self: *Report) void {
        if (comptime builtin.os.tag != .linux) return;
        const descriptor = sys.fd.openAtZ(sys.fd.cwd_descriptor, "/proc/self/fd/2", .{
            .ACCMODE = .WRONLY,
            .NONBLOCK = true,
            .CLOEXEC = true,
            .NOCTTY = true,
        }, 0) catch return;
        const file: Io.File = .{ .handle = descriptor, .flags = .{ .nonblocking = true } };
        const status = file.stat(guard_io) catch {
            sys.fd.close(descriptor);
            return;
        };
        if (status.kind != .named_pipe) {
            sys.fd.close(descriptor);
            return;
        }
        self.descriptor = descriptor;
    }

    fn close(self: *Report) void {
        if (self.descriptor < 0) return;
        sys.fd.close(self.descriptor);
        self.descriptor = -1;
        self.armed = false;
    }

    /// Formats the line for the test about to run. A name too long for the line is cut.
    fn name(self: *Report, test_name: []const u8, duration_ns: u64) void {
        var suffix_storage: [48]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_storage, " exceeded {d} ms\n", .{
            duration_ns / std.time.ns_per_ms,
        }) catch unreachable;
        const room = line_bytes - prefix.len - suffix.len;
        var writer: Io.Writer = .fixed(&self.line);
        writer.writeAll(prefix) catch unreachable;
        if (test_name.len <= room) {
            writer.writeAll(test_name) catch unreachable;
        } else {
            writer.writeAll(test_name[0 .. room - cut.len]) catch unreachable;
            writer.writeAll(cut) catch unreachable;
        }
        writer.writeAll(suffix) catch unreachable;
        self.len = writer.end;
    }

    /// One write, never retried and never read back: the caller kills the process next
    /// whatever happened here.
    fn emit(self: *const Report) void {
        self.emitWith(sys.tinyrt.writeRaw);
    }

    fn emitWith(self: *const Report, write: anytype) void {
        if (!self.armed or self.descriptor < 0 or self.len == 0) return;
        _ = write(self.descriptor, &self.line, self.len);
    }

    /// Blocks SIGPIPE for the calling thread alone, for the rest of its life.
    fn blockBrokenPipe() bool {
        _ = sys.signal.BlockMask.begin(&.{.PIPE}) catch return false;
        return true;
    }
};

/// One test's own deadline, in place of the guard's. `test_index` is its position in
/// `builtin.test_functions`.
pub const Override = struct {
    test_index: usize,
    milliseconds: u64,
};

/// The most tests one guard gives their own deadline.
pub const max_overrides = 8;

/// Tests stay on their original thread. The guard owns one thread, its default
/// virtual stack, and this fixed record, independently of std.testing lifetimes.
/// Keep this record at a stable address from start through stop.
pub const Guard = struct {
    owner_pid: sys.process.ProcessId = 0,
    duration_ns: u64 = 0,
    override_tests: [max_overrides]usize = undefined,
    override_ns: [max_overrides]u64 = undefined,
    override_count: usize = 0,
    /// The name of the test at a position in `builtin.test_functions`. Null leaves every
    /// kill unnamed.
    names: ?*const fn (test_index: usize) []const u8 = null,
    report: Report = .{},
    /// Blocks SIGPIPE for the watchdog. A failure leaves the report off and the deadline on.
    block_broken_pipe: *const fn () bool = Report.blockBrokenPipe,
    state: State = .{},
    clock: sys.time.AwakeClock = .{},
    mutex: sys.thread.Mutex = .{},
    condition: sys.thread.Condition = .{},
    thread: ?sys.thread.JoinHandle = null,

    /// Every test gets `milliseconds`, except each test in `overrides`, which gets its own.
    pub fn start(self: *Guard, milliseconds: u64, overrides: []const Override) !void {
        if (comptime builtin.os.tag != .linux) return error.UnsupportedDeadlineTarget;
        if (milliseconds == 0) return error.DisabledDeadline;
        const duration = std.math.mul(u64, milliseconds, std.time.ns_per_ms) catch
            return error.DeadlineOverflow;
        if (overrides.len > max_overrides) return error.TooManyDeadlineOverrides;
        for (overrides, 0..) |override, index| {
            if (override.milliseconds == 0) return error.DisabledDeadline;
            for (overrides[0..index]) |prior| {
                if (prior.test_index == override.test_index) return error.DuplicateDeadlineOverride;
            }
            self.override_tests[index] = override.test_index;
            self.override_ns[index] = std.math.mul(u64, override.milliseconds, std.time.ns_per_ms) catch
                return error.DeadlineOverflow;
        }
        self.override_count = overrides.len;
        self.owner_pid = try sys.process.currentProcessId();
        if (self.owner_pid <= 0) return error.InvalidProcessOwner;
        self.duration_ns = duration;
        self.state = .{ .last_ns = (try self.clock.now()).asNanoseconds() };
        if (self.names != null) self.report.open();
        errdefer self.report.close();
        self.thread = try sys.thread.spawn(watch, .{self});
    }

    pub fn arm(self: *Guard, test_index: usize, repeat_index: usize) u64 {
        if (!self.owned()) terminateCurrent();
        self.mutex.lock();
        defer self.mutex.unlock();
        const duration = self.bound(test_index);
        const generation = self.state.arm(self.now(), duration, test_index, repeat_index) catch
            terminateCurrent();
        if (self.names) |name_of| self.report.name(name_of(test_index), duration);
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
        self.report.close();
    }

    /// The deadline `test_index` runs under: its own when it has one, the guard's otherwise.
    fn bound(self: *const Guard, test_index: usize) u64 {
        for (self.override_tests[0..self.override_count], self.override_ns[0..self.override_count]) |listed, ns| {
            if (listed == test_index) return ns;
        }
        return self.duration_ns;
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
        const pipe_blocked = self.block_broken_pipe();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.report.armed = pipe_blocked;
        while (true) {
            if (self.state.expired(self.now()) catch terminateCurrent()) {
                self.report.emit();
                terminateCurrent();
            }
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

const WriteProbe = struct {
    var calls: usize = 0;

    /// Answers as an interrupted write does.
    fn interrupted(_: c_int, _: [*]const u8, _: usize) usize {
        calls += 1;
        const eintr: isize = 4;
        return @bitCast(-eintr);
    }
};

/// A forked test process whose one test never returns, and what its parent saw of it.
const Hang = struct {
    term: sys.process.Termination,
    /// Everything the process wrote to a piped stderr.
    output: [64 * 1024]u8 = undefined,
    len: usize = 0,
    /// Bytes a regular-file stderr holds afterwards.
    file_bytes: u64 = 0,

    const Stderr = enum { drained, full, unread, regular, device, contended, stopped, unmasked };
    const name = "fixture.test.hangs";
    const line = "\ntest deadline: " ++ name ++ " exceeded 50 ms\n";
    const noise = "another thread's line\n";

    fn nameOf(_: usize) []const u8 {
        return name;
    }

    fn maskFails() bool {
        return false;
    }

    /// Paced, so the pipe has room when the deadline expires: a writer that keeps the
    /// pipe full is the full-pipe case.
    fn chatter() void {
        while (true) {
            _ = sys.tinyrt.writeRaw(2, noise, noise.len);
            sys.time.sleepNanoseconds(100 * std.time.ns_per_us);
        }
    }

    fn openWrite(path: [*:0]const u8, flags: sys.fd.OpenFlags) !sys.fd.Descriptor {
        var write_flags = flags;
        write_flags.ACCMODE = .WRONLY;
        return sys.fd.openAtZ(sys.fd.cwd_descriptor, path, write_flags, 0o600);
    }

    /// Runs in the child, which leaves only by a signal or an exit code.
    fn child(
        stderr: Stderr,
        source: sys.fd.Descriptor,
        other: sys.fd.Descriptor,
        ready: sys.fd.Descriptor,
        go: sys.fd.Descriptor,
    ) noreturn {
        sys.fd.duplicateTo(source, 2) catch sys.process.exit(21);
        sys.fd.close(source);
        if (other >= 0) sys.fd.close(other);
        if (stderr == .full) {
            // Fill the pipe through a description of our own, so stderr stays blocking.
            const filler = openWrite("/proc/self/fd/2", .{ .NONBLOCK = true }) catch sys.process.exit(22);
            const block: [4096]u8 = @splat('f');
            while (true) _ = sys.fd.write(filler, &block) catch break;
            sys.fd.close(filler);
        }
        if (sys.fd.nonBlocking(2) catch true) sys.process.exit(20);
        var guard: Guard = .{ .names = nameOf };
        if (stderr == .unmasked) guard.block_broken_pipe = maskFails;
        guard.start(50, &.{}) catch sys.process.exit(23);
        if (sys.fd.nonBlocking(2) catch true) sys.process.exit(24);
        const piped = switch (stderr) {
            .regular, .device => false,
            else => true,
        };
        if (piped != (guard.report.descriptor >= 0)) sys.process.exit(25);
        if (piped) {
            const private = guard.report.descriptor;
            if (!(sys.fd.nonBlocking(private) catch false)) sys.process.exit(26);
            if (!(sys.fd.closeOnExec(private) catch false)) sys.process.exit(31);
        }
        if (stderr == .stopped) {
            const private = guard.report.descriptor;
            guard.stop();
            if (guard.report.descriptor != -1) sys.process.exit(27);
            if (sys.fd.isOpen(private)) sys.process.exit(28);
            sys.process.exit(0);
        }
        // The guard holds its description now. The parent arranges the reader's side, and
        // only then does the deadline start.
        var signal: [1]u8 = .{0};
        if ((sys.fd.write(ready, &signal) catch 0) != 1) sys.process.exit(32);
        if ((sys.fd.read(go, &signal) catch 0) != 1) sys.process.exit(33);
        if (stderr == .contended) _ = sys.thread.spawn(chatter, .{}) catch sys.process.exit(29);
        // Zig's startup ignores SIGPIPE. A test may restore the default action, and the
        // watchdog's own mask is what then keeps the report's write from ending the process.
        if (stderr == .unread) sys.signal.restoreDefault(.PIPE);
        _ = guard.arm(0, 0);
        sys.time.sleepSeconds(60);
        sys.process.exit(30);
    }

    fn run(stderr: Stderr) !Hang {
        var pipe: [2]sys.fd.Descriptor = .{ -1, -1 };
        var file: sys.fd.Descriptor = -1;
        switch (stderr) {
            // An unnamed file, gone when its last descriptor closes.
            .regular => file = try openWrite("/tmp", .{ .TMPFILE = true, .DIRECTORY = true }),
            .device => file = try openWrite("/dev/null", .{}),
            else => pipe = try sys.fd.pipe(.{}),
        }
        defer if (file >= 0) sys.fd.close(file);
        defer if (pipe[0] >= 0) sys.fd.close(pipe[0]);
        const ready = try sys.fd.pipe(.{});
        defer sys.fd.close(ready[0]);
        const go = sys.fd.pipe(.{}) catch |err| {
            sys.fd.close(ready[1]);
            return err;
        };
        defer sys.fd.close(go[1]);
        const forked = sys.process.fork() catch |err| {
            if (pipe[1] >= 0) sys.fd.close(pipe[1]);
            sys.fd.close(ready[1]);
            sys.fd.close(go[0]);
            return err;
        };
        switch (forked) {
            .child => {
                sys.fd.close(ready[0]);
                sys.fd.close(go[1]);
                child(stderr, if (file >= 0) file else pipe[1], pipe[0], ready[1], go[0]);
            },
            .parent => |pid| {
                if (pipe[1] >= 0) sys.fd.close(pipe[1]);
                sys.fd.close(ready[1]);
                sys.fd.close(go[0]);
                var hang: Hang = .{ .term = undefined };
                // A child that failed its setup closes `ready` without a byte: its exit
                // code is the result, and the caller's signal check refuses it.
                var signal: [1]u8 = .{0};
                const started = (try sys.fd.read(ready[0], &signal)) == 1;
                // The child closed its copy before it opened its description, so this
                // leaves the pipe with no reader, and the report's write gets EPIPE.
                if (started and stderr == .unread) {
                    sys.fd.close(pipe[0]);
                    pipe[0] = -1;
                }
                if (started) _ = sys.fd.write(go[1], &signal) catch 0;
                // A full pipe is read only after the process is gone, so it stays full
                // through the deadline.
                const wait_first = stderr == .full or pipe[0] < 0;
                if (wait_first) hang.term = try sys.process.waitDirect(pid);
                if (pipe[0] >= 0) while (hang.len < hang.output.len) {
                    const count = try sys.fd.read(pipe[0], hang.output[hang.len..]);
                    if (count == 0) break;
                    hang.len += count;
                };
                if (!wait_first) hang.term = try sys.process.waitDirect(pid);
                if (stderr == .regular) hang.file_bytes = (try sys.fd.status(file)).allocated_bytes;
                return hang;
            },
        }
    }

    fn expectKilled(self: *const Hang) !void {
        try std.testing.expectEqual(sys.process.Termination{ .signal = .KILL }, self.term);
    }

    fn named(self: *const Hang) bool {
        return std.mem.indexOf(u8, self.output[0..self.len], line) != null;
    }
};
