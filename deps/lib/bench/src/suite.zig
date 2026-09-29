const std = @import("std");
const coz = @import("coz");
const memtrace = @import("memtrace");
const pretty = @import("pretty");
const pretty_json = pretty.json;
const stabilizer = @import("stabilizer");
const sys = @import("sys");
const tracy = @import("tracy");

const allocation = @import("allocation.zig");
const evidence = @import("evidence.zig");
const event = @import("event.zig");
const instrumentation = @import("instrumentation.zig");
const metadata_mod = @import("metadata.zig");
const output = @import("output.zig");
const stats = @import("stats/root.zig");
const timing = @import("timing.zig");

const Allocator = std.mem.Allocator;
const CountingAllocator = allocation.CountingAllocator;
const callWithStackPad = instrumentation.callWithStackPad;
const phaseAt = instrumentation.phaseAt;
const nowNs = timing.nowNs;
const saturatingI64 = timing.saturatingI64;
const jsonl_output_env = "BENCH_JSONL";
const coz_output_env = "BENCH_COZ_JSONL";
const coz_analysis_env = "BENCH_COZ_ANALYSIS_JSON";
const coz_experiments_env = "BENCH_COZ_EXPERIMENTS";
const tracy_output_env = "BENCH_TRACY_JSONL";
const tracy_summary_env = "BENCH_TRACY_SUMMARY_JSONL";
const min_time_env = "BENCH_MIN_TIME_NS";
const filter_env = "BENCH_FILTER";
const layout_env = "BENCH_LAYOUT";
const scoped_allocations_env = "TINY_PROFILE_ALLOCATIONS_PATH";
const metric_schema = "tiny.profiling.metric/v1";
const stretched_iteration_limit: u32 = 1_000_000;
const sample_batch_window_ns: u64 = 10 * std.time.ns_per_ms;
const zero_average_batch_size: u32 = 1000;
const automatic_eval_limit: u32 = 1_000_000;
const automatic_sample_time_limit_ns: u64 = 10 * std.time.ns_per_ms;
const max_calibration_steps: u32 = 21;
const max_calibration_batches: u32 = max_calibration_steps * 2;

pub const AutomaticEvaluation = struct {
    min_sample_time_ns: u64 = 100 * std.time.ns_per_us,
    max_sample_time_ns: u64 = automatic_sample_time_limit_ns,
    clock_resolution_multiple: u32 = 1000,
    max_evals: u32 = automatic_eval_limit,
};

pub const Evaluation = union(enum) {
    automatic: AutomaticEvaluation,
    fixed: u32,
};

pub const AutomaticSelection = struct {
    policy: AutomaticEvaluation,
    evals: u32,
    clock_target_ns: u64,
    target_ns: u64,
    target_capped: bool,
    calibration_batches: u32,
    calibration_confirmations: u32,
    calibration_evals: u64,
    calibration_ns: u64,
    calibration_last_ns: u64,
    calibration_target_reached: bool,
    samples_below_target: u32 = 0,
};

pub const EvaluationSelection = union(enum) {
    automatic: AutomaticSelection,
    fixed: u32,

    pub fn evalCount(self: EvaluationSelection) u32 {
        return switch (self) {
            .automatic => |selection| selection.evals,
            .fixed => |evals| evals,
        };
    }
};

pub const AllocationAttribution = enum {
    none,
    sample_call,
    prepare_owner,
};

pub const Config = struct {
    suite_name: []const u8 = "bench",

    min_time_ns: u64 = 5_000_000,

    max_iterations: u32 = 10_000,

    min_iterations: u32 = 1,

    evaluation: Evaluation = .{ .automatic = .{} },

    warmup_iterations: u32 = 0,

    prepare: ?PrepareFn = null,

    teardown: ?TeardownFn = null,

    allocation_attribution: AllocationAttribution = .none,

    layout_randomization: ?stabilizer.Config = .{
        .seed = stabilizer.default_seed,
        .heap = .{
            .pointer_validation = false,
            .shuffle_slots = 16,
            .max_shuffled_size = 16 * 1024,
        },
        .code = .{ .enabled = false },
    },
};

pub const RunOptions = struct {
    write_stdout: bool = true,
    write_env_jsonl: bool = true,
};

pub const Result = struct {
    name: []const u8,
    iterations: u32,
    evals: u32,
    evaluation: EvaluationSelection,
    clock_probe: timing.ClockProbe,
    samples: []const u64,
    sample_total_ns: []const u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: f64,
    median_ns: u64,
    stddev_ns: f64,
    p75_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    total_ns: u64,
    warmup_iterations: u32,
    confidence_intervals: ?stats.BootstrapConfidenceIntervals = null,
    allocation_attribution: AllocationAttribution,
    alloc_count: ?u64 = null,
    free_count: ?u64 = null,
    alloc_bytes: ?u64 = null,
    alloc_count_per_eval: ?u64 = null,
    free_count_per_eval: ?u64 = null,
    alloc_bytes_per_eval: ?u64 = null,
    layout_randomization: ?stabilizer.Config = null,
};

pub const BenchFn = *const fn (Allocator) void;
pub const PrepareFn = *const fn (Allocator) void;
pub const TeardownFn = *const fn () void;

pub const JsonlOptions = struct {
    suite_name: []const u8,
    output_path: []const u8 = "",
    metadata: ?metadata_mod.BuildMetadata = null,
};

const Definition = struct {
    name: []const u8,
    func: BenchFn,
    config: Config,
};

pub const Suite = struct {
    alloc: Allocator,
    default_config: Config,
    filter: ?[]const u8 = null,
    clock_probe: ?timing.ClockProbe = null,
    benchmarks: std.ArrayListUnmanaged(Definition) = .empty,
    results: std.ArrayListUnmanaged(Result) = .empty,

    pub fn init(alloc: Allocator, config: Config) Suite {
        return .{ .alloc = alloc, .default_config = config };
    }

    pub fn deinit(self: *Suite) void {
        for (self.results.items) |result| {
            self.alloc.free(result.samples);
            self.alloc.free(result.sample_total_ns);
        }
        self.results.deinit(self.alloc);
        self.benchmarks.deinit(self.alloc);
    }

    pub fn add(self: *Suite, name: []const u8, func: BenchFn, override: anytype) !void {
        try self.benchmarks.append(self.alloc, .{
            .name = name,
            .func = func,
            .config = applyConfigOverride(self.default_config, override),
        });
    }

    pub fn setFilter(self: *Suite, filter: ?[]const u8) void {
        self.filter = filter;
    }

    pub fn run(self: *Suite) !void {
        try self.runWithOptions(.{});
    }

    pub fn runWithOptions(self: *Suite, options: RunOptions) !void {
        const clock_probe = try timing.probeClock();
        self.clock_probe = clock_probe;
        var coz_env = try CozEnv.read(self.alloc);
        defer coz_env.deinit(self.alloc);
        var tracy_env = try TracyEnv.read(self.alloc);
        defer tracy_env.deinit(self.alloc);
        var control_env = try ControlEnv.read(self.alloc);
        defer control_env.deinit(self.alloc);
        var coz_session: instrumentation.CozSession = .{};
        try startCozSession(self.alloc, &coz_session, coz_env);
        defer coz_session.deinit();
        var tracy_session: instrumentation.ProfilingSession = .{};
        try startTracySession(self.alloc, &tracy_session, tracy_env, self.default_config.suite_name);
        defer tracy_session.deinit();
        var memtrace_session: MemtraceSession = .{};
        try memtrace_session.start(self.alloc);
        defer memtrace_session.deinit(self.alloc);
        var executed: usize = 0;

        tracy.setThreadName("tiny-bench");
        tracy.appInfo("tiny benchmark harness");
        {
            const suite_phase = phaseAt("bench.suite.run", @src());
            defer suite_phase.end();

            if (options.write_stdout) try output.writeHeader();

            for (self.benchmarks.items) |def| {
                if (!matchesFilter(def.name, self.filter)) continue;
                if (!matchesFilter(def.name, control_env.filter)) continue;
                const result = try runOne(
                    self.alloc,
                    memtrace_session.sampleAllocator(),
                    memtrace_session.tracerPtr(),
                    controlledDefinition(def, control_env),
                    clock_probe,
                );
                executed += 1;
                try self.results.append(self.alloc, result);
                if (options.write_stdout) try output.writeResult(result);
            }

            if (options.write_stdout) try output.writeStdoutDoc(pretty.hardline);
        }
        if (options.write_env_jsonl) try self.writeEnvJsonlFile();
        try finishInstrumentation(
            self.alloc,
            executed,
            &memtrace_session,
            &coz_session,
            coz_env,
            &tracy_session,
            tracy_env,
        );
    }

    pub fn runSilent(self: *Suite) ![]const Result {
        const clock_probe = try timing.probeClock();
        self.clock_probe = clock_probe;
        var coz_env = try CozEnv.read(self.alloc);
        defer coz_env.deinit(self.alloc);
        var tracy_env = try TracyEnv.read(self.alloc);
        defer tracy_env.deinit(self.alloc);
        var control_env = try ControlEnv.read(self.alloc);
        defer control_env.deinit(self.alloc);
        var coz_session: instrumentation.CozSession = .{};
        try startCozSession(self.alloc, &coz_session, coz_env);
        defer coz_session.deinit();
        var tracy_session: instrumentation.ProfilingSession = .{};
        try startTracySession(self.alloc, &tracy_session, tracy_env, self.default_config.suite_name);
        defer tracy_session.deinit();
        var memtrace_session: MemtraceSession = .{};
        try memtrace_session.start(self.alloc);
        defer memtrace_session.deinit(self.alloc);
        var executed: usize = 0;

        tracy.setThreadName("tiny-bench");
        tracy.appInfo("tiny benchmark harness");
        {
            const suite_phase = phaseAt("bench.suite.run_silent", @src());
            defer suite_phase.end();

            for (self.benchmarks.items) |def| {
                if (!matchesFilter(def.name, self.filter)) continue;
                if (!matchesFilter(def.name, control_env.filter)) continue;
                const result = try runOne(
                    self.alloc,
                    memtrace_session.sampleAllocator(),
                    memtrace_session.tracerPtr(),
                    controlledDefinition(def, control_env),
                    clock_probe,
                );
                executed += 1;
                try self.results.append(self.alloc, result);
            }
        }
        try finishInstrumentation(
            self.alloc,
            executed,
            &memtrace_session,
            &coz_session,
            coz_env,
            &tracy_session,
            tracy_env,
        );
        return self.results.items;
    }

    pub fn writeJsonl(self: *const Suite, writer: *std.Io.Writer, options: JsonlOptions) !void {
        try writeJsonlStart(self, writer, options);
        for (self.results.items) |result| try writeJsonlResult(writer, options, result);
        try event.writeRunEnd(writer, .{
            .benches = @intCast(self.results.items.len),
            .errors = 0,
        });
    }

    pub fn writeJsonlFile(self: *const Suite, path: []const u8, options: JsonlOptions) !void {
        try ensureParent(path);
        var file = try sys.fs.createFile(path, .{ .truncate = true });
        defer file.close(sys.fs.debugIo());

        var buffer: [8192]u8 = undefined;
        var writer = file.writer(sys.fs.debugIo(), &buffer);
        try self.writeJsonl(&writer.interface, withOutputPath(options, path));
        try writer.interface.flush();
    }

    pub fn appendJsonlFile(self: *const Suite, path: []const u8, options: JsonlOptions) !void {
        try ensureParent(path);
        var out = std.Io.Writer.Allocating.init(self.alloc);
        defer out.deinit();
        try self.writeJsonl(&out.writer, withOutputPath(options, path));
        try sys.fs.appendFile(path, &.{out.written()});
    }

    fn writeEnvJsonlFile(self: *const Suite) !void {
        const path = try sys.env.getOwned(self.alloc, jsonl_output_env);
        defer if (path) |actual| self.alloc.free(actual);
        if (path) |actual| try self.appendJsonlFile(actual, .{ .suite_name = self.default_config.suite_name });
    }
};

