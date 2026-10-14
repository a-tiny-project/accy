const std = @import("std");
const builtin = @import("builtin");

const Counter = if (builtin.single_threaded)
    Plain
else if (@bitSizeOf(usize) >= @bitSizeOf(u64))
    Wide
else
    Locked;

const retry_limit = std.math.maxInt(u32);

pub const Sequence64 = struct {
    counter: Counter,

    pub fn init(value: u64) Sequence64 {
        return .{ .counter = Counter.init(value) };
    }

    pub fn take(self: *Sequence64) ?u64 {
        return self.counter.take();
    }
};

const Plain = struct {
    value: u64,

    fn init(value: u64) Plain {
        return .{ .value = value };
    }

    fn take(self: *Plain) ?u64 {
        if (self.value == std.math.maxInt(u64)) return null;
        self.value += 1;
        return self.value;
    }
};

const Wide = struct {
    value: std.atomic.Value(u64),

    fn init(value: u64) Wide {
        return .{ .value = .init(value) };
    }

    fn take(self: *Wide) ?u64 {
        var current = self.value.load(.monotonic);
        var retries: u32 = 0;
        while (current != std.math.maxInt(u64)) : (retries += 1) {
            std.debug.assert(retries < retry_limit);
            const next = current + 1;
            if (self.value.cmpxchgWeak(
                current,
                next,
                .monotonic,
                .monotonic,
            )) |observed| {
                current = observed;
            } else return next;
        }
        return null;
    }
};

const Locked = struct {
    guard: std.atomic.Value(u32),
    value: u64,

    fn init(value: u64) Locked {
        return .{ .guard = .init(0), .value = value };
    }

    fn take(self: *Locked) ?u64 {
        self.acquire();
        defer self.release();
        if (self.value == std.math.maxInt(u64)) return null;
        self.value += 1;
        return self.value;
    }

    fn acquire(self: *Locked) void {
        var retries: u32 = 0;
        while (self.guard.cmpxchgWeak(
            0,
            1,
            .acquire,
            .monotonic,
        ) != null) : (retries += 1) {
            std.debug.assert(retries < retry_limit);
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *Locked) void {
        self.guard.store(0, .release);
    }
};

fn expectSaturation(comptime CounterType: type) !void {
    var counter = CounterType.init(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), counter.take());
    try std.testing.expectEqual(@as(?u64, null), counter.take());
    try std.testing.expectEqual(@as(?u64, null), counter.take());
}

const concurrent_workers = 8;
const values_per_worker = 64;
const concurrent_values = concurrent_workers * values_per_worker;

fn takeConcurrent(counter: anytype, values: []u64) void {
    for (values) |*value| value.* = counter.take() orelse unreachable;
}

fn expectConcurrentSequence(comptime CounterType: type) !void {
    if (builtin.single_threaded) return error.SkipZigTest;

    var counter = CounterType.init(0);
    var values: [concurrent_values]u64 = undefined;
    var threads: [concurrent_workers]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        const begin = index * values_per_worker;
        const end = begin + values_per_worker;
        thread.* = try std.Thread.spawn(
            .{},
            takeConcurrent,
            .{ &counter, values[begin..end] },
        );
    }
    for (threads) |thread| thread.join();

    std.mem.sort(u64, &values, {}, std.sort.asc(u64));
    for (values, 0..) |value, index| {
        try std.testing.expectEqual(@as(u64, index + 1), value);
    }
}
