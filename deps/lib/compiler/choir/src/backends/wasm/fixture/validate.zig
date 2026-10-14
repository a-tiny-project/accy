const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys");
const census = @import("root.zig").census;
const options = @import("wasm_node_options");

pub const module_limit = 32 * 1024;
pub const output_limit = 4096;
pub const deadline_ms = 5000;
pub const cleanup_deadline_ms = 1000;
pub const Word = struct {
    kind: Kind,
    word: []const u8,

    pub const Kind = enum { i32, i64 };
};
pub const Call = struct {
    function: []const u8,
    args: []const Word,
    expected: []const []const u8,
    /// The call stops in a guest trap, so `expected` is empty.
    trap: bool = false,
    /// Imports in `env` that ignore their arguments and answer a fixed word, dirty or not.
    imports: []const Import = &.{},
    /// An absolute path to a module whose exports are bound, unwrapped, as the `math` imports.
    companion: ?[]const u8 = null,
    /// Instantiation succeeds. False expects a link refusal, and then nothing runs.
    linked: bool = true,
};
pub const Import = struct { name: []const u8, reply: Word };
pub const Capture = struct {
    stdout: [output_limit]u8 = undefined,
    stderr: [output_limit]u8 = undefined,
    stdout_len: usize = 0,
    stderr_len: usize = 0,
    term: sys.process.Termination = undefined,
    reaped: bool = false,
    handed_off: bool = false,
    child_id: ?sys.process.Child.Id = null,
};
const Reply = struct {
    path: []const u8,
    version: []const u8,
    valid: bool,
    linked: bool = false,
    /// Times the host called the companion's `_initialize`: once when it binds one.
    initialized: u32 = 0,
    trapped: bool = false,
    results: []const []const u8,
};
var identity_reported = false;
var selection_reported = false;

pub fn supported() bool {
    return builtin.os.tag == .linux or builtin.os.tag == .macos;
}

/// Guards the original TERM-and-blocking-reap regression. The mutex
/// protects child identity until reap so the watchdog cannot signal a reused ID.
pub const Guard = struct {
    mutex: sys.thread.Mutex = .{},
    child_id: ?sys.process.Child.Id = null,
    done: bool = false,
    fired: bool = false,

    pub fn watch(self: *Guard) void {
        for (0..300) |_| {
            sys.time.sleepMilliseconds(10);
            self.mutex.lock();
            const done = self.done;
            self.mutex.unlock();
            if (done) return;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.done) {
            self.fired = true;
            if (self.child_id) |id| sys.process.forceKillChildId(id);
        }
    }
};

/// Spawn itself is synchronous and has no deadline in the public process owner.
/// After it returns, execution and draining share timeout_ms. Forced cleanup has
/// a separate cleanup_deadline_ms bound. Failure transfers reap ownership;
/// detached thread creation and synchronous spawn have no syscall deadline.
pub fn run(script: []const u8, payload: []const u8, timeout_ms: u64, capture: *Capture) !void {
    return runGuarded(script, payload, timeout_ms, capture, null);
}

