const std = @import("std");
const transport = @import("transport.zig");

const assert = std.debug.assert;

const schema = transport.schema;
const OverflowPolicy = transport.OverflowPolicy;
const State = transport.State;
const Report = transport.Report;

pub const FlightRecorder = struct {
    writer: std.Io.Writer,
    storage: []u8,
    event_storage: []u8,
    policy: OverflowPolicy,
    state: State = .accepting,
    header_seen: bool = false,
    header_len: usize = 0,
    ring_head: usize = 0,
    ring_len: usize = 0,
    ring_events: usize = 0,
    event_len: usize = 0,
    discarding_event: bool = false,
    observed_events: u64 = 0,
    stored_events: u64 = 0,
    overwritten_events: u64 = 0,
    dropped_events: u64 = 0,
    oversized_events: u64 = 0,

    pub fn init(
        storage: []u8,
        event_storage: []u8,
        writer_storage: []u8,
        policy: OverflowPolicy,
    ) FlightRecorder {
        assert(storage.len > 0);
        assert(event_storage.len > 0);
        assert(writer_storage.len > 0);
        assert(disjoint(storage, event_storage));
        assert(disjoint(storage, writer_storage));
        assert(disjoint(event_storage, writer_storage));
        var recorder: FlightRecorder = .{
            .writer = .{ .vtable = &writer_vtable, .buffer = writer_storage },
            .storage = storage,
            .event_storage = event_storage,
            .policy = policy,
        };
        recorder.assertValid();
        return recorder;
    }

    pub fn interface(self: *FlightRecorder) *std.Io.Writer {
        self.assertValid();
        return &self.writer;
    }

    pub fn reset(self: *FlightRecorder) void {
        self.writer.flush() catch unreachable;
        self.state = .accepting;
        self.header_seen = false;
        self.header_len = 0;
        self.ring_head = 0;
        self.ring_len = 0;
        self.ring_events = 0;
        self.event_len = 0;
        self.discarding_event = false;
        self.observed_events = 0;
        self.stored_events = 0;
        self.overwritten_events = 0;
        self.dropped_events = 0;
        self.oversized_events = 0;
        self.assertValid();
    }

    pub fn snapshot(self: *FlightRecorder, destination: *std.Io.Writer) !Report {
        if (destination == &self.writer) return error.InvalidSnapshotWriter;
        try self.writer.flush();
        self.assertValid();
        const result = self.report();
        if (self.header_len > 0) {
            try destination.writeAll(self.storage[0..self.header_len]);
        }
        const ring = self.ringStorage();
        if (self.ring_len > 0) {
            const first_len = @min(self.ring_len, ring.len - self.ring_head);
            try destination.writeAll(ring[self.ring_head..][0..first_len]);
            const second_len = self.ring_len - first_len;
            if (second_len > 0) try destination.writeAll(ring[0..second_len]);
        }
        try result.writeJsonl(destination);
        return result;
    }

    pub fn report(self: *FlightRecorder) Report {
        self.writer.flush() catch unreachable;
        self.assertValid();
        const retained_header: usize = if (self.header_len > 0) 1 else 0;
        return .{
            .policy = self.policy,
            .state = self.state,
            .capacity_bytes = self.storage.len,
            .retained_bytes = self.header_len + self.ring_len,
            .event_capacity_bytes = self.event_storage.len,
            .writer_capacity_bytes = self.writer.buffer.len,
            .observed_events = self.observed_events,
            .stored_events = self.stored_events,
            .retained_events = retained_header + self.ring_events,
            .overwritten_events = self.overwritten_events,
            .dropped_events = self.dropped_events,
            .oversized_events = self.oversized_events,
            .partial_event_bytes = self.event_len,
            .discarding_oversized_event = self.discarding_event,
        };
    }

    fn accept(self: *FlightRecorder, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.discarding_event) {
                if (byte == '\n') {
                    self.finishOversizedEvent();
                }
                continue;
            }
            if (byte == '\n') {
                self.commitEvent(self.event_storage[0..self.event_len]);
                self.event_len = 0;
            } else if (self.event_len == self.event_storage.len) {
                self.event_len = 0;
                self.discarding_event = true;
            } else {
                self.event_storage[self.event_len] = byte;
                self.event_len += 1;
            }
        }
        self.assertValid();
    }

    fn finishOversizedEvent(self: *FlightRecorder) void {
        self.observed_events +|= 1;
        self.oversized_events +|= 1;
        self.discarding_event = false;
        if (self.header_seen) return;
        self.header_seen = true;
        if (self.policy == .stop_when_full) self.state = .full;
    }

    fn commitEvent(self: *FlightRecorder, payload: []const u8) void {
        self.observed_events +|= 1;
        const required = std.math.add(usize, payload.len, 1) catch {
            self.oversized_events +|= 1;
            return;
        };
        if (!self.header_seen) {
            self.header_seen = true;
            if (required > self.storage.len) {
                self.oversized_events +|= 1;
                if (self.policy == .stop_when_full) self.state = .full;
                return;
            }
            @memcpy(self.storage[0..payload.len], payload);
            self.storage[payload.len] = '\n';
            self.header_len = required;
            self.stored_events +|= 1;
            return;
        }
        self.commitRingEvent(payload, required);
    }

    fn commitRingEvent(self: *FlightRecorder, payload: []const u8, required: usize) void {
        if (self.state == .full) {
            self.dropped_events +|= 1;
            return;
        }
        const ring = self.ringStorage();
        if (required > ring.len) {
            self.oversized_events +|= 1;
            if (self.policy == .stop_when_full) self.state = .full;
            return;
        }
        if (self.policy == .stop_when_full and required > ring.len - self.ring_len) {
            self.state = .full;
            self.dropped_events +|= 1;
            return;
        }
        while (required > ring.len - self.ring_len) self.evictOldest();
        self.appendRing(payload);
        self.stored_events +|= 1;
        self.ring_events += 1;
    }

    fn appendRing(self: *FlightRecorder, payload: []const u8) void {
        const ring = self.ringStorage();
        assert(payload.len + 1 <= ring.len - self.ring_len);
        var tail = advance(self.ring_head, self.ring_len, ring.len);
        const first_len = @min(payload.len, ring.len - tail);
        @memcpy(ring[tail..][0..first_len], payload[0..first_len]);
        const second_len = payload.len - first_len;
        if (second_len > 0) @memcpy(ring[0..second_len], payload[first_len..]);
        self.ring_len += payload.len;
        tail = advance(self.ring_head, self.ring_len, ring.len);
        ring[tail] = '\n';
        self.ring_len += 1;
    }

    fn evictOldest(self: *FlightRecorder) void {
        const ring = self.ringStorage();
        assert(self.ring_len > 0);
        var event_bytes: usize = 1;
        while (event_bytes <= self.ring_len) : (event_bytes += 1) {
            const index = advance(self.ring_head, event_bytes - 1, ring.len);
            if (ring[index] == '\n') break;
        }
        assert(event_bytes <= self.ring_len);
        self.ring_head = advance(self.ring_head, event_bytes, ring.len);
        self.ring_len -= event_bytes;
        self.ring_events -= 1;
        self.overwritten_events +|= 1;
        if (self.ring_len == 0) self.ring_head = 0;
    }

    fn ringStorage(self: *FlightRecorder) []u8 {
        return self.storage[self.header_len..];
    }

    fn assertValid(self: *FlightRecorder) void {
        assert(self.storage.len > 0);
        assert(self.event_storage.len > 0);
        assert(self.writer.buffer.len > 0);
        assert(self.header_len <= self.storage.len);
        assert(self.ring_len <= self.storage.len - self.header_len);
        assert(self.event_len <= self.event_storage.len);
        if (self.discarding_event) assert(self.event_len == 0);
        assert(self.ring_events <= self.ring_len);
        if (self.state == .full) assert(self.policy == .stop_when_full);
        if (self.ring_len == 0) {
            assert(self.ring_head == 0);
        } else {
            assert(self.ringStorage().len > 0);
            assert(self.ring_head < self.ringStorage().len);
        }
        const header_events: usize = if (self.header_len > 0) 1 else 0;
        if (std.math.cast(u64, header_events + self.ring_events)) |retained| {
            const accounted = std.math.add(u64, self.overwritten_events, retained) catch null;
            if (accounted) |count| {
                if (self.stored_events != std.math.maxInt(u64)) {
                    assert(self.stored_events == count);
                }
            }
        }
        if (self.observed_events != std.math.maxInt(u64)) {
            const accepted = std.math.add(u64, self.stored_events, self.dropped_events) catch null;
            if (accepted) |count| {
                const accounted = std.math.add(u64, count, self.oversized_events) catch null;
                if (accounted) |total| assert(self.observed_events == total);
            }
        }
    }

    const writer_vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.defaultFlush,
        .rebase = std.Io.Writer.defaultRebase,
    };

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *FlightRecorder = @alignCast(@fieldParentPtr("writer", writer));
        assert(data.len > 0);
        self.accept(writer.buffer[0..writer.end]);
        writer.end = 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.accept(bytes);
            consumed += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            self.accept(last);
            consumed += last.len;
        }
        return consumed;
    }
};

