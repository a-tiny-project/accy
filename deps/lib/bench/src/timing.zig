const std = @import("std");
const sys = @import("sys");

pub const clock_probe_reads: u32 = 256;

pub const ClockProbe = struct {
    source: []const u8 = "monotonic_awake",
    reads: u32,
    positive_deltas: u32,
    minimum_delta_ns: u64,
    span_ns: u64,
};

pub fn nowInstant() sys.time.AwakeInstant {
    return readInstant() catch @panic("awake clock unavailable");
}

pub fn readInstant() !sys.time.AwakeInstant {
    return sys.time.awakeNow();
}

pub fn nowNs() i128 {
    return @intCast(nowInstant().asNanoseconds());
}

pub fn probeClock() !ClockProbe {
    std.debug.assert(clock_probe_reads >= 2);
    var timestamps: [clock_probe_reads]sys.time.AwakeInstant = undefined;
    for (&timestamps) |*timestamp| timestamp.* = try readInstant();
    return analyzeClockProbe(&timestamps);
}

pub fn realNowNs() u64 {
    return (sys.time.wallNow() catch @panic("wall clock unavailable")).asNanoseconds();
}

pub fn elapsedNs(start: i128) u64 {
    const end = nowNs();
    return elapsedNsBetween(start, end);
}

pub fn elapsedNsBetween(start: i128, end: i128) u64 {
    if (end <= start) return 0;
    return saturatingU64(end - start);
}

pub fn nsOrZero(value: ?i128) u64 {
    return saturatingU64(value orelse return 0);
}

pub fn saturatingU64(value_int: anytype) u64 {
    if (value_int <= 0) return 0;
    if (value_int > std.math.maxInt(u64)) return std.math.maxInt(u64);
    return @intCast(value_int);
}

pub fn saturatingI64(value: u64) i64 {
    return @intCast(@min(value, std.math.maxInt(i64)));
}

fn analyzeClockProbe(timestamps: []const sys.time.AwakeInstant) !ClockProbe {
    if (timestamps.len < 2) return error.InsufficientClockReads;
    var minimum_delta: u64 = std.math.maxInt(u64);
    var positive_deltas: u32 = 0;
    var previous = timestamps[0];
    for (timestamps[1..]) |current| {
        const delta = current.elapsedSince(previous) catch return error.ClockRegressed;
        if (!delta.isZero()) {
            minimum_delta = @min(minimum_delta, delta.asNanoseconds());
            positive_deltas += 1;
        }
        previous = current;
    }
    if (positive_deltas == 0) return error.ClockNotAdvancing;
    return .{
        .reads = @intCast(timestamps.len),
        .positive_deltas = positive_deltas,
        .minimum_delta_ns = minimum_delta,
        .span_ns = (try timestamps[timestamps.len - 1].elapsedSince(timestamps[0])).asNanoseconds(),
    };
}

test "clock probe analysis retains positive minimum delta" {
    const Instant = sys.time.AwakeInstant;
    const probe = try analyzeClockProbe(&.{
        Instant.fromNanoseconds(100),
        Instant.fromNanoseconds(100),
        Instant.fromNanoseconds(103),
        Instant.fromNanoseconds(108),
        Instant.fromNanoseconds(108),
    });

    try std.testing.expectEqual(@as(u32, 5), probe.reads);
    try std.testing.expectEqual(@as(u32, 2), probe.positive_deltas);
    try std.testing.expectEqual(@as(u64, 3), probe.minimum_delta_ns);
    try std.testing.expectEqual(@as(u64, 8), probe.span_ns);
}

test "clock probe analysis rejects invalid clocks" {
    const Instant = sys.time.AwakeInstant;
    try std.testing.expectError(
        error.InsufficientClockReads,
        analyzeClockProbe(&.{Instant.fromNanoseconds(1)}),
    );
    try std.testing.expectError(error.ClockNotAdvancing, analyzeClockProbe(&.{
        Instant.fromNanoseconds(5),
        Instant.fromNanoseconds(5),
        Instant.fromNanoseconds(5),
    }));
    try std.testing.expectError(error.ClockRegressed, analyzeClockProbe(&.{
        Instant.fromNanoseconds(5),
        Instant.fromNanoseconds(4),
    }));
}

test "host clock probe advances" {
    if (!sys.time.supportsAwakeClock()) return error.SkipZigTest;
    const probe = try probeClock();

    try std.testing.expectEqual(clock_probe_reads, probe.reads);
    try std.testing.expect(probe.positive_deltas > 0);
    try std.testing.expect(probe.minimum_delta_ns > 0);
    try std.testing.expect(probe.span_ns >= probe.minimum_delta_ns);
}