const CozEnv = struct {
    output_path: ?[]u8 = null,
    analysis_path: ?[]u8 = null,
    experiments: bool = false,

    fn read(allocator: Allocator) !CozEnv {
        const experiments_value = try sys.env.getOwned(allocator, coz_experiments_env);
        defer if (experiments_value) |value| allocator.free(value);
        return .{
            .output_path = try sys.env.getOwned(allocator, coz_output_env),
            .analysis_path = try sys.env.getOwned(allocator, coz_analysis_env),
            .experiments = experimentsEnabled(experiments_value),
        };
    }

    fn deinit(self: *CozEnv, allocator: Allocator) void {
        if (self.output_path) |path| allocator.free(path);
        if (self.analysis_path) |path| allocator.free(path);
        self.* = .{};
    }
};

const TracyEnv = struct {
    output_path: ?[]u8 = null,
    summary_path: ?[]u8 = null,

    fn read(allocator: Allocator) !TracyEnv {
        const output_path = try sys.env.getOwned(allocator, tracy_output_env);
        errdefer if (output_path) |path| allocator.free(path);
        const summary_path = try sys.env.getOwned(allocator, tracy_summary_env);
        errdefer if (summary_path) |path| allocator.free(path);
        if (output_path == null and summary_path != null) return error.InvalidTracyEnvironment;
        return .{ .output_path = output_path, .summary_path = summary_path };
    }

    fn deinit(self: *TracyEnv, allocator: Allocator) void {
        if (self.output_path) |path| allocator.free(path);
        if (self.summary_path) |path| allocator.free(path);
        self.* = .{};
    }
};

fn experimentsEnabled(value: ?[]const u8) bool {
    const actual = value orelse return false;
    if (actual.len == 0) return false;
    return !std.mem.eql(u8, actual, "0");
}

const ControlEnv = struct {
    min_time_ns: ?u64 = null,
    filter: ?[]u8 = null,
    layout: LayoutControl = .inherit,

    fn read(allocator: Allocator) !ControlEnv {
        const min_time_value = try sys.env.getOwned(allocator, min_time_env);
        defer if (min_time_value) |value| allocator.free(value);
        const layout_value = try sys.env.getOwned(allocator, layout_env);
        defer if (layout_value) |value| allocator.free(value);
        const min_time_ns = try parseMinTime(min_time_value);
        const layout = try parseLayoutControl(layout_value);
        return .{
            .min_time_ns = min_time_ns,
            .filter = try sys.env.getOwned(allocator, filter_env),
            .layout = layout,
        };
    }

    fn deinit(self: *ControlEnv, allocator: Allocator) void {
        if (self.filter) |value| allocator.free(value);
        self.* = .{};
    }
};

const LayoutControl = enum {
    inherit,
    disabled,
};

fn parseMinTime(value: ?[]const u8) !?u64 {
    const actual = value orelse return null;
    if (actual.len == 0) return null;
    return std.fmt.parseUnsigned(u64, actual, 10) catch error.InvalidBenchMinTime;
}

fn parseLayoutControl(value: ?[]const u8) !LayoutControl {
    const actual = value orelse return .inherit;
    if (actual.len == 0) return .inherit;
    if (std.mem.eql(u8, actual, "off")) return .disabled;
    return error.InvalidBenchLayout;
}

fn controlledDefinition(def: Definition, control: ControlEnv) Definition {
    var controlled = stretchedDefinition(def, control.min_time_ns);
    if (control.layout == .disabled) controlled.config.layout_randomization = null;
    return controlled;
}

fn stretchedDefinition(def: Definition, min_time_ns: ?u64) Definition {
    const stretch = min_time_ns orelse return def;
    var stretched = def;
    stretched.config.min_time_ns = @max(def.config.min_time_ns, stretch);
    stretched.config.max_iterations = @max(def.config.max_iterations, stretched_iteration_limit);
    return stretched;
}

fn sampleBackingAllocator() Allocator {
    return sys.allocator.benchmarkAllocator();
}

const MemtraceSession = struct {
    output_path: ?[]u8 = null,
    tracer: ?memtrace.Tracer = null,
    traced: ?memtrace.TracingAllocator = null,

    fn start(self: *MemtraceSession, control_allocator: Allocator) !void {
        self.output_path = try sys.env.getOwned(control_allocator, scoped_allocations_env);
        errdefer if (self.output_path) |path| control_allocator.free(path);
        if (self.output_path == null) return;
        self.tracer = try memtrace.Tracer.init(control_allocator, .{
            .record_events = true,
            .allocation_attribution = .stack,
        });
        if (self.tracer) |*tracer| {
            self.traced = try tracer.tracedAllocatorWithOptions(sampleBackingAllocator(), .{
                .name = "bench.sample",
                .retention = .retains_freed_memory,
            });
        }
    }

    fn sampleAllocator(self: *MemtraceSession) Allocator {
        if (self.traced) |*traced| return traced.allocator();
        return sampleBackingAllocator();
    }

    fn tracerPtr(self: *MemtraceSession) ?*memtrace.Tracer {
        if (self.tracer) |*tracer| return tracer;
        return null;
    }

    fn finish(self: *MemtraceSession) !void {
        const path = self.output_path orelse return;
        const tracer = self.tracerPtr() orelse return;
        try tracer.writeEventsBundlePath(path);
    }

    fn deinit(self: *MemtraceSession, control_allocator: Allocator) void {
        if (self.tracer) |*tracer| tracer.deinit();
        if (self.output_path) |path| control_allocator.free(path);
        self.* = .{};
    }
};

fn startCozSession(allocator: Allocator, session: *instrumentation.CozSession, env: CozEnv) !void {
    if (env.output_path) |path| {
        try session.startWithOutputPathAndOptions(allocator, path, .{
            .resolve_sample_locations = true,
            .start_experiment_worker = env.experiments,
        });
    } else {
        try session.start(allocator);
    }
}

fn finishCozSession(allocator: Allocator, session: *instrumentation.CozSession, env: CozEnv) !void {
    try session.finish();
    const output_path = env.output_path orelse return;
    const analysis_path = env.analysis_path orelse return;
    try writeCozAnalysisFile(allocator, output_path, analysis_path);
}

fn startTracySession(
    allocator: Allocator,
    session: *instrumentation.ProfilingSession,
    env: TracyEnv,
    name: []const u8,
) !void {
    const output_path = env.output_path orelse return;
    try session.start(allocator, .{
        .name = name,
        .tracy_output = output_path,
        .tracy_summary = env.summary_path,
        .require_tracy = true,
    });
    tracy.plotConfig("bench.calibration.evals", .{ .unit = .count, .step = true });
    tracy.plotConfig("bench.sample.ns", .{ .unit = .nanoseconds });
    tracy.plotConfig("bench.definition.median_ns", .{ .unit = .nanoseconds });
}

fn finishTracySession(session: *instrumentation.ProfilingSession, env: TracyEnv) !void {
    if (env.output_path == null) return;
    try session.finish();
}

fn finishInstrumentation(
    allocator: Allocator,
    executed: usize,
    memtrace_session: *MemtraceSession,
    coz_session: *instrumentation.CozSession,
    coz_env: CozEnv,
    tracy_session: *instrumentation.ProfilingSession,
    tracy_env: TracyEnv,
) !void {
    var first_error: ?anyerror = null;
    if (executed > 0) memtrace_session.finish() catch |err| rememberError(&first_error, err);
    finishCozSession(allocator, coz_session, coz_env) catch |err| rememberError(&first_error, err);
    finishTracySession(tracy_session, tracy_env) catch |err| rememberError(&first_error, err);
    if (first_error) |err| return err;
}

fn rememberError(first_error: *?anyerror, err: anyerror) void {
    if (first_error.* == null) first_error.* = err;
}

fn writeCozAnalysisFile(allocator: Allocator, output_path: []const u8, analysis_path: []const u8) !void {
    var summary = try coz.analysis.summarizeFileAlloc(allocator, output_path, coz.analysis.default_max_profile_bytes, .{});
    defer summary.deinit(allocator);
    const io = sys.fs.debugIo();
    var atomic_file = try sys.fs.cwd().createFileAtomic(io, analysis_path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);
    var buffer: [8192]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buffer);
    try summary.writeJson(&writer.interface);
    try writer.interface.flush();
    try atomic_file.replace(io);
}

fn matchesFilter(name: []const u8, filter: ?[]const u8) bool {
    const needle = filter orelse return true;
    return needle.len == 0 or std.mem.indexOf(u8, name, needle) != null;
}

pub fn time(func: BenchFn, alloc: Allocator) u64 {
    const t0 = nowNs();
    func(alloc);
    const t1 = nowNs();
    return @intCast(@max(t1 - t0, 0));
}

