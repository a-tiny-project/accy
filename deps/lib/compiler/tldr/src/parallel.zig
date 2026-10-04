const std = @import("std");
const allocators = @import("alloc");
const alloc_arena = @import("alloc_arena");
const sys = @import("sys");

const Allocator = std.mem.Allocator;
const Arena = alloc_arena.Arena;

/// Bounds every worker budget. A budget counts the calling thread, so the
/// shared pool holds at most `max_workers - 1` threads.
pub const max_workers = 64;

/// Names the variable through which the build governor hands an admitted lane
/// its CPU count. build/api/src/capacity.zig owns it as
/// `effective_cpu_environment`.
pub const cpu_handoff_environment = "TINY_BUILD_EFFECTIVE_CPU_COUNT";

/// Settles a process's worker budget once, at startup. `handoff` is the text of
/// `cpu_handoff_environment` inside an admitted build lane and null outside any
/// lane, where the host's `host_cpus` is the fallback. Refuses a handoff that is
/// not a positive integer, and bounds the budget by `max_workers`.
pub fn settleBudget(handoff: ?[]const u8, host_cpus: usize) error{InvalidWorkerBudget}!usize {
    std.debug.assert(host_cpus >= 1);
    const cpus = if (handoff) |text|
        std.fmt.parseUnsigned(usize, text, 10) catch return error.InvalidWorkerBudget
    else
        host_cpus;
    if (cpus == 0) return error.InvalidWorkerBudget;
    const budget = @min(cpus, max_workers);
    assertBudget(budget);
    return budget;
}

/// Asserts that `budget` counts the calling thread and stays within
/// `max_workers`.
pub fn assertBudget(budget: usize) void {
    std.debug.assert(budget >= 1);
    std.debug.assert(budget <= max_workers);
}

pub const WorkerArenaPool = struct {
    backing_owner: ?*allocators.LockedAllocator = null,
    arenas: []Arena = &.{},

    pub fn init(storage: Allocator, worker_count: usize) !WorkerArenaPool {
        std.debug.assert(worker_count <= max_workers);
        const count = @max(worker_count, 1);
        std.debug.assert(count >= 1);
        std.debug.assert(count <= max_workers);

        const backing_owner = try storage.create(allocators.LockedAllocator);
        errdefer storage.destroy(backing_owner);
        backing_owner.* = allocators.LockedAllocator.init(storage);

        const arenas = try storage.alloc(Arena, count);
        for (arenas) |*arena| arena.* = Arena.init(backing_owner.allocator());
        return .{ .backing_owner = backing_owner, .arenas = arenas };
    }

    pub fn deinit(self: *WorkerArenaPool) void {
        std.debug.assert(self.backing_owner != null);
        std.debug.assert(self.arenas.len >= 1);
        const backing_owner = self.backing_owner.?;
        const storage = backing_owner.child;
        for (self.arenas) |*arena| arena.deinit();
        storage.free(self.arenas);
        storage.destroy(backing_owner);
        self.* = .{};
    }

    pub fn allocator(self: *WorkerArenaPool, worker: usize) Allocator {
        std.debug.assert(self.backing_owner != null);
        std.debug.assert(worker < self.arenas.len);
        return self.arenas[worker].allocator();
    }
};

pub fn FailureSlots(comptime Failure: type) type {
    return struct {
        items: []Failure = &.{},
        empty: Failure,

        const Self = @This();

        pub fn init(storage: Allocator, slot_count: usize, empty: Failure) !Self {
            const count = @max(slot_count, 1);
            const items = try storage.alloc(Failure, count);
            for (items) |*item| item.* = empty;
            return .{ .items = items, .empty = empty };
        }

        pub fn deinit(self: *Self, storage: Allocator) void {
            storage.free(self.items);
            self.* = .{ .empty = self.empty };
        }

        pub fn record(self: *Self, worker: usize, failure: Failure) void {
            self.items[worker] = failure;
        }

        pub fn earliest(
            self: *const Self,
            comptime found: fn (Failure) bool,
            comptime before: fn (Failure, Failure) bool,
        ) ?Failure {
            var best: ?Failure = null;
            for (self.items) |item| {
                if (!found(item)) continue;
                if (best == null or before(item, best.?)) best = item;
            }
            return best;
        }
    };
}

