const std = @import("std");
const pretty_json = @import("pretty").json;
const event = @import("event.zig");
const transport = @import("transport.zig");

pub const method = "tracy_event_sequence_and_lifecycle_v1";

pub const Counters = struct {
    events: u64 = 0,
    sequenced_events: u64 = 0,
    unsequenced_events: u64 = 0,
    sequence_gaps: u64 = 0,
    missing_sequence_events: u64 = 0,
    sequence_regressions: u64 = 0,
    start_events: u64 = 0,
    stop_events: u64 = 0,
};

pub const Integrity = struct {
    status: []const u8,
    action: []const u8,
    message: ?[]const u8,
    event_count: u64,
    sequenced_event_count: u64,
    unsequenced_event_count: u64,
    first_sequence: ?u64,
    last_sequence: ?u64,
    sequence_gap_count: u64,
    missing_sequence_event_count: u64,
    sequence_regression_count: u64,
    start_event_count: u64,
    stop_event_count: u64,
    start_sequence: ?u64,
    stop_sequence: ?u64,
    unbalanced_event_count: u64,
    flight_report: ?transport.Report,
};

pub const Tracker = struct {
    counters: Counters = .{},
    first_sequence: ?u64 = null,
    last_sequence: ?u64 = null,
    start_sequence: ?u64 = null,
    stop_sequence: ?u64 = null,
    flight_report: ?transport.Report = null,

    pub fn record(self: *Tracker, parsed: event.Parsed) void {
        self.counters.events +|= 1;
        self.recordSequence(parsed.seq);
        switch (parsed.kind) {
            .start => {
                self.counters.start_events +|= 1;
                if (self.start_sequence == null) self.start_sequence = parsed.seq;
            },
            .stop => {
                self.counters.stop_events +|= 1;
                self.stop_sequence = parsed.seq;
            },
            else => {},
        }
    }

    pub fn recordFlightReport(self: *Tracker, report: transport.Report) void {
        self.flight_report = report;
    }

    pub fn integrity(self: Tracker, unbalanced_event_count: u64) Integrity {
        var result: Integrity = .{
            .status = "complete",
            .action = "none",
            .message = null,
            .event_count = self.counters.events,
            .sequenced_event_count = self.counters.sequenced_events,
            .unsequenced_event_count = self.counters.unsequenced_events,
            .first_sequence = self.first_sequence,
            .last_sequence = self.last_sequence,
            .sequence_gap_count = self.counters.sequence_gaps,
            .missing_sequence_event_count = self.counters.missing_sequence_events,
            .sequence_regression_count = self.counters.sequence_regressions,
            .start_event_count = self.counters.start_events,
            .stop_event_count = self.counters.stop_events,
            .start_sequence = self.start_sequence,
            .stop_sequence = self.stop_sequence,
            .unbalanced_event_count = unbalanced_event_count,
            .flight_report = self.flight_report,
        };
        classify(&result);
        return result;
    }

    fn recordSequence(self: *Tracker, sequence: u64) void {
        if (sequence == 0) {
            self.counters.unsequenced_events +|= 1;
            return;
        }
        self.counters.sequenced_events +|= 1;
        const previous = self.last_sequence orelse {
            self.first_sequence = sequence;
            self.last_sequence = sequence;
            if (sequence > 1) {
                self.counters.sequence_gaps +|= 1;
                self.counters.missing_sequence_events +|= sequence - 1;
            }
            return;
        };
        if (sequence <= previous) {
            self.counters.sequence_regressions +|= 1;
        } else if (sequence - previous > 1) {
            self.counters.sequence_gaps +|= 1;
            self.counters.missing_sequence_events +|= sequence - previous - 1;
        }
        self.last_sequence = sequence;
    }
};

