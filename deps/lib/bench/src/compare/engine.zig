const std = @import("std");
const bench_bootstrap = @import("bench_bootstrap");
const pretty_json = @import("pretty").json;
const sys = @import("sys");

const capacity_mod = @import("capacity.zig");
const storage_mod = @import("storage.zig");

const Allocator = std.mem.Allocator;

pub const Limits = capacity_mod.Limits;
pub const Capacity = capacity_mod.Capacity;
pub const CapacityError = capacity_mod.DeriveError;
pub const Storage = storage_mod.Storage;
pub const StorageStatus = storage_mod.Status;
pub const StorageExhaustion = storage_mod.Exhaustion;
pub const StorageError = storage_mod.Error;

pub const max_profile_bytes = 64 * 1024 * 1024;
pub const default_threshold = 1.05;
pub const default_min_runs: u32 = 10;
pub const default_bootstrap_iterations: u32 = 1000;
pub const bootstrap_seed: u64 = 0x5449_4e59_434f_4d50;
pub const confidence_per_mille: u16 = 950;
pub const effect_confidence: f64 =
    @as(f64, @floatFromInt(confidence_per_mille)) / 1000.0;
pub const effect_method =
    "deterministic_percentile_bootstrap_unpaired_execution_median_percent_change";

pub const Options = struct {
    baseline_path: []const u8,
    candidate_path: []const u8,
    threshold: f64 = default_threshold,
    min_runs: u32 = default_min_runs,
    bootstrap_iterations: u32 = default_bootstrap_iterations,
};

pub const Counts = struct {
    compared: u64 = 0,
    regressions: u64 = 0,
    improvements: u64 = 0,
    unchanged: u64 = 0,
    uncertain: u64 = 0,
    insufficient: u64 = 0,
    missing_baseline: u64 = 0,
    missing_candidate: u64 = 0,
};

pub const Classification = enum {
    regression,
    improvement,
    unchanged,
    uncertain,
    insufficient,

    pub fn jsonName(self: Classification) []const u8 {
        return switch (self) {
            .regression => "regression",
            .improvement => "improvement",
            .unchanged => "unchanged",
            .uncertain => "uncertain",
            .insufficient => "insufficient",
        };
    }
};

pub const EffectInterval = struct {
    low_percent: f64,
    high_percent: f64,
};

pub const ExecutionObservation = struct {
    mean: f64,
    median: f64,
};

pub const ExecutionStats = struct {
    runs: usize,
    mean: f64,
    median: f64,
    min: f64,
    max: f64,
};

pub const ExecutionAnalysisOptions = struct {
    threshold: f64 = default_threshold,
    min_runs: u32 = default_min_runs,
    bootstrap_iterations: u32 = default_bootstrap_iterations,
};

pub const ExecutionComparison = struct {
    classification: Classification,
    baseline: ExecutionStats,
    candidate: ExecutionStats,
    ratio: ?f64,
    effect: ?EffectInterval,
    bootstrap_iterations: u32,
    evidence: []const u8,
};

pub const U64MedianRatio = struct {
    baseline_median: u64,
    candidate_median: u64,
    ratio: f64,
    low_ratio: f64,
    high_ratio: f64,
};

pub const parseArgs = parseComparisonArgs;

fn parseComparisonArgs(args: []const []const u8) !Options {
    if (args.len < 2) return error.InvalidArguments;
    if (args[0].len == 0 or args[0][0] == '-') return error.InvalidArguments;
    if (args[1].len == 0 or args[1][0] == '-') return error.InvalidArguments;
    var options = Options{
        .baseline_path = args[0],
        .candidate_path = args[1],
    };
    var threshold_specified = false;
    var min_runs_specified = false;
    var bootstrap_iterations_specified = false;
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--threshold")) {
            if (threshold_specified) return error.InvalidArguments;
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.threshold = parseThreshold(args[index]) catch return error.InvalidArguments;
            threshold_specified = true;
        } else if (std.mem.eql(u8, arg, "--min-runs")) {
            if (min_runs_specified) return error.InvalidArguments;
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.min_runs = std.fmt.parseUnsigned(u32, args[index], 10) catch
                return error.InvalidArguments;
            if (options.min_runs == 0) return error.InvalidArguments;
            min_runs_specified = true;
        } else if (std.mem.eql(u8, arg, "--bootstrap-iterations")) {
            if (bootstrap_iterations_specified) return error.InvalidArguments;
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.bootstrap_iterations = std.fmt.parseUnsigned(u32, args[index], 10) catch
                return error.InvalidArguments;
            if (options.bootstrap_iterations == 0) return error.InvalidArguments;
            bootstrap_iterations_specified = true;
        } else {
            return error.InvalidArguments;
        }
    }
    return options;
}

