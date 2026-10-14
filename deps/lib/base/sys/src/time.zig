const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.noLibc(&.{.time});
pub const ClockError = error{
    UnsupportedPlatform,
    ClockUnavailable,
    ClockRegressed,
    ClockOverflow,
};

pub const ExternalClockId = enum(u32) {
    _,

    pub fn fromNative(value: u32) ExternalClockId {
        return @fromBackingInt(@intCast(value));
    }

    pub fn toNative(self: ExternalClockId) u32 {
        return @backingInt(self);
    }
};

pub const real_clock_id = ExternalClockId.fromNative(
    @intCast(@backingInt(std.os.linux.clockid_t.REALTIME)),
);
pub const awake_clock_id = ExternalClockId.fromNative(
    @intCast(@backingInt(std.os.linux.clockid_t.MONOTONIC)),
);
pub const boot_clock_id = ExternalClockId.fromNative(
    @intCast(@backingInt(std.os.linux.clockid_t.BOOTTIME)),
);

pub const Duration = enum(u64) {
    _,

    pub const zero: Duration = @fromBackingInt(@intCast(0));

    pub fn fromNanoseconds(value: u64) Duration {
        return @fromBackingInt(@intCast(value));
    }

    pub fn fromMilliseconds(value: u64) Duration {
        return @fromBackingInt(@intCast(value *| std.time.ns_per_ms));
    }

    pub fn asNanoseconds(self: Duration) u64 {
        return @backingInt(self);
    }

    pub fn asMillisecondsFloor(self: Duration) u64 {
        return self.asNanoseconds() / std.time.ns_per_ms;
    }

    pub fn asMillisecondsCeil(self: Duration) u64 {
        const nanoseconds = self.asNanoseconds();
        if (nanoseconds == 0) return 0;
        return 1 + (nanoseconds - 1) / std.time.ns_per_ms;
    }

    pub fn isZero(self: Duration) bool {
        return self == zero;
    }

    pub fn min(self: Duration, other: Duration) Duration {
        return if (self.asNanoseconds() <= other.asNanoseconds()) self else other;
    }

    pub fn saturatingMultiply(self: Duration, factor: u64) Duration {
        return .fromNanoseconds(self.asNanoseconds() *| factor);
    }
};

pub const AwakeInstant = enum(u64) {
    _,

    pub const zero: AwakeInstant = @fromBackingInt(@intCast(0));

    pub fn fromNanoseconds(value: u64) AwakeInstant {
        return @fromBackingInt(@intCast(value));
    }

    pub fn asNanoseconds(self: AwakeInstant) u64 {
        return @backingInt(self);
    }

    pub fn elapsedSince(self: AwakeInstant, earlier: AwakeInstant) ClockError!Duration {
        const current = self.asNanoseconds();
        const start = earlier.asNanoseconds();
        if (current < start) return error.ClockRegressed;
        return Duration.fromNanoseconds(current - start);
    }

    pub fn deadlineAfter(self: AwakeInstant, duration: Duration) AwakeInstant {
        return @fromBackingInt(@intCast(self.asNanoseconds() +| duration.asNanoseconds()));
    }

    pub fn reached(self: AwakeInstant, deadline: AwakeInstant) bool {
        return self.asNanoseconds() >= deadline.asNanoseconds();
    }

    pub fn isBefore(self: AwakeInstant, other: AwakeInstant) bool {
        return self.asNanoseconds() < other.asNanoseconds();
    }

    pub fn remainingUntil(self: AwakeInstant, deadline: AwakeInstant) Duration {
        if (self.reached(deadline)) return .zero;
        return .fromNanoseconds(deadline.asNanoseconds() - self.asNanoseconds());
    }
};