pub fn writeText(writer: *std.Io.Writer, integrity: Integrity) !void {
    try writer.print(
        "tracy capture_integrity={s} events={d} sequenced_events={d} " ++
            "unsequenced_events={d} sequence_gaps={d} missing_sequence_events={d} " ++
            "sequence_regressions={d} start_events={d} stop_events={d} " ++
            "unbalanced_events={d}",
        .{
            integrity.status,
            integrity.event_count,
            integrity.sequenced_event_count,
            integrity.unsequenced_event_count,
            integrity.sequence_gap_count,
            integrity.missing_sequence_event_count,
            integrity.sequence_regression_count,
            integrity.start_event_count,
            integrity.stop_event_count,
            integrity.unbalanced_event_count,
        },
    );
    try writer.writeAll(" first_sequence=");
    try writeOptionalU64Text(writer, integrity.first_sequence);
    try writer.writeAll(" last_sequence=");
    try writeOptionalU64Text(writer, integrity.last_sequence);
    try writer.writeAll(" start_sequence=");
    try writeOptionalU64Text(writer, integrity.start_sequence);
    try writer.writeAll(" stop_sequence=");
    try writeOptionalU64Text(writer, integrity.stop_sequence);
    try writer.writeByte('\n');
    if (integrity.flight_report) |report| try writeFlightText(writer, report);
    if (integrity.message) |message| {
        try writer.print("tracy capture caveat={s} action={s} message=", .{
            integrity.status,
            integrity.action,
        });
        try pretty_json.writeString(writer, message);
        try writer.writeByte('\n');
    }
}

pub fn writeFields(object: pretty_json.Object, integrity: Integrity) !void {
    const capture = try object.object("capture_integrity");
    try capture.field("method", method);
    try capture.field("status", integrity.status);
    try capture.field("action", integrity.action);
    try capture.field("message", integrity.message);
    try capture.field("event_count", integrity.event_count);
    try capture.field("sequenced_event_count", integrity.sequenced_event_count);
    try capture.field("unsequenced_event_count", integrity.unsequenced_event_count);
    try capture.field("first_sequence", integrity.first_sequence);
    try capture.field("last_sequence", integrity.last_sequence);
    try capture.field("sequence_gap_count", integrity.sequence_gap_count);
    try capture.field("missing_sequence_event_count", integrity.missing_sequence_event_count);
    try capture.field("sequence_regression_count", integrity.sequence_regression_count);
    try capture.field("start_event_count", integrity.start_event_count);
    try capture.field("stop_event_count", integrity.stop_event_count);
    try capture.field("unbalanced_event_count", integrity.unbalanced_event_count);
    try capture.field("start_sequence", integrity.start_sequence);
    try capture.field("stop_sequence", integrity.stop_sequence);
    if (integrity.flight_report) |report| {
        const flight = try capture.object("flight_report");
        try report.writeFields(flight);
        try flight.end();
    } else {
        try capture.field("flight_report", null);
    }
    const limits = try capture.array("limits");
    try limits.element(
        "sequence gaps are lower-bound missing-row evidence; " ++
            "source loss counters remain authoritative",
    );
    try limits.element(
        "complete sequence and lifecycle evidence does not prove low perturbation or " ++
            "representative coverage",
    );
    try limits.end();
    try capture.end();
}

fn writeFlightText(writer: *std.Io.Writer, report: transport.Report) !void {
    try writer.print(
        "tracy flight policy={s} state={s} capacity_bytes={d} retained_bytes={d} " ++
            "event_capacity_bytes={d} writer_capacity_bytes={d} " ++
            "observed_events={d} stored_events={d} retained_events={d} " ++
            "overwritten_events={d} dropped_events={d} oversized_events={d} " ++
            "partial_event_bytes={d} discarding_oversized_event={}\n",
        .{
            report.policy.tag(),
            report.state.tag(),
            report.capacity_bytes,
            report.retained_bytes,
            report.event_capacity_bytes,
            report.writer_capacity_bytes,
            report.observed_events,
            report.stored_events,
            report.retained_events,
            report.overwritten_events,
            report.dropped_events,
            report.oversized_events,
            report.partial_event_bytes,
            report.discarding_oversized_event,
        },
    );
}

fn classify(result: *Integrity) void {
    if (result.event_count == 0) return set(
        result,
        "no_events",
        "capture_trace_events",
        "Tracy trace contains no events",
    );
    if (result.sequence_regression_count != 0) return set(
        result,
        "non_monotonic_sequence",
        "inspect_trace_transport",
        "Tracy event sequence is non-monotonic; treat derived reports as corrupt evidence",
    );
    if (result.missing_sequence_event_count != 0) return set(
        result,
        "sequence_gaps",
        "inspect_loss_counters_or_increase_capacity",
        "Tracy event sequence has gaps; treat derived reports as partial evidence",
    );
    if (result.unsequenced_event_count != 0) return set(
        result,
        "missing_sequence_metadata",
        "recapture_with_sequence_metadata",
        "one or more Tracy events lack sequence metadata; capture completeness is unknown",
    );
    classifyLifecycle(result);
}

