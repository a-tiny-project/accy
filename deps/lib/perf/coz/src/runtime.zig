const std = @import("std");
const sys = @import("sys");

const abi = @import("abi.zig");
const debug_info = @import("debug.zig");
const delay = @import("delay.zig");
const experiment = @import("experiment.zig");
const profile = @import("profile.zig");
const profiler = @import("profiler.zig");
const sampler = @import("sampler.zig");
const signals = @import("signals.zig");
const source_map = @import("map.zig");
const thread = @import("thread.zig");

const perf = sys.perf;
const timer = sys.timer;

const CounterKind = abi.CounterKind;
const Counter = abi.Counter;
const ExperimentStepOptions = profiler.ExperimentStepOptions;
const ExperimentStepResult = profiler.ExperimentStepResult;
const Profiler = profiler.Profiler;

const ActiveProfiler = struct {
    allocator: std.mem.Allocator,
    instance: *Profiler,
};

pub const RuntimeOptions = struct {
    sampler_options: sampler.Options = .{},
    install_signal_handler: bool = true,
    start_current_thread: bool = true,
    profile_writer: ?*std.Io.Writer = null,
    start_experiment_worker: bool = false,
    experiment_step_options: ExperimentStepOptions = .{},
    experiment_duration_ns: ?u64 = null,
    source_scope: debug_info.Scope = .{},
    resolve_sample_locations: bool = false,
};