pub const BootInstant = enum(u64) {
    _,

    pub const zero: BootInstant = @fromBackingInt(@intCast(0));

    pub fn fromNanoseconds(value: u64) BootInstant {
        return @fromBackingInt(@intCast(value));
    }

    pub fn asNanoseconds(self: BootInstant) u64 {
        return @backingInt(self);
    }

    pub fn elapsedSince(self: BootInstant, earlier: BootInstant) ClockError!Duration {
        const current = self.asNanoseconds();
        const start = earlier.asNanoseconds();
        if (current < start) return error.ClockRegressed;
        return Duration.fromNanoseconds(current - start);
    }

    pub fn deadlineAfter(self: BootInstant, duration: Duration) BootInstant {
        return @fromBackingInt(@intCast(self.asNanoseconds() +| duration.asNanoseconds()));
    }

    pub fn reached(self: BootInstant, deadline: BootInstant) bool {
        return self.asNanoseconds() >= deadline.asNanoseconds();
    }

    pub fn isBefore(self: BootInstant, other: BootInstant) bool {
        return self.asNanoseconds() < other.asNanoseconds();
    }

    pub fn remainingUntil(self: BootInstant, deadline: BootInstant) Duration {
        if (self.reached(deadline)) return .zero;
        return .fromNanoseconds(deadline.asNanoseconds() - self.asNanoseconds());
    }
};

pub const WallTimestamp = enum(u64) {
    _,

    pub const epoch: WallTimestamp = @fromBackingInt(@intCast(0));

    pub fn fromNanoseconds(value: u64) WallTimestamp {
        return @fromBackingInt(@intCast(value));
    }

    pub fn asNanoseconds(self: WallTimestamp) u64 {
        return @backingInt(self);
    }

    pub fn asMilliseconds(self: WallTimestamp) u64 {
        return self.asNanoseconds() / std.time.ns_per_ms;
    }
};

pub const ClockSource = union(enum) {
    system,
    fake: *FakeClock,
    unavailable,
};

pub const AwakeClock = struct {
    source: ClockSource = .system,

    pub fn system() AwakeClock {
        return .{};
    }

    pub fn unavailable() AwakeClock {
        return .{ .source = .unavailable };
    }

    pub fn now(self: AwakeClock) ClockError!AwakeInstant {
        return switch (self.source) {
            .system => awakeNow(),
            .fake => |clock| readFakeAwake(clock),
            .unavailable => error.ClockUnavailable,
        };
    }
};

pub const BootClock = struct {
    source: ClockSource = .system,

    pub fn system() BootClock {
        return .{};
    }

    pub fn unavailable() BootClock {
        return .{ .source = .unavailable };
    }

    pub fn now(self: BootClock) ClockError!BootInstant {
        return switch (self.source) {
            .system => bootNow(),
            .fake => |clock| readFakeBoot(clock),
            .unavailable => error.ClockUnavailable,
        };
    }
};

/// Clock handles borrow this clock at a stable address for their entire lifetime.
/// Do not copy or reset it while handles are in use. Concurrent reads are supported;
/// callers must synchronize mutations of time and availability with those reads.
pub const FakeClock = struct {
    awake: AwakeInstant,
    boot: BootInstant,
    wall: WallTimestamp,
    reads_unavailable: bool = false,
    awake_reads: std.atomic.Value(u64) = .init(0),
    boot_reads: std.atomic.Value(u64) = .init(0),

    pub fn init(
        awake: AwakeInstant,
        boot: BootInstant,
        wall: WallTimestamp,
    ) FakeClock {
        return .{ .awake = awake, .boot = boot, .wall = wall };
    }

    pub fn zero() FakeClock {
        return init(.zero, .zero, .epoch);
    }

    pub fn awakeClock(self: *FakeClock) AwakeClock {
        return .{ .source = .{ .fake = self } };
    }

    pub fn bootClock(self: *FakeClock) BootClock {
        return .{ .source = .{ .fake = self } };
    }

    /// Attempted awake reads, including unavailable results, modulo 2^64.
    pub fn awakeReads(self: *const FakeClock) u64 {
        return self.awake_reads.load(.monotonic);
    }

    /// Attempted boot reads, including unavailable results, modulo 2^64.
    pub fn bootReads(self: *const FakeClock) u64 {
        return self.boot_reads.load(.monotonic);
    }

    pub fn advance(self: *FakeClock, duration: Duration) void {
        const delta = duration.asNanoseconds();
        self.awake = .fromNanoseconds(self.awake.asNanoseconds() +| delta);
        self.boot = .fromNanoseconds(self.boot.asNanoseconds() +| delta);
        self.wall = .fromNanoseconds(self.wall.asNanoseconds() +| delta);
    }

    pub fn regress(self: *FakeClock, duration: Duration) void {
        const delta = duration.asNanoseconds();
        self.awake = .fromNanoseconds(self.awake.asNanoseconds() -| delta);
        self.boot = .fromNanoseconds(self.boot.asNanoseconds() -| delta);
        self.wall = .fromNanoseconds(self.wall.asNanoseconds() -| delta);
    }

    pub fn suspendGap(self: *FakeClock, duration: Duration) void {
        const delta = duration.asNanoseconds();
        self.boot = .fromNanoseconds(self.boot.asNanoseconds() +| delta);
        self.wall = .fromNanoseconds(self.wall.asNanoseconds() +| delta);
    }

    pub fn overflow(self: *FakeClock) void {
        self.awake = .fromNanoseconds(std.math.maxInt(u64));
        self.boot = .fromNanoseconds(std.math.maxInt(u64));
        self.wall = .fromNanoseconds(std.math.maxInt(u64));
    }

    pub fn setWall(self: *FakeClock, wall: WallTimestamp) void {
        self.wall = wall;
    }

    pub fn setReadsUnavailable(self: *FakeClock, unavailable: bool) void {
        self.reads_unavailable = unavailable;
    }
};

