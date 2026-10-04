const std = @import("std");
const sys = @import("sys");
const simd = @import("../root.zig");
const spin = @import("spin.zig");
const wait = @import("wait.zig");
const autotune = simd.autotune;
const topology = simd.topology;

pub const max_clusters: usize = 33;
pub const all_clusters: usize = max_clusters - 1;
pub const max_threads: usize = 127;
pub const max_workers: usize = max_threads + 1;
pub const max_callers: usize = 60;
pub const caller_name_capacity: usize = 64;
pub const max_victims: usize = 4;
pub const max_configs: usize = 4;

pub const PoolWaitMode = enum(u8) {
    block = 1,
    spin,
};

pub const WaitType = enum(u8) {
    block,
    spin_shared,
    spin_separate,
};

pub fn waitName(wait_type: WaitType) []const u8 {
    return switch (wait_type) {
        .block => "Block",
        .spin_shared => "Single",
        .spin_separate => "Separate",
    };
}

pub const Exit = enum(u32) {
    none,
    loop,
    thread,
};

pub const Config = struct {
    spin_type: spin.SpinType = .pause,
    wait_type: WaitType = .spin_separate,
    reserved: [2]u8 = @splat(0),

    pub fn formatName(
        self: Config,
        storage: []u8,
    ) error{NoSpaceLeft}![]const u8 {
        return std.fmt.bufPrint(
            storage,
            "{s:<14} {s:<9}",
            .{ spin.name(self.spin_type), waitName(self.wait_type) },
        );
    }

    pub fn candidates(
        mode: PoolWaitMode,
        storage: *[max_configs]Config,
    ) []const Config {
        return switch (mode) {
            .block => blk: {
                storage[0] = .{ .wait_type = .block };
                break :blk storage[0..1];
            },
            .spin => blk: {
                const detected = spin.detectSpin(0);
                const spin_types: [2]spin.SpinType = .{ detected, .pause };
                const spin_count: usize = if (detected == .pause) 1 else 2;
                var count: usize = 0;
                for (spin_types[0..spin_count]) |spin_type| {
                    storage[count] = .{
                        .spin_type = spin_type,
                        .wait_type = .spin_shared,
                    };
                    count += 1;
                    storage[count] = .{
                        .spin_type = spin_type,
                        .wait_type = .spin_separate,
                    };
                    count += 1;
                }
                break :blk storage[0..count];
            },
        };
    }

    fn encode(self: Config) u16 {
        return @as(u16, @backingInt(self.spin_type)) |
            @as(u16, @backingInt(self.wait_type)) << 8;
    }

    fn decode(bits: u16) Config {
        return .{
            .spin_type = @fromBackingInt(@intCast(@as(u8, @truncate(bits)))),
            .wait_type = @fromBackingInt(@intCast(@as(u8, @truncate(bits >> 8)))),
        };
    }
};

pub const PoolWorkerMapping = struct {
    cluster_index: u8 = 0,
    max_cluster_workers: usize = 0,

    pub fn init(
        cluster_index: usize,
        max_cluster_workers: usize,
    ) error{ InvalidCluster, EmptyCluster }!PoolWorkerMapping {
        if (cluster_index > all_clusters) return error.InvalidCluster;
        if (max_cluster_workers == 0) return error.EmptyCluster;
        return .{
            .cluster_index = @intCast(cluster_index),
            .max_cluster_workers = max_cluster_workers,
        };
    }

    pub fn clusterIndex(self: PoolWorkerMapping) usize {
        return self.cluster_index;
    }

    pub fn maxClusterWorkers(self: PoolWorkerMapping) usize {
        return self.max_cluster_workers;
    }

    pub fn globalIndex(
        self: PoolWorkerMapping,
        worker_index: usize,
    ) usize {
        if (self.max_cluster_workers == 0) return worker_index;
        if (self.cluster_index == all_clusters) {
            std.debug.assert(worker_index < all_clusters);
            return worker_index * self.max_cluster_workers;
        }
        std.debug.assert(worker_index < self.max_cluster_workers);
        return self.cluster_index * self.max_cluster_workers + worker_index;
    }
};