pub const Runtime = struct {
    allocator: ?std.mem.Allocator = null,
    profiler: Profiler = .{},
    profile_writer: ?*std.Io.Writer = null,
    profile_writer_mutex: sys.thread.Mutex = .{},
    source_scope: debug_info.Scope = .{},
    resolve_sample_locations: bool = false,
    runtime_start_ns: u64 = 0,
    sampling_handler: ?signals.Installed = null,
    sample_thread: ?*thread.Thread = null,
    experiment_worker: ?sys.thread.JoinHandle = null,
    experiment_worker_running: std.atomic.Value(bool) = .init(false),
    experiment_worker_error: ?anyerror = null,
    experiment_worker_options: ExperimentStepOptions = .{},
    profiler_installed: bool = false,
    current_thread_started: bool = false,

    pub fn start(self: *Runtime, allocator: std.mem.Allocator, options: RuntimeOptions) !void {
        if (self.profiler_installed) return error.RuntimeAlreadyStarted;

        self.allocator = allocator;
        self.runtime_start_ns = timestampNs();
        errdefer self.shutdown();

        installProfiler(allocator, &self.profiler);
        self.profiler_installed = true;

        if (options.install_signal_handler) {
            self.sampling_handler = installSamplingHandler();
        }

        if (options.start_current_thread) {
            current_thread = try thread.Thread.openAndStartCurrent(options.sampler_options);
            self.sample_thread = &current_thread;
            self.current_thread_started = true;
        }

        self.source_scope = options.source_scope;
        self.resolve_sample_locations = options.resolve_sample_locations;
        if (options.experiment_duration_ns) |duration_ns| {
            self.profiler.experiment_duration_ns = duration_ns;
        }

        if (options.profile_writer) |writer| {
            try self.profiler.writeStartup(writer, self.runtime_start_ns);
            self.profile_writer = writer;
        }

        if (options.start_experiment_worker) {
            if (self.profile_writer == null) return error.ProfileWriterUnavailable;
            try self.startExperimentWorker(options.experiment_step_options);
        }
    }

    pub fn startIfAvailable(self: *Runtime, allocator: std.mem.Allocator, options: RuntimeOptions) !bool {
        self.start(allocator, options) catch |err| {
            if (runtimeUnavailable(err)) return false;
            return err;
        };
        return true;
    }

    pub fn runExperimentStep(self: *Runtime, options: ExperimentStepOptions) !ExperimentStepResult {
        return self.runExperimentStepWithWait(options, waitNs, true);
    }

    fn runExperimentStepWithWait(
        self: *Runtime,
        options: ExperimentStepOptions,
        wait_fn: sampler.WaitFn,
        drain_current_thread: bool,
    ) !ExperimentStepResult {
        const allocator = self.allocator orelse return error.RuntimeNotStarted;
        const writer = self.profile_writer orelse return error.ProfileWriterUnavailable;

        if (drain_current_thread and self.current_thread_started) {
            _ = try current_thread.processDefault(&self.profiler, waitNs);
        }

        self.profile_writer_mutex.lock();
        defer self.profile_writer_mutex.unlock();

        const result = try self.profiler.runExperimentStep(allocator, writer, options, wait_fn);
        if (result.emitted) try writer.flush();
        return result;
    }

    pub fn stop(self: *Runtime) !void {
        var first_error: ?anyerror = null;
        var loss_counter: profile.LossCounter = .unsupported;
        var terminal_status: profile.TerminalStatus = .not_started;

        self.stopExperimentWorker() catch |err| rememberRuntimeError(&first_error, err);

        if (self.current_thread_started) {
            var stopped = true;
            current_thread.sampler.stop() catch |err| {
                stopped = false;
                rememberRuntimeError(&first_error, err);
            };
            var drained = true;
            _ = current_thread.drainDefault(&self.profiler) catch |err| failed: {
                drained = false;
                rememberRuntimeError(&first_error, err);
                break :failed 0;
            };
            terminal_status = if (!drained)
                .drain_failed
            else if (!stopped)
                .stop_failed
            else
                .complete;
            loss_counter = profileLossCounter(current_thread.sampler.readLossCounter());
            current_thread.close();
            current_thread = .{};
            self.sample_thread = null;
            self.current_thread_started = false;
        }

        if (self.sampling_handler) |*handler| {
            handler.restore();
            self.sampling_handler = null;
        }

        if (self.profiler_installed) {
            uninstallProfiler(&self.profiler);
            self.profiler_installed = false;
        }

        if (self.profile_writer) |writer| {
            if (self.allocator) |allocator| {
                self.profile_writer_mutex.lock();
                defer self.profile_writer_mutex.unlock();
                self.profiler.writeRuntimeAndSamples(
                    allocator,
                    writer,
                    elapsedSinceNs(self.runtime_start_ns),
                    loss_counter,
                    terminal_status,
                ) catch |err| rememberRuntimeError(&first_error, err);
                writer.flush() catch |err| rememberRuntimeError(&first_error, err);
            }
            self.profile_writer = null;
        }

        if (self.allocator) |allocator| {
            self.profiler.deinit(allocator);
            self.allocator = null;
        }

        self.runtime_start_ns = 0;
        self.source_scope = .{};
        self.resolve_sample_locations = false;

        if (first_error) |err| return err;
    }

    pub fn shutdown(self: *Runtime) void {
        self.stop() catch {};
    }

    fn startExperimentWorker(self: *Runtime, options: ExperimentStepOptions) !void {
        if (self.experiment_worker != null) return error.ExperimentWorkerAlreadyStarted;

        self.experiment_worker_options = options;
        self.experiment_worker_error = null;
        self.experiment_worker_running.store(true, .release);
        errdefer self.experiment_worker_running.store(false, .release);
        self.experiment_worker = try sys.thread.spawn(experimentWorkerMain, .{self});
    }

    fn stopExperimentWorker(self: *Runtime) !void {
        if (self.experiment_worker) |worker| {
            self.experiment_worker_running.store(false, .release);
            worker.join();
            self.experiment_worker = null;
        } else {
            self.experiment_worker_running.store(false, .release);
        }

        if (self.experiment_worker_error) |err| {
            self.experiment_worker_error = null;
            return err;
        }
    }

    fn runExperimentWorkerStepWithWait(
        self: *Runtime,
        prng: *std.Random.DefaultPrng,
        wait_fn: sampler.WaitFn,
    ) !ExperimentStepResult {
        var options = self.experiment_worker_options;
        options.running = &self.experiment_worker_running;
        if (options.fixed_speedup_percent == null) {
            const draw_value = prng.random().intRangeAtMost(u64, 0, experiment.Draw.maxDraw());
            options.draw = try experiment.Draw.init(draw_value);
        }
        return self.runExperimentStepWithWait(options, wait_fn, false);
    }

    fn drainSampleThread(self: *Runtime) !usize {
        if (!self.resolve_sample_locations) return 0;
        const allocator = self.allocator orelse return 0;
        const sample_thread = self.sample_thread orelse return 0;
        return sample_thread.drainResolvedDefault(&self.profiler, allocator, self.source_scope);
    }
};

pub fn runtimeUnavailable(err: anyerror) bool {
    return sampler.unavailable(err);
}

pub fn profilerPresent() bool {
    return activeProfilerPresent();
}

pub fn installSamplingHandler() signals.Installed {
    return signals.installSampleHandler(sampleSignalHandler);
}

pub fn installProfiler(allocator: std.mem.Allocator, instance: *Profiler) void {
    active_profiler_mutex.lock();
    defer active_profiler_mutex.unlock();
    active_profiler = .{
        .allocator = allocator,
        .instance = instance,
    };
    _ = active_profiler_generation.fetchAdd(1, .release);
    active_profiler_signal.store(@intFromPtr(instance), .release);
}

pub fn uninstallProfiler(instance: *Profiler) void {
    active_profiler_mutex.lock();
    defer active_profiler_mutex.unlock();
    if (active_profiler) |active| {
        if (active.instance == instance) {
            active_profiler_signal.store(0, .release);
            _ = active_profiler_generation.fetchAdd(1, .release);
            active_profiler = null;
        }
    }
}