fn parseThreshold(text: []const u8) !f64 {
    const value = try std.fmt.parseFloat(f64, text);
    if (!std.math.isFinite(value) or value < 1.0) return error.InvalidThreshold;
    return value;
}

fn assertOptions(options: Options) void {
    std.debug.assert(options.baseline_path.len > 0);
    std.debug.assert(options.candidate_path.len > 0);
    std.debug.assert(std.math.isFinite(options.threshold));
    std.debug.assert(options.threshold >= 1.0);
    std.debug.assert(options.min_runs > 0);
    std.debug.assert(options.bootstrap_iterations > 0);
}

fn RowGroup(comptime Row: type) type {
    return struct {
        row: Row,
        observations: std.ArrayListUnmanaged(ExecutionObservation) = .empty,
        last_run: u64,

        fn deinit(self: *@This(), allocator: Allocator) void {
            self.row.deinit(allocator);
            self.observations.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn RowMap(comptime Row: type) type {
    return std.StringHashMapUnmanaged(RowGroup(Row));
}

fn RowOrder(comptime Row: type) type {
    return struct {
        fn lessThan(_: void, left: *const RowGroup(Row), right: *const RowGroup(Row)) bool {
            return std.mem.lessThan(u8, left.row.key, right.row.key);
        }
    };
}

pub fn SummaryComparison(comptime Spec: type) type {
    return struct {
        pub fn runFiles(
            allocator: Allocator,
            out: *std.Io.Writer,
            args: []const []const u8,
        ) !u8 {
            return runComparisonFiles(Spec, allocator, out, args);
        }

        pub fn parseArgs(args: []const []const u8) !Options {
            return parseComparisonArgs(args);
        }

        pub fn compareSources(
            allocator: Allocator,
            out: *std.Io.Writer,
            options: Options,
            baseline_source: []const u8,
            candidate_source: []const u8,
        ) !Counts {
            return compareSummarySources(
                Spec,
                allocator,
                out,
                options,
                baseline_source,
                candidate_source,
            );
        }
    };
}

fn runComparisonFiles(
    comptime Spec: type,
    allocator: Allocator,
    out: *std.Io.Writer,
    args: []const []const u8,
) !u8 {
    const options = try parseComparisonArgs(args);
    const baseline = try sys.fs.readFileAlloc(
        allocator,
        options.baseline_path,
        max_profile_bytes,
    );
    defer allocator.free(baseline);
    const candidate = try sys.fs.readFileAlloc(
        allocator,
        options.candidate_path,
        max_profile_bytes,
    );
    defer allocator.free(candidate);
    _ = try compareSummarySources(Spec, allocator, out, options, baseline, candidate);
    return 0;
}

fn compareSummarySources(
    comptime Spec: type,
    allocator: Allocator,
    out: *std.Io.Writer,
    options: Options,
    baseline_source: []const u8,
    candidate_source: []const u8,
) !Counts {
    assertOptions(options);
    var baseline = try loadRows(Spec, allocator, baseline_source);
    defer deinitRows(Spec.Row, allocator, &baseline);
    var candidate = try loadRows(Spec, allocator, candidate_source);
    defer deinitRows(Spec.Row, allocator, &candidate);
    return compareRows(Spec, allocator, out, options, &baseline, &candidate);
}

pub fn compareRows(
    comptime Spec: type,
    allocator: Allocator,
    out: *std.Io.Writer,
    options: Options,
    baseline: *RowMap(Spec.Row),
    candidate: *RowMap(Spec.Row),
) !Counts {
    var counts = Counts{};
    try writeStart(Spec, out, options, baseline.count(), candidate.count());
    const baseline_rows = try sortedRowPointers(Spec.Row, allocator, baseline);
    defer allocator.free(baseline_rows);
    const candidate_rows = try sortedRowPointers(Spec.Row, allocator, candidate);
    defer allocator.free(candidate_rows);
    const max_samples = @max(
        maxRowSamples(Spec.Row, baseline_rows),
        maxRowSamples(Spec.Row, candidate_rows),
    );
    var comparison_storage: ?Storage = if (max_samples == 0)
        null
    else
        try Storage.init(allocator, .{
            .max_samples_per_series = max_samples,
            .max_bootstrap_iterations = options.bootstrap_iterations,
        });
    defer if (comparison_storage) |*storage| storage.deinit(allocator);
    if (comparison_storage) |*storage| storage.activate();

    for (baseline_rows) |base| {
        if (candidate.getPtr(base.row.key)) |cand| {
            if (@hasDecl(Spec, "validatePair")) {
                try Spec.validatePair(base.row, cand.row);
            }
            std.debug.assert(comparison_storage != null);
            const result = try analyzeExecutions(
                &comparison_storage.?,
                base.observations.items,
                cand.observations.items,
                .{
                    .threshold = options.threshold,
                    .min_runs = options.min_runs,
                    .bootstrap_iterations = options.bootstrap_iterations,
                },
            );
            recordClassification(&counts, result.classification);
            try writeComparison(Spec, out, base.row, cand.row, result);
        } else {
            counts.missing_candidate += 1;
            std.debug.assert(comparison_storage != null);
            try writeMissing(Spec, &comparison_storage.?, out, "candidate", base.*);
        }
    }
    for (candidate_rows) |cand| {
        if (baseline.contains(cand.row.key)) continue;
        counts.missing_baseline += 1;
        std.debug.assert(comparison_storage != null);
        try writeMissing(Spec, &comparison_storage.?, out, "baseline", cand.*);
    }
    try writeEnd(Spec, out, options, counts);
    return counts;
}

fn maxRowSamples(
    comptime Row: type,
    rows: []const *const RowGroup(Row),
) usize {
    var max_samples: usize = 0;
    for (rows) |row| max_samples = @max(max_samples, row.observations.items.len);
    return max_samples;
}

pub fn loadRows(
    comptime Spec: type,
    allocator: Allocator,
    source: []const u8,
) !RowMap(Spec.Row) {
    var map: RowMap(Spec.Row) = .{};
    errdefer deinitRows(Spec.Row, allocator, &map);
    var run_open = false;
    var run_count: u64 = 0;
    var run_summaries: u64 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = parseJsonLine(allocator, line) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidProfileJsonl,
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidProfileJsonl,
        };
        const kind = objectStringOptional(object, "kind") orelse continue;
        const benchmark = objectStringOptional(object, "benchmark") orelse "";
        if (!std.mem.eql(u8, benchmark, Spec.benchmark_name)) continue;
        if (std.mem.eql(u8, kind, "run")) {
            const was_open = run_open;
            try updateRunState(object, &run_open, &run_count);
            if (!was_open and run_open) run_summaries = 0;
            if (was_open and !run_open and run_summaries == 0) {
                return error.MissingSummaryInRun;
            }
        } else if (std.mem.eql(u8, kind, "summary")) {
            if (!run_open) return error.MissingRunStart;
            try appendSummary(Spec, allocator, &map, object, run_count);
            run_summaries = std.math.add(u64, run_summaries, 1) catch
                return error.TooManySummaries;
        }
    }
    if (run_open) return error.MissingRunEnd;
    if (run_count == 0) return error.MissingRunStart;
    std.debug.assert(run_count <= source.len);
    return map;
}

fn appendSummary(
    comptime Spec: type,
    allocator: Allocator,
    map: *RowMap(Spec.Row),
    object: std.json.ObjectMap,
    run: u64,
) !void {
    var row = try Spec.parseRow(allocator, object);
    var row_owned = true;
    defer if (row_owned) row.deinit(allocator);
    if (map.getPtr(row.key)) |group| {
        if (group.last_run == run) return error.DuplicateSummaryInRun;
        std.debug.assert(group.last_run < run);
        if (@hasDecl(Spec, "validateRepeat")) {
            try Spec.validateRepeat(group.row, row);
        }
        try group.observations.append(allocator, observation(row));
        group.last_run = run;
        return;
    }

    var observations: std.ArrayListUnmanaged(ExecutionObservation) = .empty;
    errdefer observations.deinit(allocator);
    try observations.append(allocator, observation(row));
    try map.put(allocator, row.key, .{
        .row = row,
        .observations = observations,
        .last_run = run,
    });
    row_owned = false;
}

fn sortedRowPointers(
    comptime Row: type,
    allocator: Allocator,
    map: *RowMap(Row),
) ![]*const RowGroup(Row) {
    const rows = try allocator.alloc(*const RowGroup(Row), map.count());
    var index: usize = 0;
    var iter = map.valueIterator();
    while (iter.next()) |row| {
        rows[index] = row;
        index += 1;
    }
    std.debug.assert(index == rows.len);
    std.mem.sort(*const RowGroup(Row), rows, {}, RowOrder(Row).lessThan);
    return rows;
}

pub fn deinitRows(
    comptime Row: type,
    allocator: Allocator,
    map: *RowMap(Row),
) void {
    var iter = map.valueIterator();
    while (iter.next()) |row| row.deinit(allocator);
    map.deinit(allocator);
}

fn writeStart(
    comptime Spec: type,
    out: *std.Io.Writer,
    options: Options,
    baseline_count: usize,
    candidate_count: usize,
) !void {
    var stream = pretty_json.Writer.init(out, .minified);
    const object = try stream.object();
    try object.field("kind", "compare");
    try object.field("benchmark", Spec.benchmark_name);
    try object.field("protocol", Spec.protocol_name);
    try object.field("event", "start");
    try object.field("baseline", options.baseline_path);
    try object.field("candidate", options.candidate_path);
    try object.field("threshold", options.threshold);
    try object.field("minimum_runs", options.min_runs);
    try object.field("confidence", effect_confidence);
    try object.field("bootstrap_iterations", options.bootstrap_iterations);
    try object.field("effect_method", effect_method);
    try object.field("baseline_summaries", baseline_count);
    try object.field("candidate_summaries", candidate_count);
    try object.endLine();
}

fn writeComparison(
    comptime Spec: type,
    out: *std.Io.Writer,
    baseline: Spec.Row,
    candidate: Spec.Row,
    result: ExecutionComparison,
) !void {
    var stream = pretty_json.Writer.init(out, .minified);
    const object = try stream.object();
    try object.field("kind", "comparison");
    try object.field("benchmark", Spec.benchmark_name);
    try object.field("summary", baseline.summary);
    try object.field("name", baseline.name);
    try Spec.writeIdentity(object, baseline);
    try object.field("classification", result.classification.jsonName());
    try object.field("evidence", result.evidence);
    try writeExecutionFields(object, result);
    if (@hasDecl(Spec, "writeComparisonExtra")) {
        try Spec.writeComparisonExtra(object, baseline, candidate);
    }
    try object.endLine();
}

fn writeExecutionFields(
    object: pretty_json.Object,
    result: ExecutionComparison,
) !void {
    try object.field("baseline_runs", result.baseline.runs);
    try object.field("candidate_runs", result.candidate.runs);
    try object.field("baseline_mean", result.baseline.mean);
    try object.field("candidate_mean", result.candidate.mean);
    try object.field("delta", result.candidate.mean - result.baseline.mean);
    try object.field("baseline_median", result.baseline.median);
    try object.field("candidate_median", result.candidate.median);
    try object.field(
        "median_delta",
        result.candidate.median - result.baseline.median,
    );
    try object.field("baseline_min", result.baseline.min);
    try object.field("candidate_min", result.candidate.min);
    try object.field("baseline_max", result.baseline.max);
    try object.field("candidate_max", result.candidate.max);
    try object.field("ratio", result.ratio);
    try writeEffect(object, result.effect, result.bootstrap_iterations);
}

fn writeMissing(
    comptime Spec: type,
    storage: *Storage,
    out: *std.Io.Writer,
    missing: []const u8,
    group: RowGroup(Spec.Row),
) !void {
    const execution = try summarizeExecutions(storage, group.observations.items);
    var stream = pretty_json.Writer.init(out, .minified);
    const object = try stream.object();
    try object.field("kind", "missing");
    try object.field("benchmark", Spec.benchmark_name);
    try object.field("missing", missing);
    try object.field("summary", group.row.summary);
    try object.field("name", group.row.name);
    try Spec.writeIdentity(object, group.row);
    if (@hasDecl(Spec, "writeMissingExtra")) {
        try Spec.writeMissingExtra(object, group.row);
    }
    try object.field("runs", execution.runs);
    try object.field("mean", execution.mean);
    try object.field("median", execution.median);
    try object.endLine();
}

fn writeEnd(
    comptime Spec: type,
    out: *std.Io.Writer,
    options: Options,
    counts: Counts,
) !void {
    var stream = pretty_json.Writer.init(out, .minified);
    const object = try stream.object();
    try object.field("kind", "compare");
    try object.field("benchmark", Spec.benchmark_name);
    try object.field("protocol", Spec.protocol_name);
    try object.field("event", "end");
    try object.field("baseline", options.baseline_path);
    try object.field("candidate", options.candidate_path);
    try object.field("threshold", options.threshold);
    try object.field("minimum_runs", options.min_runs);
    try object.field("compared", counts.compared);
    try object.field("regressions", counts.regressions);
    try object.field("improvements", counts.improvements);
    try object.field("unchanged", counts.unchanged);
    try object.field("uncertain", counts.uncertain);
    try object.field("insufficient", counts.insufficient);
    try object.field("missing_baseline", counts.missing_baseline);
    try object.field("missing_candidate", counts.missing_candidate);
    try object.endLine();
}

fn parseJsonLine(
    allocator: Allocator,
    line: []const u8,
) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, line, .{});
}