pub const ShuffledIota = struct {
    coprime: u32 = 1,

    pub fn init(coprime: u32) ShuffledIota {
        return .{ .coprime = coprime };
    }

    pub fn next(
        self: ShuffledIota,
        current: u32,
        size: u32,
    ) u32 {
        std.debug.assert(size != 0);
        std.debug.assert(current < size);
        return @intCast(
            (@as(u64, current) + self.coprime) % @as(u64, size),
        );
    }

    pub fn coprimeNonzero(a_value: u32, b_value: u32) bool {
        std.debug.assert(a_value != 0);
        std.debug.assert(b_value != 0);
        var a = a_value;
        var b = b_value;
        const trailing_a = @ctz(a);
        const trailing_b = @ctz(b);
        if (@min(trailing_a, trailing_b) != 0) return false;
        a >>= @intCast(trailing_a);
        b >>= @intCast(trailing_b);
        while (true) {
            const previous_a = a;
            a = @max(previous_a, b);
            b = @min(previous_a, b);
            if (b == 1) return true;
            a -= b;
            if (a == 0) return false;
            a >>= @intCast(@ctz(a));
        }
    }

    pub fn findAnotherCoprime(size: u32, start: u32) u32 {
        std.debug.assert(size != 0);
        if (size <= 2) return 1;
        const increment: u32 = if (size & 1 == 0) 2 else 1;
        var candidate = start | 1;
        var attempts: u64 = 0;
        const max_attempts = @as(u64, size) * 16;
        while (attempts < max_attempts) : (attempts += 1) {
            if (coprimeNonzero(candidate, size)) return candidate;
            candidate +%= increment;
            if (candidate == 0) candidate = 1;
        }
        unreachable;
    }
};

pub const Caller = struct {
    index: u8 = 0,

    pub fn id(self: Caller) usize {
        return self.index;
    }
};

pub const CallerStats = struct {
    runs: u64 = 0,
    tasks: u64 = 0,
    workers: u64 = 0,
    elapsed_ns: u64 = 0,
};

pub const PoolStats = struct {
    runs: u64 = 0,
    serial_runs: u64 = 0,
    threaded_runs: u64 = 0,
    tasks: u64 = 0,
    stolen_tasks: u64 = 0,
    elapsed_ns: u64 = 0,
};

const CallerRegistry = struct {
    guard: std.atomic.Mutex = .unlocked,
    count: usize = 1,
    lengths: [max_callers]u8 = @splat(0),
    names: [max_callers][caller_name_capacity]u8 = @splat(@splat(0)),

    fn add(
        self: *CallerRegistry,
        caller_name: []const u8,
    ) error{ EmptyCallerName, CallerNameTooLong, TooManyCallers }!Caller {
        if (caller_name.len == 0) return error.EmptyCallerName;
        if (caller_name.len > caller_name_capacity) {
            return error.CallerNameTooLong;
        }
        while (!self.guard.tryLock()) std.atomic.spinLoopHint();
        defer self.guard.unlock();
        for (self.names[1..self.count], 1..) |stored, index| {
            const length = self.lengths[index];
            if (std.mem.eql(u8, stored[0..length], caller_name)) {
                return .{ .index = @intCast(index) };
            }
        }
        if (self.count == max_callers) return error.TooManyCallers;
        const index = self.count;
        @memcpy(self.names[index][0..caller_name.len], caller_name);
        self.lengths[index] = @intCast(caller_name.len);
        self.count += 1;
        return .{ .index = @intCast(index) };
    }

    fn name(self: *CallerRegistry, caller: Caller) ?[]const u8 {
        while (!self.guard.tryLock()) std.atomic.spinLoopHint();
        defer self.guard.unlock();
        if (caller.index == 0 or caller.index >= self.count) return null;
        const length = self.lengths[caller.index];
        return self.names[caller.index][0..length];
    }
};

var caller_registry = CallerRegistry{};