const ChunkCallback = *const fn (*anyopaque, usize, usize, usize) void;

const Job = struct {
    total: usize = 0,
    slots: usize = 0,
    context: *anyopaque = undefined,
    callback: ChunkCallback = undefined,
    background: bool = false,
    next_slot: usize = 0,
    pending: usize = 0,
    prev: ?*Job = null,
    next: ?*Job = null,
};

const Claim = struct {
    job: *Job,
    slot: usize,
};

const JobQueue = struct {
    head: ?*Job = null,
    tail: ?*Job = null,

    fn append(self: *JobQueue, job: *Job) void {
        job.prev = self.tail;
        job.next = null;
        if (self.tail) |tail| {
            tail.next = job;
        } else {
            self.head = job;
        }
        self.tail = job;
    }

    fn remove(self: *JobQueue, job: *Job) void {
        if (job.prev) |prev| {
            prev.next = job.next;
        } else {
            self.head = job.next;
        }
        if (job.next) |next| {
            next.prev = job.prev;
        } else {
            self.tail = job.prev;
        }
        job.prev = null;
        job.next = null;
    }
};

const WorkerPool = struct {
    mutex: sys.thread.Mutex = .{},
    ready: sys.thread.Condition = .{},
    done: sys.thread.Condition = .{},
    worker_count: usize = 0,
    spawn_failed: bool = false,
    foreground: JobQueue = .{},
    background: JobQueue = .{},

    fn ensureStarted(self: *WorkerPool, desired_workers: usize) bool {
        if (desired_workers == 0) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        const desired = @min(desired_workers, max_workers - 1);
        while (self.worker_count < desired and !self.spawn_failed) {
            const handle = sys.thread.spawn(workerLoop, .{self}) catch {
                self.spawn_failed = true;
                break;
            };
            self.worker_count += 1;
            handle.detach();
        }
        return self.worker_count != 0;
    }

    fn submit(self: *WorkerPool, job: *Job, desired_workers: usize, reserved_slots: usize) bool {
        std.debug.assert(job.slots > reserved_slots);
        if (!self.ensureStarted(desired_workers)) return false;
        self.mutex.lock();
        job.next_slot = reserved_slots;
        job.pending = job.slots;
        self.queueFor(job).append(job);
        self.ready.broadcast();
        self.mutex.unlock();
        return true;
    }

    fn queueFor(self: *WorkerPool, job: *Job) *JobQueue {
        return if (job.background) &self.background else &self.foreground;
    }

    fn claimAnyLocked(self: *WorkerPool) ?Claim {
        const job = self.foreground.head orelse self.background.head orelse return null;
        return self.claimFromLocked(job);
    }

    fn claimFromLocked(self: *WorkerPool, job: *Job) Claim {
        const slot = job.next_slot;
        job.next_slot += 1;
        if (job.next_slot == job.slots) self.queueFor(job).remove(job);
        return .{ .job = job, .slot = slot };
    }

    fn runClaim(claim: Claim) void {
        const job = claim.job;
        const start = rangeStart(job.total, job.slots, claim.slot);
        const end = rangeStart(job.total, job.slots, claim.slot + 1);
        job.callback(job.context, claim.slot, start, end);
    }

    fn finishLocked(self: *WorkerPool, job: *Job) void {
        job.pending -= 1;
        if (job.pending == 0) self.done.broadcast();
    }

    fn workerLoop(self: *WorkerPool) void {
        self.mutex.lock();
        while (true) {
            if (self.claimAnyLocked()) |claim| {
                self.mutex.unlock();
                runClaim(claim);
                self.mutex.lock();
                self.finishLocked(claim.job);
            } else {
                self.ready.wait(&self.mutex);
            }
        }
    }

    fn wait(self: *WorkerPool, job: *Job) void {
        self.mutex.lock();
        while (job.pending != 0) {
            if (job.next_slot < job.slots) {
                const claim = self.claimFromLocked(job);
                self.mutex.unlock();
                runClaim(claim);
                self.mutex.lock();
                self.finishLocked(job);
            } else {
                self.done.wait(&self.mutex);
            }
        }
        self.mutex.unlock();
    }

    fn completeReserved(self: *WorkerPool, job: *Job) void {
        runClaim(.{ .job = job, .slot = 0 });
        self.mutex.lock();
        self.finishLocked(job);
        self.mutex.unlock();
        self.wait(job);
    }
};

