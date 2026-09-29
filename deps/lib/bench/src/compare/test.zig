const std = @import("std");
const alloc_phase = @import("alloc_phase");
const compare = @import("root.zig");
const engine = @import("engine.zig");

const Allocator = std.mem.Allocator;
const Storage = compare.Storage;
const ExecutionObservation = compare.ExecutionObservation;
const ExecutionStats = compare.ExecutionStats;
const Classification = compare.Classification;
const default_bootstrap_iterations = compare.default_bootstrap_iterations;
const analyzeExecutions = compare.analyzeExecutions;
const summarizeExecutions = compare.summarizeExecutions;
const parseArgs = compare.parseArgs;
const SummaryComparison = compare.SummaryComparison;
const duplicateObjectString = compare.duplicateObjectString;
const objectNumberOptional = compare.objectNumberOptional;
const pretty_json = @import("pretty").json;
const classifyChange = engine.classifyChange;
const loadRows = engine.loadRows;
const deinitRows = engine.deinitRows;
const compareRows = engine.compareRows;

const comparison_baseline = [_]ExecutionObservation{
    .{ .mean = 100, .median = 100 },
    .{ .mean = 105, .median = 105 },
    .{ .mean = 95, .median = 95 },
    .{ .mean = 102, .median = 102 },
    .{ .mean = 98, .median = 98 },
    .{ .mean = 103, .median = 103 },
    .{ .mean = 97, .median = 97 },
    .{ .mean = 101, .median = 101 },
};

const comparison_candidate = [_]ExecutionObservation{
    .{ .mean = 97, .median = 97 },
    .{ .mean = 99, .median = 99 },
    .{ .mean = 101, .median = 101 },
    .{ .mean = 96, .median = 96 },
    .{ .mean = 100, .median = 100 },
    .{ .mean = 98, .median = 98 },
    .{ .mean = 102, .median = 102 },
    .{ .mean = 95, .median = 95 },
};