pub fn addCaller(
    name: []const u8,
) error{ EmptyCallerName, CallerNameTooLong, TooManyCallers }!Caller {
    return caller_registry.add(name);
}

pub fn callerName(caller: Caller) ?[]const u8 {
    return caller_registry.name(caller);
}

pub fn workerRange(
    begin: u64,
    end: u64,
    worker_count: usize,
    worker_index: usize,
) error{ InvalidRange, EmptyWorkers, WorkerOutOfBounds, TooManyTasks }!struct {
    begin: u64,
    end: u64,
} {
    if (begin > end) return error.InvalidRange;
    if (worker_count == 0) return error.EmptyWorkers;
    if (worker_index >= worker_count) return error.WorkerOutOfBounds;
    const task_count_u64 = end - begin;
    if (task_count_u64 > std.math.maxInt(usize)) return error.TooManyTasks;
    const task_count: usize = @intCast(task_count_u64);
    const minimum = task_count / worker_count;
    const remainder = task_count % worker_count;
    const local_begin = worker_index * minimum + @min(worker_index, remainder);
    const local_count = minimum + @intFromBool(worker_index < remainder);
    return .{
        .begin = begin + local_begin,
        .end = begin + local_begin + local_count,
    };
}

const Worker = struct {
    begin: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    end: usize = 0,
    last_tasks: usize = 0,
    last_stolen: usize = 0,
    wait_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    barrier_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    victims: [max_victims]u8 = @splat(0),
    victim_count: u8 = 0,
    padding: [if (@sizeOf(usize) == 8) 19 else 35]u8 = @splat(0),
};

comptime {
    if (@sizeOf(Worker) != 64) @compileError("thread worker must occupy one cache line");
}

const Callback = *const fn (*anyopaque, u64, usize) void;
const AutoTuner = autotune.AutoTune(Config, max_configs, 30);