fn disjoint(left: []const u8, right: []const u8) bool {
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return false;
    const right_end = std.math.add(usize, right_start, right.len) catch return false;
    return left_end <= right_start or right_end <= left_start;
}

fn advance(start: usize, amount: usize, capacity: usize) usize {
    assert(capacity > 0);
    assert(start < capacity);
    assert(amount <= capacity);
    const until_end = capacity - start;
    if (amount < until_end) return start + amount;
    return amount - until_end;
}

fn expectSnapshot(
    snapshot: []const u8,
    expected_events: []const u8,
    expected_report: Report,
) !void {
    try std.testing.expectEqual(expected_report.retained_bytes, expected_events.len);
    try std.testing.expect(snapshot.len > expected_events.len);
    try std.testing.expectEqualStrings(expected_events, snapshot[0..expected_events.len]);
    const actual_report = try transport.parseLine(
        std.testing.allocator,
        snapshot[expected_events.len..],
    );
    try std.testing.expectEqualDeep(expected_report, actual_report);
}

test "flight recorder preserves the header and latest complete events" {
    var storage: [18]u8 = undefined;
    var events: [8]u8 = undefined;
    var writer_buffer: [5]u8 = undefined;
    var recorder = FlightRecorder.init(&storage, &events, &writer_buffer, .overwrite_oldest);
    try recorder.interface().writeAll("header\none\ntwo22\nthree\n");

    var snapshot = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer snapshot.deinit();
    const result = try recorder.snapshot(&snapshot.writer);
    try expectSnapshot(snapshot.written(), "header\nthree\n", result);
    try std.testing.expectEqual(@as(u64, 4), result.observed_events);
    try std.testing.expectEqual(@as(u64, 2), result.overwritten_events);
    try std.testing.expectEqual(@as(usize, 2), result.retained_events);
}

