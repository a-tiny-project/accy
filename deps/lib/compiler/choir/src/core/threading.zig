const std = @import("std");
const sys = @import("sys");
const simd = @import("simd");

/// Persistent workers that a caller creates and starts once, then lends to each parallel call
/// through `Options.pool`. Its size is the caller's thread budget: a build that runs N Choir
/// processes gives each a pool of its share, so no process starts threads beyond its share.
pub const Pool = simd.ThreadPool;

/// The order in which items are dealt to lanes. Output never depends on it. The determinism
/// witnesses compare both orders.
pub const Deal = enum {
    ascending,
    descending,

    fn item(self: Deal, item_count: usize, position: usize) usize {
        std.debug.assert(position < item_count);
        return switch (self) {
            .ascending => position,
            .descending => item_count - 1 - position,
        };
    }
};

pub const Options = struct {
    /// The most lanes one call uses. Zero asks for the whole pool, or without one for the workers
    /// the process's CPU time allows.
    max_threads: usize = 1,
    worker_allocator: ?std.mem.Allocator = null,
    /// The workers a parallel call runs on. Without one, a parallel call starts and joins its own
    /// threads.
    pool: ?*Pool = null,
    deal: Deal = .ascending,

    pub fn workerCount(self: Options, item_count: usize) usize {
        if (item_count == 0) return 1;
        const available = if (self.pool) |pool| pool.numWorkers() else sys.thread.parallelism();
        const configured = if (self.max_threads == 0)
            available
        else if (self.pool != null)
            @min(self.max_threads, available)
        else
            self.max_threads;
        return @max(@as(usize, 1), @min(configured, item_count));
    }

    pub fn workerAllocator(self: Options, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.worker_allocator orelse fallback;
    }

    pub fn requestsParallelism(self: Options) bool {
        return self.max_threads == 0 or self.max_threads > 1;
    }
};

pub const ExecutionState = struct {
    active: std.atomic.Value(usize),

    pub fn init() ExecutionState {
        return .{ .active = std.atomic.Value(usize).init(0) };
    }

    pub fn enter(self: *ExecutionState) ExecutionGuard {
        _ = self.active.fetchAdd(1, .acq_rel);
        return .{ .state = self };
    }

    pub fn isActive(self: *const ExecutionState) bool {
        return self.active.load(.acquire) != 0;
    }

    fn exit(self: *ExecutionState) void {
        const prior = self.active.fetchSub(1, .acq_rel);
        std.debug.assert(prior != 0);
    }
};

pub const ExecutionGuard = struct {
    state: ?*ExecutionState,

    pub fn deinit(self: *ExecutionGuard) void {
        if (self.state) |state| {
            state.exit();
            self.state = null;
        }
    }
};

pub const ParallelError = Pool.StartError;

/// Calls `run(context, item)` once for every item below `item_count`, on `options.workerCount`
/// lanes. Each call writes only state that belongs to its item.
pub fn parallelForEachIndex(
    options: Options,
    item_count: usize,
    context: anytype,
    comptime run: fn (@TypeOf(context), usize) void,
) ParallelError!void {
    try parallelForEachLane(options, item_count, context, IgnoreLane(@TypeOf(context), run).call);
}

/// Calls `run(context, item, lane)` once for every item below `item_count`. `lane` is below
/// `options.workerCount(item_count)`, and one lane runs its items one at a time, so a caller can
/// keep one workspace per lane. Lanes take items from one counter in `options.deal` order, so an
/// item's lane depends on the schedule and an item's output must not.
pub fn parallelForEachLane(
    options: Options,
    item_count: usize,
    context: anytype,
    comptime run: fn (@TypeOf(context), usize, usize) void,
) ParallelError!void {
    const lane_count = options.workerCount(item_count);
    if (lane_count == 1) {
        for (0..item_count) |position| run(context, options.deal.item(item_count, position), 0);
        return;
    }

    const LaneDealer = Dealer(@TypeOf(context), run);
    var dealer = LaneDealer{ .context = context, .item_count = item_count, .deal = options.deal };
    if (options.pool) |pool| return runLanes(pool, lane_count, &dealer, LaneDealer.lane);

    var transient = Pool.init(lane_count - 1, .{});
    defer transient.deinit();
    try transient.start();
    try runLanes(&transient, lane_count, &dealer, LaneDealer.lane);
}

fn IgnoreLane(comptime Context: type, comptime run: fn (Context, usize) void) type {
    return struct {
        fn call(context: Context, item: usize, lane: usize) void {
            _ = lane;
            run(context, item);
        }
    };
}

/// One pool task per lane. Each lane takes the next undealt item until none remain.
fn Dealer(comptime Context: type, comptime run: fn (Context, usize, usize) void) type {
    return struct {
        context: Context,
        next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        item_count: usize,
        deal: Deal,

        fn lane(self: *@This(), lane_index: u64, worker_index: usize) void {
            _ = worker_index;
            while (true) {
                const position = self.next.fetchAdd(1, .monotonic);
                if (position >= self.item_count) return;
                const item = self.deal.item(self.item_count, position);
                run(self.context, item, @intCast(lane_index));
            }
        }
    };
}

fn runLanes(
    pool: *Pool,
    lane_count: usize,
    dealer: anytype,
    comptime lane: fn (@TypeOf(dealer), u64, usize) void,
) ParallelError!void {
    pool.run(0, lane_count, dealer, lane) catch |err| switch (err) {
        // A call made while the pool runs another, from one of its own items or from another
        // thread, runs on the calling thread instead of waiting for the pool.
        error.Busy => lane(dealer, 0, 0),
        error.InvalidRange, error.TooManyTasks => unreachable,
        else => |start_error| return start_error,
    };
}

const VisitTask = struct {
    hits: []std.atomic.Value(usize),
    lanes: []std.atomic.Value(usize),
    order: []usize,
    next_order: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn visit(task: *VisitTask, item: usize, lane: usize) void {
        _ = task.hits[item].fetchAdd(1, .acq_rel);
        _ = task.lanes[lane].fetchAdd(1, .acq_rel);
        task.order[task.next_order.fetchAdd(1, .acq_rel)] = item;
    }

    fn expectEveryItemOnce(task: *VisitTask, lane_count: usize) !void {
        const testing = std.testing;
        for (task.hits) |*hit| try testing.expectEqual(@as(usize, 1), hit.load(.acquire));
        var visited: usize = 0;
        for (task.lanes, 0..) |*lane, index| {
            const count = lane.load(.acquire);
            if (index >= lane_count) try testing.expectEqual(@as(usize, 0), count);
            visited += count;
        }
        try testing.expectEqual(task.hits.len, visited);
    }
};

const NestedTask = struct {
    pool: *Pool,
    inner_hits: [3][4]std.atomic.Value(usize) = @splat(@splat(std.atomic.Value(usize).init(0))),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(task: *NestedTask, item: usize) void {
        const values: []std.atomic.Value(usize) = &task.inner_hits[item];
        const options = Options{ .max_threads = 0, .pool = task.pool };
        parallelForEachIndex(options, values.len, values, countHit) catch {
            task.failed.store(true, .release);
        };
    }
};

fn countHit(values: []std.atomic.Value(usize), index: usize) void {
    _ = values[index].fetchAdd(1, .acq_rel);
}