test "comparison storage rejects every input boundary before mutation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").ComparisonStorage, "bench_comparison_boundaries"),
        );
    }

    var storage = try Storage.init(std.testing.allocator, .{
        .max_samples_per_series = 3,
        .max_bootstrap_iterations = 5,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    @memset(storage.bytes, 42);

    try std.testing.expectError(
        error.EmptyExecutionSet,
        analyzeExecutions(&storage, &.{}, &.{.{ .mean = 1, .median = 1 }}, .{}),
    );
    try std.testing.expectError(
        error.EmptyExecutionSet,
        analyzeExecutions(&storage, &.{.{ .mean = 1, .median = 1 }}, &.{}, .{}),
    );
    try std.testing.expectError(
        error.InvalidBootstrapIterations,
        analyzeExecutions(
            &storage,
            &.{.{ .mean = 1, .median = 1 }},
            &.{.{ .mean = 1, .median = 1 }},
            .{ .bootstrap_iterations = 0 },
        ),
    );
    try std.testing.expectError(
        error.BaseSampleCapacityExceeded,
        analyzeExecutions(
            &storage,
            &.{
                .{ .mean = 1, .median = 1 },
                .{ .mean = 2, .median = 2 },
                .{ .mean = 3, .median = 3 },
                .{ .mean = 4, .median = 4 },
            },
            &.{.{ .mean = 1, .median = 1 }},
            .{ .min_runs = 1, .bootstrap_iterations = 5 },
        ),
    );
    try std.testing.expectError(
        error.CandidateSampleCapacityExceeded,
        analyzeExecutions(
            &storage,
            &.{.{ .mean = 1, .median = 1 }},
            &.{
                .{ .mean = 1, .median = 1 },
                .{ .mean = 2, .median = 2 },
                .{ .mean = 3, .median = 3 },
                .{ .mean = 4, .median = 4 },
            },
            .{ .min_runs = 1, .bootstrap_iterations = 5 },
        ),
    );
    try std.testing.expectError(
        error.BootstrapIterationCapacityExceeded,
        analyzeExecutions(
            &storage,
            &.{.{ .mean = 1, .median = 1 }},
            &.{.{ .mean = 1, .median = 1 }},
            .{ .min_runs = 1, .bootstrap_iterations = 6 },
        ),
    );
    try std.testing.expectError(
        error.SampleCapacityExceeded,
        summarizeExecutions(&storage, &.{
            .{ .mean = 1, .median = 1 },
            .{ .mean = 2, .median = 2 },
            .{ .mean = 3, .median = 3 },
            .{ .mean = 4, .median = 4 },
        }),
    );
    for (storage.bytes) |byte| try std.testing.expectEqual(@as(u8, 42), byte);
    _ = try storage.acquireF64(1, 1, 1);
    try std.testing.expectError(
        error.ComparisonStorageInUse,
        analyzeExecutions(
            &storage,
            &.{.{ .mean = 1, .median = 1 }},
            &.{.{ .mean = 1, .median = 1 }},
            .{ .min_runs = 1, .bootstrap_iterations = 1 },
        ),
    );
    for (storage.bytes) |byte| try std.testing.expectEqual(@as(u8, 42), byte);
    storage.reset();
    _ = try analyzeExecutions(
        &storage,
        &.{.{ .mean = 1, .median = 1 }},
        &.{.{ .mean = 1, .median = 1 }},
        .{ .min_runs = 1, .bootstrap_iterations = 5 },
    );
    try std.testing.expect(!storage.status().in_use);
}

test "comparison storage preserves execution output and reusable state" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").ComparisonStorage, "bench_comparison_reuse"),
        );
    }

    var storage = try Storage.init(std.testing.allocator, .{
        .max_samples_per_series = comparison_baseline.len,
        .max_bootstrap_iterations = default_bootstrap_iterations,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    const first = try analyzeExecutions(
        &storage,
        &comparison_baseline,
        &comparison_candidate,
        .{ .min_runs = comparison_baseline.len },
    );
    const second = try analyzeExecutions(
        &storage,
        &comparison_baseline,
        &comparison_candidate,
        .{ .min_runs = comparison_baseline.len },
    );

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(Classification.uncertain, first.classification);
    try std.testing.expectEqual(ExecutionStats{
        .runs = 8,
        .mean = 100.125,
        .median = 100.5,
        .min = 95,
        .max = 105,
    }, first.baseline);
    try std.testing.expectEqual(ExecutionStats{
        .runs = 8,
        .mean = 98.5,
        .median = 98.5,
        .min = 95,
        .max = 102,
    }, first.candidate);
    try std.testing.expectEqual(@as(f64, 0.9800995024875622), first.ratio.?);
    try std.testing.expectEqual(@as(f64, -5.3398058252427205), first.effect.?.low_percent);
    try std.testing.expectEqual(@as(f64, 2.040816326530617), first.effect.?.high_percent);
    try std.testing.expectEqual(default_bootstrap_iterations, first.bootstrap_iterations);
    try std.testing.expectEqualStrings("execution_run_effect_interval", first.evidence);
    try std.testing.expect(!storage.status().in_use);
}

test "activated execution comparison performs no backing allocation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").ComparisonStorage, "bench_comparison_sealed_f64_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").ComparisonStorage, "bench_comparison_sealed_f64_foreign_risk"),
        );
    }

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var storage = try Storage.init(counting.allocator(), .{
        .max_samples_per_series = comparison_baseline.len,
        .max_bootstrap_iterations = default_bootstrap_iterations,
    });
    defer storage.deinit(counting.allocator());
    storage.activate();
    const allocations = counting.alloc_index;
    const bytes = counting.allocated_bytes;

    const result = try analyzeExecutions(
        &storage,
        &comparison_baseline,
        &comparison_candidate,
        .{ .min_runs = comparison_baseline.len },
    );

    try std.testing.expectEqual(Classification.uncertain, result.classification);
    try std.testing.expectEqual(@as(usize, 1), allocations);
    try std.testing.expectEqual(@as(usize, 8_096), bytes);
    try std.testing.expectEqual(allocations, counting.alloc_index);
    try std.testing.expectEqual(bytes, counting.allocated_bytes);
}

const TestRow = struct {
    key: []u8,
    summary: []u8,
    name: []u8,
    mean: f64,
    median: f64,
    min: f64,
    max: f64,

    pub fn deinit(self: TestRow, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.summary);
        allocator.free(self.name);
    }
};

