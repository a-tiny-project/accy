const std = @import("std");
const pretty_json = @import("pretty").json;
const stabilizer = @import("stabilizer");

const evidence = @import("evidence.zig");
const instrumentation = @import("instrumentation.zig");
const metadata_mod = @import("metadata.zig");
const stats = @import("stats/root.zig");
const timing = @import("timing.zig");

pub const RunStart = struct {
    output: []const u8,
    coz_output: ?[]const u8 = null,
    coz_summary: ?[]const u8 = null,
    metadata: metadata_mod.BuildMetadata,
    warmup: u32,
    samples: u32,
    evals: u32,
    kind: ?[]const u8 = null,
    load_samples: u32 = 0,
    phase_samples: u32 = 0,
    filter: ?[]const u8 = null,
    stabilizer: bool = false,
    stabilizer_config: ?stabilizer.Config = null,
    profiling_session: ?instrumentation.ProfilingReport = null,
};

pub const RunEnd = struct {
    files: ?u32 = null,
    benches: u32,
    errors: u32,
};

const SampledResultFixture = struct {
    warmup: u32 = 1,
    samples: u32 = 2,
    evals: u32 = 3,
    sample_ns: []const u64 = &.{ 20, 10 },
    sample_total_ns: []const u64 = &.{ 60, 30 },
    min_ns: u64 = 10,
    max_ns: u64 = 20,
    mean_ns: f64 = 15.0,
    median_ns: u64 = 20,
    p75_ns: u64 = 20,
    p95_ns: u64 = 20,
    p99_ns: u64 = 20,
    total_ns: u64 = 30,
    confidence_intervals: ?stats.BootstrapConfidenceIntervals = .{
        .confidence = 0.95,
        .iterations = 100,
        .seed = 7,
        .mean_ns = .{ .low_ns = 12.0, .high_ns = 18.0 },
        .median_ns = .{ .low_ns = 10.0, .high_ns = 20.0 },
        .p75_ns = .{ .low_ns = 20.0, .high_ns = 20.0 },
        .p95_ns = .{ .low_ns = 20.0, .high_ns = 20.0 },
        .p99_ns = .{ .low_ns = 20.0, .high_ns = 20.0 },
    },
};

pub fn writeRunStart(writer: *std.Io.Writer, event: RunStart) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("event", "run_start");
    try object.field("protocol", "bench.run/v1");
    if (event.kind) |kind| try object.field("kind", kind);
    try object.field("timestamp_ns", timing.realNowNs());
    try object.field("output", event.output);
    if (event.coz_output) |path| try object.field("coz_output", path);
    if (event.coz_summary) |path| try object.field("coz_summary", path);
    try metadata_mod.writeBuildMetadata(try object.object("metadata"), event.metadata);
    try object.field("warmup", event.warmup);
    try object.field("samples", event.samples);
    try object.field("evals", event.evals);
    if (event.load_samples > 0) try object.field("load_samples", event.load_samples);
    if (event.phase_samples > 0) try object.field("phase_samples", event.phase_samples);
    if (event.filter) |filter| try object.field("filter", filter);
    try object.field("stabilizer", event.stabilizer);
    if (event.stabilizer_config) |layout_config| {
        try metadata_mod.writeStabilizerConfig(
            try object.object("stabilizer_config"),
            layout_config,
        );
    }
    try evidence.writeBenchmarkEvidence(
        try object.object("agent_evidence"),
        event.stabilizer_config,
    );
    if (event.profiling_session) |report| {
        try instrumentation.writeProfilingReport(
            try object.object("profiling_session"),
            report,
        );
    }
    try object.endLine();
}

pub fn writeSampleEvent(
    writer: *std.Io.Writer,
    id: []const u8,
    index: u32,
    evals: u32,
    total_ns: u64,
    ns: u64,
) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("event", "sample");
    try object.field("id", id);
    try object.field("sample_index", index);
    try object.field("evals", evals);
    try object.field("total_ns", total_ns);
    try object.field("ns", ns);
    try object.endLine();
}

pub fn writeRunEnd(writer: *std.Io.Writer, event: RunEnd) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("event", "run_end");
    if (event.files) |files| try object.field("files", files);
    try object.field("benches", event.benches);
    try object.field("errors", event.errors);
    try object.endLine();
}

pub fn writeSampledResultFields(
    comptime Row: type,
    object: pretty_json.Object,
    result: Row,
) !void {
    if (result.sample_ns.len != result.sample_total_ns.len) {
        return error.InvalidSamplePairing;
    }
    try object.field("warmup", result.warmup);
    try object.field("samples", result.samples);
    try object.field("evals", result.evals);
    try writeU64Array(try object.array("sample_ns"), result.sample_ns);
    try writeU64Array(try object.array("sample_total_ns"), result.sample_total_ns);
    try writeSampleSequence(try object.object("sample_sequence"));
    try object.field("min_ns", result.min_ns);
    try object.field("max_ns", result.max_ns);
    try object.field("mean_ns", result.mean_ns);
    try object.field("median_ns", result.median_ns);
    try object.field("p75_ns", result.p75_ns);
    try object.field("p95_ns", result.p95_ns);
    try object.field("p99_ns", result.p99_ns);
    try object.field("total_ns", result.total_ns);
    if (@hasField(Row, "confidence_intervals")) {
        if (result.confidence_intervals) |intervals| {
            try writeBootstrapConfidenceIntervals(
                try object.object("confidence_intervals"),
                intervals,
            );
        } else {
            try object.field("confidence_intervals", null);
        }
    }
}

