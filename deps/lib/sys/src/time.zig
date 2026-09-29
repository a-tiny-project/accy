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

pub const AwakeClock = struct {
    context: ?*anyopaque = null,
    read_fn: *const fn (?*anyopaque) ClockError!AwakeInstant = readSystemAwake,

    pub fn system() AwakeClock {
        return .{};
    }

    pub fn now(self: AwakeClock) ClockError!AwakeInstant {
        return self.read_fn(self.context);
    }
};

pub const BootClock = struct {
    context: ?*anyopaque = null,
    read_fn: *const fn (?*anyopaque) ClockError!BootInstant = readSystemBoot,

    pub fn system() BootClock {
        return .{};
    }

    pub fn now(self: BootClock) ClockError!BootInstant {
        return self.read_fn(self.context);
    }
};

pub const FakeClock = struct {
    awake: AwakeInstant,
    boot: BootInstant,
    wall: WallTimestamp,
    reads_unavailable: bool = false,

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
        return .{ .context = self, .read_fn = readFakeAwake };
    }

    pub fn bootClock(self: *FakeClock) BootClock {
        return .{ .context = self, .read_fn = readFakeBoot };
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

fn readSystemAwake(_: ?*anyopaque) ClockError!AwakeInstant {
    return awakeNow();
}

fn readSystemBoot(_: ?*anyopaque) ClockError!BootInstant {
    return bootNow();
}

fn readFakeAwake(context: ?*anyopaque) ClockError!AwakeInstant {
    const clock: *FakeClock = @ptrCast(@alignCast(context orelse unreachable));
    if (clock.reads_unavailable) return error.ClockUnavailable;
    return clock.awake;
}

fn readFakeBoot(context: ?*anyopaque) ClockError!BootInstant {
    const clock: *FakeClock = @ptrCast(@alignCast(context orelse unreachable));
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

test "timestamp helpers are callable on every target" {
    if (supportsAwakeClock()) {
        try std.testing.expect((try awakeNow()).asNanoseconds() > 0);
        try std.testing.expect(nanoTimestamp() >= 0);
        try std.testing.expect(seconds() >= 0);
        try std.testing.expect(microTimestamp() >= 0);
        try std.testing.expect(milliTimestamp() >= 0);
        try std.testing.expect(timestamp() >= 0);
    } else {
        try std.testing.expectError(error.ClockUnavailable, awakeNow());
    }
    if (supportsBootClock()) {
        try std.testing.expect((try bootNow()).asNanoseconds() > 0);
    } else {
        try std.testing.expectError(error.ClockUnavailable, bootNow());
    }
    if (supportsRealClock()) {
        try std.testing.expect((try wallNow()).asNanoseconds() > 0);
        try std.testing.expect(realNanoTimestamp() >= 0);
        try std.testing.expect(realSeconds() >= 0);
        try std.testing.expect(realMilliTimestamp() >= 0);
    } else {
        try std.testing.expectError(error.ClockUnavailable, wallNow());
    }
}

test "Linux awake clock read is monotone within the vDSO budget" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const sample_count: usize = 64;
    const median_budget_ns: u64 = 250;
    var samples: [sample_count]u64 = undefined;
    for (&samples) |*sample| {
        const before = try awakeNow();
        const after = try awakeNow();
        try std.testing.expect(after.asNanoseconds() >= before.asNanoseconds());
        sample.* = (try after.elapsedSince(before)).asNanoseconds();
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    try std.testing.expect(samples[samples.len / 2] <= median_budget_ns);
}

test "instant subtraction accepts one clock type" {
    comptime {
        const awake_subtract: *const fn (
            AwakeInstant,
            AwakeInstant,
        ) ClockError!Duration = AwakeInstant.elapsedSince;
        const boot_subtract: *const fn (
            BootInstant,
            BootInstant,
        ) ClockError!Duration = BootInstant.elapsedSince;
        _ = awake_subtract;
        _ = boot_subtract;
        std.debug.assert(AwakeInstant != BootInstant);
        std.debug.assert(AwakeInstant != WallTimestamp);
    }
}

test "instant subtraction reports regression" {
    const earlier = AwakeInstant.fromNanoseconds(8);
    const current = AwakeInstant.fromNanoseconds(5);
    try std.testing.expectError(error.ClockRegressed, current.elapsedSince(earlier));
}

test "deadline and duration arithmetic saturate" {
    const duration = Duration.fromMilliseconds(std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), duration.asNanoseconds());
    const start = AwakeInstant.fromNanoseconds(std.math.maxInt(u64) - 1);
    const deadline = start.deadlineAfter(.fromNanoseconds(2));
    try std.testing.expectEqual(std.math.maxInt(u64), deadline.asNanoseconds());
    try std.testing.expectEqual(
        @as(u64, 2),
        Duration.fromNanoseconds(1_001_000).asMillisecondsCeil(),
    );
    try std.testing.expectEqual(
        Duration.fromNanoseconds(5),
        Duration.fromNanoseconds(8).min(.fromNanoseconds(5)),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        Duration.fromNanoseconds(std.math.maxInt(u64)).saturatingMultiply(2).asNanoseconds(),
    );
}

test "fake clock separates awake suspension and wall jumps" {
    var clock = FakeClock.zero();
    clock.advance(.fromMilliseconds(2));
    try std.testing.expectEqual(@as(u64, 2_000_000), clock.awake.asNanoseconds());
    clock.suspendGap(.fromMilliseconds(3));
    try std.testing.expectEqual(@as(u64, 2_000_000), clock.awake.asNanoseconds());
    try std.testing.expectEqual(@as(u64, 5_000_000), clock.boot.asNanoseconds());
    clock.setWall(.fromNanoseconds(9));
    try std.testing.expectEqual(@as(u64, 9), clock.wall.asNanoseconds());
    clock.regress(.fromNanoseconds(1));
    try std.testing.expectEqual(@as(u64, 1_999_999), clock.awake.asNanoseconds());
    clock.overflow();
    try std.testing.expectEqual(std.math.maxInt(u64), clock.awake.asNanoseconds());
}

test "fake typed clocks report unavailability" {
    var fake = FakeClock.zero();
    const awake_clock = fake.awakeClock();
    const boot_clock = fake.bootClock();
    try std.testing.expectEqual(AwakeInstant.zero, try awake_clock.now());
    try std.testing.expectEqual(BootInstant.zero, try boot_clock.now());
    fake.setReadsUnavailable(true);
    try std.testing.expectError(error.ClockUnavailable, awake_clock.now());
    try std.testing.expectError(error.ClockUnavailable, boot_clock.now());
}

test "external clock ids route through the opaque sampled clock boundary" {
    if (builtin.os.tag != .linux) {
        try std.testing.expectError(
            error.UnsupportedPlatform,
            externalClockNanoseconds(awake_clock_id),
        );
        return;
    }
    try std.testing.expectEqual(
        @as(u32, @intCast(@backingInt(std.os.linux.clockid_t.REALTIME))),
        real_clock_id.toNative(),
    );
    try std.testing.expect(try externalClockNanoseconds(real_clock_id) > 0);
    try std.testing.expect(try externalClockNanoseconds(awake_clock_id) > 0);
    try std.testing.expect(try externalClockNanoseconds(boot_clock_id) > 0);
    try std.testing.expectError(
        error.ClockUnavailable,
        externalClockNanoseconds(.fromNative(std.math.maxInt(u32))),
    );
}

test "io timestamp conversion preserves nanoseconds" {
    try std.testing.expectEqual(@as(u64, 1234), ioTimestampNanoseconds(.{ .nanoseconds = 1234 }));
}

test "sleep second conversion rejects invalid durations" {
    try std.testing.expectEqual(@as(u64, 0), sleepNanosecondsForSeconds(-1));
    try std.testing.expectEqual(@as(u64, 0), sleepNanosecondsForSeconds(0));
    try std.testing.expectEqual(@as(u64, 0), sleepNanosecondsForSeconds(std.math.inf(f64)));
}

test "sleep millisecond conversion saturates" {
    try std.testing.expectEqual(@as(u64, 0), sleepNanosecondsForMilliseconds(0));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_ms), sleepNanosecondsForMilliseconds(1));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        sleepNanosecondsForMilliseconds(std.math.maxInt(u64)),
    );
}

test "sleep second conversion rounds and saturates" {
    try std.testing.expectEqual(@as(u64, 1), sleepNanosecondsForSeconds(0.000000001));
    try std.testing.expectEqual(@as(u64, 1_500_000_000), sleepNanosecondsForSeconds(1.5));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        sleepNanosecondsForSeconds(@as(f64, @floatFromInt(std.math.maxInt(u64)))),
    );
}