pub inline fn progress(comptime src: std.builtin.SourceLocation) void {
    progressNamed(std.fmt.comptimePrint("{s}:{d}", .{ src.file, src.line }));
}

pub inline fn progressNamed(comptime name: []const u8) void {
    increment(.throughput, name);
}

pub inline fn begin(comptime name: []const u8) void {
    increment(.begin, name);
}

pub inline fn end(comptime name: []const u8) void {
    increment(.end, name);
}

pub fn Scope(comptime name: []const u8) type {
    return struct {
        pub inline fn init() @This() {
            begin(name);
            return .{};
        }

        pub inline fn end(_: @This()) void {
            module.end(name);
        }
    };
}

pub inline fn scope(comptime name: []const u8) Scope(name) {
    return Scope(name).init();
}

pub inline fn preBlock() void {
    _ = activePreBlock();
}

pub inline fn catchUp() void {
    _ = activeCatchUp();
}

pub inline fn postBlock(skip_delays: bool) void {
    _ = activePostBlock(skip_delays);
}

const module = @This();

inline fn increment(comptime kind: CounterKind, comptime name: []const u8) void {
    if (counterFor(kind, name)) |counter| {
        _ = @atomicRmw(usize, &counter.count, .Add, 1, .monotonic);
        checkDelaysAtProgressPoint();
    }
}

fn counterFor(comptime kind: CounterKind, comptime name: []const u8) ?*Counter {
    comptime validateName(name);

    return activeCounter(kind, name);
}

/// The counter one marker resolved for one installed profiler, keyed by the
/// marker's kind and name. A slot whose generation equals
/// `active_profiler_generation` holds a counter of the installed profiler, so
/// after its first event under a profiler a marker finds its counter with
/// three loads and no lock or hash. Generation zero marks a marker that has
/// not resolved.
const CounterSlot = struct {
    kind: CounterKind,
    name: []const u8,
    generation: std.atomic.Value(u64) = .init(0),
    counter: std.atomic.Value(?*Counter) = .init(null),
};

/// Returns the slot of one (kind, name) marker. The storage type captures the
/// key, so each pair gets its own slot and every site of one pair shares it.
fn counterSlot(comptime kind: CounterKind, comptime name: []const u8) *CounterSlot {
    const Storage = struct {
        var slot: CounterSlot = .{ .kind = kind, .name = name };
    };
    return &Storage.slot;
}

fn activeCounter(comptime kind: CounterKind, comptime name: []const u8) ?*Counter {
    if (active_profiler_signal.load(.acquire) == 0) return null;
    const slot = counterSlot(kind, name);
    const generation = active_profiler_generation.load(.acquire);
    if (slot.generation.load(.acquire) == generation) return slot.counter.load(.monotonic);
    return resolveCounter(slot);
}

/// Resolves a marker's counter in the installed profiler's registry and
/// records it in the marker's slot, counter first and generation last. Every
/// marker shares this path, so a marker site compiles to its slot check.
/// Install and uninstall change the generation under the same lock, so the
/// recorded generation is the one the counter belongs to.
fn resolveCounter(slot: *CounterSlot) ?*Counter {
    active_profiler_mutex.lock();
    defer active_profiler_mutex.unlock();

    const active = active_profiler orelse return null;
    const instance = active.instance;
    const resolved = instance.getCounter(active.allocator, slot.kind, slot.name) catch return null;
    slot.counter.store(resolved, .monotonic);
    slot.generation.store(active_profiler_generation.load(.monotonic), .release);
    return resolved;
}

fn activeProfilerPresent() bool {
    if (active_profiler_signal.load(.acquire) == 0) return false;
    active_profiler_mutex.lock();
    defer active_profiler_mutex.unlock();
    return active_profiler != null;
}

fn activePreBlock() bool {
    const instance = activeProfilerInstance() orelse return false;
    instance.preBlock(&current_thread.delay_state);
    return true;
}

fn activeCatchUp() bool {
    const instance = activeProfilerInstance() orelse return false;
    _ = instance.catchUp(&current_thread.delay_state, waitNs);
    return true;
}

fn activePostBlock(skip_delays: bool) bool {
    const instance = activeProfilerInstance() orelse return false;
    instance.postBlock(&current_thread.delay_state, skip_delays);
    return true;
}

fn activeProfilerInstance() ?*Profiler {
    if (active_profiler_signal.load(.acquire) == 0) return null;
    active_profiler_mutex.lock();
    defer active_profiler_mutex.unlock();
    const active = active_profiler orelse return null;
    return active.instance;
}

fn activeProfilerForSignal() ?*Profiler {
    const address = active_profiler_signal.load(.acquire);
    if (address == 0) return null;
    return @ptrFromInt(address);
}