test "flight recorder overwrite window matches an independent suffix model" {
    const rows = [_][]const u8{ "h\n", "a\n", "b\n", "c\n", "d\n", "e\n" };
    var storage: [16]u8 = undefined;
    var events: [8]u8 = undefined;
    var writer_buffer: [3]u8 = undefined;
    var capacity: usize = 2;
    while (capacity <= storage.len) : (capacity += 1) {
        var recorder = FlightRecorder.init(
            storage[0..capacity],
            &events,
            &writer_buffer,
            .overwrite_oldest,
        );
        for (rows) |row| try recorder.interface().writeAll(row);
        var snapshot = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer snapshot.deinit();
        const result = try recorder.snapshot(&snapshot.writer);

        var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer expected.deinit();
        try expected.writer.writeAll(rows[0]);
        const suffix_count = @min(rows.len - 1, (capacity - rows[0].len) / 2);
        for (rows[rows.len - suffix_count ..]) |row| try expected.writer.writeAll(row);
        try expectSnapshot(snapshot.written(), expected.written(), result);
        try std.testing.expect(result.retained_bytes <= capacity);
        try std.testing.expectEqual(@as(u64, rows.len), result.observed_events);
        try std.testing.expectEqual(1 + suffix_count, result.retained_events);
    }
}

test "flight recorder stop policy preserves the earliest complete window" {
    var storage: [16]u8 = undefined;
    var events: [8]u8 = undefined;
    var writer_buffer: [5]u8 = undefined;
    var recorder = FlightRecorder.init(&storage, &events, &writer_buffer, .stop_when_full);
    try recorder.interface().writeAll("h00\none\ntwo\ntri\nend\nmore\n");

    var snapshot = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer snapshot.deinit();
    const result = try recorder.snapshot(&snapshot.writer);
    try expectSnapshot(snapshot.written(), "h00\none\ntwo\ntri\n", result);
    try std.testing.expectEqual(State.full, result.state);
    try std.testing.expectEqual(@as(u64, 2), result.dropped_events);
    try std.testing.expectEqual(@as(u64, 0), result.overwritten_events);
}

test "flight recorder drops oversized rows without corrupting later rows" {
    var storage: [16]u8 = undefined;
    var events: [4]u8 = undefined;
    var writer_buffer: [3]u8 = undefined;
    var recorder = FlightRecorder.init(&storage, &events, &writer_buffer, .overwrite_oldest);
    try recorder.interface().writeAll("h\n12345\nok\n");

    var snapshot = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer snapshot.deinit();
    const result = try recorder.snapshot(&snapshot.writer);
    try expectSnapshot(snapshot.written(), "h\nok\n", result);
    try std.testing.expectEqual(@as(u64, 3), result.observed_events);
    try std.testing.expectEqual(@as(u64, 1), result.oversized_events);
    try std.testing.expectEqual(@as(u64, 2), result.stored_events);
}