fn applyConfigOverride(default_config: Config, override: anytype) Config {
    const Override = @TypeOf(override);
    var config = default_config;
    if (@hasField(Override, "suite_name")) config.suite_name = override.suite_name;
    if (@hasField(Override, "min_time_ns")) config.min_time_ns = override.min_time_ns;
    if (@hasField(Override, "max_iterations")) config.max_iterations = override.max_iterations;
    if (@hasField(Override, "min_iterations")) config.min_iterations = override.min_iterations;
    if (@hasField(Override, "evaluation")) config.evaluation = override.evaluation;
    if (@hasField(Override, "warmup_iterations")) {
        config.warmup_iterations = override.warmup_iterations;
    }
    if (@hasField(Override, "prepare")) config.prepare = override.prepare;
    if (@hasField(Override, "teardown")) config.teardown = override.teardown;
    if (@hasField(Override, "allocation_attribution")) {
        config.allocation_attribution = override.allocation_attribution;
    }
    if (@hasField(Override, "layout_randomization")) {
        config.layout_randomization = override.layout_randomization;
    }
    return config;
}

const DefinitionContext = struct {
    name: []const u8,
    runtime: *?stabilizer.Runtime,
    func: BenchFn,
    alloc: Allocator,
    prepare: ?PrepareFn,
    prepare_alloc: Allocator,
    trace: ?*memtrace.Tracer,
};

const CollectedSamples = struct {
    samples: std.ArrayListUnmanaged(u64) = .empty,
    totals: std.ArrayListUnmanaged(u64) = .empty,
    total_ns: u64 = 0,
    iterations: u32 = 0,

    fn deinit(self: *CollectedSamples, allocator: Allocator) void {
        self.samples.deinit(allocator);
        self.totals.deinit(allocator);
        self.* = .{};
    }
};

const MeasuredSample = struct {
    per_eval_ns: u64,
    total_ns: u64,
};

const CalibrationAction = union(enum) {
    confirm,
    reached,
    exhausted,
    grow: u32,
};

fn runOne(
    control_alloc: Allocator,
    sample_backing_alloc: Allocator,
    trace: ?*memtrace.Tracer,
    def: Definition,
    clock_probe: timing.ClockProbe,
) !Result {
    const definition_phase = phaseAt("bench.definition", @src());
    definition_phase.setName(def.name);
    defer definition_phase.end();
    var definition_trace = try enterTrace(trace, def.name);
    defer definition_trace.exit();

    const cfg = def.config;
    try validatePreparedEvaluation(cfg);
    var layout_runtime: ?stabilizer.Runtime = if (cfg.layout_randomization) |layout_config|
        try stabilizer.Runtime.init(sample_backing_alloc, layout_config)
    else
        null;
    defer if (layout_runtime) |*runtime| runtime.deinit();
    var teardown_pending = cfg.teardown != null;
    defer if (teardown_pending) cfg.teardown.?();
    const layout_allocator = if (layout_runtime) |*runtime|
        runtime.randomizedAllocator()
    else
        sample_backing_alloc;
    var allocation_tracker = CountingAllocator.init(layout_allocator);
    const tracked_allocator = allocation_tracker.allocator();
    const bench_allocator = switch (cfg.allocation_attribution) {
        .none, .prepare_owner => layout_allocator,
        .sample_call => tracked_allocator,
    };
    const prepare_allocator = switch (cfg.allocation_attribution) {
        .none, .sample_call => layout_allocator,
        .prepare_owner => tracked_allocator,
    };
    const context = DefinitionContext{
        .name = def.name,
        .runtime = &layout_runtime,
        .func = def.func,
        .alloc = bench_allocator,
        .prepare = cfg.prepare,
        .prepare_alloc = prepare_allocator,
        .trace = trace,
    };
    const selection = try selectEvaluation(context, cfg.evaluation, clock_probe);
    try runWarmups(context, cfg.warmup_iterations, selection.evalCount());
    if (cfg.allocation_attribution == .prepare_owner and cfg.warmup_iterations > 0) {
        cfg.teardown.?();
    }
    if (cfg.allocation_attribution != .none) allocation_tracker.reset();
    var collected = try collectSamples(control_alloc, context, cfg, selection.evalCount());
    defer collected.deinit(control_alloc);
    if (cfg.allocation_attribution == .prepare_owner) {
        cfg.teardown.?();
        teardown_pending = false;
    }
    return buildResult(
        control_alloc,
        def,
        &collected,
        selection,
        clock_probe,
        allocation_tracker.counts,
    );
}

fn selectEvaluation(
    context: DefinitionContext,
    evaluation: Evaluation,
    clock_probe: timing.ClockProbe,
) !EvaluationSelection {
    return switch (evaluation) {
        .fixed => |evals| if (evals == 0) error.InvalidEvalCount else .{ .fixed = evals },
        .automatic => |policy| calibrateEvaluation(context, policy, clock_probe),
    };
}

fn validatePreparedEvaluation(config: Config) !void {
    if (config.allocation_attribution == .prepare_owner and
        (config.prepare == null or config.teardown == null))
    {
        return error.InvalidPrepareOwnerAttribution;
    }
    if (config.prepare == null) return;
    switch (config.evaluation) {
        .fixed => |evals| if (evals != 1) return error.InvalidPreparedEvaluation,
        .automatic => return error.InvalidPreparedEvaluation,
    }
}

fn calibrateEvaluation(
    context: DefinitionContext,
    policy: AutomaticEvaluation,
    clock_probe: timing.ClockProbe,
) !EvaluationSelection {
    try validateAutomaticEvaluation(policy);
    const clock_target = std.math.mul(
        u64,
        clock_probe.minimum_delta_ns,
        policy.clock_resolution_multiple,
    ) catch std.math.maxInt(u64);
    const target = @min(@max(policy.min_sample_time_ns, clock_target), policy.max_sample_time_ns);
    var selection = AutomaticSelection{
        .policy = policy,
        .evals = 1,
        .clock_target_ns = clock_target,
        .target_ns = target,
        .target_capped = clock_target > policy.max_sample_time_ns,
        .calibration_batches = 0,
        .calibration_confirmations = 0,
        .calibration_evals = 0,
        .calibration_ns = 0,
        .calibration_last_ns = 0,
        .calibration_target_reached = false,
    };
    try runCalibration(context, &selection);
    return .{ .automatic = selection };
}

fn validateAutomaticEvaluation(policy: AutomaticEvaluation) !void {
    if (policy.min_sample_time_ns == 0) return error.InvalidEvaluationPolicy;
    if (policy.max_sample_time_ns < policy.min_sample_time_ns) {
        return error.InvalidEvaluationPolicy;
    }
    if (policy.max_sample_time_ns > automatic_sample_time_limit_ns) {
        return error.InvalidEvaluationPolicy;
    }
    if (policy.clock_resolution_multiple == 0) return error.InvalidEvaluationPolicy;
    if (policy.max_evals == 0 or policy.max_evals > automatic_eval_limit) {
        return error.InvalidEvaluationPolicy;
    }
}

fn runCalibration(context: DefinitionContext, selection: *AutomaticSelection) !void {
    std.debug.assert(selection.evals > 0);
    std.debug.assert(selection.evals <= selection.policy.max_evals);
    const calibration_phase = phaseAt("bench.calibration", @src());
    calibration_phase.setName(context.name);
    defer calibration_phase.end();
    var calibration_trace = try enterTrace(context.trace, "calibration");
    defer calibration_trace.exit();

    var steps: u32 = 0;
    while (steps < max_calibration_steps) : (steps += 1) {
        const first = try runCalibrationBatch(context, selection);
        var action = calibrationAction(selection.*, first, null);
        if (action == .confirm) {
            selection.calibration_confirmations += 1;
            const confirmation = try runCalibrationBatch(context, selection);
            action = calibrationAction(selection.*, first, confirmation);
        }
        switch (action) {
            .reached => {
                selection.calibration_target_reached = true;
                break;
            },
            .exhausted => break,
            .grow => |evals| selection.evals = evals,
            .confirm => unreachable,
        }
    }
    if (steps == max_calibration_steps and
        selection.evals != selection.policy.max_evals and
        !selection.calibration_target_reached)
    {
        return error.CalibrationBoundExceeded;
    }
    calibration_phase.setValue(selection.evals);
    tracy.plotInt("bench.calibration.evals", selection.evals);
}

fn runCalibrationBatch(context: DefinitionContext, selection: *AutomaticSelection) !u64 {
    rerandomizeDefinitionLayout(context.runtime);
    const elapsed = try measureDefinition(context, selection.evals);
    selection.calibration_batches += 1;
    selection.calibration_evals +|= selection.evals;
    selection.calibration_ns +|= elapsed;
    selection.calibration_last_ns = elapsed;
    coz.progressNamed("bench.calibration");
    return elapsed;
}

fn calibrationAction(
    selection: AutomaticSelection,
    first_ns: u64,
    confirmation_ns: ?u64,
) CalibrationAction {
    if (first_ns >= selection.target_ns and confirmation_ns == null) return .confirm;
    const observed = @min(first_ns, confirmation_ns orelse first_ns);
    if (observed >= selection.target_ns) return .reached;
    if (selection.evals == selection.policy.max_evals) return .exhausted;
    return .{ .grow = nextEvalCount(
        selection.evals,
        observed,
        selection.target_ns,
        selection.policy.max_evals,
    ) };
}

fn nextEvalCount(current: u32, elapsed_ns: u64, target_ns: u64, maximum: u32) u32 {
    std.debug.assert(current > 0);
    std.debug.assert(current <= maximum);
    std.debug.assert(target_ns > 0);
    const ratio = if (elapsed_ns == 0)
        @as(u64, 10)
    else
        std.math.divCeil(u64, target_ns, elapsed_ns) catch 10;
    const growth = @min(@max(ratio, 2), 10);
    return @intCast(@min(@as(u64, current) * growth, maximum));
}

fn runWarmups(context: DefinitionContext, iterations: u32, evals: u32) !void {
    for (0..iterations) |_| {
        const warmup_phase = phaseAt("bench.warmup", @src());
        warmup_phase.setName(context.name);
        defer warmup_phase.end();
        var warmup_trace = try enterTrace(context.trace, "warmup");
        prepareDefinition(context);
        callDefinitionEvals(context.runtime, context.func, context.alloc, evals);
        warmup_trace.exit();
        coz.progressNamed("bench.warmup");
    }
}