pub fn runGuarded(
    script: []const u8,
    payload: []const u8,
    timeout_ms: u64,
    capture: *Capture,
    guard: ?*Guard,
) !void {
    if (comptime !supported()) return error.NodeProcessUnavailable;
    capture.* = .{};
    var child = sys.process.spawn(std.testing.io, .{
        .argv = &.{ if (census.qualified) options.path else "node", "--eval", script, payload },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.NodeUnavailable,
        else => return err,
    };
    capture.child_id = child.id;
    defer child.stdout.?.close(std.testing.io);
    defer child.stderr.?.close(std.testing.io);
    if (guard) |watchdog| {
        watchdog.mutex.lock();
        watchdog.child_id = child.id;
        watchdog.mutex.unlock();
    }
    const result = drain(&child, timeout_ms, capture);
    // Never use Child.kill: this toolchain sends TERM and waits without a bound.
    try cleanup(&child, capture, guard);
    try result;
}

fn cleanup(child: *sys.process.Child, capture: *Capture, guard: ?*Guard) !void {
    // Every failure retains a future waiter, even a failed clock read.
    errdefer handoff(child, capture, guard);
    sys.process.forceKillChildId(child.id.?);
    const deadline = (try sys.time.awakeNow()).deadlineAfter(
        .fromMilliseconds(cleanup_deadline_ms),
    );
    while (true) {
        if (guard) |watchdog| watchdog.mutex.lock();
        const outcome = sys.process.waitNoHang(child.id.?);
        if (outcome) |maybe_term| {
            if (maybe_term) |term| {
                capture.term = term.term;
                capture.reaped = true;
                child.id = null;
                if (guard) |watchdog| watchdog.child_id = null;
            }
        } else |_| {}
        if (guard) |watchdog| watchdog.mutex.unlock();
        _ = try outcome;
        if (capture.reaped) return;
        if ((try sys.time.awakeNow()).reached(deadline)) return error.NodeCleanupDeadlineExceeded;
        sys.time.sleepMilliseconds(1);
    }
}

fn handoff(child: *sys.process.Child, capture: *Capture, guard: ?*Guard) void {
    if (guard) |watchdog| watchdog.mutex.lock();
    defer if (guard) |watchdog| watchdog.mutex.unlock();
    sys.process.forceKillChildId(child.id.?);
    sys.process.handoffReap(child) catch {
        // Thread creation failed and the PID still belongs to this process.
        // End the failed test process rather than forget that owned child.
        write("wasm-node cleanup=handoff-failed process-exit=124\n") catch {};
        sys.process.exit(124);
    };
    if (guard) |watchdog| watchdog.child_id = null;
    capture.handed_off = true;
    write("wasm-node cleanup=handed-off reaped=0\n") catch {};
}

fn drain(child: *sys.process.Child, timeout_ms: u64, capture: *Capture) !void {
    const deadline = (try sys.time.awakeNow()).deadlineAfter(.fromMilliseconds(timeout_ms));
    try sys.fd.setNonBlocking(child.stdout.?.handle);
    try sys.fd.setNonBlocking(child.stderr.?.handle);
    var descriptors = [_]sys.poll.Descriptor{
        .{ .fd = child.stdout.?.handle, .events = sys.poll.Event.input, .revents = 0 },
        .{ .fd = child.stderr.?.handle, .events = sys.poll.Event.input, .revents = 0 },
    };
    var ended = [_]bool{ false, false };
    while (true) {
        const now = try sys.time.awakeNow();
        if (now.reached(deadline)) return error.NodeDeadlineExceeded;
        const remaining = now.remainingUntil(deadline).asMillisecondsCeil();
        _ = try sys.poll.wait(&descriptors, @intCast(@min(remaining, 10)));
        for (&descriptors, 0..) |*descriptor, index| {
            if (ended[index] or descriptor.revents == 0) continue;
            const buffer = if (index == 0) &capture.stdout else &capture.stderr;
            const length = if (index == 0) &capture.stdout_len else &capture.stderr_len;
            // A separate byte detects overflow even when the bank is exactly full.
            var excess: [1]u8 = undefined;
            const target = if (length.* == buffer.len) &excess else buffer[length.*..];
            const count = sys.fd.read(descriptor.fd, target) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (count == 0) {
                ended[index] = true;
                descriptor.fd = -1;
            } else {
                if (length.* == buffer.len) return error.NodeOutputExceeded;
                length.* += count;
            }
        }
        if (ended[0] and ended[1]) {
            if (try sys.process.peekNoHang(child.id.?)) |_| {
                if (!(try sys.time.awakeNow()).isBefore(deadline)) {
                    return error.NodeDeadlineExceeded;
                }
                return;
            }
        }
    }
}

pub fn report(validated: usize, executed: usize, negative: usize, skipped: usize) !void {
    var buffer: [192]u8 = undefined;
    if (!selection_reported) {
        try write(try std.fmt.bufPrint(&buffer, "wasm-node selected={d}\n", .{
            builtin.test_functions.len,
        }));
        selection_reported = true;
    }
    const bytes = try std.fmt.bufPrint(
        &buffer,
        "wasm-node validated={d} executed={d} negative={d} skipped={d}\n",
        .{ validated, executed, negative, skipped },
    );
    try write(bytes);
}

pub fn witness(identity: census.Negative) !void {
    try census.negative(identity);
    var buffer: [192]u8 = undefined;
    try write(try std.fmt.bufPrint(&buffer, "wasm-node witness={s}\n", .{@tagName(identity)}));
}

fn write(bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var stream = sys.stdio.stderr().writer(std.testing.io, &buffer);
    try stream.interface.writeAll(bytes);
    try stream.interface.flush();
}

/// Runs Node on `bytes` and checks its reply without recording a census
/// identity, for callers outside the owner's qualification. Returns false only
/// for a declared missing external capability.
pub fn agree(bytes: []const u8, call: ?Call) !bool {
    if (comptime !supported()) {
        if (census.qualified) return error.NodeProcessUnavailable;
        try write("wasm-node skip=NodeProcessUnavailable\n");
        try report(0, 0, 0, 1);
        return false;
    }
    if (bytes.len > module_limit) return error.NodeModuleExceeded;
    const allocator = std.testing.allocator;
    const hex = try allocator.alloc(u8, 2 * bytes.len);
    defer allocator.free(hex);
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        hex[2 * index] = alphabet[byte >> 4];
        hex[2 * index + 1] = alphabet[byte & 15];
    }
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.write(.{
        .hex = hex,
        .function = if (call) |value| value.function else null,
        .args = if (call) |value| value.args else &.{},
        .imports = if (call) |value| value.imports else &.{},
        .companion = if (call) |value| value.companion else null,
    });
    var capture: Capture = .{};
    run(
        @embedFile("validate.mjs"),
        payload.written(),
        deadline_ms,
        &capture,
    ) catch |err| switch (err) {
        error.NodeUnavailable => {
            if (census.qualified) return error.NodeUnavailable;
            try write("wasm-node skip=NodeUnavailable\n");
            try report(0, 0, 0, 1);
            return false;
        },
        else => return err,
    };
    try expectReply(&capture, call);
    return true;
}