fn writeSampleSequence(object: pretty_json.Object) !void {
    try object.field("order", "measured_acquisition_order");
    try object.field("index_origin", 0);
    try object.field("pairing", "same_index");
    const paired = try object.array("paired_fields");
    try paired.element("sample_ns");
    try paired.element("sample_total_ns");
    try paired.end();
    try object.field("timestamps", "not_recorded");
    try object.field(
        "claim_limit",
        "sequence exposes within-process shifts but does not attribute their cause",
    );
    try object.end();
}

pub fn writeBootstrapConfidenceIntervals(
    object: pretty_json.Object,
    intervals: stats.BootstrapConfidenceIntervals,
) !void {
    try object.field("method", "percentile_bootstrap");
    try object.field("confidence", intervals.confidence);
    try object.field("iterations", intervals.iterations);
    try object.field("seed", intervals.seed);
    try writeConfidenceInterval(try object.object("mean_ns"), intervals.mean_ns);
    try writeConfidenceInterval(try object.object("median_ns"), intervals.median_ns);
    try writeConfidenceInterval(try object.object("p75_ns"), intervals.p75_ns);
    try writeConfidenceInterval(try object.object("p95_ns"), intervals.p95_ns);
    try writeConfidenceInterval(try object.object("p99_ns"), intervals.p99_ns);
    try object.end();
}

fn writeConfidenceInterval(object: pretty_json.Object, interval: stats.ConfidenceInterval) !void {
    try object.field("low_ns", interval.low_ns);
    try object.field("high_ns", interval.high_ns);
    try object.end();
}

fn writeU64Array(array: pretty_json.Array, values: []const u64) !void {
    for (values) |item| try array.element(item);
    try array.end();
}

test "run events keep benchmark report fields" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try writeRunStart(&out.writer, .{
        .output = "out.jsonl",
        .coz_output = "out.coz.jsonl",
        .metadata = .{
            .git_sha = "abc123",
            .git_dirty = false,
            .optimize = "ReleaseFast",
            .target = "native",
            .zig_version = "0.16.0",
            .host_os = "linux",
            .host_arch = "x86_64",
        },
        .warmup = 1,
        .samples = 2,
        .evals = 3,
        .kind = "load",
        .load_samples = 4,
        .filter = "answer",
        .stabilizer = true,
        .stabilizer_config = .{
            .seed = 77,
            .heap = .{ .shuffle_slots = 5 },
            .code = .{ .enabled = false },
        },
        .profiling_session = .{
            .capabilities = &.{
                .{ .name = .coz, .state = .enabled, .requested = true, .artifact = "out.coz.jsonl" },
                .{ .name = .perf, .state = .disabled, .reason = "no perf counter artifact configured" },
            },
            .artifacts = &.{
                .{ .name = "coz_output", .path = "out.coz.jsonl" },
                .{ .name = "coz_summary", .path = "out.coz.analysis.json" },
            },
        },
    });
    try writeSampleEvent(&out.writer, "bench_answer", 1, 3, 99, 33);
    try writeRunEnd(&out.writer, .{ .files = 1, .benches = 2, .errors = 0 });

    const jsonl = out.written();
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"event\":\"run_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"protocol\":\"bench.run/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"timestamp_ns\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"git_sha\":\"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"host_os\":\"linux\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"host_arch\":\"x86_64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"load_samples\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"filter\":\"answer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"stabilizer_config\":{\"seed\":77") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"agent_evidence\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"code\":\"not_randomized\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"profiling_session\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"name\":\"perf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"coz_summary\":\"out.coz.analysis.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"event\":\"sample\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"id\":\"bench_answer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"event\":\"run_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"errors\":0") != null);
}

test "sampled result fields write raw samples and summaries" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var stream = pretty_json.Writer.init(&out.writer, .minified);
    const object = try stream.object();
    try writeSampledResultFields(SampledResultFixture, object, .{});
    try object.end();

    const json = out.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sample_ns\":[20,10]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sample_total_ns\":[60,30]") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "\"order\":\"measured_acquisition_order\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pairing\":\"same_index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timestamps\":\"not_recorded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"median_ns\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"confidence_intervals\":{\"method\":\"percentile_bootstrap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"seed\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"low_ns\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_ns\":30") != null);
}

test "sampled result fields reject unpaired arrays" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var stream = pretty_json.Writer.init(&out.writer, .minified);
    const object = try stream.object();
    try std.testing.expectError(
        error.InvalidSamplePairing,
        writeSampledResultFields(SampledResultFixture, object, .{
            .sample_total_ns = &.{60},
        }),
    );
}