fn updateRunState(
    object: std.json.ObjectMap,
    run_open: *bool,
    run_count: *u64,
) !void {
    const run_event = objectStringOptional(object, "event") orelse
        return error.InvalidRunEvent;
    if (std.mem.eql(u8, run_event, "start")) {
        if (run_open.*) return error.NestedRun;
        run_count.* = std.math.add(u64, run_count.*, 1) catch return error.TooManyRuns;
        run_open.* = true;
    } else if (std.mem.eql(u8, run_event, "end")) {
        if (!run_open.*) return error.UnmatchedRunEnd;
        run_open.* = false;
    } else {
        return error.InvalidRunEvent;
    }
}

fn observation(row: anytype) ExecutionObservation {
    return .{ .mean = row.mean, .median = row.median };
}

pub fn analyzeExecutions(
    storage: *Storage,
    baseline: []const ExecutionObservation,
    candidate: []const ExecutionObservation,
    options: ExecutionAnalysisOptions,
) !ExecutionComparison {
    if (!std.math.isFinite(options.threshold) or options.threshold < 1.0) {
        return error.InvalidThreshold;
    }
    if (options.min_runs == 0) return error.InvalidMinimumRuns;
    if (options.bootstrap_iterations == 0) return error.InvalidBootstrapIterations;
    if (baseline.len == 0 or candidate.len == 0) return error.EmptyExecutionSet;
    const regions = try storage.acquireF64(
        baseline.len,
        candidate.len,
        options.bootstrap_iterations,
    );
    defer storage.reset();
    const baseline_stats = try summarizeExecutionsInScratch(
        baseline,
        regions.samples[0..baseline.len],
    );
    const candidate_stats = try summarizeExecutionsInScratch(
        candidate,
        regions.samples[0..candidate.len],
    );
    const ratio = ratioOrNull(baseline_stats.median, candidate_stats.median);
    const enough = baseline.len >= options.min_runs and candidate.len >= options.min_runs;
    const effect = if (enough)
        try bootstrapMedianPercentChange(baseline, candidate, regions)
    else
        null;
    return .{
        .classification = classifyChange(effect, enough, options.threshold),
        .baseline = baseline_stats,
        .candidate = candidate_stats,
        .ratio = ratio,
        .effect = effect,
        .bootstrap_iterations = options.bootstrap_iterations,
        .evidence = evidenceState(enough, effect),
    };
}