fn collectSamples(
    control_alloc: Allocator,
    context: DefinitionContext,
    cfg: Config,
    evals: u32,
) !CollectedSamples {
    var collected: CollectedSamples = .{};
    errdefer collected.deinit(control_alloc);
    while ((collected.total_ns < cfg.min_time_ns or
        collected.iterations < cfg.min_iterations) and
        collected.iterations < cfg.max_iterations)
    {
        const batch = adaptiveBatchSize(
            collected.iterations,
            collected.total_ns,
            cfg.min_time_ns,
            cfg.max_iterations,
        );
        for (0..batch) |_| {
            const sample = try measureSample(context, evals);
            try collected.samples.append(control_alloc, sample.per_eval_ns);
            try collected.totals.append(control_alloc, sample.total_ns);
            collected.total_ns +|= sample.total_ns;
        }
        collected.iterations += batch;
        if (collected.iterations >= cfg.min_iterations and
            collected.total_ns >= cfg.min_time_ns) break;
    }
    return collected;
}

fn measureSample(context: DefinitionContext, evals: u32) !MeasuredSample {
    rerandomizeDefinitionLayout(context.runtime);
    prepareDefinition(context);
    const sample_phase = phaseAt("bench.sample", @src());
    sample_phase.setName(context.name);
    defer sample_phase.end();
    var sample_trace = try enterTrace(context.trace, "sample");
    defer sample_trace.exit();
    const elapsed = try measureDefinition(context, evals);
    const per_eval = elapsed / evals;
    sample_phase.setValue(per_eval);
    tracy.plotInt("bench.sample.ns", saturatingI64(per_eval));
    tracy.frameMarkNamed("bench.sample");
    coz.progressNamed("bench.sample");
    return .{ .per_eval_ns = per_eval, .total_ns = elapsed };
}

fn prepareDefinition(context: DefinitionContext) void {
    const prepare = context.prepare orelse return;
    callDefinition(context.runtime, prepare, context.prepare_alloc);
}

fn measureDefinition(context: DefinitionContext, evals: u32) !u64 {
    std.debug.assert(evals > 0);
    const started = try timing.readInstant();
    callDefinitionEvals(context.runtime, context.func, context.alloc, evals);
    const finished = try timing.readInstant();
    return (try finished.elapsedSince(started)).asNanoseconds();
}

fn buildResult(
    allocator: Allocator,
    def: Definition,
    collected: *CollectedSamples,
    selection_value: EvaluationSelection,
    clock_probe: timing.ClockProbe,
    allocation_counts: allocation.Counts,
) !Result {
    var statistics_storage = try stats.Storage.init(allocator, .{
        .samples = collected.samples.items.len,
    });
    defer statistics_storage.deinit(allocator);
    statistics_storage.activate();
    const sample_stats = try stats.computeSampleStats(
        &statistics_storage,
        collected.samples.items,
    );
    var selection = selection_value;
    recordTargetCoverage(&selection, collected.totals.items);
    const stddev_ns = sampleStddev(collected.samples.items, sample_stats.mean_ns);
    coz.progressNamed("bench.definition.complete");
    tracy.plotInt("bench.definition.median_ns", saturatingI64(sample_stats.median_ns));
    tracy.message(def.name);
    const owned_samples = try collected.samples.toOwnedSlice(allocator);
    errdefer allocator.free(owned_samples);
    const owned_totals = try collected.totals.toOwnedSlice(allocator);
    const measured_evals =
        @as(u64, collected.iterations) * @as(u64, selection.evalCount());
    return .{
        .name = def.name,
        .iterations = collected.iterations,
        .evals = selection.evalCount(),
        .evaluation = selection,
        .clock_probe = clock_probe,
        .samples = owned_samples,
        .sample_total_ns = owned_totals,
        .min_ns = sample_stats.min_ns,
        .max_ns = sample_stats.max_ns,
        .mean_ns = sample_stats.mean_ns,
        .median_ns = sample_stats.median_ns,
        .stddev_ns = stddev_ns,
        .p75_ns = sample_stats.p75_ns,
        .p95_ns = sample_stats.p95_ns,
        .p99_ns = sample_stats.p99_ns,
        .total_ns = sample_stats.total_ns,
        .warmup_iterations = def.config.warmup_iterations,
        .confidence_intervals = sample_stats.confidence_intervals,
        .allocation_attribution = def.config.allocation_attribution,
        .alloc_count = if (def.config.allocation_attribution != .none) allocation_counts.alloc_count else null,
        .free_count = if (def.config.allocation_attribution != .none) allocation_counts.free_count else null,
        .alloc_bytes = if (def.config.allocation_attribution != .none) allocation_counts.alloc_bytes else null,
        .alloc_count_per_eval = if (def.config.allocation_attribution != .none)
            perEvaluation(allocation_counts.alloc_count, measured_evals)
        else
            null,
        .free_count_per_eval = if (def.config.allocation_attribution != .none)
            perEvaluation(allocation_counts.free_count, measured_evals)
        else
            null,
        .alloc_bytes_per_eval = if (def.config.allocation_attribution != .none)
            perEvaluation(allocation_counts.alloc_bytes, measured_evals)
        else
            null,
        .layout_randomization = def.config.layout_randomization,
    };
}

fn perEvaluation(total: u64, evaluations: u64) u64 {
    std.debug.assert(evaluations > 0);
    return std.math.divCeil(u64, total, evaluations) catch unreachable;
}

fn recordTargetCoverage(selection: *EvaluationSelection, totals: []const u64) void {
    std.debug.assert(totals.len <= std.math.maxInt(u32));
    switch (selection.*) {
        .automatic => |*automatic| {
            var below: u32 = 0;
            for (totals) |total| below += @intFromBool(total < automatic.target_ns);
            automatic.samples_below_target = below;
        },
        .fixed => {},
    }
}

fn sampleStddev(samples: []const u64, mean_ns: f64) f64 {
    if (samples.len < 2) return 0;
    var variance_sum: f64 = 0;
    for (samples) |sample| {
        const difference = @as(f64, @floatFromInt(sample)) - mean_ns;
        variance_sum += difference * difference;
    }
    return @sqrt(variance_sum / @as(f64, @floatFromInt(samples.len - 1)));
}

fn enterTrace(tracer: ?*memtrace.Tracer, label: []const u8) !memtrace.Span {
    return try memtrace.Context.init(tracer, null).enter(label);
}

fn withOutputPath(options: JsonlOptions, path: []const u8) JsonlOptions {
    if (options.output_path.len != 0) return options;
    var updated = options;
    updated.output_path = path;
    return updated;
}

fn writeJsonlStart(self: *const Suite, writer: *std.Io.Writer, options: JsonlOptions) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("event", "run_start");
    try object.field("protocol", "bench.suite/v1");
    try object.field("timestamp_ns", timing.realNowNs());
    try object.field("suite", options.suite_name);
    if (options.output_path.len != 0) try object.field("output", options.output_path);
    const metadata = options.metadata orelse metadata_mod.compiledBuildMetadata();
    try metadata_mod.writeBuildMetadata(try object.object("metadata"), metadata);
    if (self.clock_probe) |clock_probe| {
        try writeClockProbe(try object.object("clock"), clock_probe);
    }
    if (self.filter) |filter| try object.field("filter", filter);
    try object.field("definitions", self.benchmarks.items.len);
    try object.field("benchmarks", self.results.items.len);
    try object.endLine();
}

fn writeJsonlResult(writer: *std.Io.Writer, options: JsonlOptions, result: Result) !void {
    const row = .{
        .warmup = result.warmup_iterations,
        .samples = result.iterations,
        .evals = result.evals,
        .sample_ns = result.samples,
        .sample_total_ns = result.sample_total_ns,
        .min_ns = result.min_ns,
        .max_ns = result.max_ns,
        .mean_ns = result.mean_ns,
        .median_ns = result.median_ns,
        .p75_ns = result.p75_ns,
        .p95_ns = result.p95_ns,
        .p99_ns = result.p99_ns,
        .total_ns = result.total_ns,
        .confidence_intervals = result.confidence_intervals,
    };

    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", metric_schema);
    try object.field("event", "bench_end");
    try object.field("family", "timing");
    try object.field("metric", "duration_ns");
    try object.field("unit", "ns");
    try object.field("aggregation", "sample_distribution");
    try object.field("id", result.name);
    try object.field("path", options.suite_name);
    try object.field("name", result.name);
    try object.field("suite", options.suite_name);
    try event.writeSampledResultFields(@TypeOf(row), object, row);
    try writeClockProbe(try object.object("clock"), result.clock_probe);
    try writeEvaluation(try object.object("evaluation"), result.evaluation);
    if (result.layout_randomization) |layout_config| {
        try metadata_mod.writeStabilizerConfig(
            try object.object("stabilizer_config"),
            layout_config,
        );
    } else {
        try object.field("stabilizer_config", @as(?u8, null));
    }
    try evidence.writeBenchmarkEvidence(
        try object.object("agent_evidence"),
        result.layout_randomization,
    );
    try object.field("allocation_attribution", @tagName(result.allocation_attribution));
    try object.field("alloc_count", result.alloc_count);
    try object.field("free_count", result.free_count);
    try object.field("alloc_bytes", result.alloc_bytes);
    try object.field("alloc_count_per_eval", result.alloc_count_per_eval);
    try object.field("free_count_per_eval", result.free_count_per_eval);
    try object.field("alloc_bytes_per_eval", result.alloc_bytes_per_eval);
    try object.endLine();
}

fn writeClockProbe(object: pretty_json.Object, probe: timing.ClockProbe) !void {
    try object.field("schema", "bench.clock/v1");
    try object.field("source", probe.source);
    try object.field("reads", probe.reads);
    try object.field("positive_deltas", probe.positive_deltas);
    try object.field("minimum_delta_ns", probe.minimum_delta_ns);
    try object.field("span_ns", probe.span_ns);
    try object.end();
}

fn writeEvaluation(
    object: pretty_json.Object,
    selection: EvaluationSelection,
) !void {
    try object.field("schema", "bench.evaluation/v1");
    switch (selection) {
        .fixed => |evals| {
            try object.field("mode", "fixed");
            try object.field("evals", evals);
        },
        .automatic => |automatic| try writeAutomaticEvaluation(object, automatic),
    }
    try object.end();
}

