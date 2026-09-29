const std = @import("std");
const pretty_json = @import("pretty").json;
const sys = @import("sys");

const metric_schema = "tiny.profiling.metric/v1";
const output_env = "BENCH_JSONL";

pub const ProcessState = enum {
    process_cold,
    shared_process,
};

pub const CacheState = enum {
    warm,
    externally_controlled,
    uncontrolled,
};

pub const Phase = struct {
    sequence: usize,
    name: []const u8,
    duration_ns: u64,
    bytes: u64,
    records: u64,
};

pub const Point = struct {
    name: []const u8,
    operation: []const u8,
    state_bytes: u64,
    records: u64,
    process_state: ProcessState,
    cache_state: CacheState,
    correctness_admitted: bool,
    sample_ns: []const u64,
    median_ns: u64,
    alloc_count: ?u64,
    alloc_bytes: ?u64,
    phases: []const Phase,
};

pub fn appendEnvPoint(allocator: std.mem.Allocator, point: Point) !void {
    const path = try sys.env.getOwned(allocator, output_env);
    defer if (path) |value| allocator.free(value);
    const actual = path orelse return;

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writePoint(&output.writer, point);
    try sys.fs.appendFile(actual, &.{output.written()});
}

pub fn writePoint(writer: *std.Io.Writer, point: Point) !void {
    if (point.sample_ns.len == 0) return error.MissingRecoverySamples;
    if (point.state_bytes == 0) return error.MissingRecoveryState;

    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", metric_schema);
    try object.field("event", "recovery_curve_point");
    try object.field("family", "timing");
    try object.field("metric", "duration_ns");
    try object.field("unit", "ns");
    try object.field("aggregation", "fresh_process_sample");
    try object.field("name", point.name);
    try object.field("operation", point.operation);
    try object.field("state_bytes", point.state_bytes);
    try object.field("records", point.records);
    try object.field("process_state", @tagName(point.process_state));
    try object.field("cache_state", @tagName(point.cache_state));
    try object.field("correctness_admitted", point.correctness_admitted);
    const samples = try object.array("sample_ns");
    for (point.sample_ns) |sample| try samples.element(sample);
    try samples.end();
    try object.field("median_ns", point.median_ns);
    try object.field("alloc_count", point.alloc_count);
    try object.field("alloc_bytes", point.alloc_bytes);
    try object.field("peak_rss", "captured_by_profile_driver");
    const phases = try object.array("phase_receipts");
    for (point.phases) |phase| {
        const receipt = try phases.object();
        try receipt.field("sequence", phase.sequence);
        try receipt.field("name", phase.name);
        try receipt.field("duration_ns", phase.duration_ns);
        try receipt.field("bytes", phase.bytes);
        try receipt.field("records", phase.records);
        try receipt.end();
    }
    try phases.end();
    try object.endLine();
}

test "recovery curve point preserves premises and ordered phases" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writePoint(&output.writer, .{
        .name = "sql recovery 1",
        .operation = "sql.history.replay",
        .state_bytes = 4096,
        .records = 3,
        .process_state = .process_cold,
        .cache_state = .warm,
        .correctness_admitted = true,
        .sample_ns = &.{ 10, 20 },
        .median_ns = 15,
        .alloc_count = 2,
        .alloc_bytes = 64,
        .phases = &.{.{
            .sequence = 0,
            .name = "batch_load",
            .duration_ns = 4,
            .bytes = 4096,
            .records = 3,
        }},
    });
    const text = output.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"state_bytes\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"process_state\":\"process_cold\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"phase_receipts\":[{") != null);
}