pub fn analyzeU64Medians(
    storage: *Storage,
    baseline: []const u64,
    candidate: []const u64,
    bootstrap_iterations: u32,
    seed: u64,
) StorageError!U64MedianRatio {
    const regions = try storage.acquireU64(
        baseline.len,
        candidate.len,
        bootstrap_iterations,
    );
    defer storage.reset();
    const baseline_values = canonicalU64(baseline, regions.samples[0..baseline.len]);
    const baseline_median = upperMedianU64(baseline_values);
    const candidate_values = canonicalU64(candidate, regions.samples[0..candidate.len]);
    const candidate_median = upperMedianU64(candidate_values);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const bootstrap_baseline = canonicalU64(baseline, regions.samples[0..baseline.len]);
    for (regions.effects) |*value| {
        value.* = @floatFromInt(
            resampleUpperMedian(bootstrap_baseline, regions.counts[0..baseline.len], random),
        );
    }
    const bootstrap_candidate = canonicalU64(candidate, regions.samples[0..candidate.len]);
    for (regions.effects) |*ratio| {
        const candidate_value = resampleUpperMedian(
            bootstrap_candidate,
            regions.counts[0..candidate.len],
            random,
        );
        ratio.* = u64RatioFloat(candidate_value, ratio.*);
    }
    std.mem.sort(f64, regions.effects, {}, std.sort.asc(f64));
    const bounds = bench_bootstrap.interval(regions.effects, confidence_per_mille, .truncated);
    return .{
        .baseline_median = baseline_median,
        .candidate_median = candidate_median,
        .ratio = u64Ratio(candidate_median, baseline_median),
        .low_ratio = bounds.low,
        .high_ratio = bounds.high,
    };
}