const TestSpec = struct {
    pub const Row: type = TestRow;
    pub const benchmark_name = "bench.test";
    pub const protocol_name = "bench.test_compare/v1";

    pub fn parseRow(allocator: Allocator, object: std.json.ObjectMap) !TestRow {
        const summary = try duplicateObjectString(allocator, object, "summary");
        errdefer allocator.free(summary);
        const name = try duplicateObjectString(allocator, object, "name");
        errdefer allocator.free(name);
        const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ summary, name });
        return .{
            .key = key,
            .summary = summary,
            .name = name,
            .mean = objectNumberOptional(object, "mean") orelse return error.InvalidSummary,
            .median = objectNumberOptional(object, "median") orelse
                return error.InvalidSummary,
            .min = objectNumberOptional(object, "min") orelse return error.InvalidSummary,
            .max = objectNumberOptional(object, "max") orelse return error.InvalidSummary,
        };
    }

    pub fn writeIdentity(_: pretty_json.Object, _: TestRow) !void {}
};

const TestEngine = SummaryComparison(TestSpec);
const test_run_start =
    "{\"kind\":\"run\",\"benchmark\":\"bench.test\",\"event\":\"start\"}\n";
const test_run_end =
    "{\"kind\":\"run\",\"benchmark\":\"bench.test\",\"event\":\"end\"}\n";
const test_run_invalid =
    "{\"kind\":\"run\",\"benchmark\":\"bench.test\",\"event\":\"pause\"}\n";
const test_summary_10 =
    "{\"kind\":\"summary\",\"benchmark\":\"bench.test\"," ++
    "\"summary\":\"phase\",\"name\":\"total\",\"mean\":10," ++
    "\"median\":10,\"min\":10,\"max\":10}\n";
const test_summary_11 =
    "{\"kind\":\"summary\",\"benchmark\":\"bench.test\"," ++
    "\"summary\":\"phase\",\"name\":\"total\",\"mean\":11," ++
    "\"median\":11,\"min\":11,\"max\":11}\n";
const test_summary_parse_20 =
    "{\"kind\":\"summary\",\"benchmark\":\"bench.test\"," ++
    "\"summary\":\"phase\",\"name\":\"parse\",\"mean\":20," ++
    "\"median\":20,\"min\":20,\"max\":20}\n";

test "parseArgs accepts material threshold execution minimum and bootstrap limit" {
    const options = try parseArgs(&.{
        "base.jsonl",
        "candidate.jsonl",
        "--threshold",
        "1.2",
        "--min-runs",
        "12",
        "--bootstrap-iterations",
        "500",
    });
    try std.testing.expectEqual(@as(f64, 1.2), options.threshold);
    try std.testing.expectEqual(@as(u32, 12), options.min_runs);
    try std.testing.expectEqual(@as(u32, 500), options.bootstrap_iterations);
}

test "parseArgs rejects invalid comparison evidence options" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{}));
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "base", "candidate", "--threshold", "nan" }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "base", "candidate", "--min-runs", "0" }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "base", "candidate", "--bootstrap-iterations", "0" }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "base", "candidate", "--noise-threshold", "0.2" }),
    );
}

test "effect intervals classify supported, equivalent, and uncertain changes" {
    try std.testing.expectEqual(
        Classification.insufficient,
        classifyChange(.{ .low_percent = 20, .high_percent = 20 }, false, 1.05),
    );
    try std.testing.expectEqual(
        Classification.regression,
        classifyChange(.{ .low_percent = 5, .high_percent = 8 }, true, 1.05),
    );
    try std.testing.expectEqual(
        Classification.improvement,
        classifyChange(.{ .low_percent = -8, .high_percent = -5 }, true, 1.05),
    );
    try std.testing.expectEqual(
        Classification.unchanged,
        classifyChange(.{ .low_percent = -2, .high_percent = 2 }, true, 1.05),
    );
    try std.testing.expectEqual(
        Classification.uncertain,
        classifyChange(.{ .low_percent = 2, .high_percent = 8 }, true, 1.05),
    );
    try std.testing.expectEqual(
        Classification.unchanged,
        classifyChange(.{ .low_percent = 0, .high_percent = 0 }, true, 1.0),
    );
}

test "repeated run summaries produce supported effect intervals" {
    var baseline = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer baseline.deinit();
    var candidate = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer candidate.deinit();
    try writeTestRuns(&baseline.writer, 10, 100);
    try writeTestRuns(&candidate.writer, 10, 120);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const counts = try TestEngine.compareSources(
        std.testing.allocator,
        &out.writer,
        .{
            .baseline_path = "base",
            .candidate_path = "candidate",
            .bootstrap_iterations = 500,
        },
        baseline.written(),
        candidate.written(),
    );
    try std.testing.expectEqual(@as(u64, 1), counts.regressions);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "\"evidence\":\"execution_run_effect_interval\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"baseline_runs\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"effect_low_percent\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"bootstrap_iterations\":500") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"effect_bootstrap_iterations\":500") != null);
}

