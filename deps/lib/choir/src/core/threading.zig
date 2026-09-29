const std = @import("std");
const sys = @import("sys");

pub const Options = struct {
    max_threads: usize = 1,
    worker_allocator: ?std.mem.Allocator = null,

    pub fn workerCount(self: Options, item_count: usize) usize {
        if (item_count == 0) return 1;
        const configured = if (self.max_threads == 0)
            sys.thread.cpuCount()
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

pub const ParallelError = std.mem.Allocator.Error || sys.thread.SpawnError;

pub fn parallelForEachIndex(
    allocator: std.mem.Allocator,
    options: Options,
    item_count: usize,
    context: anytype,
    comptime run: fn (@TypeOf(context), usize) void,
) ParallelError!void {
    const worker_count = options.workerCount(item_count);
    if (worker_count == 1) {
        for (0..item_count) |index| {
            run(context, index);
        }
        return;
    }

    const Context = @TypeOf(context);
    const Batch = struct {
        task_context: Context,
        next_index: *std.atomic.Value(usize),
        item_count: usize,
    };
    const Worker = struct {
        fn work(batch: *Batch) void {
            while (true) {
                const index = batch.next_index.fetchAdd(1, .monotonic);
                if (index >= batch.item_count) return;
                run(batch.task_context, index);
            }
        }
    };

    var next_index = std.atomic.Value(usize).init(0);
    var batch = Batch{
        .task_context = context,
        .next_index = &next_index,
        .item_count = item_count,
    };

    const spawned_count = worker_count - 1;
    const threads = try allocator.alloc(sys.thread.JoinHandle, spawned_count);
    defer allocator.free(threads);

    var spawned: usize = 0;
    errdefer {
        for (threads[0..spawned]) |thread| {
            thread.join();
        }
    }

    for (threads) |*thread| {
        thread.* = try sys.thread.spawn(Worker.work, .{&batch});
        spawned += 1;
    }
    Worker.work(&batch);
    for (threads) |thread| {
        thread.join();
    }
}

test "ThreadingOptions counts workers with item and cpu limits" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 1), (Options{}).workerCount(0));
    try testing.expectEqual(@as(usize, 1), (Options{}).workerCount(8));
    try testing.expectEqual(@as(usize, 2), (Options{ .max_threads = 2 }).workerCount(8));
    try testing.expectEqual(@as(usize, 2), (Options{ .max_threads = 4 }).workerCount(2));
    try testing.expect((Options{ .max_threads = 0 }).workerCount(8) >= 1);
}

test "ThreadingExecutionState tracks nested execution guards" {
    const testing = std.testing;

    var state = ExecutionState.init();
    try testing.expect(!state.isActive());

    var outer = state.enter();
    defer outer.deinit();
    try testing.expect(state.isActive());

    {
        var inner = state.enter();
        defer inner.deinit();
        try testing.expect(state.isActive());
    }

    try testing.expect(state.isActive());
    outer.deinit();
    try testing.expect(!state.isActive());
}

test "parallelForEachIndex visits every item" {
    const testing = std.testing;
    if (!sys.thread.threadsSupported()) return error.SkipZigTest;

    var hits: [8]std.atomic.Value(usize) = undefined;
    for (&hits) |*hit| hit.* = std.atomic.Value(usize).init(0);

    const Task = struct {
        values: []std.atomic.Value(usize),
    };
    const Runner = struct {
        fn run(task: *Task, index: usize) void {
            _ = task.values[index].fetchAdd(1, .acq_rel);
        }
    };

    var task = Task{ .values = &hits };
    try parallelForEachIndex(testing.allocator, .{ .max_threads = 2 }, hits.len, &task, Runner.run);

    for (&hits) |*hit| {
        try testing.expectEqual(@as(usize, 1), hit.load(.acquire));
    }
}