fn sampleSignalHandler(_: signals.Signal, _: *const signals.SignalInfo, _: ?*anyopaque) callconv(.c) void {
    const instance = activeProfilerForSignal() orelse return;
    _ = current_thread.processDefault(instance, waitNs) catch {};
}

fn validateName(comptime name: []const u8) void {
    if (std.mem.indexOfScalar(u8, name, 0) != null) {
        @compileError("coz progress point names must not contain NUL bytes");
    }
}

/// Applies pending delays at a marker. The installed profiler is read without
/// the lock, as the sampling signal handler reads it: `activeProfilerInstance`
/// returns the instance after unlocking, so the lock gave the call no
/// lifetime guarantee.
inline fn checkDelaysAtProgressPoint() void {
    const instance = activeProfilerForSignal() orelse return;
    _ = instance.catchUp(&current_thread.delay_state, waitNs);
}

fn waitNs(ns: u64) u64 {
    const start = sys.time.nanoTimestamp();
    sys.time.sleepNanoseconds(ns);
    const finish = sys.time.nanoTimestamp();
    if (finish <= start) return 0;
    const elapsed = finish - start;
    if (elapsed > std.math.maxInt(u64)) return std.math.maxInt(u64);
    return @intCast(elapsed);
}

fn timestampNs() u64 {
    const now = sys.time.nanoTimestamp();
    if (now <= 0) return 0;
    if (now > std.math.maxInt(u64)) return std.math.maxInt(u64);
    return @intCast(now);
}

fn elapsedSinceNs(start_ns: u64) u64 {
    return timestampNs() -| start_ns;
}

fn rememberRuntimeError(first_error: *?anyerror, err: anyerror) void {
    if (first_error.* == null) first_error.* = err;
}

fn profileLossCounter(counter: sampler.LossCounter) profile.LossCounter {
    return switch (counter) {
        .available => |value| .{ .available = value },
        .unsupported => .unsupported,
        .read_failed => .read_failed,
    };
}

fn experimentWorkerMain(runtime: *Runtime) void {
    experiment_worker_runtime = runtime;
    defer experiment_worker_runtime = null;

    var prng = std.Random.DefaultPrng.init(experimentWorkerSeed(runtime));
    while (runtime.experiment_worker_running.load(.acquire)) {
        _ = runtime.drainSampleThread() catch |err| {
            runtime.experiment_worker_error = err;
            runtime.experiment_worker_running.store(false, .release);
            break;
        };
        _ = runtime.runExperimentWorkerStepWithWait(&prng, experimentWorkerWait) catch |err| {
            runtime.experiment_worker_error = err;
            runtime.experiment_worker_running.store(false, .release);
            break;
        };
        _ = waitWhileRunning(&runtime.experiment_worker_running, experiment.experiment_cool_off_time_ns, experimentWorkerWait);
    }
}

fn experimentWorkerWait(ns: u64) u64 {
    const elapsed_ns = waitNs(ns);
    if (experiment_worker_runtime) |runtime| {
        _ = runtime.drainSampleThread() catch |err| {
            runtime.experiment_worker_error = err;
            runtime.experiment_worker_running.store(false, .release);
        };
    }
    return elapsed_ns;
}

fn waitWhileRunning(running: *std.atomic.Value(bool), duration_ns: u64, wait_fn: sampler.WaitFn) u64 {
    var elapsed_ns: u64 = 0;
    while (elapsed_ns < duration_ns and running.load(.acquire)) {
        const remaining_ns = duration_ns - elapsed_ns;
        const interval_ns = @min(remaining_ns, experiment.experiment_cool_off_time_ns);
        const waited_ns = wait_fn(interval_ns);
        elapsed_ns +|= if (waited_ns == 0 and interval_ns != 0) interval_ns else waited_ns;
    }
    return elapsed_ns;
}

fn experimentWorkerSeed(self: *Runtime) u64 {
    const address_seed: u64 = @truncate(@intFromPtr(self));
    const seed = timestampNs() ^ address_seed;
    return if (seed == 0) 1 else seed;
}

var active_profiler_mutex: sys.thread.Mutex = .{};
var active_profiler: ?ActiveProfiler = null;
var active_profiler_signal: std.atomic.Value(usize) = .init(0);
/// Counts installs and uninstalls, starting above the zero that marks an
/// unresolved counter slot. A profiler installed at a released profiler's
/// address still gets a new generation, so no slot resolves to the released
/// profiler's counters.
var active_profiler_generation: std.atomic.Value(u64) = .init(1);
threadlocal var current_thread: thread.Thread = .{};
threadlocal var experiment_worker_runtime: ?*Runtime = null;
var runtime_experiment_counter: ?*Counter = null;

fn runtimeProgressWait(ns: u64) u64 {
    if (runtime_experiment_counter) |counter| {
        _ = @atomicRmw(usize, &counter.count, .Add, 6, .monotonic);
    }
    return ns;
}