test "flight recorder snapshots analyzable tracy jsonl" {
    const event = @import("event.zig");
    const record_mod = @import("record.zig");
    var storage: [1024]u8 = undefined;
    var events: [512]u8 = undefined;
    var writer_buffer: [256]u8 = undefined;
    var recorder = FlightRecorder.init(&storage, &events, &writer_buffer, .overwrite_oldest);
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 10, .thread = 1 })
        .writeJsonLine(recorder.interface());
    try (event.TraceEvent{ .seq = 2, .kind = .frame, .time_ns = 20, .thread = 1 })
        .writeJsonLine(recorder.interface());

    var snapshot = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer snapshot.deinit();
    _ = try recorder.snapshot(&snapshot.writer);
    var lines = std.mem.tokenizeScalar(u8, snapshot.written(), '\n');
    var event_count: usize = 0;
    var report_count: usize = 0;
    while (lines.next()) |line| {
        var parsed = try record_mod.parseLine(std.testing.allocator, line);
        defer parsed.deinit();
        switch (parsed) {
            .event => event_count += 1,
            .flight => report_count += 1,
        }
    }
    try std.testing.expectEqual(@as(usize, 2), event_count);
    try std.testing.expectEqual(@as(usize, 1), report_count);
}

test "flight recorder overwrite is visible in tracy capture integrity" {
    const event = @import("event.zig");
    const summary = @import("summary.zig");
    var storage: [1024]u8 = undefined;
    var events: [512]u8 = undefined;
    var writer_buffer: [256]u8 = undefined;
    var recorder = FlightRecorder.init(&storage, &events, &writer_buffer, .overwrite_oldest);
    try (event.TraceEvent{ .seq = 1, .kind = .start }).writeJsonLine(recorder.interface());
    for (2..34) |sequence| {
        try (event.TraceEvent{
            .seq = sequence,
            .kind = .message,
            .name = "flight event",
        }).writeJsonLine(recorder.interface());
    }
    try (event.TraceEvent{ .seq = 34, .kind = .stop }).writeJsonLine(recorder.interface());

    var snapshot = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer snapshot.deinit();
    const snapshot_report = try recorder.snapshot(&snapshot.writer);
    var analyzer = summary.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(snapshot.written());
    const integrity = analyzer.captureIntegrity();
    try std.testing.expect(snapshot_report.overwritten_events > 0);
    try std.testing.expectEqualDeep(snapshot_report, integrity.flight_report.?);
    try std.testing.expectEqualStrings("sequence_gaps", integrity.status);
    try std.testing.expect(integrity.missing_sequence_event_count > 0);
    try std.testing.expectEqual(@as(u64, 1), integrity.start_event_count);
    try std.testing.expectEqual(@as(u64, 1), integrity.stop_event_count);
}

test "enabled tracy runtime records through the flight recorder" {
    const build_options = @import("build_options");
    if (!build_options.enabled) return;
    const instrumentation = @import("instrumentation.zig");
    const summary = @import("summary.zig");
    var storage: [4096]u8 = undefined;
    var events: [1024]u8 = undefined;
    var writer_buffer: [512]u8 = undefined;
    var recorder = FlightRecorder.init(&storage, &events, &writer_buffer, .overwrite_oldest);
    try std.testing.expect(try instrumentation.start(recorder.interface(), .{
        .name = "flight test",
    }));
    defer instrumentation.stop();
    const active_zone = instrumentation.zone("flight.test.zone");
    active_zone.end();
    instrumentation.stop();

    var snapshot = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer snapshot.deinit();
    const snapshot_report = try recorder.snapshot(&snapshot.writer);
    var analyzer = summary.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(snapshot.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.completed_zones);
    try std.testing.expectEqual(@as(u64, 4), snapshot_report.observed_events);
    try std.testing.expectEqualDeep(snapshot_report, analyzer.captureIntegrity().flight_report.?);
}

test "flight recorder report is machine readable and resettable" {
    var storage: [16]u8 = undefined;
    var events: [8]u8 = undefined;
    var writer_buffer: [4]u8 = undefined;
    var recorder = FlightRecorder.init(&storage, &events, &writer_buffer, .overwrite_oldest);
    try recorder.interface().writeAll("head\nrow\npartial");
    const before = recorder.report();
    try std.testing.expectEqual(@as(usize, 7), before.partial_event_bytes);

    var jsonl = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer jsonl.deinit();
    try before.writeJsonl(&jsonl.writer);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        jsonl.written(),
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        schema,
        parsed.value.object.get("schema").?.string,
    );
    recorder.reset();
    const after = recorder.report();
    try std.testing.expectEqual(@as(u64, 0), after.observed_events);
    try std.testing.expectEqual(@as(usize, 0), after.retained_bytes);
}