pub fn supportsAwakeClock() bool {
    return switch (builtin.os.tag) {
        .freestanding, .wasi => false,
        else => true,
    };
}

pub fn supportsBootClock() bool {
    return switch (builtin.os.tag) {
        .freestanding, .wasi => false,
        else => true,
    };
}

pub fn supportsRealClock() bool {
    return switch (builtin.os.tag) {
        .freestanding, .wasi => false,
        else => true,
    };
}

pub fn awakeNow() ClockError!AwakeInstant {
    const value = awakeNanoseconds() orelse return error.ClockUnavailable;
    return .fromNanoseconds(try nonnegativeNanoseconds(value));
}

pub fn bootNow() ClockError!BootInstant {
    const value = bootNanoseconds() orelse return error.ClockUnavailable;
    return .fromNanoseconds(try nonnegativeNanoseconds(value));
}

pub fn wallNow() ClockError!WallTimestamp {
    const value = realNanoseconds() orelse return error.ClockUnavailable;
    return .fromNanoseconds(try nonnegativeNanoseconds(value));
}

pub fn awakeNanoseconds() ?i128 {
    if (comptime !supportsAwakeClock()) return null;
    return switch (builtin.os.tag) {
        .linux => linuxClockNanoseconds(.MONOTONIC),
        else => std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds(),
    };
}

/// CPU time spent by every thread of the process, or null where the host keeps no such clock.
pub fn processCpuNanoseconds() ?i128 {
    return switch (builtin.os.tag) {
        .linux => linuxClockNanoseconds(.PROCESS_CPUTIME_ID),
        else => null,
    };
}

pub fn bootNanoseconds() ?i128 {
    if (comptime !supportsBootClock()) return null;
    return switch (builtin.os.tag) {
        .linux => linuxClockNanoseconds(.BOOTTIME),
        else => std.Io.Timestamp.now(std.Options.debug_io, .boot).toNanoseconds(),
    };
}

pub fn realNanoseconds() ?i128 {
    if (comptime !supportsRealClock()) return null;
    return switch (builtin.os.tag) {
        .linux => linuxClockNanoseconds(.REALTIME),
        else => std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(),
    };
}

pub fn externalClockNanoseconds(clock_id: ExternalClockId) ClockError!i128 {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
    const clock: std.os.linux.clockid_t = @fromBackingInt(@intCast(clock_id.toNative()));
    return linuxClockNanoseconds(clock) orelse error.ClockUnavailable;
}

pub fn nanoTimestamp() i128 {
    return @intCast((awakeNow() catch @panic("awake clock unavailable")).asNanoseconds());
}

pub fn realNanoTimestamp() i128 {
    return @intCast((wallNow() catch @panic("wall clock unavailable")).asNanoseconds());
}