/// Grows to the largest budget, less the calling thread, that any caller has
/// passed, and never past `max_workers - 1` threads.
var global_worker_pool = WorkerPool{};

/// Returns whether `budget` leaves a worker beside the calling thread.
pub fn overlapAvailable(budget: usize) bool {
    assertBudget(budget);
    return budget > 1 and sys.thread.threadsSupported();
}

/// Returns the workers `size` units of work earn at one worker per `grain`
/// units: at least one, and at most `budget`.
pub fn grainWorkers(budget: usize, size: usize, grain: usize) usize {
    assertBudget(budget);
    std.debug.assert(grain > 0);
    return std.math.clamp(size / grain, 1, budget);
}

/// Returns how many workers, the calling thread included, split `total` items
/// under `budget`.
pub fn chooseWorkers(total: usize, budget: usize) usize {
    assertBudget(budget);
    if (total <= 1 or !sys.thread.threadsSupported()) return 1;
    return @min(total, budget);
}

pub fn rangeStart(total: usize, workers: usize, worker: usize) usize {
    const base = total / workers;
    const remainder = total % workers;
    return worker * base + @min(worker, remainder);
}

fn ChunkCallbackType(
    comptime Context: type,
    comptime body: fn (Context, usize, usize, usize) void,
) type {
    return struct {
        fn run_opaque(opaque_context: *anyopaque, worker: usize, start: usize, end: usize) void {
            const typed_context: *Context = @ptrCast(@alignCast(opaque_context));
            body(typed_context.*, worker, start, end);
        }
    };
}

pub fn forChunks(
    total: usize,
    budget: usize,
    context: anytype,
    comptime body: fn (@TypeOf(context), usize, usize, usize) void,
) void {
    const workers = chooseWorkers(total, budget);
    if (workers <= 1) {
        body(context, 0, 0, total);
        return;
    }

    const Context: type = @TypeOf(context);
    const Callback: type = ChunkCallbackType(Context, body);

    var context_storage = context;
    var job = Job{
        .total = total,
        .slots = workers,
        .context = @ptrCast(&context_storage),
        .callback = Callback.run_opaque,
    };
    if (global_worker_pool.submit(&job, workers - 1, 1)) {
        global_worker_pool.completeReserved(&job);
        return;
    }

    var worker: usize = 0;
    while (worker < workers) : (worker += 1) {
        body(
            context,
            worker,
            rangeStart(total, workers, worker),
            rangeStart(total, workers, worker + 1),
        );
    }
}

fn ItemStateType(comptime Context: type) type {
    return struct {
        user: Context,
        next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        total: usize,
    };
}

fn ItemCallbackType(
    comptime Context: type,
    comptime State: type,
    comptime body: fn (Context, usize, usize) void,
) type {
    return struct {
        fn run(state: *State, worker: usize, start: usize, end: usize) void {
            _ = start;
            _ = end;
            while (true) {
                const item = state.next.fetchAdd(1, .monotonic);
                if (item >= state.total) break;
                body(state.user, worker, item);
            }
        }
    };
}