fn writeAutomaticEvaluation(
    object: pretty_json.Object,
    selection: AutomaticSelection,
) !void {
    try object.field("mode", "automatic");
    try object.field("evals", selection.evals);
    const policy = try object.object("policy");
    try policy.field("min_sample_time_ns", selection.policy.min_sample_time_ns);
    try policy.field("max_sample_time_ns", selection.policy.max_sample_time_ns);
    try policy.field(
        "clock_resolution_multiple",
        selection.policy.clock_resolution_multiple,
    );
    try policy.field("max_evals", selection.policy.max_evals);
    try policy.end();
    try object.field("clock_target_ns", selection.clock_target_ns);
    try object.field("target_ns", selection.target_ns);
    try object.field("target_capped", selection.target_capped);
    try object.field("calibration_batches", selection.calibration_batches);
    try object.field("calibration_confirmations", selection.calibration_confirmations);
    try object.field("calibration_evals", selection.calibration_evals);
    try object.field("calibration_ns", selection.calibration_ns);
    try object.field("calibration_last_ns", selection.calibration_last_ns);
    try object.field("calibration_target_reached", selection.calibration_target_reached);
    try object.field("samples_below_target", selection.samples_below_target);
}

fn ensureParent(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try sys.fs.createDirPath(dir);
    }
}

fn rerandomizeDefinitionLayout(runtime: *?stabilizer.Runtime) void {
    instrumentation.rerandomizeLayout(runtime, "bench.stabilizer.rerandomize");
}

fn adaptiveBatchSize(iterations: u32, total_ns: u64, min_time_ns: u64, max_iterations: u32) u32 {
    if (iterations == 0) return 1;
    const remaining_iterations = max_iterations - iterations;
    const average_ns = total_ns / iterations;
    const target_ns = @min(min_time_ns -| total_ns, sample_batch_window_ns);
    const estimated: u64 = if (average_ns == 0) zero_average_batch_size else target_ns / average_ns;
    return @intCast(@min(@max(estimated, 1), remaining_iterations));
}

fn callDefinitionEvals(runtime: *?stabilizer.Runtime, func: BenchFn, alloc: Allocator, evals: u32) void {
    for (0..evals) |_| callDefinition(runtime, func, alloc);
}

fn callDefinition(runtime: *?stabilizer.Runtime, func: BenchFn, alloc: Allocator) void {
    if (runtime.*) |*active| {
        const pad = active.nextStackPad();
        callWithStackPad(pad.unit, func, .{alloc});
    } else {
        func(alloc);
    }
}

fn test_noop(_: Allocator) void {}

fn test_teardown_noop() void {}

fn test_allocate_32_cc(allocator: Allocator) void {
    const bytes = allocator.alloc(u8, 32) catch unreachable;
    defer allocator.free(bytes);
    @memset(bytes, 0xcc);
}

fn test_allocate_16_ee(allocator: Allocator) void {
    const bytes = allocator.alloc(u8, 16) catch unreachable;
    defer allocator.free(bytes);
    @memset(bytes, 0xee);
}

fn test_allocate_8_aa(allocator: Allocator) void {
    const bytes = allocator.alloc(u8, 8) catch unreachable;
    defer allocator.free(bytes);
    @memset(bytes, 0xaa);
}

fn test_allocate_16_dd(allocator: Allocator) void {
    const bytes = allocator.alloc(u8, 16) catch unreachable;
    defer allocator.free(bytes);
    @memset(bytes, 0xdd);
}

fn test_allocate_64_cc(allocator: Allocator) void {
    const bytes = allocator.alloc(u8, 64) catch unreachable;
    defer allocator.free(bytes);
    @memset(bytes, 0xcc);
}

const TestCallCounter = struct {
    var count: u32 = 0;

    fn reset() void {
        count = 0;
    }

    fn run(_: Allocator) void {
        count += 1;
    }
};

const TestBackingWitness = struct {
    var sample: ?Allocator = null;

    fn reset() void {
        sample = null;
    }

    fn run(allocator: Allocator) void {
        sample = allocator;
    }
};

const TestTeardownWitness = struct {
    var allocator: ?Allocator = null;
    var memory: ?[]u8 = null;
    var calls: usize = 0;
    var teardowns: usize = 0;

    fn reset() void {
        allocator = null;
        memory = null;
        calls = 0;
        teardowns = 0;
    }

    fn run(sample_allocator: Allocator) void {
        if (memory == null) {
            allocator = sample_allocator;
            memory = sample_allocator.alloc(u8, 32) catch @panic("bench teardown witness allocation failed");
        }
        calls += 1;
    }

    fn teardown() void {
        allocator.?.free(memory.?);
        allocator = null;
        memory = null;
        teardowns += 1;
    }
};

const TestPrepareWitness = struct {
    var prepares: usize = 0;
    var calls: usize = 0;

    fn reset() void {
        prepares = 0;
        calls = 0;
    }

    fn prepare(allocator: Allocator) void {
        const bytes = allocator.alloc(u8, 32) catch @panic("bench prepare witness allocation failed");
        defer allocator.free(bytes);
        @memset(bytes, 0xee);
        prepares += 1;
    }

    fn run(_: Allocator) void {
        calls += 1;
    }
};

const TestPrepareOwnerWitness = struct {
    var allocator: ?Allocator = null;
    var prepared_memory: ?[]u8 = null;
    var call_memory: ?[]u8 = null;
    var prepares: usize = 0;
    var calls: usize = 0;
    var teardowns: usize = 0;

    fn reset() void {
        allocator = null;
        prepared_memory = null;
        call_memory = null;
        prepares = 0;
        calls = 0;
        teardowns = 0;
    }

    fn prepare(owner_allocator: Allocator) void {
        release();
        allocator = owner_allocator;
        prepared_memory = owner_allocator.alloc(u8, 32) catch
            @panic("bench prepare owner allocation failed");
        @memset(prepared_memory.?, 0xcc);
        prepares += 1;
    }

    fn run(sample_allocator: Allocator) void {
        const transient = sample_allocator.alloc(u8, 8) catch
            @panic("bench prepare owner sample allocation failed");
        defer sample_allocator.free(transient);
        call_memory = allocator.?.alloc(u8, 16) catch
            @panic("bench retained owner allocation failed");
        @memset(call_memory.?, 0xee);
        calls += 1;
    }

    fn teardown() void {
        release();
        teardowns += 1;
    }

    fn release() void {
        const owner_allocator = allocator orelse return;
        if (call_memory) |memory| owner_allocator.free(memory);
        if (prepared_memory) |memory| owner_allocator.free(memory);
        allocator = null;
        prepared_memory = null;
        call_memory = null;
    }
};

const TestPrepareOwnerResizeWitness = struct {
    var allocator: ?Allocator = null;
    var memory: ?[]u8 = null;

    fn reset() void {
        allocator = null;
        memory = null;
    }

    fn prepare(owner_allocator: Allocator) void {
        release();
        allocator = owner_allocator;
        memory = owner_allocator.alloc(u8, 32) catch
            @panic("bench prepare owner resize allocation failed");
    }

    fn run(sample_allocator: Allocator) void {
        const owner_allocator = allocator.?;
        const current = memory.?;
        if (!owner_allocator.resize(current, 48)) {
            @panic("bench prepare owner resize failed");
        }
        memory = current.ptr[0..48];
        const transient = sample_allocator.alloc(u8, 8) catch
            @panic("bench prepare owner resize sample allocation failed");
        sample_allocator.free(transient);
    }

    fn teardown() void {
        release();
    }

    fn release() void {
        const owner_allocator = allocator orelse return;
        owner_allocator.free(memory.?);
        allocator = null;
        memory = null;
    }
};

test "default benchmark layout disables pointer validation bookkeeping" {
    try std.testing.expect(!(Config{}).layout_randomization.?.heap.pointer_validation);
}

test "suite feeds workloads the production heap regardless of init allocator" {
    TestBackingWitness.reset();
    var s = Suite.init(std.testing.allocator, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .layout_randomization = null,
    });
    defer s.deinit();

    try s.add("backing witness", TestBackingWitness.run, .{});
    _ = try s.runSilent();

    const witness = TestBackingWitness.sample orelse return error.TestUnexpectedResult;
    const production = sampleBackingAllocator();
    try std.testing.expectEqual(production.ptr, witness.ptr);
    try std.testing.expectEqual(production.vtable, witness.vtable);
    try std.testing.expect(witness.vtable != std.testing.allocator.vtable);
}

test "suite enables coz experiments from a nonempty environment value" {
    try std.testing.expect(experimentsEnabled("1"));
    try std.testing.expect(experimentsEnabled("true"));
    try std.testing.expect(!experimentsEnabled("0"));
    try std.testing.expect(!experimentsEnabled(""));
    try std.testing.expect(!experimentsEnabled(null));
}

test "suite parses the minimum-time stretch from the environment value" {
    try std.testing.expectEqual(@as(?u64, null), try parseMinTime(null));
    try std.testing.expectEqual(@as(?u64, null), try parseMinTime(""));
    try std.testing.expectEqual(@as(?u64, 30_000_000_000), try parseMinTime("30000000000"));
    try std.testing.expectError(error.InvalidBenchMinTime, parseMinTime("30s"));
}

test "suite parses the layout control from the environment value" {
    try std.testing.expectEqual(LayoutControl.inherit, try parseLayoutControl(null));
    try std.testing.expectEqual(LayoutControl.inherit, try parseLayoutControl(""));
    try std.testing.expectEqual(LayoutControl.disabled, try parseLayoutControl("off"));
    try std.testing.expectError(error.InvalidBenchLayout, parseLayoutControl("fixed"));

    const def = Definition{
        .name = "layout control",
        .func = undefined,
        .config = .{},
    };
    const controlled = controlledDefinition(def, .{ .layout = .disabled });
    try std.testing.expect(controlled.config.layout_randomization == null);
}

test "stretched definitions raise minimum time and iteration cap without shrinking" {
    const def = Definition{
        .name = "stretch",
        .func = undefined,
        .config = .{ .min_time_ns = 5_000_000, .max_iterations = 100 },
    };

    const unchanged = stretchedDefinition(def, null);
    try std.testing.expectEqual(@as(u64, 5_000_000), unchanged.config.min_time_ns);
    try std.testing.expectEqual(@as(u32, 100), unchanged.config.max_iterations);

    const stretched = stretchedDefinition(def, 30_000_000_000);
    try std.testing.expectEqual(@as(u64, 30_000_000_000), stretched.config.min_time_ns);
    try std.testing.expectEqual(stretched_iteration_limit, stretched.config.max_iterations);

    const long = Definition{
        .name = "long",
        .func = undefined,
        .config = .{ .min_time_ns = 60_000_000_000, .max_iterations = 2_000_000 },
    };
    const kept = stretchedDefinition(long, 30_000_000_000);
    try std.testing.expectEqual(@as(u64, 60_000_000_000), kept.config.min_time_ns);
    try std.testing.expectEqual(@as(u32, 2_000_000), kept.config.max_iterations);
}

