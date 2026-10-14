const std = @import("std");

const balance = @import("balance.zig");
const command = @import("command.zig");
const options = @import("options.zig");

pub const receipt_directory_option = options.directory_option;
pub const receipt_token_option = options.token_option;
pub const receipt_directory_environment = options.directory_environment;
pub const receipt_token_environment = options.token_environment;
pub const shard_count_environment = options.shard_count_environment;

/// Read once by the package and pass the effective policy to every simple run.
/// The argv, including an explicit zero, is an ordinary run-cache input.
pub const TestTimeout = struct {
    milliseconds: u64 = 0,
    /// Whether a run may give a listed test its own deadline. A qualification build never
    /// may: it certifies one deadline for every test.
    exceptions: bool = false,

    /// The deadline both `required` and `exceptions` hold every unlisted test to.
    pub const qualification_ms: u64 = 120000;

    /// One test's own deadline, for a test measured above `qualification_ms`.
    pub const Exception = struct {
        /// The test's full name, as the runner prints it.
        name: []const u8,
        milliseconds: u64,
    };

    pub fn read(b: *std.Build) TestTimeout {
        const text = b.option([]const u8, "timing-test-timeout-ms", "Awake deadline for each test including teardown, in milliseconds (0 disables)") orelse "0";
        const required = b.option(bool, "timing-test-timeout-required", "Require the 120000 ms qualification deadline") orelse false;
        const exceptions = b.option(bool, "timing-test-deadline-exceptions", "Give each listed test its own deadline beside the 120000 ms default; refused in a qualification build") orelse false;
        const milliseconds = command.timeoutValue(text) catch |err|
            std.debug.panic("invalid timing-test-timeout-ms: {s}", .{@errorName(err)});
        validate(milliseconds, required, exceptions) catch |err| switch (err) {
            error.RequiredTestTimeout => std.debug.panic("qualification requires timing-test-timeout-ms=120000", .{}),
            error.ExceptionsRequireDefault => std.debug.panic("timing-test-deadline-exceptions requires timing-test-timeout-ms=120000", .{}),
            error.QualificationRefusesExceptions => std.debug.panic("timing-test-timeout-required refuses timing-test-deadline-exceptions: qualification certifies one deadline for every test", .{}),
        };
        return .{ .milliseconds = milliseconds, .exceptions = exceptions };
    }

    pub fn apply(self: TestTimeout, b: *std.Build, run: *std.Build.Step.Run) void {
        // The build runner's own `--test-timeout` acts only on a run in its test-server
        // mode. A run that takes this deadline must stay out of that mode, or a second
        // killer would end a listed test at the build runner's value.
        std.debug.assert(run.stdio != .zig_test);
        run.addArg(b.fmt("{s}={d}", .{ command.timeout_flag, self.milliseconds }));
    }

    /// Gives `exception`'s test its own deadline in `run`, whose binary must hold that
    /// test. Does nothing unless the build admits exceptions.
    pub fn except(self: TestTimeout, b: *std.Build, run: *std.Build.Step.Run, exception: Exception) void {
        if (!self.exceptions) return;
        std.debug.assert(self.milliseconds == qualification_ms);
        std.debug.assert(exception.milliseconds > self.milliseconds);
        std.debug.assert(exception.milliseconds <= command.deadline_max_ms);
        run.addArg(b.fmt("{s}={d}={s}", .{ command.deadline_flag, exception.milliseconds, exception.name }));
    }

    fn validate(milliseconds: u64, required: bool, exceptions: bool) !void {
        if (required and exceptions) return error.QualificationRefusesExceptions;
        if (required and milliseconds != qualification_ms) return error.RequiredTestTimeout;
        if (exceptions and milliseconds != qualification_ms) return error.ExceptionsRequireDefault;
    }
};

pub fn addFocusedRun(
    b: *std.Build,
    run: *std.Build.Step.Run,
    output_name: []const u8,
) std.Build.LazyPath {
    run.setEnvironmentVariable(options.supervised_environment, "1");
    run.setEnvironmentVariable(
        options.supervisor_deadline_environment,
        b.fmt("{d}", .{options.supervised_deadline_ms}),
    );
    run.setEnvironmentVariable(
        options.supervisor_heartbeat_environment,
        b.fmt("{d}", .{options.supervised_heartbeat_ms}),
    );
    run.setEnvironmentVariable("TINY_TIMING_RUNNER_REPORT", "0");
    run.stdio = .inherit;
    run.addArg(command.supervised_receipts_flag);
    return run.addOutputDirectoryArg(output_name);
}