pub fn summarizeExecutions(
    storage: *Storage,
    observations: []const ExecutionObservation,
) !ExecutionStats {
    if (observations.len == 0) return error.EmptyExecutionSet;
    const scratch = try storage.acquireF64Samples(observations.len);
    defer storage.reset();
    return summarizeExecutionsInScratch(observations, scratch);
}

fn summarizeExecutionsInScratch(
    observations: []const ExecutionObservation,
    scratch: []f64,
) !ExecutionStats {
    std.debug.assert(observations.len > 0);
    std.debug.assert(scratch.len >= observations.len);
    for (observations) |item| {
        if (!std.math.isFinite(item.mean) or !std.math.isFinite(item.median) or
            item.mean < 0 or item.median < 0)
        {
            return error.InvalidSummary;
        }
    }
    const values = scratch[0..observations.len];
    for (observations, values) |item, *value| value.* = canonicalZero(item.mean);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    var execution_mean: f64 = 0;
    for (values, 0..) |value, index| {
        const count: f64 = @floatFromInt(index + 1);
        execution_mean += (value - execution_mean) / count;
    }
    for (observations, values) |item, *value| value.* = canonicalZero(item.median);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return .{
        .runs = observations.len,
        .mean = execution_mean,
        .median = medianSorted(values),
        .min = values[0],
        .max = values[values.len - 1],
    };
}