pub fn forItems(
    total: usize,
    budget: usize,
    context: anytype,
    comptime body: fn (@TypeOf(context), usize, usize) void,
) void {
    const workers = chooseWorkers(total, budget);
    if (workers <= 1) {
        var item: usize = 0;
        while (item < total) : (item += 1) body(context, 0, item);
        return;
    }

    const Context: type = @TypeOf(context);
    const State: type = ItemStateType(Context);
    const Callback: type = ItemCallbackType(Context, State, body);

    var state = State{ .user = context, .total = total };
    forChunks(workers, workers, &state, Callback.run);
}

pub fn Background(
    comptime Context: type,
    comptime body: fn (Context, usize) void,
) type {
    return struct {
        job: Job = .{ .background = true },
        context: Context = undefined,
        submitted: bool = false,

        const Self = @This();

        /// Runs `total` items on up to `workers` pool threads while the
        /// calling thread goes on with its own work, so a caller passes its
        /// budget less the calling thread.
        pub fn submit(self: *Self, total: usize, workers: usize, context: Context) void {
            std.debug.assert(!self.submitted);
            std.debug.assert(workers >= 1);
            std.debug.assert(workers < max_workers);
            if (total == 0) return;
            self.context = context;
            self.job.total = total;
            self.job.slots = total;
            self.job.context = @ptrCast(self);
            self.job.callback = runOpaque;
            if (sys.thread.threadsSupported()) {
                if (global_worker_pool.submit(&self.job, @min(workers, total), 0)) {
                    self.submitted = true;
                    return;
                }
            }
            var item: usize = 0;
            while (item < total) : (item += 1) body(context, item);
        }

        pub fn wait(self: *Self) void {
            if (!self.submitted) return;
            global_worker_pool.wait(&self.job);
            self.submitted = false;
        }

        fn runOpaque(opaque_context: *anyopaque, slot: usize, start: usize, end: usize) void {
            _ = start;
            _ = end;
            const self: *Self = @ptrCast(@alignCast(opaque_context));
            body(self.context, slot);
        }
    };
}

fn SortChunkStateType(comptime T: type, comptime Context: type) type {
    return struct {
        items: []T,
        chunk: usize,
        user: Context,
    };
}

fn SortMergeStateType(comptime T: type, comptime Context: type) type {
    return struct {
        source: []T,
        target: []T,
        width: usize,
        user: Context,
    };
}

fn SortCallbacksType(
    comptime T: type,
    comptime Context: type,
    comptime SortState: type,
    comptime MergeState: type,
    comptime less: fn (Context, T, T) bool,
) type {
    return struct {
        fn sort_chunk(state: *SortState, worker: usize, index: usize) void {
            _ = worker;
            const low = index * state.chunk;
            if (low >= state.items.len) return;
            const high = @min(low + state.chunk, state.items.len);
            std.sort.pdq(T, state.items[low..high], state.user, less);
        }

        fn merge_segment(state: *MergeState, worker: usize, index: usize) void {
            _ = worker;
            const low = index * 2 * state.width;
            if (low >= state.source.len) return;
            const middle = @min(low + state.width, state.source.len);
            const high = @min(low + 2 * state.width, state.source.len);
            merge_runs(
                state.user,
                state.source[low..middle],
                state.source[middle..high],
                state.target[low..high],
            );
        }

        fn merge_runs(user: Context, left: []const T, right: []const T, out: []T) void {
            var left_index: usize = 0;
            var right_index: usize = 0;
            var out_index: usize = 0;
            while (left_index < left.len and right_index < right.len) : (out_index += 1) {
                if (less(user, right[right_index], left[left_index])) {
                    out[out_index] = right[right_index];
                    right_index += 1;
                } else {
                    out[out_index] = left[left_index];
                    left_index += 1;
                }
            }
            if (left_index < left.len) {
                @memcpy(out[out_index..], left[left_index..]);
            } else if (right_index < right.len) {
                @memcpy(out[out_index..], right[right_index..]);
            }
        }
    };
}