fn classifyLifecycle(result: *Integrity) void {
    if (result.start_event_count > 1 or result.stop_event_count > 1) return set(
        result,
        "multiple_trace_sessions",
        "capture_one_trace_session",
        "Tracy trace mixes multiple lifecycles; capture completeness is ambiguous",
    );
    if (result.start_event_count == 0) return set(
        result,
        "missing_start_event",
        "capture_complete_trace_lifecycle",
        "Tracy trace does not contain its start event; treat it as partial evidence",
    );
    if (result.stop_event_count == 0) return set(
        result,
        "missing_stop_event",
        "capture_complete_trace_lifecycle",
        "Tracy trace does not contain its stop event; treat terminal state as partial evidence",
    );
    if (result.start_sequence != result.first_sequence or
        result.stop_sequence != result.last_sequence)
    {
        return set(
            result,
            "lifecycle_not_bounded",
            "capture_complete_trace_lifecycle",
            "Tracy start and stop events do not bound the event sequence; " ++
                "treat it as partial evidence",
        );
    }
    if (result.unbalanced_event_count != 0) set(
        result,
        "unbalanced_events",
        "inspect_trace_lifecycles",
        "Tracy trace contains unmatched lifecycle events; inspect capture integrity details",
    );
}

fn set(result: *Integrity, status: []const u8, action: []const u8, message: []const u8) void {
    result.status = status;
    result.action = action;
    result.message = message;
}

fn writeOptionalU64Text(writer: *std.Io.Writer, value: ?u64) !void {
    if (value) |actual| try writer.print("{d}", .{actual}) else try writer.writeAll("none");
}

test "capture tracker classifies missing sequences" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .message }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .stop }).writeJsonLine(&trace.writer);

    var tracker: Tracker = .{};
    var lines = std.mem.tokenizeScalar(u8, trace.written(), '\n');
    while (lines.next()) |line| {
        var parsed = try event.parseLine(std.testing.allocator, line);
        tracker.record(parsed);
        parsed.deinit();
    }
    const integrity = tracker.integrity(0);
    try std.testing.expectEqualStrings("sequence_gaps", integrity.status);
    try std.testing.expectEqual(@as(u64, 2), integrity.missing_sequence_event_count);
}

test "capture tracker writes canonical text and json evidence" {
    var tracker: Tracker = .{};
    tracker.counters.events = 2;
    tracker.counters.unsequenced_events = 2;
    const integrity = tracker.integrity(0);
    var text = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text.deinit();
    try writeText(&text.writer, integrity);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text.written(),
        "capture_integrity=missing_sequence_metadata",
    ) != null);
    var json = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json.deinit();
    var stream = pretty_json.Writer.init(&json.writer, .minified);
    const object = try stream.object();
    try object.field("seed", 0);
    try writeFields(object, integrity);
    try object.end();
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json.written(),
        .{},
    );
    defer parsed.deinit();
}

test "capture tracker preserves an exact flight report" {
    const report: transport.Report = .{
        .policy = .overwrite_oldest,
        .state = .accepting,
        .capacity_bytes = 256,
        .retained_bytes = 128,
        .event_capacity_bytes = 64,
        .writer_capacity_bytes = 32,
        .observed_events = 9,
        .stored_events = 9,
        .retained_events = 6,
        .overwritten_events = 3,
        .dropped_events = 0,
        .oversized_events = 0,
        .partial_event_bytes = 0,
        .discarding_oversized_event = false,
    };
    var tracker: Tracker = .{};
    tracker.recordFlightReport(report);
    const integrity = tracker.integrity(0);
    try std.testing.expectEqualDeep(report, integrity.flight_report.?);

    var text = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text.deinit();
    try writeText(&text.writer, integrity);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text.written(),
        "overwritten_events=3",
    ) != null);

    var json = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json.deinit();
    var stream = pretty_json.Writer.init(&json.writer, .minified);
    const object = try stream.object();
    try object.field("seed", 0);
    try writeFields(object, integrity);
    try object.end();
    try std.testing.expect(std.mem.indexOf(
        u8,
        json.written(),
        "\"flight_report\":{\"schema\":\"tracy.flight/v0\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json.written(),
        "\"overwritten_events\":3",
    ) != null);
}
