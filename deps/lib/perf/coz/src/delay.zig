const std = @import("std");

pub const ThreadState = struct {
    in_use: std.atomic.Value(bool) = .init(false),
    local_delay_ns: std.atomic.Value(u64) = .init(0),
    pre_block_time_ns: u64 = 0,
    is_blocked: std.atomic.Value(bool) = .init(false),

    pub fn setInUse(self: *ThreadState, value: bool) void {
        self.in_use.store(value, .seq_cst);
    }

    pub fn acquireUse(self: *ThreadState) bool {
        return self.in_use.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null;
    }

    pub fn checkInUse(self: *const ThreadState) bool {
        return self.in_use.load(.seq_cst);
    }

    pub fn localDelay(self: *const ThreadState) u64 {
        return self.local_delay_ns.load(.monotonic);
    }
};

pub const Coordinator = struct {
    experiment_active: std.atomic.Value(bool) = .init(false),
    global_delay_ns: std.atomic.Value(u64) = .init(0),
    delay_size_ns: std.atomic.Value(u64) = .init(0),
    overshoot_ns: std.atomic.Value(u64) = .init(0),
    capped_waits: bool = false,

    pub fn startExperiment(self: *Coordinator, delay_size_ns: u64) void {
        self.delay_size_ns.store(delay_size_ns, .monotonic);
        self.overshoot_ns.store(0, .monotonic);
        self.experiment_active.store(true, .release);
    }

    pub fn finishExperiment(self: *Coordinator) void {
        self.experiment_active.store(false, .release);
    }

    pub fn active(self: *const Coordinator) bool {
        return self.experiment_active.load(.acquire);
    }

    pub fn globalDelay(self: *const Coordinator) u64 {
        return self.global_delay_ns.load(.monotonic);
    }

    pub fn delaySize(self: *const Coordinator) u64 {
        return self.delay_size_ns.load(.monotonic);
    }

    pub fn overshoot(self: *const Coordinator) u64 {
        return self.overshoot_ns.load(.monotonic);
    }

    pub fn preBlock(self: *Coordinator, thread: *ThreadState) void {
        thread.is_blocked.store(true, .release);
        thread.pre_block_time_ns = self.globalDelay();
    }

    pub fn postBlock(self: *Coordinator, thread: *ThreadState, skip_delays: bool) void {
        thread.setInUse(true);
        defer thread.setInUse(false);

        if (skip_delays) {
            const delta = self.globalDelay() -| thread.pre_block_time_ns;
            _ = thread.local_delay_ns.fetchAdd(delta, .monotonic);
        }
        thread.is_blocked.store(false, .release);
    }

    pub fn creditSelectedHit(self: *Coordinator, thread: *ThreadState) void {
        if (!self.active()) return;
        _ = thread.local_delay_ns.fetchAdd(self.delaySize(), .monotonic);
    }

    pub fn creditSelectedThreadAndPush(self: *Coordinator, thread: *ThreadState) u64 {
        if (!self.active()) return self.globalDelay();

        const delay_size = self.delaySize();
        const new_global = self.global_delay_ns.fetchAdd(delay_size, .monotonic) + delay_size;
        var local = thread.localDelay();
        while (local < new_global) {
            if (thread.local_delay_ns.cmpxchgWeak(local, new_global, .monotonic, .monotonic) == null) break;
            local = thread.localDelay();
        }
        return new_global;
    }

    pub fn addDelays(self: *Coordinator, thread: *ThreadState, wait: anytype) u64 {
        if (self.active()) {
            if (thread.is_blocked.load(.acquire)) return 0;

            const global = self.globalDelay();
            const local = thread.localDelay();
            if (local > global) {
                _ = self.global_delay_ns.fetchAdd(local - global, .monotonic);
                return 0;
            }
            if (local < global) {
                const needed = global - local;
                const waited = callWait(wait, needed);
                if (self.capped_waits) {
                    _ = thread.local_delay_ns.fetchAdd(needed, .monotonic);
                    if (waited > needed) _ = self.overshoot_ns.fetchAdd(waited - needed, .monotonic);
                } else {
                    _ = thread.local_delay_ns.fetchAdd(waited, .monotonic);
                }
                return waited;
            }
            return 0;
        }

        thread.local_delay_ns.store(self.globalDelay(), .monotonic);
        return 0;
    }

    pub fn inheritDelay(_: *Coordinator, child: *ThreadState, parent_delay_ns: u64) void {
        child.local_delay_ns.store(parent_delay_ns, .monotonic);
    }
};

fn callWait(wait: anytype, ns: u64) u64 {
    switch (@typeInfo(@TypeOf(wait))) {
        .@"struct", .@"enum", .@"union", .@"opaque" => if (comptime @hasDecl(@TypeOf(wait), "wait")) return wait.wait(ns),
        else => {},
    }
    return wait(ns);
}

fn exactWait(ns: u64) u64 {
    return ns;
}

fn overshootingWait(ns: u64) u64 {
    return ns + 3;
}