test "adaptive sample batches stay inside the measurement window" {
    try std.testing.expectEqual(@as(u32, 1), adaptiveBatchSize(0, 0, std.time.ns_per_s, 1_000_000));
    try std.testing.expectEqual(@as(u32, 33), adaptiveBatchSize(1, 300_000, std.time.ns_per_s, 1_000_000));
    try std.testing.expectEqual(@as(u32, 5), adaptiveBatchSize(10, 20 * std.time.ns_per_ms, std.time.ns_per_s, 1_000_000));
    try std.testing.expectEqual(zero_average_batch_size, adaptiveBatchSize(1, 0, std.time.ns_per_s, 1_000_000));
    try std.testing.expectEqual(@as(u32, 1), adaptiveBatchSize(10, std.time.ns_per_s, std.time.ns_per_s, 1_000_000));
    try std.testing.expectEqual(@as(u32, 3), adaptiveBatchSize(97, 97_000, std.time.ns_per_s, 100));
}

test "automatic eval growth is bounded and progressive" {
    try std.testing.expectEqual(@as(u32, 10), nextEvalCount(1, 0, 100, 1000));
    try std.testing.expectEqual(@as(u32, 100), nextEvalCount(10, 10, 100, 1000));
    try std.testing.expectEqual(@as(u32, 20), nextEvalCount(10, 60, 100, 1000));
    try std.testing.expectEqual(@as(u32, 25), nextEvalCount(20, 10, 100, 25));

    var evals: u32 = 1;
    var steps: u32 = 1;
    while (evals < automatic_eval_limit) : (steps += 1) {
        evals = nextEvalCount(evals, 60, 100, automatic_eval_limit);
    }
    try std.testing.expectEqual(automatic_eval_limit, evals);
    try std.testing.expectEqual(max_calibration_steps, steps);
    try std.testing.expectEqual(max_calibration_steps * 2, max_calibration_batches);
}

test "automatic calibration requires a confirming target observation" {
    var selection = AutomaticSelection{
        .policy = .{ .max_evals = 100 },
        .evals = 1,
        .clock_target_ns = 100,
        .target_ns = 100,
        .target_capped = false,
        .calibration_batches = 0,
        .calibration_confirmations = 0,
        .calibration_evals = 0,
        .calibration_ns = 0,
        .calibration_last_ns = 0,
        .calibration_target_reached = false,
    };
    try std.testing.expect(calibrationAction(selection, 150, null) == .confirm);
    const cold_action = calibrationAction(selection, 150, 60);
    try std.testing.expectEqual(@as(u32, 2), cold_action.grow);
    try std.testing.expect(calibrationAction(selection, 150, 120) == .reached);

    selection.evals = selection.policy.max_evals;
    try std.testing.expect(calibrationAction(selection, 99, null) == .exhausted);
}

test "automatic evaluation policy enforces absolute bounds" {
    try std.testing.expectError(
        error.InvalidEvaluationPolicy,
        validateAutomaticEvaluation(.{ .min_sample_time_ns = 0 }),
    );
    try std.testing.expectError(
        error.InvalidEvaluationPolicy,
        validateAutomaticEvaluation(.{
            .min_sample_time_ns = 2,
            .max_sample_time_ns = 1,
        }),
    );
    try std.testing.expectError(
        error.InvalidEvaluationPolicy,
        validateAutomaticEvaluation(.{
            .max_sample_time_ns = automatic_sample_time_limit_ns + 1,
        }),
    );
    try std.testing.expectError(
        error.InvalidEvaluationPolicy,
        validateAutomaticEvaluation(.{ .clock_resolution_multiple = 0 }),
    );
    try std.testing.expectError(
        error.InvalidEvaluationPolicy,
        validateAutomaticEvaluation(.{ .max_evals = automatic_eval_limit + 1 }),
    );
}

test "suite basic run" {
    const alloc = std.testing.allocator;
    var s = Suite.init(alloc, .{ .min_time_ns = 1_000_000, .min_iterations = 3 });
    defer s.deinit();

    try s.add("noop", test_noop, .{});

    const results = try s.runSilent();
    try std.testing.expect(results.len == 1);
    try std.testing.expect(results[0].iterations >= 3);
    try std.testing.expect(results[0].evals > 0);
    try std.testing.expect(results[0].evaluation == .automatic);
    try std.testing.expect(results[0].clock_probe.minimum_delta_ns > 0);
    const selection = results[0].evaluation.automatic;
    try std.testing.expect(selection.target_ns >= selection.policy.min_sample_time_ns);
    try std.testing.expect(selection.target_ns <= selection.policy.max_sample_time_ns);
    try std.testing.expect(selection.calibration_batches > 0);
    try std.testing.expect(selection.calibration_batches <= max_calibration_batches);
    try std.testing.expect(selection.calibration_confirmations > 0);
    try std.testing.expect(selection.calibration_evals >= selection.evals);
    if (selection.calibration_target_reached) {
        try std.testing.expect(selection.calibration_last_ns >= selection.target_ns);
    }
    try std.testing.expect(selection.samples_below_target <= results[0].iterations);
    try std.testing.expect(std.mem.eql(u8, results[0].name, "noop"));
}

test "build result preserves measured sample order" {
    const allocator = std.testing.allocator;
    var collected: CollectedSamples = .{};
    defer collected.deinit(allocator);
    try collected.samples.appendSlice(allocator, &.{ 30, 10, 20 });
    try collected.totals.appendSlice(allocator, &.{ 90, 30, 60 });
    collected.total_ns = 180;
    collected.iterations = 3;
    const result = try buildResult(
        allocator,
        .{ .name = "ordered", .func = test_noop, .config = .{} },
        &collected,
        .{ .fixed = 3 },
        .{
            .reads = 2,
            .positive_deltas = 1,
            .minimum_delta_ns = 1,
            .span_ns = 1,
        },
        .{},
    );
    defer allocator.free(result.samples);
    defer allocator.free(result.sample_total_ns);
    try std.testing.expectEqualSlices(u64, &.{ 30, 10, 20 }, result.samples);
    try std.testing.expectEqualSlices(u64, &.{ 90, 30, 60 }, result.sample_total_ns);
    try std.testing.expectEqual(@as(u64, 10), result.min_ns);
    try std.testing.expectEqual(@as(u64, 20), result.median_ns);
    try std.testing.expectEqual(@as(u64, 30), result.max_ns);
}

test "suite honors minimum iterations after time target" {
    const alloc = std.testing.allocator;
    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 3,
        .max_iterations = 3,
    });
    defer s.deinit();

    try s.add("noop", test_noop, .{});

    const results = try s.runSilent();
    try std.testing.expectEqual(@as(u32, 3), results[0].iterations);
}

test "suite applies per-row config overrides" {
    const alloc = std.testing.allocator;
    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 5,
    });
    defer s.deinit();

    try s.add("default", test_noop, .{});
    try s.add("override", test_noop, .{
        .min_iterations = 3,
        .max_iterations = 3,
        .evaluation = Evaluation{ .fixed = 2 },
    });

    const results = try s.runSilent();
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(u32, 1), results[0].iterations);
    try std.testing.expectEqual(@as(u32, 3), results[1].iterations);
    try std.testing.expect(results[0].evaluation == .automatic);
    try std.testing.expectEqual(@as(u32, 2), results[1].evals);
    try std.testing.expect(results[1].evaluation == .fixed);
}

test "suite filters benchmark definitions" {
    const alloc = std.testing.allocator;
    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .layout_randomization = null,
    });
    defer s.deinit();
    s.setFilter("keep");

    try s.add("drop row", test_noop, .{});
    try s.add("keep row", test_noop, .{});

    const results = try s.runSilent();
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("keep row", results[0].name);
}

test "suite tears down retained sample storage before definition instrumentation" {
    TestTeardownWitness.reset();
    var s = Suite.init(std.testing.allocator, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .warmup_iterations = 1,
        .evaluation = .{ .fixed = 1 },
    });
    defer s.deinit();

    try s.add("retained fixture", TestTeardownWitness.run, .{
        .teardown = TestTeardownWitness.teardown,
    });
    _ = try s.runSilent();

    try std.testing.expectEqual(@as(usize, 2), TestTeardownWitness.calls);
    try std.testing.expectEqual(@as(usize, 1), TestTeardownWitness.teardowns);
    try std.testing.expect(TestTeardownWitness.memory == null);
    try std.testing.expect(TestTeardownWitness.allocator == null);
}

test "suite preserves null allocation fields for unattributed prepared rows" {
    TestPrepareWitness.reset();
    var s = Suite.init(std.testing.allocator, .{
        .min_time_ns = 0,
        .min_iterations = 3,
        .max_iterations = 3,
        .warmup_iterations = 1,
        .evaluation = .{ .fixed = 1 },
        .layout_randomization = null,
    });
    defer s.deinit();

    try s.add("prepared fixture", TestPrepareWitness.run, .{
        .prepare = TestPrepareWitness.prepare,
    });
    const results = try s.runSilent();

    try std.testing.expectEqual(@as(usize, 4), TestPrepareWitness.prepares);
    try std.testing.expectEqual(@as(usize, 4), TestPrepareWitness.calls);
    try std.testing.expectEqual(AllocationAttribution.none, results[0].allocation_attribution);
    try std.testing.expectEqual(@as(?u64, null), results[0].alloc_count);
    try std.testing.expectEqual(@as(?u64, null), results[0].alloc_bytes);
    try std.testing.expectEqual(@as(?u64, null), results[0].alloc_count_per_eval);
    try std.testing.expectEqual(@as(?u64, null), results[0].alloc_bytes_per_eval);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try s.writeJsonl(&out.writer, .{ .suite_name = "unattributed-suite" });
    const jsonl = out.written();
    try std.testing.expect(
        std.mem.indexOf(u8, jsonl, "\"allocation_attribution\":\"none\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"alloc_count\":null") != null);
}