/// Returns false only for a declared missing external capability. Owner test
/// assertions continue after that result instead of skipping their test body.
pub fn check(bytes: []const u8, call: ?Call, identity: census.Validation) !bool {
    if (!try agree(bytes, call)) return false;
    try census.validation(identity);
    var observation_buffer: [192]u8 = undefined;
    try write(try std.fmt.bufPrint(&observation_buffer, "wasm-node validation={s}\n", .{@tagName(identity)}));
    if (call) |value| {
        const smoke_identity: census.Smoke = switch (identity) {
            .backend_handle => .backend_identity,
            .verified_artifact => .verified_artifact,
            .sealed_add => .add,
            .imported_call => .imported,
            .fixture_i32 => .fixture_i32,
            .fixture_i64 => .fixture_i64,
            else => return error.UnexpectedNodeSmoke,
        };
        const expected_function: []const u8 = switch (smoke_identity) {
            .backend_identity, .verified_artifact => "identity",
            .add => "add_i32",
            .imported => "call_external",
            .fixture_i32, .fixture_i64 => "identity",
        };
        const expected_word: []const u8 = switch (smoke_identity) {
            .backend_identity, .verified_artifact, .fixture_i32 => "37",
            .add, .imported => "42",
            .fixture_i64 => "9223372036854775807",
        };
        if (!std.mem.eql(u8, expected_function, value.function) or value.expected.len != 1 or
            !std.mem.eql(u8, expected_word, value.expected[0])) return error.NodeSmokeIdentityMismatch;
        try census.smoke(smoke_identity);
        var buffer: [192]u8 = undefined;
        try write(try std.fmt.bufPrint(&buffer, "wasm-node smoke={s} result={s}\n", .{
            value.function, value.expected[0],
        }));
    }
    try report(1, @intFromBool(call != null), 0, 0);
    return true;
}

pub fn expectReply(capture: *const Capture, call: ?Call) !void {
    const allocator = std.testing.allocator;
    if (!capture.term.success()) return error.NodeExitFailed;
    const reply = std.json.parseFromSlice(
        Reply,
        allocator,
        capture.stdout[0..capture.stdout_len],
        .{},
    ) catch
        return error.NodeMalformedReply;
    defer reply.deinit();
    if (census.qualified) {
        // The pin may name a toolchain link. Node reports its resolved executable.
        const pinned = try sys.fs.realPathAlloc(allocator, options.path);
        defer allocator.free(pinned);
        if (!std.mem.eql(u8, pinned, reply.value.path) or
            !std.mem.eql(u8, options.version, reply.value.version))
            return error.NodeIdentityMismatch;
    }
    if (!identity_reported) {
        var buffer: [2048]u8 = undefined;
        try write(try std.fmt.bufPrint(&buffer, "wasm-node pin={s} path={s} version={s}\n", .{
            options.path, reply.value.path, reply.value.version,
        }));
        identity_reported = true;
    }
    if (!reply.value.valid) return error.NodeValidationRejected;
    if (call) |value| {
        if (reply.value.linked != value.linked) return error.NodeWrongOutcome;
        if (reply.value.initialized != @intFromBool(value.companion != null)) return error.NodeWrongOutcome;
        if (reply.value.trapped != value.trap) return error.NodeWrongOutcome;
        if (reply.value.results.len != value.expected.len) return error.NodeWrongResult;
        for (reply.value.results, value.expected) |actual, expected| {
            if (!std.mem.eql(u8, actual, expected)) return error.NodeWrongResult;
        }
    } else if (reply.value.trapped or reply.value.results.len != 0)
        return error.NodeMalformedReply;
}

pub fn validate(bytes: []const u8, identity: census.Validation) !void {
    _ = try check(bytes, null, identity);
}
