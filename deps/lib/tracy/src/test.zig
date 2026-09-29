const namespace = @import("root.zig");
const std = @import("std");
const sys = @import("sys");
const allocator_mod = @import("allocator.zig");
const capture_mod = @import("capture.zig");
const event_mod = @import("event.zig");
const flight_mod = @import("flight.zig");
const frame_mod = @import("frame.zig");
const instrumentation = @import("instrumentation.zig");
const runtime = @import("runtime.zig");
const find = namespace.find;
const flame = namespace.flame;
const frame = namespace.frame;
const source = namespace.source;
const stats = namespace.stats;
const timeline = namespace.timeline;
const tree = namespace.tree;
const FlightRecorder = namespace.FlightRecorder;
const start = namespace.start;
const stop = namespace.stop;
const zone = namespace.zone;
const free = namespace.free;
fn writePartialTreeFixture(writer: *std.Io.Writer) !void {
    const rows = [_]event_mod.TraceEvent{
        .{ .seq = 1, .kind = .start, .time_ns = 80 },
        .{
            .seq = 3,
            .kind = .zone_begin,
            .time_ns = 100,
            .thread = 7,
            .id = 1,
            .name = "render.present",
            .file = "render.zig",
            .line = 9,
        },
        .{ .seq = 4, .kind = .zone_end, .time_ns = 90, .thread = 7, .id = 1 },
        .{
            .seq = 5,
            .kind = .zone_begin,
            .time_ns = 120,
            .thread = 7,
            .id = 2,
            .name = "render.old",
            .file = "render.zig",
            .line = 10,
        },
        .{
            .seq = 6,
            .kind = .zone_begin,
            .time_ns = 130,
            .thread = 7,
            .id = 2,
            .name = "render.new",
            .file = "render.zig",
            .line = 11,
        },
        .{ .seq = 7, .kind = .zone_end, .time_ns = 140, .thread = 7, .id = 2 },
        .{
            .seq = 8,
            .kind = .zone_begin,
            .time_ns = 150,
            .thread = 7,
            .id = 3,
            .name = "render.zero",
            .file = "render.zig",
            .line = 12,
        },
        .{ .seq = 9, .kind = .zone_end, .time_ns = 150, .thread = 7, .id = 3 },
        .{ .seq = 10, .kind = .stop, .time_ns = 160 },
    };
    for (rows) |row| try row.writeJsonLine(writer);
}

fn expectPartialTreeReports(path: []const u8) !void {
    try expectPartialTreeReport(
        tree.writeJsonlFromJsonlPath,
        path,
        tree.Options{},
        &.{ "\"state\":\"superseded\"", "\"duration_valid\":true" },
    );
    try expectPartialTreeReport(
        stats.writeJsonlFromJsonlPath,
        path,
        stats.Options{},
        &.{
            "\"invalid_duration_spans\":1",
            "\"superseded_spans\":1",
            "\"zero_spans\":1",
        },
    );
    try expectPartialTreeReport(
        find.writeJsonlFromJsonlPath,
        path,
        find.Options{ .pattern = "render" },
        &.{
            "\"invalid_duration_spans\":1",
            "\"superseded_spans\":1",
            "\"zero_duration_spans\":1",
        },
    );
    try expectPartialTreeReport(
        source.writeJsonlFromJsonlPath,
        path,
        source.Options{},
        &.{
            "\"invalid_duration_spans\":1",
            "\"superseded_spans\":1",
            "\"zero_spans\":1",
        },
    );
    try expectPartialTreeReport(
        flame.writeJsonlFromJsonlPath,
        path,
        flame.Options{},
        &.{
            "\"invalid_duration_spans\":1",
            "\"superseded_spans\":1",
            "\"zero_duration_spans\":1",
        },
    );
    try expectPartialTreeReport(
        timeline.writeJsonlFromJsonlPath,
        path,
        timeline.Options{ .kind = .zone },
        &.{ "\"state\":\"superseded\"", "\"duration_valid\":false" },
    );
}

fn expectPartialTreeReport(
    comptime write_report: anytype,
    path: []const u8,
    options: anytype,
    extras: []const []const u8,
) !void {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try write_report(std.testing.allocator, path, &output.writer, options);
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "\"tree_evidence\":{\"status\":\"partial\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "\"zone_timestamp_regressions\":1") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "\"duplicate_zone_begins\":1") != null,
    );
    for (extras) |extra| {
        try std.testing.expect(std.mem.indexOf(u8, output.written(), extra) != null);
    }
    var lines = std.mem.splitScalar(u8, output.written(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            line,
            .{},
        );
        defer parsed.deinit();
    }
}

test {
    _ = @import("cli/args/test.zig");
}

test "tracy package namespace" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(namespace);
    std.testing.refAllDecls(allocator_mod);
    std.testing.refAllDecls(capture_mod);
    std.testing.refAllDecls(event_mod);
    std.testing.refAllDecls(flight_mod);
    std.testing.refAllDecls(frame_mod);
    std.testing.refAllDecls(instrumentation);
    std.testing.refAllDecls(runtime);
}

test "flight overwrite reaches frame capture integrity" {
    var storage: [1024]u8 = undefined;
    var events: [512]u8 = undefined;
    var writer_buffer: [256]u8 = undefined;
    var recorder = flight_mod.FlightRecorder.init(
        &storage,
        &events,
        &writer_buffer,
        .overwrite_oldest,
    );
    try (event_mod.TraceEvent{ .seq = 1, .kind = .start })
        .writeJsonLine(recorder.interface());
    for (2..43) |sequence| {
        try (event_mod.TraceEvent{
            .seq = @intCast(sequence),
            .kind = .frame,
            .time_ns = @as(u64, @intCast(sequence)) * 16_666_667,
            .thread = 1,
            .name = "render",
        }).writeJsonLine(recorder.interface());
    }
    try (event_mod.TraceEvent{ .seq = 43, .kind = .stop })
        .writeJsonLine(recorder.interface());

    var snapshot = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer snapshot.deinit();
    const snapshot_report = try recorder.snapshot(&snapshot.writer);
    var analyzer = frame_mod.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(snapshot.written());
    const integrity = analyzer.captureIntegrity();
    try std.testing.expect(snapshot_report.overwritten_events > 0);
    try std.testing.expectEqualDeep(snapshot_report, integrity.flight_report.?);
    try std.testing.expect(analyzer.counters.frames > 0);
    try std.testing.expectEqualStrings("sequence_gaps", integrity.status);
    try std.testing.expect(integrity.missing_sequence_event_count > 0);
}

test "tree-derived reports preserve partial duration evidence" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try writePartialTreeFixture(&trace.writer);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.parent_dir.realPathFileAlloc(
        sys.fs.debugIo(),
        tmp.sub_path[0..],
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "trace.jsonl" });
    defer std.testing.allocator.free(path);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = path, .data = trace.written() });

    try expectPartialTreeReports(path);
}