test "suite attributes prepare owner traffic outside sample timing" {
    TestPrepareOwnerWitness.reset();
    var s = Suite.init(std.testing.allocator, .{
        .min_time_ns = 0,
        .min_iterations = 3,
        .max_iterations = 3,
        .warmup_iterations = 1,
        .evaluation = .{ .fixed = 1 },
        .allocation_attribution = .prepare_owner,
        .layout_randomization = null,
    });
    defer s.deinit();

    try s.add("prepare owner fixture", TestPrepareOwnerWitness.run, .{
        .prepare = TestPrepareOwnerWitness.prepare,
        .teardown = TestPrepareOwnerWitness.teardown,
    });
    const results = try s.runSilent();

    try std.testing.expectEqual(@as(usize, 4), TestPrepareOwnerWitness.prepares);
    try std.testing.expectEqual(@as(usize, 4), TestPrepareOwnerWitness.calls);
    try std.testing.expectEqual(@as(usize, 2), TestPrepareOwnerWitness.teardowns);
    try std.testing.expect(TestPrepareOwnerWitness.allocator == null);
    try std.testing.expectEqual(
        AllocationAttribution.prepare_owner,
        results[0].allocation_attribution,
    );
    try std.testing.expectEqual(@as(?u64, 6), results[0].alloc_count);
    try std.testing.expectEqual(@as(?u64, 6), results[0].free_count);
    try std.testing.expectEqual(@as(?u64, 144), results[0].alloc_bytes);
    try std.testing.expectEqual(@as(?u64, 2), results[0].alloc_count_per_eval);
    try std.testing.expectEqual(@as(?u64, 2), results[0].free_count_per_eval);
    try std.testing.expectEqual(@as(?u64, 48), results[0].alloc_bytes_per_eval);
}

test "suite attributes prepare owner resize traffic" {
    TestPrepareOwnerResizeWitness.reset();
    var backing: [512]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const result = try runOne(
        std.testing.allocator,
        fixed.allocator(),
        null,
        .{
            .name = "prepare owner resize",
            .func = TestPrepareOwnerResizeWitness.run,
            .config = .{
                .min_time_ns = 0,
                .min_iterations = 2,
                .max_iterations = 2,
                .warmup_iterations = 1,
                .evaluation = .{ .fixed = 1 },
                .prepare = TestPrepareOwnerResizeWitness.prepare,
                .teardown = TestPrepareOwnerResizeWitness.teardown,
                .allocation_attribution = .prepare_owner,
                .layout_randomization = null,
            },
        },
        try timing.probeClock(),
    );
    defer std.testing.allocator.free(result.samples);
    defer std.testing.allocator.free(result.sample_total_ns);

    try std.testing.expect(TestPrepareOwnerResizeWitness.allocator == null);
    try std.testing.expectEqual(@as(?u64, 2), result.alloc_count);
    try std.testing.expectEqual(@as(?u64, 2), result.free_count);
    try std.testing.expectEqual(@as(?u64, 96), result.alloc_bytes);
    try std.testing.expectEqual(@as(?u64, 1), result.alloc_count_per_eval);
    try std.testing.expectEqual(@as(?u64, 1), result.free_count_per_eval);
    try std.testing.expectEqual(@as(?u64, 48), result.alloc_bytes_per_eval);
}

test "suite rejects prepared batched evaluations" {
    var s = Suite.init(std.testing.allocator, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .evaluation = .{ .fixed = 2 },
        .layout_randomization = null,
    });
    defer s.deinit();

    try s.add("invalid prepared fixture", test_noop, .{
        .prepare = test_noop,
    });
    try std.testing.expectError(error.InvalidPreparedEvaluation, s.runSilent());
}

test "suite rejects incomplete prepare owner attribution" {
    var missing_teardown = Suite.init(std.testing.allocator, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .evaluation = .{ .fixed = 1 },
        .allocation_attribution = .prepare_owner,
        .layout_randomization = null,
    });
    defer missing_teardown.deinit();
    try missing_teardown.add("missing teardown", test_noop, .{
        .prepare = test_noop,
    });
    try std.testing.expectError(
        error.InvalidPrepareOwnerAttribution,
        missing_teardown.runSilent(),
    );

    var missing_prepare = Suite.init(std.testing.allocator, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .evaluation = .{ .fixed = 1 },
        .allocation_attribution = .prepare_owner,
        .layout_randomization = null,
    });
    defer missing_prepare.deinit();
    try missing_prepare.add("missing prepare", test_noop, .{
        .teardown = test_teardown_noop,
    });
    try std.testing.expectError(
        error.InvalidPrepareOwnerAttribution,
        missing_prepare.runSilent(),
    );
}

test "suite applies per-row layout randomization overrides" {
    const default_config: Config = .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .layout_randomization = null,
    };

    const enabled = applyConfigOverride(default_config, .{
        .layout_randomization = @as(?stabilizer.Config, .{
            .seed = 77,
            .heap = .{ .shuffle_slots = 3 },
            .code = .{ .enabled = false },
        }),
    });
    try std.testing.expectEqual(@as(u64, 77), enabled.layout_randomization.?.seed);
    try std.testing.expectEqual(@as(usize, 3), enabled.layout_randomization.?.heap.shuffle_slots);

    const disabled = applyConfigOverride(.{}, .{
        .layout_randomization = @as(?stabilizer.Config, null),
    });
    try std.testing.expect(disabled.layout_randomization == null);
}

test "suite tracks measured allocation counts" {
    const alloc = std.testing.allocator;
    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 2,
        .max_iterations = 2,
        .warmup_iterations = 1,
        .evaluation = .{ .fixed = 1 },
        .allocation_attribution = .sample_call,
        .layout_randomization = null,
    });
    defer s.deinit();

    try s.add("alloc", test_allocate_32_cc, .{});

    const results = try s.runSilent();
    try std.testing.expectEqual(@as(u32, 2), results[0].iterations);
    try std.testing.expectEqual(@as(u32, 1), results[0].evals);
    try std.testing.expectEqual(@as(u64, 2), results[0].alloc_count.?);
    try std.testing.expectEqual(@as(u64, 2), results[0].free_count.?);
    try std.testing.expectEqual(@as(u64, 64), results[0].alloc_bytes.?);
    try std.testing.expectEqual(@as(u64, 1), results[0].alloc_count_per_eval.?);
    try std.testing.expectEqual(@as(u64, 1), results[0].free_count_per_eval.?);
    try std.testing.expectEqual(@as(u64, 32), results[0].alloc_bytes_per_eval.?);
}

test "suite batches evals per timed sample" {
    const alloc = std.testing.allocator;
    TestCallCounter.reset();

    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 3,
        .max_iterations = 3,
        .evaluation = .{ .fixed = 4 },
        .warmup_iterations = 1,
        .layout_randomization = null,
    });
    defer s.deinit();

    try s.add("batched", TestCallCounter.run, .{});

    const results = try s.runSilent();
    try std.testing.expectEqual(@as(u32, 3), results[0].iterations);
    try std.testing.expectEqual(@as(u32, 4), results[0].evals);
    try std.testing.expectEqual(@as(u32, 16), TestCallCounter.count);
    try std.testing.expectEqual(@as(usize, 3), results[0].samples.len);
    try std.testing.expectEqual(@as(usize, 3), results[0].sample_total_ns.len);
    for (results[0].samples, results[0].sample_total_ns) |sample_ns, total_ns| {
        try std.testing.expect(total_ns >= sample_ns);
    }

    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    try s.writeJsonl(&out.writer, .{ .suite_name = "batched-suite" });
    const jsonl = out.written();
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"evals\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"sample_total_ns\":[") != null);
}

test "suite tracks allocation counts across batched evals" {
    const alloc = std.testing.allocator;
    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 2,
        .max_iterations = 2,
        .evaluation = .{ .fixed = 3 },
        .allocation_attribution = .sample_call,
        .layout_randomization = null,
    });
    defer s.deinit();

    try s.add("alloc batched", test_allocate_16_ee, .{});

    const results = try s.runSilent();
    try std.testing.expectEqual(@as(u32, 2), results[0].iterations);
    try std.testing.expectEqual(@as(u32, 3), results[0].evals);
    try std.testing.expectEqual(@as(u64, 6), results[0].alloc_count.?);
    try std.testing.expectEqual(@as(u64, 6), results[0].free_count.?);
    try std.testing.expectEqual(@as(u64, 96), results[0].alloc_bytes.?);
    try std.testing.expectEqual(@as(u64, 1), results[0].alloc_count_per_eval.?);
    try std.testing.expectEqual(@as(u64, 1), results[0].free_count_per_eval.?);
    try std.testing.expectEqual(@as(u64, 16), results[0].alloc_bytes_per_eval.?);
}

test "suite rejects zero eval batches" {
    const alloc = std.testing.allocator;
    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .evaluation = .{ .fixed = 0 },
    });
    defer s.deinit();

    try s.add("noop", test_noop, .{});

    try std.testing.expectError(error.InvalidEvalCount, s.runSilent());
}

test "suite writes comparable JSONL results" {
    const alloc = std.testing.allocator;
    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 2,
        .max_iterations = 2,
        .warmup_iterations = 1,
        .allocation_attribution = .sample_call,
        .layout_randomization = null,
    });
    defer s.deinit();

    try s.add("json row", test_allocate_8_aa, .{});

    _ = try s.runSilent();

    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    try s.writeJsonl(&out.writer, .{
        .suite_name = "suite-json-test",
        .output_path = "suite.jsonl",
        .metadata = .{
            .git_sha = "abc123",
            .git_dirty = true,
            .optimize = "ReleaseFast",
            .target = "native",
            .zig_version = "0.16.0",
            .host_os = "linux",
            .host_arch = "x86_64",
        },
    });

    const jsonl = out.written();
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"protocol\":\"bench.suite/v1\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, jsonl, "\"metadata\":{\"git_sha\":\"abc123\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"event\":\"bench_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"id\":\"json row\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"median_ns\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"p95_ns\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"clock\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"schema\":\"bench.clock/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"evaluation\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"mode\":\"automatic\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, jsonl, "\"calibration_confirmations\":") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"sample_ns\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"sample_total_ns\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"agent_evidence\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"code\":\"not_recorded\"") != null);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            jsonl,
            "\"allocation_attribution\":\"sample_call\"",
        ) != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"alloc_count\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"event\":\"run_end\"") != null);
}

test "suite writes row evidence from effective layout config" {
    const alloc = std.testing.allocator;
    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .layout_randomization = .{
            .seed = 77,
            .heap = .{ .shuffle_slots = 5 },
            .code = .{ .enabled = false },
        },
    });
    defer s.deinit();

    try s.add("default evidence", test_noop, .{});
    try s.add(
        "override evidence",
        test_noop,
        .{ .layout_randomization = @as(?stabilizer.Config, null) },
    );
    _ = try s.runSilent();

    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    try s.writeJsonl(&out.writer, .{ .suite_name = "evidence-suite" });

    const jsonl = out.written();
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"agent_evidence\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"stabilizer_config\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"pointer_validation\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"stabilizer_config\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"code\":\"not_randomized\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"code\":\"not_recorded\"") != null);
}

