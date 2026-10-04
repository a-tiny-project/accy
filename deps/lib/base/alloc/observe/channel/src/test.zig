const std = @import("std");
const Channel = @import("root.zig").Channel;

const Tick = struct {
    producer: u32,
    sequence: u64,
};

const Mark = struct {
    value: u32,
};

const Ticks = Channel(Tick);
const Marks = Channel(Mark);

const producer_count = 4;
const wait_limit = 1 << 26;

/// Counts deliveries and the callbacks running right now. Each callback spins
/// briefly, so an uninstall races callbacks that are still inside the sink.
const Counting = struct {
    in_callback: std.atomic.Value(u32) = .init(0),
    delivered: std.atomic.Value(u64) = .init(0),

    fn sink(self: *Counting) Ticks.Sink {
        return .{ .context = self, .record = accept };
    }

    fn accept(context: *anyopaque, event: Tick) void {
        const self: *Counting = @ptrCast(@alignCast(context));
        std.debug.assert(event.producer < producer_count);
        _ = self.in_callback.fetchAdd(1, .acq_rel);
        var spin: u32 = 0;
        while (spin < 256) : (spin += 1) std.atomic.spinLoopHint();
        _ = self.delivered.fetchAdd(1, .acq_rel);
        _ = self.in_callback.fetchSub(1, .acq_rel);
    }

    fn awaitDelivered(self: *const Counting, target: u64) !void {
        var waited: u32 = 0;
        while (self.delivered.load(.acquire) < target) : (waited += 1) {
            if (waited == wait_limit) return error.DeliveriesStalled;
            std.Thread.yield() catch {};
        }
    }
};

const Producer = struct {
    id: u32,
    stop: *const std.atomic.Value(bool),

    fn run(self: Producer) void {
        var sequence: u64 = 0;
        while (!self.stop.load(.acquire)) : (sequence += 1) {
            Ticks.record(.{ .producer = self.id, .sequence = sequence });
        }
    }
};

const Echo = struct {
    count: u32 = 0,

    fn accept(context: *anyopaque, event: Tick) void {
        const self: *Echo = @ptrCast(@alignCast(context));
        self.count += 1;
        std.debug.assert(Ticks.suppressed());
        Ticks.record(.{ .producer = event.producer, .sequence = event.sequence + 1 });
    }
};

const Relay = struct {
    ticks: u32 = 0,
    marks: u32 = 0,

    fn tick(context: *anyopaque, event: Tick) void {
        const self: *Relay = @ptrCast(@alignCast(context));
        self.ticks += 1;
        Marks.record(.{ .value = @intCast(event.sequence) });
    }

    fn mark(context: *anyopaque, event: Mark) void {
        const self: *Relay = @ptrCast(@alignCast(context));
        std.debug.assert(event.value == self.ticks - 1);
        self.marks += 1;
    }
};

const Last = struct {
    event: ?Tick = null,

    fn accept(context: *anyopaque, event: Tick) void {
        const self: *Last = @ptrCast(@alignCast(context));
        self.event = event;
    }
};

const Uninstall = struct {
    fn run(session: *Ticks.Session, done: *std.atomic.Value(bool)) void {
        session.deinit();
        done.store(true, .release);
    }
};

test "uninstall drains concurrent deliveries and refuses a second install" {
    var stop = std.atomic.Value(bool).init(false);
    var threads: [producer_count]std.Thread = undefined;
    var spawned: u32 = 0;
    defer {
        stop.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    while (spawned < producer_count) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, Producer.run, .{Producer{
            .id = spawned,
            .stop = &stop,
        }});
    }

    var rounds: u32 = 0;
    while (rounds < 3) : (rounds += 1) {
        var counting = Counting{};
        const sink = counting.sink();
        var session = try Ticks.install(&sink);
        try counting.awaitDelivered(4096);

        var rival = Counting{};
        const rival_sink = rival.sink();
        try std.testing.expectError(error.AlreadyInstalled, Ticks.install(&rival_sink));

        session.deinit();
        try std.testing.expectEqual(@as(u32, 0), counting.in_callback.load(.acquire));
        const delivered = counting.delivered.load(.acquire);
        var waited: u32 = 0;
        while (waited < 1 << 12) : (waited += 1) std.Thread.yield() catch {};
        try std.testing.expectEqual(delivered, counting.delivered.load(.acquire));
        try std.testing.expectEqual(@as(u64, 0), rival.delivered.load(.acquire));
    }
}

test "a callback never observes events its own thread records" {
    var echo = Echo{};
    const sink = Ticks.Sink{ .context = &echo, .record = Echo.accept };
    var session = try Ticks.install(&sink);
    defer session.deinit();

    Ticks.record(.{ .producer = 0, .sequence = 0 });
    Ticks.record(.{ .producer = 0, .sequence = 1 });
    try std.testing.expectEqual(@as(u32, 2), echo.count);

    var suppression = Ticks.suppress();
    Ticks.record(.{ .producer = 0, .sequence = 2 });
    suppression.deinit();
    suppression.deinit();
    try std.testing.expectEqual(@as(u32, 2), echo.count);
    try std.testing.expect(!Ticks.suppressed());
}

test "channels for different event types install and suppress independently" {
    var relay = Relay{};
    const tick_sink = Ticks.Sink{ .context = &relay, .record = Relay.tick };
    const mark_sink = Marks.Sink{ .context = &relay, .record = Relay.mark };
    var ticks = try Ticks.install(&tick_sink);
    defer ticks.deinit();
    var marks = try Marks.install(&mark_sink);
    defer marks.deinit();

    Ticks.record(.{ .producer = 0, .sequence = 0 });
    try std.testing.expectEqual(@as(u32, 1), relay.ticks);
    try std.testing.expectEqual(@as(u32, 1), relay.marks);

    var suppression = Marks.suppress();
    defer suppression.deinit();
    Ticks.record(.{ .producer = 0, .sequence = 1 });
    try std.testing.expectEqual(@as(u32, 2), relay.ticks);
    try std.testing.expectEqual(@as(u32, 1), relay.marks);
}

test "a bracket held across an operation delays uninstall until release" {
    var last = Last{};
    const sink = Ticks.Sink{ .context = &last, .record = Last.accept };
    var session = try Ticks.install(&sink);

    const held = Ticks.acquire().?;
    try std.testing.expectEqual(&sink, held);
    var done = std.atomic.Value(bool).init(false);
    const uninstall = try std.Thread.spawn(.{}, Uninstall.run, .{ &session, &done });
    var waited: u32 = 0;
    while (waited < 1 << 12) : (waited += 1) std.Thread.yield() catch {};
    const early = done.load(.acquire);
    Ticks.deliver(held, .{ .producer = 1, .sequence = 7 });
    Ticks.release();
    uninstall.join();
    try std.testing.expect(!early);
    try std.testing.expect(done.load(.acquire));
    try std.testing.expectEqual(Tick{ .producer = 1, .sequence = 7 }, last.event.?);
    try std.testing.expectEqual(@as(?*const Ticks.Sink, null), Ticks.acquire());
}