/// The executable search path a cached test run sees. It is part of the cache key, so it is
/// pinned rather than inherited: a shell with a different PATH still hits the cache.
pub const cached_run_path = "/usr/bin:/bin";

/// Runner variables that change which tests run or what they report.
const cached_runner_environment = [_][]const u8{
    "TINY_TIMING_RUNNER_FILTER",
    "TINY_TIMING_RUNNER_ALLOW_EMPTY_FILTER",
    "TINY_TIMING_RUNNER_REPEAT",
    "TINY_TIMING_RUNNER_REPORT",
    "TINY_TIMING_RUNNER_PROGRESS",
    // `disk` keeps a run's tree in its cached output directory and `memory` asks for a
    // memory-backed one, whatever the package's build requested.
    "TINY_TIMING_RUNNER_TREE",
};

/// These modes run child processes or write receipts outside the cached tree. Their
/// environment and output contracts belong to those modes, so the ordinary cached run
/// leaves them on the original side-effecting path.
const uncached_runner_environment = [_][]const u8{
    options.directory_environment,
    options.token_environment,
    options.shard_count_environment,
    options.shard_index_environment,
    options.external_shard_environment,
    "TINY_TIMING_RUNNER_SHARD_CHILD",
    "TINY_TIMING_RUNNER_SHARD_PORT",
    options.supervised_environment,
    options.supervisor_child_environment,
    options.supervisor_order_environment,
    options.supervisor_deadline_environment,
    options.supervisor_heartbeat_environment,
};

pub const CachedRunInput = struct {
    /// Repository-relative path the tests reach from `cwd`.
    path: []const u8,
    /// The file whose bytes the run's cache key covers.
    source: std.Build.LazyPath,
};

pub const CachedRunOptions = struct {
    /// Repository-relative working directory the tests expect, such as `lib/research/chic`.
    cwd: []const u8,
    /// Every file a test reads at run time. A read of any other relative path fails.
    inputs: []const CachedRunInput = &.{},
    /// Variables a test reads, copied from the build's environment at configure time.
    environment: []const []const u8 = &.{},
    /// Where the run's tree lives. `memory` suits tests that force many small writes, and
    /// the runner falls back to disk when no memory-backed directory has room.
    tree: TreeStore = .disk,
};

pub const TreeStore = enum { disk, memory };

/// Makes a timing-runner test run cacheable. Its key covers the test binary, arguments,
/// declared inputs and every variable the run can see. The tests run in a private tree of
/// the declared inputs, and the run's standard error is captured to the returned report.
/// A build that sets the receipt directory keeps the run uncached, because receipts land
/// outside the cache.
pub fn addCachedRun(
    b: *std.Build,
    run: *std.Build.Step.Run,
    run_options: CachedRunOptions,
) ?std.Build.LazyPath {
    std.debug.assert(run.stdio == .infer_from_args);
    for (uncached_runner_environment) |name| {
        if (b.graph.environ_map.get(name) != null) {
            run.has_side_effects = true;
            return null;
        }
    }
    run.clearEnvironment();
    run.setEnvironmentVariable("PATH", cached_run_path);
    run.setEnvironmentVariable(
        "TINY_TIMING_RUNNER_COLOR",
        b.graph.environ_map.get("TINY_TIMING_RUNNER_COLOR") orelse "0",
    );
    for (cached_runner_environment) |name| copyEnvironment(b, run, name);
    for (run_options.environment) |name| copyEnvironment(b, run, name);
    _ = run.addPrefixedOutputDirectoryArg(command.tree_flag ++ "=", "tree");
    run.addArg(b.fmt("{s}={s}", .{ command.cwd_flag, run_options.cwd }));
    if (run_options.tree == .memory) run.addArg(command.tree_store_flag ++ "=memory");
    for (run_options.inputs) |input| {
        const flag = b.fmt("{s}={s}=", .{ command.input_flag, input.path });
        run.addPrefixedFileArg(flag, input.source);
    }
    return run.captureStdErr(.{ .basename = "report.txt" });
}

fn copyEnvironment(b: *std.Build, run: *std.Build.Step.Run, name: []const u8) void {
    const inherited = b.graph.environ_map.get(name) orelse return;
    run.setEnvironmentVariable(name, inherited);
}