pub fn sortItems(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime less: fn (@TypeOf(context), T, T) bool,
    scratch: []T,
    budget: usize,
) void {
    const workers = chooseWorkers(items.len, budget);
    if (workers <= 1 or items.len < 2) {
        std.sort.pdq(T, items, context, less);
        return;
    }
    std.debug.assert(scratch.len >= items.len);

    const Context: type = @TypeOf(context);
    const SortState: type = SortChunkStateType(T, Context);
    const MergeState: type = SortMergeStateType(T, Context);
    const Callbacks: type = SortCallbacksType(T, Context, SortState, MergeState, less);
    const total = items.len;
    const chunk = (total + workers - 1) / workers;

    var sort_state = SortState{ .items = items, .chunk = chunk, .user = context };
    forItems(workers, workers, &sort_state, Callbacks.sort_chunk);

    var source = items;
    var target = scratch[0..total];
    var width = chunk;
    while (width < total) : (width *= 2) {
        const segments = (total + 2 * width - 1) / (2 * width);
        var merge_state = MergeState{
            .source = source,
            .target = target,
            .width = width,
            .user = context,
        };
        forItems(segments, workers, &merge_state, Callbacks.merge_segment);
        const swapped = source;
        source = target;
        target = swapped;
    }
    if (source.ptr != items.ptr) @memcpy(items, source);
}

fn lessUsize(_: void, left: usize, right: usize) bool {
    return left < right;
}

const U8HitsContext = struct {
    hits: []u8,
};

const U16HitsContext = struct {
    hits: []u16,
};

const SumContext = struct {
    sum: *usize,
};

const TestFailure = struct {
    found: bool = false,
    index: usize = 0,
};

const WorkerArenaPoolAllocationFailures = struct {
    fn run(storage: Allocator) !void {
        var pool = try WorkerArenaPool.init(storage, 4);
        defer pool.deinit();
        _ = try pool.allocator(3).alloc(u8, 128);
    }
};

fn count_u8_chunks(context: U8HitsContext, _: usize, start: usize, end: usize) void {
    var index = start;
    while (index < end) : (index += 1) context.hits[index] += 1;
}

fn count_u16_chunks(context: U16HitsContext, _: usize, start: usize, end: usize) void {
    var index = start;
    while (index < end) : (index += 1) context.hits[index] += 1;
}

fn count_u8_item(context: U8HitsContext, _: usize, item: usize) void {
    context.hits[item] += 1;
}

fn count_u8_background_item(context: U8HitsContext, item: usize) void {
    context.hits[item] += 1;
}

fn failure_found(failure: TestFailure) bool {
    return failure.found;
}

fn failure_before(left: TestFailure, right: TestFailure) bool {
    return left.index < right.index;
}

const TestBackground = Background(U8HitsContext, count_u8_background_item);
const chained_background_total = 128;
const nested_parallel_inner_total = 64;

const ChainedBackgroundContext = struct {
    hits: []u8,
    second: *TestBackground,
    second_hits: []u8,
};

fn start_chained_background(context: ChainedBackgroundContext, item: usize) void {
    context.hits[item] += 1;
    if (item == 0) {
        context.second.submit(chained_background_total, 2, .{ .hits = context.second_hits });
    }
}

const ChainedBackground = Background(ChainedBackgroundContext, start_chained_background);

fn count_nested_chunks(context: U8HitsContext, _: usize, start: usize, end: usize) void {
    var chunk = start;
    while (chunk < end) : (chunk += 1) {
        const offset = chunk * nested_parallel_inner_total;
        forItems(nested_parallel_inner_total, 2, U8HitsContext{
            .hits = context.hits[offset..][0..nested_parallel_inner_total],
        }, count_u8_item);
    }
}

fn sum_chunk(context: SumContext, _: usize, start: usize, end: usize) void {
    context.sum.* += end - start;
}