pub const ThreadPool = struct {
    pub const State = enum(u8) {
        initialization,
        steady,
        teardown,
    };

    pub const Capacity = struct {
        requested_threads: usize,
        threads: u8,
        workers: u8,

        pub fn derive(requested_threads: usize) Capacity {
            const supported = topology.haveThreadingSupport() and
                sys.thread.threadsSupported();
            const thread_count: usize = if (supported)
                @min(requested_threads, max_threads)
            else
                0;
            const worker_count: usize = thread_count + 1;
            return .{
                .requested_threads = requested_threads,
                .threads = @intCast(thread_count),
                .workers = @intCast(worker_count),
            };
        }

        pub fn wasClamped(self: Capacity) bool {
            return self.requested_threads != self.threads;
        }
    };

    pub const StartError = sys.thread.SpawnError || error{
        AlreadyDeinitialized,
        PoolMoved,
    };

    pub const RunError = StartError || error{
        Busy,
        InvalidRange,
        TooManyTasks,
    };

    state: State = .initialization,
    capacity: Capacity,
    mapping: PoolWorkerMapping,
    address: usize = 0,
    wait_mode: std.atomic.Value(u8) =
        std.atomic.Value(u8).init(@backingInt(PoolWaitMode.block)),
    config_bits: std.atomic.Value(u16) =
        std.atomic.Value(u16).init((Config{ .wait_type = .block }).encode()),
    epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    work_available: std.atomic.Value(bool) =
        std.atomic.Value(bool).init(false),
    exiting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    synchronization: sys.thread.Mutex = .{},
    done: sys.thread.Condition = .{},
    started_threads: usize = 0,
    handles: [max_threads]sys.thread.JoinHandle = undefined,
    workers: [max_workers]Worker align(64) = @splat(.{}),
    task_context: *anyopaque = undefined,
    task_callback: Callback = undefined,
    current_begin: u64 = 0,
    current_tasks: usize = 0,
    stats: PoolStats = .{},
    caller_stats: [max_callers]CallerStats = @splat(.{}),
    block_tuner: AutoTuner = .{},
    spin_tuner: AutoTuner = .{},

    pub fn init(
        requested_threads: usize,
        mapping: PoolWorkerMapping,
    ) ThreadPool {
        var self = ThreadPool{
            .capacity = Capacity.derive(requested_threads),
            .mapping = mapping,
        };
        var candidates: [max_configs]Config = undefined;
        self.block_tuner.setCandidates(
            Config.candidates(.block, &candidates),
        ) catch unreachable;
        self.spin_tuner.setCandidates(
            Config.candidates(.spin, &candidates),
        ) catch unreachable;
        self.config_bits.store(
            self.block_tuner.nextConfig().encode(),
            .monotonic,
        );
        self.configureWorkers();
        return self;
    }

    pub fn maxThreads() usize {
        if (!topology.haveThreadingSupport() or
            !sys.thread.threadsSupported())
        {
            return 0;
        }
        var affinity = topology.LogicalProcessorSet{};
        if (topology.getThreadAffinity(&affinity)) {
            const count = affinity.count();
            if (count != 0) return @min(count - 1, max_threads);
        }
        return @min(
            topology.totalLogicalProcessors() -| 1,
            max_threads,
        );
    }

    pub fn numThreadsFromCores(
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!usize {
        if (!topology.haveThreadingSupport() or
            !sys.thread.threadsSupported())
        {
            return 0;
        }
        var detected = try topology.init(allocator);
        defer detected.deinit(allocator);
        if (detected.packages.len == 0) return maxThreads();
        return @min(detected.packages[0].cores.len -| 1, max_threads);
    }

    pub fn start(self: *ThreadPool) StartError!void {
        if (self.state == .teardown) return error.AlreadyDeinitialized;
        if (self.state == .steady) {
            try self.requireStableAddress();
            return;
        }
        self.address = @intFromPtr(self);
        if (self.capacity.threads == 0) {
            self.state = .steady;
            return;
        }
        var spawned: usize = 0;
        while (spawned < self.capacity.threads) : (spawned += 1) {
            self.handles[spawned] = sys.thread.spawn(workerMain, .{
                WorkerContext{
                    .pool = self,
                    .worker_index = spawned + 1,
                },
            }) catch |err| {
                self.stopSpawned(spawned);
                return err;
            };
            nameWorker(self.handles[spawned], spawned);
        }
        self.synchronization.lock();
        while (self.started_threads != self.capacity.threads) {
            self.done.wait(&self.synchronization);
        }
        self.synchronization.unlock();
        self.state = .steady;
    }

    pub fn deinit(self: *ThreadPool) void {
        if (self.state == .teardown) return;
        if (self.state == .initialization) {
            self.state = .teardown;
            self.address = 0;
            return;
        }
        self.requireStableAddress() catch unreachable;
        std.debug.assert(!self.busy.load(.acquire));
        if (self.capacity.threads != 0) {
            self.signalExit();
            for (self.handles[0..self.capacity.threads]) |handle| {
                handle.join();
            }
        }
        self.state = .teardown;
        self.address = 0;
    }

    pub fn numWorkers(self: *const ThreadPool) usize {
        return self.capacity.workers;
    }

    pub fn wasClamped(self: *const ThreadPool) bool {
        return self.capacity.wasClamped();
    }

    pub fn setWaitMode(
        self: *ThreadPool,
        mode: PoolWaitMode,
    ) (error{Busy} || StartError)!void {
        if (self.state == .teardown) return error.AlreadyDeinitialized;
        if (self.busy.cmpxchgStrong(
            false,
            true,
            .acquire,
            .monotonic,
        ) != null) return error.Busy;
        defer self.busy.store(false, .release);
        self.wait_mode.store(@backingInt(mode), .release);
        const mode_tuner = self.tuner(mode);
        const selected = mode_tuner.best() orelse mode_tuner.nextConfig();
        self.config_bits.store(selected.encode(), .release);
        if (self.state == .steady and self.capacity.threads != 0) {
            try self.requireStableAddress();
            const epoch = self.wakeWorkers(false, true);
            self.waitForWorkers(epoch);
        }
    }

    pub fn waitMode(self: *const ThreadPool) PoolWaitMode {
        return @fromBackingInt(@intCast(self.wait_mode.load(.acquire)));
    }

    pub fn config(self: *const ThreadPool) Config {
        return Config.decode(self.config_bits.load(.acquire));
    }

    pub fn autoTuneComplete(self: *const ThreadPool) bool {
        return self.tunerConst(self.waitMode()).best() != null;
    }

    pub fn autoTuneCosts(self: *ThreadPool) []autotune.CostDistribution {
        return self.tuner(self.waitMode()).costs();
    }

    pub fn statsSnapshot(self: *ThreadPool) PoolStats {
        self.synchronization.lock();
        defer self.synchronization.unlock();
        return self.stats;
    }

    pub fn callerStats(
        self: *ThreadPool,
        caller: Caller,
    ) ?CallerStats {
        if (caller.index >= max_callers) return null;
        self.synchronization.lock();
        defer self.synchronization.unlock();
        return self.caller_stats[caller.index];
    }

    pub fn resetStats(self: *ThreadPool) error{Busy}!void {
        if (self.busy.cmpxchgStrong(
            false,
            true,
            .acquire,
            .monotonic,
        ) != null) return error.Busy;
        defer self.busy.store(false, .release);
        self.synchronization.lock();
        defer self.synchronization.unlock();
        self.stats = .{};
        self.caller_stats = @splat(.{});
    }

    pub fn globalWorkerIndex(
        self: *const ThreadPool,
        local_worker_index: usize,
    ) error{WorkerOutOfBounds}!usize {
        if (local_worker_index >= self.numWorkers()) {
            return error.WorkerOutOfBounds;
        }
        return self.mapping.globalIndex(local_worker_index);
    }

    pub fn run(
        self: *ThreadPool,
        begin: u64,
        end: u64,
        context: anytype,
        comptime body: fn (@TypeOf(context), u64, usize) void,
    ) RunError!void {
        return self.runWithCaller(begin, end, .{}, context, body);
    }

    pub fn runWithCaller(
        self: *ThreadPool,
        begin: u64,
        end: u64,
        caller: Caller,
        context: anytype,
        comptime body: fn (@TypeOf(context), u64, usize) void,
    ) RunError!void {
        if (begin > end) return error.InvalidRange;
        const task_count_u64 = end - begin;
        if (task_count_u64 > std.math.maxInt(usize)) {
            return error.TooManyTasks;
        }
        const task_count: usize = @intCast(task_count_u64);
        const Context = @TypeOf(context);
        const Adapter = CallbackAdapter(Context, body);
        var context_storage = context;
        const started_ns = nowNanoseconds();
        if (task_count <= 1 or self.numWorkers() == 1) {
            var task = begin;
            while (task < end) : (task += 1) body(context, task, 0);
            self.recordRun(
                caller,
                task_count,
                false,
                0,
                elapsedNanoseconds(started_ns),
            );
            return;
        }
        if (self.busy.cmpxchgStrong(
            false,
            true,
            .acquire,
            .monotonic,
        ) != null) return error.Busy;
        defer self.busy.store(false, .release);
        try self.start();
        try self.requireStableAddress();
        self.task_context = @ptrCast(&context_storage);
        self.task_callback = Adapter.call;
        self.current_begin = begin;
        self.current_tasks = task_count;
        self.divideRange(begin, end);
        for (self.workers[0..self.numWorkers()]) |*worker| {
            worker.last_tasks = 0;
            worker.last_stolen = 0;
        }
        const epoch = self.wakeWorkers(
            true,
            self.config().wait_type == .block,
        );
        self.runWorker(0);
        self.waitForWorkers(epoch);
        var stolen_tasks: usize = 0;
        for (self.workers[0..self.numWorkers()]) |worker| {
            stolen_tasks += worker.last_stolen;
        }
        const elapsed_ns = elapsedNanoseconds(started_ns);
        self.recordRun(
            caller,
            task_count,
            true,
            stolen_tasks,
            elapsed_ns,
        );
        self.notifyAutotune(elapsed_ns);
    }

    fn configureWorkers(self: *ThreadPool) void {
        const worker_count: u32 = self.capacity.workers;
        for (self.workers[0..worker_count], 0..) |*worker, worker_index| {
            worker.* = .{};
            worker.victim_count = @intCast(@min(max_victims, worker_count));
            const coprime = ShuffledIota.findAnotherCoprime(
                worker_count,
                @intCast((worker_index + 1) * 257 + worker_index * 13),
            );
            const shuffled = ShuffledIota.init(coprime);
            worker.victims[0] = @intCast(worker_index);
            for (1..worker.victim_count) |victim_index| {
                worker.victims[victim_index] = @intCast(shuffled.next(
                    worker.victims[victim_index - 1],
                    worker_count,
                ));
            }
        }
    }

    fn divideRange(self: *ThreadPool, begin: u64, end: u64) void {
        for (self.workers[0..self.numWorkers()], 0..) |*worker, index| {
            const range = workerRange(
                0,
                end - begin,
                self.numWorkers(),
                index,
            ) catch unreachable;
            worker.begin.store(@intCast(range.begin), .monotonic);
            worker.end = @intCast(range.end);
        }
    }

    fn runWorker(self: *ThreadPool, worker_index: usize) void {
        var task_count: usize = 0;
        var stolen_count: usize = 0;
        if (self.current_tasks <= self.numWorkers()) {
            const offset = self.workers[0].begin.load(.monotonic) +
                worker_index;
            const end = self.workers[self.numWorkers() - 1].end;
            if (offset < end) {
                self.task_callback(
                    self.task_context,
                    self.current_begin + offset,
                    worker_index,
                );
                task_count = 1;
            }
        } else {
            const worker = &self.workers[worker_index];
            for (worker.victims[0..worker.victim_count]) |victim_index| {
                const victim = &self.workers[victim_index];
                while (true) {
                    const offset = victim.begin.fetchAdd(1, .monotonic);
                    if (offset >= victim.end) break;
                    self.task_callback(
                        self.task_context,
                        self.current_begin + offset,
                        worker_index,
                    );
                    task_count += 1;
                    stolen_count += @intFromBool(victim_index != worker_index);
                }
            }
        }
        self.workers[worker_index].last_tasks = task_count;
        self.workers[worker_index].last_stolen = stolen_count;
    }

    fn wakeWorkers(
        self: *ThreadPool,
        work_available: bool,
        wake_blocked: bool,
    ) u32 {
        self.work_available.store(work_available, .monotonic);
        const epoch = self.epoch.load(.monotonic) +% 1;
        self.epoch.store(epoch, .release);
        for (self.workers[1..self.numWorkers()]) |*worker| {
            worker.wait_epoch.store(epoch, .release);
        }
        if (wake_blocked and self.capacity.threads != 0) {
            wait.wakeAll(&self.workers[1].wait_epoch);
        }
        return epoch;
    }

    fn waitForWorkers(self: *ThreadPool, epoch: u32) void {
        spin.callWithSpin(
            self.config().spin_type,
            BarrierContext{ .pool = self, .epoch = epoch },
            waitAtBarrier,
        );
    }

    fn waitForWork(
        self: *ThreadPool,
        worker_index: usize,
        observed_epoch: u32,
    ) ?u32 {
        while (true) {
            if (self.exiting.load(.acquire)) return null;
            const config_value = self.config();
            switch (config_value.wait_type) {
                .block => {
                    const next_epoch = wait.blockUntilDifferent(
                        observed_epoch,
                        &self.workers[1].wait_epoch,
                    );
                    if (self.exiting.load(.acquire)) return null;
                    return next_epoch;
                },
                .spin_shared, .spin_separate => {
                    const watched = if (config_value.wait_type ==
                        .spin_separate)
                        &self.workers[worker_index].wait_epoch
                    else
                        &self.epoch;
                    var next_epoch: u32 = observed_epoch;
                    spin.callWithSpin(
                        config_value.spin_type,
                        SpinWaitContext{
                            .previous = observed_epoch,
                            .watched = watched,
                            .next = &next_epoch,
                        },
                        waitUntilDifferent,
                    );
                    if (self.exiting.load(.acquire)) return null;
                    return next_epoch;
                },
            }
        }
    }

    fn workerStarted(self: *ThreadPool) void {
        self.synchronization.lock();
        self.started_threads += 1;
        self.done.broadcast();
        self.synchronization.unlock();
    }

    fn workerReached(self: *ThreadPool, worker_index: usize, epoch: u32) void {
        self.workers[worker_index].barrier_epoch.store(epoch, .release);
    }

    fn stopSpawned(self: *ThreadPool, spawned: usize) void {
        self.signalExit();
        for (self.handles[0..spawned]) |handle| handle.join();
        self.exiting.store(false, .monotonic);
        self.epoch.store(0, .monotonic);
        self.started_threads = 0;
        self.address = 0;
        self.work_available.store(false, .monotonic);
        self.configureWorkers();
    }

    fn signalExit(self: *ThreadPool) void {
        self.exiting.store(true, .release);
        const epoch = self.epoch.load(.monotonic) +% 1;
        self.epoch.store(epoch, .release);
        for (self.workers[1..self.numWorkers()]) |*worker| {
            worker.wait_epoch.store(epoch, .release);
        }
        if (self.capacity.threads != 0) {
            wait.wakeAll(&self.workers[1].wait_epoch);
        }
    }

    fn requireStableAddress(self: *const ThreadPool) error{PoolMoved}!void {
        if (self.address != @intFromPtr(self)) return error.PoolMoved;
    }

    fn recordRun(
        self: *ThreadPool,
        caller: Caller,
        tasks: usize,
        threaded: bool,
        stolen_tasks: usize,
        elapsed_ns: u64,
    ) void {
        self.synchronization.lock();
        defer self.synchronization.unlock();
        self.stats.runs +|= 1;
        self.stats.serial_runs +|= @intFromBool(!threaded);
        self.stats.threaded_runs +|= @intFromBool(threaded);
        self.stats.tasks +|= tasks;
        self.stats.stolen_tasks +|= stolen_tasks;
        self.stats.elapsed_ns +|= elapsed_ns;
        const caller_index = if (caller.index < max_callers)
            caller.index
        else
            0;
        const stats = &self.caller_stats[caller_index];
        stats.runs +|= 1;
        stats.tasks +|= tasks;
        stats.workers +|= if (threaded) self.numWorkers() else 1;
        stats.elapsed_ns +|= elapsed_ns;
    }

    fn notifyAutotune(self: *ThreadPool, elapsed_ns: u64) void {
        const mode = self.waitMode();
        const selected = blk: {
            const tuner_value = self.tuner(mode);
            if (tuner_value.best()) |best| break :blk best.*;
            tuner_value.notifyCost(@max(elapsed_ns, 1));
            break :blk if (tuner_value.best()) |best|
                best.*
            else
                tuner_value.nextConfig().*;
        };
        self.config_bits.store(selected.encode(), .release);
    }

    fn tuner(self: *ThreadPool, mode: PoolWaitMode) *AutoTuner {
        return switch (mode) {
            .block => &self.block_tuner,
            .spin => &self.spin_tuner,
        };
    }

    fn tunerConst(self: *const ThreadPool, mode: PoolWaitMode) *const AutoTuner {
        return switch (mode) {
            .block => &self.block_tuner,
            .spin => &self.spin_tuner,
        };
    }
};

const WorkerContext = struct {
    pool: *ThreadPool,
    worker_index: usize,
};

const SpinWaitContext = struct {
    previous: u32,
    watched: *const std.atomic.Value(u32),
    next: *u32,
};

fn waitUntilDifferent(context: SpinWaitContext, policy: anytype) void {
    context.next.* = policy.untilDifferent(
        context.previous,
        context.watched,
    ).value;
}

const BarrierContext = struct {
    pool: *ThreadPool,
    epoch: u32,
};

fn waitAtBarrier(context: BarrierContext, policy: anytype) void {
    for (context.pool.workers[1..context.pool.numWorkers()]) |*worker| {
        _ = policy.untilEqual(context.epoch, &worker.barrier_epoch);
    }
}

fn workerMain(context: WorkerContext) void {
    const pool = context.pool;
    pool.workerStarted();
    var observed_epoch: u32 = 0;
    while (pool.waitForWork(context.worker_index, observed_epoch)) |epoch| {
        if (pool.work_available.load(.acquire)) {
            pool.runWorker(context.worker_index);
        }
        pool.workerReached(context.worker_index, epoch);
        observed_epoch = epoch;
    }
}

fn nameWorker(handle: sys.thread.JoinHandle, index: usize) void {
    if (comptime std.Thread.max_name_len < 9) return;
    var storage: [std.Thread.max_name_len]u8 = undefined;
    const name_value = std.fmt.bufPrint(
        &storage,
        "worker{d:0>3}",
        .{index},
    ) catch return;
    handle.setName(name_value) catch {};
}

fn CallbackAdapter(
    comptime Context: type,
    comptime body: fn (Context, u64, usize) void,
) type {
    return struct {
        fn call(
            opaque_context: *anyopaque,
            task: u64,
            worker: usize,
        ) void {
            const context: *Context = @ptrCast(@alignCast(opaque_context));
            body(context.*, task, worker);
        }
    };
}

fn nowNanoseconds() u64 {
    return @intCast(@max(sys.time.nanoTimestamp(), 0));
}

fn elapsedNanoseconds(started: u64) u64 {
    return nowNanoseconds() -| started;
}

const HitContext = struct {
    begin: u64,
    hits: []std.atomic.Value(u32),
    worker_bits: *std.atomic.Value(usize),
};

fn recordHit(context: *HitContext, task: u64, worker: usize) void {
    _ = context.hits[@intCast(task - context.begin)].fetchAdd(1, .monotonic);
    _ = context.worker_bits.fetchOr(
        @as(usize, 1) << @intCast(worker),
        .monotonic,
    );
}

const AssignmentContext = struct {
    expected_tasks: usize,
    expected_workers: usize,
    calls: *std.atomic.Value(usize),
    worker_bits: *std.atomic.Value(usize),
};

fn recordAssignment(
    context: *AssignmentContext,
    task: u64,
    worker: usize,
) void {
    std.debug.assert(task < context.expected_tasks);
    std.debug.assert(worker < context.expected_workers);
    _ = context.calls.fetchAdd(1, .monotonic);
    _ = context.worker_bits.fetchOr(
        @as(usize, 1) << @intCast(worker),
        .monotonic,
    );
}

const SumContext = struct {
    counters: []std.atomic.Value(usize),
};

fn addTask(context: *SumContext, task: u64, worker: usize) void {
    _ = context.counters[worker].fetchAdd(@intCast(task), .monotonic);
}

const NestedContext = struct {
    begin: u64,
    end: u64,
    hits: []std.atomic.Value(u32),
    inner_calls: *std.atomic.Value(usize),
};

fn innerTask(context: *NestedContext, task: u64, worker: usize) void {
    std.debug.assert(worker == 0);
    std.debug.assert(context.begin <= task);
    std.debug.assert(task < context.end);
    _ = context.inner_calls.fetchAdd(1, .monotonic);
}

fn outerTask(context: *NestedContext, task: u64, _: usize) void {
    std.debug.assert(context.begin <= task);
    std.debug.assert(task < context.end);
    _ = context.hits[@intCast(task - context.begin)].fetchAdd(1, .monotonic);
    var inner = ThreadPool.init(0, .{});
    defer inner.deinit();
    inner.run(context.begin, context.end, context, innerTask) catch unreachable;
}

fn emptyTask(_: void, _: u64, _: usize) void {}