test "summary comparison reuses one exact region across rows" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").ComparisonStorage, "bench_comparison_rows"),
        );
    }

    var source = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source.deinit();
    for (0..10) |_| {
        try source.writer.writeAll(
            test_run_start ++ test_summary_10 ++ test_summary_parse_20 ++ test_run_end,
        );
    }
    var baseline = try loadRows(TestSpec, std.testing.allocator, source.written());
    defer deinitRows(TestRow, std.testing.allocator, &baseline);
    var candidate = try loadRows(TestSpec, std.testing.allocator, source.written());
    defer deinitRows(TestRow, std.testing.allocator, &candidate);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});

    const counts = try compareRows(
        TestSpec,
        counting.allocator(),
        &out.writer,
        .{
            .baseline_path = "base",
            .candidate_path = "candidate",
            .bootstrap_iterations = 500,
        },
        &baseline,
        &candidate,
    );

    try std.testing.expectEqual(@as(u64, 2), counts.compared);
    try std.testing.expectEqual(@as(usize, 3), counting.alloc_index);
    try std.testing.expectEqual(@as(usize, 4_152), counting.allocated_bytes);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"bootstrap_iterations\":500") != null);
}

test "single run threshold crossings are insufficient" {
    var baseline = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer baseline.deinit();
    var candidate = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer candidate.deinit();
    try writeTestRuns(&baseline.writer, 1, 100);
    try writeTestRuns(&candidate.writer, 1, 120);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const counts = try TestEngine.compareSources(
        std.testing.allocator,
        &out.writer,
        .{ .baseline_path = "base", .candidate_path = "candidate" },
        baseline.written(),
        candidate.written(),
    );
    try std.testing.expectEqual(@as(u64, 1), counts.insufficient);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "\"classification\":\"insufficient\"",
    ) != null);
}

test "duplicate summaries inside one run are rejected" {
    const source = test_run_start ++ test_summary_10 ++ test_summary_11 ++ test_run_end;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(
        error.DuplicateSummaryInRun,
        TestEngine.compareSources(
            std.testing.allocator,
            &out.writer,
            .{ .baseline_path = "base", .candidate_path = "candidate" },
            source,
            source,
        ),
    );
}

test "complete execution scopes are required" {
    try expectSourceError(error.MissingRunStart, test_summary_10);
    try expectSourceError(error.MissingRunEnd, test_run_start ++ test_summary_10);
    try expectSourceError(error.UnmatchedRunEnd, test_run_end);
    try expectSourceError(error.NestedRun, test_run_start ++ test_run_start);
    try expectSourceError(error.InvalidRunEvent, test_run_invalid);
    try expectSourceError(error.MissingSummaryInRun, test_run_start ++ test_run_end);
    try expectSourceError(error.InvalidProfileJsonl, "not-json\n");
}

fn expectSourceError(expected: anyerror, source: []const u8) !void {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(
        expected,
        TestEngine.compareSources(
            std.testing.allocator,
            &out.writer,
            .{ .baseline_path = "base", .candidate_path = "candidate" },
            source,
            source,
        ),
    );
}

test "comparison releases ownership on every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compareTestSources,
        .{},
    );
}

fn compareTestSources(allocator: Allocator) !void {
    const source = test_run_start ++ test_summary_10 ++ test_run_end;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    _ = try TestEngine.compareSources(
        allocator,
        &out.writer,
        .{
            .baseline_path = "base",
            .candidate_path = "candidate",
            .min_runs = 1,
        },
        source,
        source,
    );
}

fn writeTestRuns(writer: *std.Io.Writer, count: u32, value: u64) !void {
    for (0..count) |_| {
        try writeTestRunMarker(writer, "start");
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("kind", "summary");
        try object.field("benchmark", "bench.test");
        try object.field("summary", "phase");
        try object.field("name", "total");
        try object.field("mean", value);
        try object.field("median", value);
        try object.field("min", value);
        try object.field("max", value);
        try object.endLine();
        try writeTestRunMarker(writer, "end");
    }
}

fn writeTestRunMarker(writer: *std.Io.Writer, event: []const u8) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("kind", "run");
    try object.field("benchmark", "bench.test");
    try object.field("event", event);
    try object.endLine();
}