test "suite appends JSONL files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(std.Options.debug_io, tmp.sub_path[0..], alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "suite.jsonl" });
    defer alloc.free(path);

    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .layout_randomization = null,
    });
    defer s.deinit();
    try s.add("append row", test_noop, .{});
    _ = try s.runSilent();

    try s.appendJsonlFile(path, .{ .suite_name = "append-suite" });
    try s.appendJsonlFile(path, .{ .suite_name = "append-suite" });

    const jsonl = try sys.fs.readFileAlloc(alloc, path, 1024 * 1024);
    defer alloc.free(jsonl);
    var count: usize = 0;
    var rest = jsonl;
    while (std.mem.indexOf(u8, rest, "\"event\":\"bench_end\"")) |index| {
        count += 1;
        rest = rest[index + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "suite can leave environment JSONL to caller" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(std.Options.debug_io, tmp.sub_path[0..], alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "suite.jsonl" });
    defer alloc.free(path);

    var map = sys.env.Map.init(alloc);
    defer map.deinit();
    try map.put(jsonl_output_env, path);

    const block = try map.createPosixBlock(alloc, .{});
    defer block.deinit(alloc);

    const previous = sys.env.current();
    sys.env.installProcessEnvironment(.{ .block = block });
    defer sys.env.installProcessEnvironment(previous);

    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .layout_randomization = null,
    });
    defer s.deinit();
    try s.add("manual row", test_noop, .{});

    try s.runWithOptions(.{
        .write_stdout = false,
        .write_env_jsonl = false,
    });
    try std.testing.expectError(error.FileNotFound, sys.fs.readFileAlloc(alloc, path, 1024 * 1024));

    try s.appendJsonlFile(path, .{ .suite_name = "manual-suite" });
    const jsonl = try sys.fs.readFileAlloc(alloc, path, 1024 * 1024);
    defer alloc.free(jsonl);
    var count: usize = 0;
    var rest = jsonl;
    while (std.mem.indexOf(u8, rest, "\"event\":\"bench_end\"")) |index| {
        count += 1;
        rest = rest[index + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"suite\":\"manual-suite\"") != null);
}

test "suite reads Coz artifact environment paths" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var map = sys.env.Map.init(alloc);
    defer map.deinit();
    try map.put(coz_output_env, "out.coz.jsonl");
    try map.put(coz_analysis_env, "out.coz.analysis.json");

    const block = try map.createPosixBlock(alloc, .{});
    defer block.deinit(alloc);

    const previous = sys.env.current();
    sys.env.installProcessEnvironment(.{ .block = block });
    defer sys.env.installProcessEnvironment(previous);

    var env = try CozEnv.read(alloc);
    defer env.deinit(alloc);
    try std.testing.expectEqualStrings("out.coz.jsonl", env.output_path.?);
    try std.testing.expectEqualStrings("out.coz.analysis.json", env.analysis_path.?);
}

test "suite replaces the Coz analysis with the summary of the profile" {
    const io = sys.fs.debugIo();
    const profile_text =
        \\{"schema":"coz.profile/v1","event":"startup","timestamp_ns":1}
        \\{"schema":"coz.profile/v1","event":"experiment","selected":{"file":"src/work.zig","line":10},"virtual_speedup":0,"duration_ns":100,"selected_samples":1}
        \\{"schema":"coz.profile/v1","event":"throughput","name":"items","delta":10}
        \\{"schema":"coz.profile/v1","event":"experiment","selected":{"file":"src/work.zig","line":10},"virtual_speedup":0.5,"duration_ns":80,"selected_samples":2}
        \\{"schema":"coz.profile/v1","event":"throughput","name":"items","delta":10}
        \\{"schema":"coz.profile/v1","event":"runtime","duration_ns":200}
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bench.coz.jsonl", .data = profile_text });
    try tmp.dir.writeFile(io, .{ .sub_path = "bench.coz.analysis.json", .data = "stale" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const profile_path = try std.fs.path.join(arena, &.{ root, "bench.coz.jsonl" });
    const analysis_path = try std.fs.path.join(arena, &.{ root, "bench.coz.analysis.json" });

    try writeCozAnalysisFile(std.testing.allocator, profile_path, analysis_path);

    var summary = try coz.analysis.summarizeJsonLines(std.testing.allocator, profile_text, .{});
    defer summary.deinit(std.testing.allocator);
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    try summary.writeJson(&expected.writer);
    const written = try sys.fs.readFileAlloc(arena, analysis_path, 1024 * 1024);
    try std.testing.expectEqualStrings(expected.written(), written);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, written, .{});
    try std.testing.expectEqualStrings(coz.analysis.schema, parsed.object.get("schema").?.string);

    var entries = tmp.dir.iterate();
    var entry_count: usize = 0;
    while (try entries.next(io)) |_| entry_count += 1;
    try std.testing.expectEqual(@as(usize, 2), entry_count);
}

test "suite reads Tracy artifact environment paths" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var map = sys.env.Map.init(alloc);
    defer map.deinit();
    try map.put(tracy_output_env, "out.tracy.jsonl");
    try map.put(tracy_summary_env, "out.tracy.summary.jsonl");

    const block = try map.createPosixBlock(alloc, .{});
    defer block.deinit(alloc);

    const previous = sys.env.current();
    sys.env.installProcessEnvironment(.{ .block = block });
    defer sys.env.installProcessEnvironment(previous);

    var env = try TracyEnv.read(alloc);
    defer env.deinit(alloc);
    try std.testing.expectEqualStrings("out.tracy.jsonl", env.output_path.?);
    try std.testing.expectEqualStrings("out.tracy.summary.jsonl", env.summary_path.?);
}

test "suite rejects a Tracy summary without an event stream" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var map = sys.env.Map.init(alloc);
    defer map.deinit();
    try map.put(tracy_summary_env, "out.tracy.summary.jsonl");
    const block = try map.createPosixBlock(alloc, .{});
    defer block.deinit(alloc);
    const previous = sys.env.current();
    sys.env.installProcessEnvironment(.{ .block = block });
    defer sys.env.installProcessEnvironment(previous);

    try std.testing.expectError(error.InvalidTracyEnvironment, TracyEnv.read(alloc));
}

test "suite owns enabled Tracy capture lifecycle" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;
    if (!tracy.enabled) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(std.Options.debug_io, tmp.sub_path[0..], alloc);
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "bench.tracy.jsonl" });
    defer alloc.free(trace_path);
    const summary_path = try std.fs.path.join(alloc, &.{ root, "bench.tracy.summary.jsonl" });
    defer alloc.free(summary_path);

    var map = sys.env.Map.init(alloc);
    defer map.deinit();
    try map.put(tracy_output_env, trace_path);
    try map.put(tracy_summary_env, summary_path);
    const block = try map.createPosixBlock(alloc, .{});
    defer block.deinit(alloc);
    const previous = sys.env.current();
    sys.env.installProcessEnvironment(.{ .block = block });
    defer sys.env.installProcessEnvironment(previous);

    var suite = Suite.init(alloc, .{
        .suite_name = "tracy-lifecycle",
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .layout_randomization = null,
    });
    defer suite.deinit();
    try suite.add("capture", test_noop, .{});
    try suite.runWithOptions(.{ .write_stdout = false, .write_env_jsonl = false });

    const trace_jsonl = try sys.fs.readFileAlloc(alloc, trace_path, 1024 * 1024);
    defer alloc.free(trace_jsonl);
    const summary_jsonl = try sys.fs.readFileAlloc(alloc, summary_path, 1024 * 1024);
    defer alloc.free(summary_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, trace_jsonl, "\"kind\":\"start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace_jsonl, "bench.suite.run") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace_jsonl, "\"kind\":\"plot.config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace_jsonl, "\"plot_unit\":\"count\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, trace_jsonl, "\"plot_unit\":\"nanoseconds\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, summary_jsonl, "\"kind\":\"summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_jsonl, "\"kind\":\"zone\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, summary_jsonl, "\"plot_configurations\":3") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, summary_jsonl, "\"unit\":\"count\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, summary_jsonl, "\"unit\":\"nanoseconds\"") != null,
    );
}

test "suite writes scoped allocation memtrace events" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(std.Options.debug_io, tmp.sub_path[0..], alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "scoped-allocations.jsonl" });
    defer alloc.free(path);

    var map = sys.env.Map.init(alloc);
    defer map.deinit();
    try map.put(scoped_allocations_env, path);

    const block = try map.createPosixBlock(alloc, .{});
    defer block.deinit(alloc);

    const previous = sys.env.current();
    sys.env.installProcessEnvironment(.{ .block = block });
    defer sys.env.installProcessEnvironment(previous);

    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 1,
        .max_iterations = 1,
        .allocation_attribution = .sample_call,
        .evaluation = .{ .fixed = 1 },
        .layout_randomization = null,
    });
    defer s.deinit();

    try s.add("scoped row", test_allocate_32_cc, .{});

    _ = try s.runSilent();

    const events = try sys.fs.readFileAlloc(alloc, path, 1024 * 1024);
    defer alloc.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"alloc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"scope\":\"root/scoped row/sample\"") != null);
}

test "suite tracks allocations through layout randomization" {
    const alloc = std.testing.allocator;
    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 3,
        .max_iterations = 3,
        .evaluation = .{ .fixed = 1 },
        .allocation_attribution = .sample_call,
        .layout_randomization = .{
            .seed = 123,
            .heap = .{
                .shuffle_slots = 4,
                .max_shuffled_size = 1024,
            },
            .code = .{ .enabled = false },
        },
    });
    defer s.deinit();

    try s.add("alloc", test_allocate_16_dd, .{});

    const results = try s.runSilent();
    try std.testing.expectEqual(@as(u32, 3), results[0].iterations);
    try std.testing.expectEqual(@as(u32, 1), results[0].evals);
    try std.testing.expectEqual(@as(u64, 3), results[0].alloc_count.?);
    try std.testing.expectEqual(@as(u64, 3), results[0].free_count.?);
    try std.testing.expectEqual(@as(u64, 48), results[0].alloc_bytes.?);
}

test "suite runs definitions through layout randomized allocator" {
    const alloc = std.testing.allocator;
    var s = Suite.init(alloc, .{
        .min_time_ns = 0,
        .min_iterations = 4,
        .max_iterations = 4,
    });
    defer s.deinit();

    try s.add("alloc", test_allocate_64_cc, .{});

    const results = try s.runSilent();
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u32, 4), results[0].iterations);
}