fn canonicalZero(value: f64) f64 {
    return if (value == 0) 0 else value;
}

pub fn classifyChange(
    effect: ?EffectInterval,
    enough: bool,
    threshold: f64,
) Classification {
    if (!enough) return .insufficient;
    const actual_effect = effect orelse return .uncertain;
    const regression_percent = threshold * 100.0 - 100.0;
    const improvement_percent = 100.0 / threshold - 100.0;
    if (threshold == 1.0) {
        if (actual_effect.low_percent > 0) return .regression;
        if (actual_effect.high_percent < 0) return .improvement;
        if (actual_effect.low_percent == 0 and actual_effect.high_percent == 0) {
            return .unchanged;
        }
        return .uncertain;
    }
    if (actual_effect.low_percent >= regression_percent) return .regression;
    if (actual_effect.high_percent <= improvement_percent) return .improvement;
    if (actual_effect.low_percent > improvement_percent and
        actual_effect.high_percent < regression_percent)
    {
        return .unchanged;
    }
    return .uncertain;
}

fn recordClassification(counts: *Counts, classification: Classification) void {
    counts.compared += 1;
    switch (classification) {
        .regression => counts.regressions += 1,
        .improvement => counts.improvements += 1,
        .unchanged => counts.unchanged += 1,
        .uncertain => counts.uncertain += 1,
        .insufficient => counts.insufficient += 1,
    }
}

fn evidenceState(enough: bool, effect: ?EffectInterval) []const u8 {
    if (!enough) return "insufficient_execution_runs";
    if (effect == null) return "effect_interval_unavailable";
    return "execution_run_effect_interval";
}

fn ratioOrNull(baseline: f64, candidate: f64) ?f64 {
    if (baseline == 0) return null;
    const ratio = candidate / baseline;
    return if (std.math.isFinite(ratio)) ratio else null;
}