const CountingWait = struct {
    calls: *u32,

    pub fn wait(self: CountingWait, ns: u64) u64 {
        self.calls.* += 1;
        return ns;
    }
};

test "thread state publishes in-use changes" {
    var thread: ThreadState = .{};

    try std.testing.expect(!thread.checkInUse());
    try std.testing.expect(thread.acquireUse());
    try std.testing.expect(!thread.acquireUse());
    thread.setInUse(true);
    try std.testing.expect(thread.checkInUse());
    thread.setInUse(false);
    try std.testing.expect(!thread.checkInUse());
}

test "selected hit advances sampled thread then pushes global delay" {
    var coordinator: Coordinator = .{};
    var sampled: ThreadState = .{};
    var other: ThreadState = .{};

    coordinator.startExperiment(10);
    coordinator.creditSelectedHit(&sampled);
    try std.testing.expectEqual(@as(u64, 10), sampled.localDelay());

    try std.testing.expectEqual(@as(u64, 0), coordinator.addDelays(&sampled, exactWait));
    try std.testing.expectEqual(@as(u64, 10), coordinator.globalDelay());

    try std.testing.expectEqual(@as(u64, 10), coordinator.addDelays(&other, exactWait));
    try std.testing.expectEqual(@as(u64, 10), other.localDelay());
}

test "inactive coordinator catches thread local delay up without waiting" {
    var coordinator: Coordinator = .{};
    var thread: ThreadState = .{};
    coordinator.global_delay_ns.store(25, .monotonic);

    try std.testing.expectEqual(@as(u64, 0), coordinator.addDelays(&thread, exactWait));
    try std.testing.expectEqual(@as(u64, 25), thread.localDelay());
}

test "blocked threads do not wait until post block clears the flag" {
    var coordinator: Coordinator = .{};
    var thread: ThreadState = .{};

    coordinator.startExperiment(0);
    coordinator.global_delay_ns.store(20, .monotonic);
    coordinator.preBlock(&thread);

    try std.testing.expectEqual(@as(u64, 0), coordinator.addDelays(&thread, exactWait));
    try std.testing.expectEqual(@as(u64, 0), thread.localDelay());

    coordinator.postBlock(&thread, false);
    try std.testing.expectEqual(@as(u64, 20), coordinator.addDelays(&thread, exactWait));
    try std.testing.expectEqual(@as(u64, 20), thread.localDelay());
}

test "post block can skip delays inserted while blocked" {
    var coordinator: Coordinator = .{};
    var thread: ThreadState = .{};

    coordinator.startExperiment(0);
    coordinator.global_delay_ns.store(10, .monotonic);
    coordinator.preBlock(&thread);
    coordinator.global_delay_ns.store(35, .monotonic);
    coordinator.postBlock(&thread, true);

    try std.testing.expectEqual(@as(u64, 25), thread.localDelay());
    try std.testing.expectEqual(@as(u64, 10), thread.pre_block_time_ns);
    try std.testing.expectEqual(@as(u64, 10), coordinator.addDelays(&thread, exactWait));
    try std.testing.expectEqual(@as(u64, 35), thread.localDelay());
}

test "selected sampled thread credit pushes global delay without delaying sampled thread" {
    var coordinator: Coordinator = .{};
    var sampled: ThreadState = .{};
    var other: ThreadState = .{};

    coordinator.startExperiment(12);
    try std.testing.expectEqual(@as(u64, 12), coordinator.creditSelectedThreadAndPush(&sampled));
    try std.testing.expectEqual(@as(u64, 12), sampled.localDelay());
    try std.testing.expectEqual(@as(u64, 12), coordinator.globalDelay());
    try std.testing.expectEqual(@as(u64, 12), coordinator.addDelays(&other, exactWait));
}

test "capped waits charge requested delay and record overshoot separately" {
    var coordinator: Coordinator = .{ .capped_waits = true };
    var thread: ThreadState = .{};

    coordinator.startExperiment(0);
    coordinator.global_delay_ns.store(10, .monotonic);

    try std.testing.expectEqual(@as(u64, 13), coordinator.addDelays(&thread, overshootingWait));
    try std.testing.expectEqual(@as(u64, 10), thread.localDelay());
    try std.testing.expectEqual(@as(u64, 3), coordinator.overshoot());
}

test "delay coordinator accepts wait objects" {
    var coordinator: Coordinator = .{};
    var thread: ThreadState = .{};
    var calls: u32 = 0;

    coordinator.startExperiment(0);
    coordinator.global_delay_ns.store(11, .monotonic);

    try std.testing.expectEqual(@as(u64, 11), coordinator.addDelays(&thread, CountingWait{ .calls = &calls }));
    try std.testing.expectEqual(@as(u32, 1), calls);
    try std.testing.expectEqual(@as(u64, 11), thread.localDelay());
}

test "child threads inherit parent delay credit" {
    var coordinator: Coordinator = .{};
    var child: ThreadState = .{};

    coordinator.inheritDelay(&child, 17);

    try std.testing.expectEqual(@as(u64, 17), child.localDelay());
}