pub const ShardedRunOptions = struct {
    timeout: TestTimeout = .{},
    /// The cached-run options every shard shares. Null runs every shard uncached, for a
    /// build whose environment asks the tests for writes outside the cache.
    cached: ?CachedRunOptions,
    /// Shard processes. The lane that runs them declares the same count as `max_jobs`.
    shards: u32,
    /// The recorded test weights every shard assigns from. Its bytes key every shard.
    weights: std.Build.LazyPath,
    /// Each shard's `max_rss`: the reservation the build runner schedules shards against
    /// inside `--maxrss`. The pinned runner reports a shard that peaks above it and still
    /// counts the step a success, so this bounds concurrency, not a shard's memory.
    shard_rss: usize,
    /// The merge tool's source, `timing/merge.zig` in this package.
    merge_source: std.Build.LazyPath,
    /// The largest binary, in bytes, a shard runs. A larger binary fails every shard before
    /// its first test. Null admits any size.
    maximum_binary_bytes: ?u64 = null,
};

pub const ShardedRun = struct {
    shard_runs: []const *std.Build.Step.Run,
    merge_run: *std.Build.Step.Run,
    merge_compile: *std.Build.Step.Compile,
    /// Every shard's results in one report, after the merge checks coverage.
    report: std.Build.LazyPath,
    /// A weights table measured by this run.
    weights: std.Build.LazyPath,
    /// Each shard's captured report. An uncached run has none.
    shard_reports: []const ?std.Build.LazyPath,
};

/// Runs one timing-runner binary as `shards` cached external shards, each taking its
/// longest-processing-time-first share from `weights`, and merges their rows. Each shard's
/// argv starts from `addCachedRun`, so whatever that helper adds reaches every shard. The
/// shard index and count are set after it clears the environment, so both key the run.
pub fn addShardedRun(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    run_options: ShardedRunOptions,
) ShardedRun {
    std.debug.assert(run_options.shards > 0);
    std.debug.assert(run_options.shards <= balance.max_shards);
    std.debug.assert(run_options.shard_rss > 0);
    const merge = b.addExecutable(.{
        .name = "timing-merge",
        .root_module = b.createModule(.{
            .root_source_file = run_options.merge_source,
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const merged = b.addRunArtifact(merge);
    merged.setName(b.fmt("merge {s} shards", .{compile.name}));
    merged.step.max_rss = merge_rss;
    merged.addArg("--weights");
    merged.addFileArg(run_options.weights);
    merged.addArg("--report");
    const report = merged.addOutputFileArg("report.txt");
    merged.addArg("--table");
    const table = merged.addOutputFileArg("weights.tsv");
    const shard_reports = b.allocator.alloc(?std.Build.LazyPath, run_options.shards) catch
        @panic("OOM");
    const shard_runs = b.allocator.alloc(*std.Build.Step.Run, run_options.shards) catch @panic("OOM");
    for (shard_reports, shard_runs, 0..) |*shard_report, *shard_run, index| {
        const run = b.addRunArtifact(compile);
        shard_run.* = run;
        run.setName(b.fmt("{s} shard {d}/{d}", .{ compile.name, index + 1, run_options.shards }));
        run_options.timeout.apply(b, run);
        shard_report.* = if (run_options.cached) |cached| addCachedRun(b, run, cached) else null;
        if (run_options.cached == null) run.has_side_effects = true;
        run.setEnvironmentVariable(options.external_shard_environment, "1");
        run.setEnvironmentVariable(
            options.shard_count_environment,
            b.fmt("{d}", .{run_options.shards}),
        );
        run.setEnvironmentVariable(options.shard_index_environment, b.fmt("{d}", .{index}));
        run.addPrefixedFileArg(command.weights_flag ++ "=", run_options.weights);
        if (run_options.maximum_binary_bytes) |bytes| {
            run.addArg(b.fmt("{s}={d}", .{ command.binary_limit_flag, bytes }));
        }
        merged.addFileArg(run.addPrefixedOutputFileArg(command.rows_flag ++ "=", "rows.tsv"));
        run.step.max_rss = run_options.shard_rss;
    }
    return .{ .report = report, .weights = table, .shard_reports = shard_reports, .shard_runs = shard_runs, .merge_run = merged, .merge_compile = merge };
}

/// The merge holds every shard's rows at once: a few MiB for the largest binary.
const merge_rss: usize = 256 * 1024 * 1024;