fn bootstrapMedianPercentChange(
    baseline: []const ExecutionObservation,
    candidate: []const ExecutionObservation,
    regions: storage_mod.F64Regions,
) !?EffectInterval {
    if (baseline.len == 0 or candidate.len == 0) return null;
    var prng = std.Random.DefaultPrng.init(bootstrap_seed);
    const random = prng.random();
    const baseline_values = canonicalMedians(regions.samples, baseline);
    for (regions.effects) |*value| {
        value.* = resampleMedian(baseline_values, regions.counts[0..baseline.len], random);
    }
    const candidate_values = canonicalMedians(regions.samples, candidate);
    for (regions.effects) |*change| {
        const baseline_median = change.*;
        if (baseline_median == 0) return null;
        const candidate_median = resampleMedian(
            candidate_values,
            regions.counts[0..candidate.len],
            random,
        );
        const ratio = candidate_median / baseline_median;
        if (!std.math.isFinite(ratio)) return null;
        change.* = ratio * 100.0 - 100.0;
        if (!std.math.isFinite(change.*)) return null;
    }
    std.mem.sort(f64, regions.effects, {}, std.sort.asc(f64));
    const bounds = bench_bootstrap.interval(regions.effects, confidence_per_mille, .outward);
    return .{ .low_percent = bounds.low, .high_percent = bounds.high };
}

fn canonicalMedians(
    output: []f64,
    observations: []const ExecutionObservation,
) []const f64 {
    std.debug.assert(observations.len > 0);
    std.debug.assert(output.len >= observations.len);
    const values = output[0..observations.len];
    for (observations, values) |item, *value| value.* = canonicalZero(item.median);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values;
}

/// The midpoint median of one resample of `sorted`.
fn resampleMedian(sorted: []const f64, counts: []u32, random: std.Random) f64 {
    bench_bootstrap.resampleCounts(random, counts);
    const low = bench_bootstrap.rankValue(f64, sorted, counts, (sorted.len - 1) / 2);
    const high = bench_bootstrap.rankValue(f64, sorted, counts, sorted.len / 2);
    return low + (high - low) / 2.0;
}

fn canonicalU64(values: []const u64, output: []u64) []const u64 {
    std.debug.assert(values.len > 0);
    std.debug.assert(values.len == output.len);
    @memcpy(output, values);
    std.mem.sort(u64, output, {}, std.sort.asc(u64));
    return output;
}

fn upperMedianU64(sorted: []const u64) u64 {
    std.debug.assert(sorted.len > 0);
    return sorted[sorted.len / 2];
}

/// The upper median of one resample of `sorted`.
fn resampleUpperMedian(sorted: []const u64, counts: []u32, random: std.Random) u64 {
    bench_bootstrap.resampleCounts(random, counts);
    return bench_bootstrap.rankValue(u64, sorted, counts, sorted.len / 2);
}

fn u64Ratio(candidate_median: u64, baseline_median: u64) f64 {
    if (baseline_median == 0) return std.math.inf(f64);
    return @as(f64, @floatFromInt(candidate_median)) /
        @as(f64, @floatFromInt(baseline_median));
}

fn u64RatioFloat(candidate_median: u64, baseline_median: f64) f64 {
    if (baseline_median == 0) return std.math.inf(f64);
    return @as(f64, @floatFromInt(candidate_median)) / baseline_median;
}

fn medianSorted(sorted: []const f64) f64 {
    std.debug.assert(sorted.len > 0);
    const middle = sorted.len / 2;
    if (sorted.len % 2 == 1) return sorted[middle];
    return sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) / 2.0;
}

fn writeEffect(
    object: pretty_json.Object,
    effect: ?EffectInterval,
    bootstrap_iterations: u32,
) !void {
    try object.field(
        "effect_low_percent",
        if (effect) |value| value.low_percent else null,
    );
    try object.field(
        "effect_high_percent",
        if (effect) |value| value.high_percent else null,
    );
    try object.field("effect_confidence", effect_confidence);
    try object.field("effect_bootstrap_iterations", bootstrap_iterations);
    try object.field("effect_method", effect_method);
}

pub fn duplicateObjectString(
    allocator: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]u8 {
    const text = objectStringOptional(object, key) orelse return error.InvalidSummary;
    return try allocator.dupe(u8, text);
}

pub fn objectStringOptional(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

pub fn objectU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidSummary;
    return switch (value) {
        .integer => |integer| if (integer < 0) error.InvalidSummary else @intCast(integer),
        .number_string => |text| std.fmt.parseUnsigned(u64, text, 10) catch
            return error.InvalidSummary,
        else => error.InvalidSummary,
    };
}

pub fn objectNumberOptional(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(number)) number else null;
}

pub fn objectBoolDefault(
    object: std.json.ObjectMap,
    key: []const u8,
    default: bool,
) !bool {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .bool => |actual| actual,
        else => error.InvalidSummary,
    };
}