pub fn realMilliTimestamp() i64 {
    return @intCast(@divTrunc(realNanoTimestamp(), std.time.ns_per_ms));
}

pub fn ioTimestampNanoseconds(timestamp_value: std.Io.Timestamp) u64 {
    return @intCast(timestamp_value.nanoseconds);
}

pub fn seconds() f64 {
    return @as(f64, @floatFromInt(nanoTimestamp())) / @as(f64, @floatFromInt(std.time.ns_per_s));
}

pub fn realSeconds() f64 {
    return @as(f64, @floatFromInt(realNanoTimestamp())) /
        @as(f64, @floatFromInt(std.time.ns_per_s));
}

pub fn microTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_us));
}

pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_ms));
}

pub fn timestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_s));
}

pub fn sleepNanoseconds(duration_ns: u64) void {
    if (duration_ns == 0) return;
    if (comptime builtin.os.tag == .freestanding or builtin.os.tag == .wasi) return;
    switch (builtin.os.tag) {
        .linux => linuxSleepNanoseconds(duration_ns),
        else => std.Io.sleep(std.Options.debug_io, .fromNanoseconds(duration_ns), .awake) catch {},
    }
}

pub fn sleepMilliseconds(duration_ms: u64) void {
    sleepNanoseconds(sleepNanosecondsForMilliseconds(duration_ms));
}

pub fn sleepSeconds(duration_seconds: f64) void {
    sleepNanoseconds(sleepNanosecondsForSeconds(duration_seconds));
}

fn sleepNanosecondsForMilliseconds(duration_ms: u64) u64 {
    if (duration_ms > std.math.maxInt(u64) / std.time.ns_per_ms) return std.math.maxInt(u64);
    return duration_ms * std.time.ns_per_ms;
}

fn sleepNanosecondsForSeconds(duration_seconds: f64) u64 {
    if (!std.math.isFinite(duration_seconds) or duration_seconds <= 0) return 0;
    const ns_per_s: f64 = @floatFromInt(std.time.ns_per_s);
    const max_seconds = @as(f64, @floatFromInt(std.math.maxInt(u64))) / ns_per_s;
    if (duration_seconds >= max_seconds) return std.math.maxInt(u64);
    return @intFromFloat(@round(duration_seconds * ns_per_s));
}

fn readFakeAwake(clock: *FakeClock) ClockError!AwakeInstant {
    _ = clock.awake_reads.fetchAdd(1, .monotonic);
    if (clock.reads_unavailable) return error.ClockUnavailable;
    return clock.awake;
}

fn readFakeBoot(clock: *FakeClock) ClockError!BootInstant {
    _ = clock.boot_reads.fetchAdd(1, .monotonic);
    if (clock.reads_unavailable) return error.ClockUnavailable;
    return clock.boot;
}

fn nonnegativeNanoseconds(value: i128) ClockError!u64 {
    if (value < 0 or value > std.math.maxInt(u64)) return error.ClockUnavailable;
    return @intCast(value);
}

fn linuxClockNanoseconds(clock: std.os.linux.clockid_t) ?i128 {
    const linux = std.os.linux;
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(clock, &ts);
    if (linux.errno(rc) != .SUCCESS) return null;
    if (ts.sec < 0 or ts.nsec < 0) return null;
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
}

fn linuxSleepNanoseconds(duration_ns: u64) void {
    const linux = std.os.linux;
    var remaining = linux.timespec{
        .sec = @intCast(duration_ns / std.time.ns_per_s),
        .nsec = @intCast(duration_ns % std.time.ns_per_s),
    };
    while (true) {
        var next: linux.timespec = undefined;
        const rc = linux.syscall2(.nanosleep, @intFromPtr(&remaining), @intFromPtr(&next));
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => remaining = next,
            else => return,
        }
    }
}

fn readClockAttempts(awake: AwakeClock, boot: BootClock) void {
    for (0..128) |_| {
        std.debug.assert((awake.now() catch unreachable) == AwakeInstant.zero);
        std.debug.assert((boot.now() catch unreachable) == BootInstant.zero);
    }
}
