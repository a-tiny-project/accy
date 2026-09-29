const std = @import("std");
const pretty_json = @import("pretty").json;
const capture_mod = @import("capture.zig");
const report = @import("report.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");
const transport = @import("transport.zig");

pub const schema = "tracy.locks/v0";
pub const CaptureIntegrity = capture_mod.Integrity;

pub const Mode = enum {
    all,
    lock,
    shared,

    pub fn fromName(text: []const u8) ?Mode {
        if (std.mem.eql(u8, text, "all")) return .all;
        if (std.mem.eql(u8, text, "lock")) return .lock;
        if (std.mem.eql(u8, text, "shared")) return .shared;
        return null;
    }

    fn tag(self: Mode) []const u8 {
        return switch (self) {
            .all => "all",
            .lock => "lock",
            .shared => "shared",
        };
    }
};

pub const Kind = enum {
    all,
    wait,
    hold,

    pub fn fromName(text: []const u8) ?Kind {
        if (std.mem.eql(u8, text, "all")) return .all;
        if (std.mem.eql(u8, text, "wait")) return .wait;
        if (std.mem.eql(u8, text, "hold")) return .hold;
        return null;
    }

    fn tag(self: Kind) []const u8 {
        return switch (self) {
            .all => "all",
            .wait => "wait",
            .hold => "hold",
        };
    }
};

pub const Sort = enum {
    wait,
    wait_tail,
    hold,
    hold_tail,
    contention,
    count,
    name,
    last,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "wait")) return .wait;
        if (std.mem.eql(u8, text, "wait-tail")) return .wait_tail;
        if (std.mem.eql(u8, text, "hold")) return .hold;
        if (std.mem.eql(u8, text, "hold-tail")) return .hold_tail;
        if (std.mem.eql(u8, text, "contention")) return .contention;
        if (std.mem.eql(u8, text, "count")) return .count;
        if (std.mem.eql(u8, text, "name")) return .name;
        if (std.mem.eql(u8, text, "last")) return .last;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .wait => "wait",
            .wait_tail => "wait-tail",
            .hold => "hold",
            .hold_tail => "hold-tail",
            .contention => "contention",
            .count => "count",
            .name => "name",
            .last => "last",
        };
    }
};

pub const Options = struct {
    top: usize = 20,
    occurrences: usize = 40,
    sort: Sort = .wait,
    kind: Kind = .all,
    mode: Mode = .all,
    min_wait_ns: u64 = 0,
    min_hold_ns: u64 = 0,
    lock: ?u64 = null,
    thread: ?u64 = null,
    since_ns: ?u64 = null,
    until_ns: ?u64 = null,
    match: ?[]const u8 = null,
    ignore_case: bool = false,
};

pub const Counters = struct {
    events: u64 = 0,
    announces: u64 = 0,
    terminates: u64 = 0,
    names: u64 = 0,
    marks: u64 = 0,
    waits: u64 = 0,
    obtains: u64 = 0,
    releases: u64 = 0,
    shared_waits: u64 = 0,
    shared_obtains: u64 = 0,
    shared_releases: u64 = 0,
    completed_waits: u64 = 0,
    completed_holds: u64 = 0,
    wait_samples: u64 = 0,
    hold_samples: u64 = 0,
    duplicate_waits: u64 = 0,
    duplicate_obtains: u64 = 0,
    timestamp_regressions: u64 = 0,
    unmatched_releases: u64 = 0,
};

const SlotKey = struct {
    lock: u64,
    thread: u64,
    shared: bool,
};

const WaitRecord = struct {
    start_ns: u64,
};

const HoldRecord = struct {
    start_ns: u64,
};

const Entry = struct {
    kind: Kind,
    lock: u64,
    thread: u64,
    shared: bool,
    start_ns: u64,
    end_ns: u64,
    duration_ns: u64,
    valid_time: bool = true,
};

const DurationSample = struct {
    lock: u64,
    duration_ns: u64,
};

const LockState = struct {
    id: u64,
    mode: Mode = .lock,
    name: ?[]u8 = null,
    file: ?[]u8 = null,
    function: ?[]u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    announce_ns: u64 = 0,
    terminate_ns: u64 = 0,
    last_event_ns: u64 = 0,
    mark_count: u64 = 0,
    last_mark_file: ?[]u8 = null,
    last_mark_function: ?[]u8 = null,
    last_mark_line: u32 = 0,
    threads: std.AutoHashMapUnmanaged(u64, void) = .{},

    fn deinit(self: *LockState, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.file) |file| allocator.free(file);
        if (self.function) |function| allocator.free(function);
        if (self.last_mark_file) |file| allocator.free(file);
        if (self.last_mark_function) |function| allocator.free(function);
        self.threads.deinit(allocator);
        self.* = undefined;
    }

    fn displayName(self: LockState) []const u8 {
        return self.name orelse "<lock>";
    }
};

const Row = struct {
    id: u64,
    name: []const u8,
    mode: Mode,
    file: ?[]const u8,
    function: ?[]const u8,
    line: u32,
    column: u32,
    announce_ns: u64,
    terminate_ns: u64,
    last_event_ns: u64,
    mark_count: u64,
    last_mark_file: ?[]const u8,
    last_mark_function: ?[]const u8,
    last_mark_line: u32,
    thread_count: u64,
    wait_count: u64 = 0,
    hold_count: u64 = 0,
    total_wait_ns: u64 = 0,
    wait_mean_ns: u64 = 0,
    wait_min_ns: u64 = 0,
    wait_p50_ns: u64 = 0,
    wait_p90_ns: u64 = 0,
    wait_p99_ns: u64 = 0,
    max_wait_ns: u64 = 0,
    total_hold_ns: u64 = 0,
    hold_mean_ns: u64 = 0,
    hold_min_ns: u64 = 0,
    hold_p50_ns: u64 = 0,
    hold_p90_ns: u64 = 0,
    hold_p99_ns: u64 = 0,
    max_hold_ns: u64 = 0,

    fn eventCount(self: Row) u64 {
        return self.wait_count + self.hold_count;
    }
};

pub const Summary = Row;

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    capture: capture_mod.Tracker = .{},
    locks: std.AutoHashMapUnmanaged(u64, LockState) = .{},
    pending_waits: std.AutoHashMapUnmanaged(SlotKey, WaitRecord) = .{},
    pending_holds: std.AutoHashMapUnmanaged(SlotKey, HoldRecord) = .{},
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        var lock_iter = self.locks.valueIterator();
        while (lock_iter.next()) |lock| lock.deinit(self.allocator);
        self.locks.deinit(self.allocator);
        self.pending_waits.deinit(self.allocator);
        self.pending_holds.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ingestJsonlBytes(self: *Analyzer, bytes: []const u8) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| try self.ingestJsonLine(line);
    }

    pub fn ingestJsonLine(self: *Analyzer, line: []const u8) !void {
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) return;
        var parsed = try record_mod.parseLine(self.allocator, text);
        defer parsed.deinit();
        switch (parsed) {
            .event => |value| try self.ingest(value),
            .flight => |report_value| self.recordFlightReport(report_value),
        }
    }

    pub fn ingest(self: *Analyzer, parsed: event.Parsed) !void {
        self.capture.record(parsed);
        self.counters.events += 1;
        if (self.start_ns == null and parsed.time_ns != 0) self.start_ns = parsed.time_ns;
        if (parsed.time_ns != 0) self.end_ns = parsed.time_ns;
        switch (parsed.kind) {
            .start => {
                if (parsed.time_ns != 0) self.start_ns = parsed.time_ns;
            },
            .stop => {
                if (parsed.time_ns != 0) self.end_ns = parsed.time_ns;
            },
            .lock_announce => try self.recordAnnounce(parsed),
            .lock_terminate => try self.recordTerminate(parsed),
            .lock_name => try self.recordName(parsed),
            .lock_mark => try self.recordMark(parsed),
            .lock_wait => try self.recordWait(parsed, false),
            .lock_obtain => try self.recordObtain(parsed, false),
            .lock_release => try self.recordRelease(parsed, false),
            .lock_shared_wait => try self.recordWait(parsed, true),
            .lock_shared_obtain => try self.recordObtain(parsed, true),
            .lock_shared_release => try self.recordRelease(parsed, true),
            else => {},
        }
    }

    pub fn durationNs(self: Analyzer) u64 {
        const start_ns = self.start_ns orelse return 0;
        const end_ns = self.end_ns orelse return 0;
        if (end_ns <= start_ns) return 0;
        return end_ns - start_ns;
    }

    pub fn captureIntegrity(self: Analyzer) CaptureIntegrity {
        return self.capture.integrity(0);
    }

    pub fn durationEvidence(self: Analyzer) []const u8 {
        if (!std.mem.eql(u8, self.captureIntegrity().status, "complete")) return "partial";
        if (self.counters.timestamp_regressions != 0) return "partial";
        if (self.counters.duplicate_waits != 0) return "partial";
        if (self.counters.duplicate_obtains != 0) return "partial";
        if (self.counters.unmatched_releases != 0) return "partial";
        if (self.pending_waits.count() != 0) return "partial";
        if (self.pending_holds.count() != 0) return "partial";
        return "complete";
    }

    pub fn recordFlightReport(self: *Analyzer, report_value: transport.Report) void {
        self.capture.recordFlightReport(report_value);
    }

    pub fn collectRows(
        self: *Analyzer,
        allocator: std.mem.Allocator,
        options: Options,
    ) !std.ArrayListUnmanaged(Row) {
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        errdefer rows.deinit(allocator);
        var row_index: std.AutoHashMapUnmanaged(u64, usize) = .{};
        defer row_index.deinit(allocator);
        var wait_samples: std.ArrayListUnmanaged(DurationSample) = .empty;
        defer wait_samples.deinit(allocator);
        var hold_samples: std.ArrayListUnmanaged(DurationSample) = .empty;
        defer hold_samples.deinit(allocator);
        for (self.entries.items) |entry| {
            if (!self.entryMatches(entry, options)) continue;
            if (!entry.valid_time) continue;
            const row_pos = try self.rowForEntry(allocator, &rows, &row_index, entry.lock);
            if (entry.kind == .wait) {
                rows.items[row_pos].wait_count += 1;
                rows.items[row_pos].total_wait_ns +|= entry.duration_ns;
                rows.items[row_pos].max_wait_ns = @max(
                    rows.items[row_pos].max_wait_ns,
                    entry.duration_ns,
                );
                try wait_samples.append(allocator, .{
                    .lock = entry.lock,
                    .duration_ns = entry.duration_ns,
                });
            } else if (entry.kind == .hold) {
                rows.items[row_pos].hold_count += 1;
                rows.items[row_pos].total_hold_ns +|= entry.duration_ns;
                rows.items[row_pos].max_hold_ns = @max(
                    rows.items[row_pos].max_hold_ns,
                    entry.duration_ns,
                );
                try hold_samples.append(allocator, .{
                    .lock = entry.lock,
                    .duration_ns = entry.duration_ns,
                });
            }
            rows.items[row_pos].last_event_ns = @max(
                rows.items[row_pos].last_event_ns,
                entry.end_ns,
            );
        }
        applyDurationDistributions(rows.items, &row_index, wait_samples.items, .wait);
        applyDurationDistributions(rows.items, &row_index, hold_samples.items, .hold);
        sortRows(rows.items, options.sort);
        if (rows.items.len > options.top) rows.shrinkRetainingCapacity(options.top);
        return rows;
    }

    pub fn collectOccurrences(
        self: *Analyzer,
        allocator: std.mem.Allocator,
        options: Options,
    ) !std.ArrayListUnmanaged(Entry) {
        var rows: std.ArrayListUnmanaged(Entry) = .empty;
        errdefer rows.deinit(allocator);
        for (self.entries.items) |entry| {
            if (!self.entryMatches(entry, options)) continue;
            try rows.append(allocator, entry);
        }
        std.mem.sort(Entry, rows.items, {}, entryDurationGreaterThan);
        if (rows.items.len > options.occurrences) {
            rows.shrinkRetainingCapacity(options.occurrences);
        }
        return rows;
    }

    fn recordAnnounce(self: *Analyzer, parsed: event.Parsed) !void {
        if (parsed.id == 0) return;
        const lock = try self.ensureLock(parsed.id);
        lock.mode = parseMode(parsed.lock_kind);
        lock.announce_ns = parsed.time_ns;
        lock.last_event_ns = parsed.time_ns;
        try replaceOptional(self.allocator, &lock.name, parsed.name);
        try replaceOptional(self.allocator, &lock.file, parsed.file);
        try replaceOptional(self.allocator, &lock.function, parsed.function);
        lock.line = parsed.line;
        lock.column = parsed.column;
        self.counters.announces += 1;
    }

    fn recordTerminate(self: *Analyzer, parsed: event.Parsed) !void {
        if (parsed.id == 0) return;
        const lock = try self.ensureLock(parsed.id);
        lock.terminate_ns = parsed.time_ns;
        lock.last_event_ns = parsed.time_ns;
        self.counters.terminates += 1;
    }

    fn recordName(self: *Analyzer, parsed: event.Parsed) !void {
        if (parsed.id == 0) return;
        const name = parsed.name orelse return;
        const lock = try self.ensureLock(parsed.id);
        try replaceOptional(self.allocator, &lock.name, name);
        lock.last_event_ns = parsed.time_ns;
        self.counters.names += 1;
    }

    fn recordMark(self: *Analyzer, parsed: event.Parsed) !void {
        if (parsed.id == 0) return;
        const lock = try self.ensureLock(parsed.id);
        lock.mark_count += 1;
        lock.last_event_ns = parsed.time_ns;
        lock.last_mark_line = parsed.line;
        try replaceOptional(self.allocator, &lock.last_mark_file, parsed.file);
        try replaceOptional(self.allocator, &lock.last_mark_function, parsed.function);
        try self.recordThread(lock, parsed.thread);
        self.counters.marks += 1;
    }

    fn recordWait(self: *Analyzer, parsed: event.Parsed, shared: bool) !void {
        if (parsed.id == 0) return;
        const lock = try self.ensureLock(parsed.id);
        if (shared) {
            lock.mode = .shared;
            self.counters.shared_waits += 1;
        } else {
            self.counters.waits += 1;
        }
        lock.last_event_ns = parsed.time_ns;
        try self.recordThread(lock, parsed.thread);
        const key = SlotKey{ .lock = parsed.id, .thread = parsed.thread, .shared = shared };
        if (self.pending_waits.contains(key)) {
            self.counters.duplicate_waits +|= 1;
            return;
        }
        try self.pending_waits.put(self.allocator, key, .{ .start_ns = parsed.time_ns });
    }

    fn recordObtain(self: *Analyzer, parsed: event.Parsed, shared: bool) !void {
        if (parsed.id == 0) return;
        const lock = try self.ensureLock(parsed.id);
        if (shared) {
            lock.mode = .shared;
            self.counters.shared_obtains += 1;
        } else {
            self.counters.obtains += 1;
        }
        lock.last_event_ns = parsed.time_ns;
        try self.recordThread(lock, parsed.thread);
        const key = SlotKey{ .lock = parsed.id, .thread = parsed.thread, .shared = shared };
        if (self.pending_waits.fetchRemove(key)) |removed| {
            try self.recordCompleted(
                .wait,
                parsed.id,
                parsed.thread,
                shared,
                removed.value.start_ns,
                parsed.time_ns,
            );
        }
        if (self.pending_holds.contains(key)) {
            self.counters.duplicate_obtains +|= 1;
            return;
        }
        try self.pending_holds.put(self.allocator, key, .{ .start_ns = parsed.time_ns });
    }

    fn recordRelease(self: *Analyzer, parsed: event.Parsed, shared: bool) !void {
        if (parsed.id == 0) return;
        const lock = try self.ensureLock(parsed.id);
        if (shared) {
            lock.mode = .shared;
            self.counters.shared_releases += 1;
        } else {
            self.counters.releases += 1;
        }
        lock.last_event_ns = parsed.time_ns;
        try self.recordThread(lock, parsed.thread);
        const key = SlotKey{ .lock = parsed.id, .thread = parsed.thread, .shared = shared };
        if (self.pending_holds.fetchRemove(key)) |removed| {
            try self.recordCompleted(
                .hold,
                parsed.id,
                parsed.thread,
                shared,
                removed.value.start_ns,
                parsed.time_ns,
            );
        } else {
            self.counters.unmatched_releases +|= 1;
        }
    }

    fn recordCompleted(
        self: *Analyzer,
        kind: Kind,
        lock: u64,
        thread: u64,
        shared: bool,
        start_ns: u64,
        end_ns: u64,
    ) !void {
        const valid_time = end_ns >= start_ns;
        try self.recordEntry(.{
            .kind = kind,
            .lock = lock,
            .thread = thread,
            .shared = shared,
            .start_ns = start_ns,
            .end_ns = end_ns,
            .duration_ns = duration(start_ns, end_ns),
            .valid_time = valid_time,
        });
        switch (kind) {
            .wait => {
                self.counters.completed_waits +|= 1;
                if (valid_time) self.counters.wait_samples +|= 1;
            },
            .hold => {
                self.counters.completed_holds +|= 1;
                if (valid_time) self.counters.hold_samples +|= 1;
            },
            .all => unreachable,
        }
        if (!valid_time) self.counters.timestamp_regressions +|= 1;
    }

    fn recordEntry(self: *Analyzer, entry: Entry) !void {
        try self.entries.append(self.allocator, entry);
    }

    fn ensureLock(self: *Analyzer, id: u64) !*LockState {
        const entry = try self.locks.getOrPut(self.allocator, id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .id = id };
        }
        return entry.value_ptr;
    }

    fn recordThread(self: *Analyzer, lock: *LockState, thread: u64) !void {
        try lock.threads.put(self.allocator, thread, {});
    }

    fn entryMatches(self: *Analyzer, entry: Entry, options: Options) bool {
        if (options.kind != .all and entry.kind != options.kind) return false;
        if (options.mode != .all and entryMode(entry) != options.mode) return false;
        if (options.lock) |lock_id| {
            if (entry.lock != lock_id) return false;
        }
        if (options.thread) |thread| {
            if (entry.thread != thread) return false;
        }
        if (entry.kind == .wait and entry.duration_ns < options.min_wait_ns) return false;
        if (entry.kind == .hold and entry.duration_ns < options.min_hold_ns) return false;
        if (options.since_ns) |since_ns| {
            if (entry.end_ns < since_ns) return false;
        }
        if (options.until_ns) |until_ns| {
            if (entry.start_ns > until_ns) return false;
        }
        if (options.match) |needle| {
            const lock = self.locks.get(entry.lock) orelse return false;
            if (!lockContains(lock, needle, options.ignore_case)) return false;
        }
        return true;
    }

    fn rowForEntry(
        self: *Analyzer,
        allocator: std.mem.Allocator,
        rows: *std.ArrayListUnmanaged(Row),
        row_index: *std.AutoHashMapUnmanaged(u64, usize),
        lock_id: u64,
    ) !usize {
        if (row_index.get(lock_id)) |index| return index;
        const lock = self.locks.get(lock_id) orelse LockState{ .id = lock_id };
        const index = rows.items.len;
        try rows.append(allocator, .{
            .id = lock_id,
            .name = lock.displayName(),
            .mode = lock.mode,
            .file = lock.file,
            .function = lock.function,
            .line = lock.line,
            .column = lock.column,
            .announce_ns = lock.announce_ns,
            .terminate_ns = lock.terminate_ns,
            .last_event_ns = lock.last_event_ns,
            .mark_count = lock.mark_count,
            .last_mark_file = lock.last_mark_file,
            .last_mark_function = lock.last_mark_function,
            .last_mark_line = lock.last_mark_line,
            .thread_count = lock.threads.count(),
        });
        try row_index.put(allocator, lock_id, index);
        return index;
    }
};

pub fn writeTextFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    return report.writeFromJsonlPath(Analyzer, writeText, allocator, path, writer, options);
}

pub fn writeJsonlFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    return report.writeFromJsonlPath(Analyzer, writeJsonl, allocator, path, writer, options);
}

pub fn ingestPath(analyzer: *Analyzer, path: []const u8) !void {
    return report.ingestJsonlPath(analyzer, path);
}

fn writeText(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var rows = try analyzer.collectRows(allocator, options);
    defer rows.deinit(allocator);
    var occurrences = try analyzer.collectOccurrences(allocator, options);
    defer occurrences.deinit(allocator);
    try writeTextSummary(writer, analyzer, options, rows.items.len);
    try capture_mod.writeText(writer, analyzer.captureIntegrity());
    for (rows.items) |row| {
        try writer.print("lock id={d} name=", .{row.id});
        try pretty_json.writeString(writer, row.name);
        try writer.print(" mode={s}", .{row.mode.tag()});
        try writeSummaryDurationsText(writer, row);
        try writer.print(" threads={d} marks={d} last_event_ns={d}", .{
            row.thread_count,
            row.mark_count,
            row.last_event_ns,
        });
        if (row.file) |file| try writer.print(" source={s}:{d}", .{ file, row.line });
        if (row.last_mark_file) |file| {
            try writer.print(" mark={s}:{d}", .{ file, row.last_mark_line });
        }
        try writer.writeByte('\n');
    }
    for (occurrences.items) |entry| {
        try writeTextOccurrence(writer, analyzer, entry);
    }
}

fn writeTextSummary(
    writer: *std.Io.Writer,
    analyzer: *Analyzer,
    options: Options,
    row_count: usize,
) !void {
    try writer.print(
        "tracy locks locks={d} rows={d} events={d} waits={d} holds={d} " ++
            "wait_samples={d} hold_samples={d} pending_waits={d} pending_holds={d} " ++
            "duplicate_waits={d} duplicate_obtains={d} timestamp_regressions={d} " ++
            "unmatched_releases={d} duration_evidence={s} duration_ns={d} " ++
            "kind={s} mode={s} sort={s}\n",
        .{
            analyzer.locks.count(),
            row_count,
            analyzer.counters.events,
            analyzer.counters.completed_waits,
            analyzer.counters.completed_holds,
            analyzer.counters.wait_samples,
            analyzer.counters.hold_samples,
            analyzer.pending_waits.count(),
            analyzer.pending_holds.count(),
            analyzer.counters.duplicate_waits,
            analyzer.counters.duplicate_obtains,
            analyzer.counters.timestamp_regressions,
            analyzer.counters.unmatched_releases,
            analyzer.durationEvidence(),
            analyzer.durationNs(),
            options.kind.tag(),
            options.mode.tag(),
            options.sort.tag(),
        },
    );
}

fn writeTextOccurrence(writer: *std.Io.Writer, analyzer: *Analyzer, entry: Entry) !void {
    try writer.print(
        "occurrence kind={s} lock={d} mode={s} thread={d} start_ns={d} " ++
            "end_ns={d} duration_ns={d}",
        .{
            entry.kind.tag(),
            entry.lock,
            entryMode(entry).tag(),
            entry.thread,
            entry.start_ns,
            entry.end_ns,
            entry.duration_ns,
        },
    );
    if (analyzer.locks.get(entry.lock)) |lock| {
        try writer.writeAll(" name=");
        try pretty_json.writeString(writer, lock.displayName());
    }
    if (!entry.valid_time) try writer.writeAll(" valid_time=false");
    try writer.writeByte('\n');
}

fn writeJsonl(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var rows = try analyzer.collectRows(allocator, options);
    defer rows.deinit(allocator);
    var occurrences = try analyzer.collectOccurrences(allocator, options);
    defer occurrences.deinit(allocator);
    try writeJsonSummary(writer, analyzer, options, rows.items.len);
    for (rows.items) |row| try writeJsonLock(writer, row);
    for (occurrences.items) |entry| try writeJsonOccurrence(writer, analyzer, entry);
}

fn writeJsonSummary(
    writer: *std.Io.Writer,
    analyzer: *Analyzer,
    options: Options,
    row_count: usize,
) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "summary");
    try object.field("locks", analyzer.locks.count());
    try object.field("rows", row_count);
    try object.field("events", analyzer.counters.events);
    try object.field("waits", analyzer.counters.completed_waits);
    try object.field("holds", analyzer.counters.completed_holds);
    try object.field("wait_samples", analyzer.counters.wait_samples);
    try object.field("hold_samples", analyzer.counters.hold_samples);
    try object.field("pending_waits", analyzer.pending_waits.count());
    try object.field("pending_holds", analyzer.pending_holds.count());
    try object.field("duplicate_waits", analyzer.counters.duplicate_waits);
    try object.field("duplicate_obtains", analyzer.counters.duplicate_obtains);
    try object.field("timestamp_regressions", analyzer.counters.timestamp_regressions);
    try object.field("unmatched_releases", analyzer.counters.unmatched_releases);
    try object.field("duration_ns", analyzer.durationNs());
    try object.field("filter_kind", options.kind.tag());
    try object.field("mode", options.mode.tag());
    try object.field("sort", options.sort.tag());
    try object.field("duration_evidence", analyzer.durationEvidence());
    try capture_mod.writeFields(object, analyzer.captureIntegrity());
    try object.endLine();
}

fn writeJsonLock(writer: *std.Io.Writer, row: Row) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "lock");
    try object.field("id", row.id);
    try object.field("name", row.name);
    try object.field("mode", row.mode.tag());
    try writeSummaryDurationFields(object, row);
    try object.field("threads", row.thread_count);
    try object.field("marks", row.mark_count);
    try object.field("announce_ns", row.announce_ns);
    try object.field("terminate_ns", row.terminate_ns);
    try object.field("last_event_ns", row.last_event_ns);
    if (row.file) |file| {
        try object.field("file", file);
        try object.field("line", row.line);
    }
    if (row.function) |function| try object.field("function", function);
    if (row.last_mark_file) |file| {
        try object.field("mark_file", file);
        try object.field("mark_line", row.last_mark_line);
    }
    if (row.last_mark_function) |function| try object.field("mark_function", function);
    try object.endLine();
}

fn writeJsonOccurrence(writer: *std.Io.Writer, analyzer: *Analyzer, entry: Entry) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", entry.kind.tag());
    try object.field("lock", entry.lock);
    try object.field("thread", entry.thread);
    try object.field("start_ns", entry.start_ns);
    try object.field("end_ns", entry.end_ns);
    try object.field("duration_ns", entry.duration_ns);
    try object.field("mode", entryMode(entry).tag());
    if (analyzer.locks.get(entry.lock)) |lock| try object.field("name", lock.displayName());
    if (!entry.valid_time) try object.field("valid_time", false);
    try object.endLine();
}

fn parseMode(lock_kind: ?[]const u8) Mode {
    const text = lock_kind orelse return .lock;
    return Mode.fromName(text) orelse .lock;
}

fn entryMode(entry: Entry) Mode {
    return if (entry.shared) .shared else .lock;
}

fn duration(start_ns: u64, end_ns: u64) u64 {
    if (end_ns <= start_ns) return 0;
    return end_ns - start_ns;
}

fn applyDurationDistributions(
    rows: []Row,
    row_index: *const std.AutoHashMapUnmanaged(u64, usize),
    samples: []DurationSample,
    kind: Kind,
) void {
    std.mem.sort(DurationSample, samples, {}, durationSampleLessThan);
    var start: usize = 0;
    while (start < samples.len) {
        var end = start + 1;
        while (end < samples.len and samples[end].lock == samples[start].lock) : (end += 1) {}
        const row = &rows[row_index.get(samples[start].lock).?];
        applyDurationDistribution(row, samples[start..end], kind);
        start = end;
    }
}

fn applyDurationDistribution(row: *Row, samples: []const DurationSample, kind: Kind) void {
    const count: u64 = @intCast(samples.len);
    switch (kind) {
        .wait => {
            row.wait_mean_ns = row.total_wait_ns / count;
            row.wait_min_ns = durationPercentile(samples, 0);
            row.wait_p50_ns = durationPercentile(samples, 50);
            row.wait_p90_ns = durationPercentile(samples, 90);
            row.wait_p99_ns = durationPercentile(samples, 99);
            row.max_wait_ns = durationPercentile(samples, 100);
        },
        .hold => {
            row.hold_mean_ns = row.total_hold_ns / count;
            row.hold_min_ns = durationPercentile(samples, 0);
            row.hold_p50_ns = durationPercentile(samples, 50);
            row.hold_p90_ns = durationPercentile(samples, 90);
            row.hold_p99_ns = durationPercentile(samples, 99);
            row.max_hold_ns = durationPercentile(samples, 100);
        },
        .all => unreachable,
    }
}

fn durationPercentile(samples: []const DurationSample, percent: u64) u64 {
    const rank: usize = @intCast((@as(u128, @min(percent, 100)) * samples.len + 99) / 100);
    const index = @min(@max(rank, 1) - 1, samples.len - 1);
    return samples[index].duration_ns;
}

fn durationSampleLessThan(_: void, left: DurationSample, right: DurationSample) bool {
    if (left.lock != right.lock) return left.lock < right.lock;
    return left.duration_ns < right.duration_ns;
}

fn replaceOptional(allocator: std.mem.Allocator, field: *?[]u8, text: ?[]const u8) !void {
    if (field.*) |old| allocator.free(old);
    field.* = null;
    if (text) |actual| field.* = try allocator.dupe(u8, actual);
}

fn lockContains(lock: LockState, needle: []const u8, ignore_case: bool) bool {
    if (contains(lock.displayName(), needle, ignore_case)) return true;
    if (lock.file) |file| if (contains(file, needle, ignore_case)) return true;
    if (lock.function) |function| if (contains(function, needle, ignore_case)) return true;
    if (lock.last_mark_file) |file| if (contains(file, needle, ignore_case)) return true;
    if (lock.last_mark_function) |function| {
        if (contains(function, needle, ignore_case)) return true;
    }
    return false;
}

fn contains(haystack: []const u8, needle: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.indexOf(u8, haystack, needle) != null;
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (asciiEqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn asciiEqlIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn sortRows(items: []Row, sort: Sort) void {
    std.mem.sort(Row, items, sort, rowLessThan);
}

fn rowLessThan(sort: Sort, left: Row, right: Row) bool {
    return switch (sort) {
        .wait => rowWaitGreaterThan({}, left, right),
        .wait_tail => rowWaitTailGreaterThan({}, left, right),
        .hold => rowHoldGreaterThan({}, left, right),
        .hold_tail => rowHoldTailGreaterThan({}, left, right),
        .contention => rowContentionGreaterThan({}, left, right),
        .count => rowCountGreaterThan({}, left, right),
        .name => rowNameLessThan({}, left, right),
        .last => rowLastGreaterThan({}, left, right),
    };
}

fn rowWaitGreaterThan(_: void, left: Row, right: Row) bool {
    if (left.total_wait_ns != right.total_wait_ns) return left.total_wait_ns > right.total_wait_ns;
    if (left.max_wait_ns != right.max_wait_ns) return left.max_wait_ns > right.max_wait_ns;
    return rowNameLessThan({}, left, right);
}

fn rowWaitTailGreaterThan(_: void, left: Row, right: Row) bool {
    if (left.wait_p99_ns != right.wait_p99_ns) return left.wait_p99_ns > right.wait_p99_ns;
    if (left.max_wait_ns != right.max_wait_ns) return left.max_wait_ns > right.max_wait_ns;
    return rowWaitGreaterThan({}, left, right);
}

fn rowHoldGreaterThan(_: void, left: Row, right: Row) bool {
    if (left.total_hold_ns != right.total_hold_ns) return left.total_hold_ns > right.total_hold_ns;
    if (left.max_hold_ns != right.max_hold_ns) return left.max_hold_ns > right.max_hold_ns;
    return rowNameLessThan({}, left, right);
}

fn rowHoldTailGreaterThan(_: void, left: Row, right: Row) bool {
    if (left.hold_p99_ns != right.hold_p99_ns) return left.hold_p99_ns > right.hold_p99_ns;
    if (left.max_hold_ns != right.max_hold_ns) return left.max_hold_ns > right.max_hold_ns;
    return rowHoldGreaterThan({}, left, right);
}

fn rowContentionGreaterThan(_: void, left: Row, right: Row) bool {
    if (left.max_wait_ns != right.max_wait_ns) return left.max_wait_ns > right.max_wait_ns;
    return rowWaitGreaterThan({}, left, right);
}

fn rowCountGreaterThan(_: void, left: Row, right: Row) bool {
    if (left.eventCount() != right.eventCount()) return left.eventCount() > right.eventCount();
    return rowWaitGreaterThan({}, left, right);
}

fn rowLastGreaterThan(_: void, left: Row, right: Row) bool {
    if (left.last_event_ns != right.last_event_ns) return left.last_event_ns > right.last_event_ns;
    return rowNameLessThan({}, left, right);
}

fn rowNameLessThan(_: void, left: Row, right: Row) bool {
    if (!std.mem.eql(u8, left.name, right.name)) return std.mem.lessThan(u8, left.name, right.name);
    return left.id < right.id;
}

fn entryDurationGreaterThan(_: void, left: Entry, right: Entry) bool {
    if (left.duration_ns != right.duration_ns) return left.duration_ns > right.duration_ns;
    if (left.end_ns != right.end_ns) return left.end_ns < right.end_ns;
    return left.lock < right.lock;
}

pub fn writeSummaryDurationsText(writer: *std.Io.Writer, row: Summary) !void {
    try writer.print(
        " waits={d} wait_total_ns={d} wait_mean_ns={d} wait_min_ns={d} " ++
            "wait_p50_ns={d} wait_p90_ns={d} wait_p99_ns={d} wait_max_ns={d} " ++
            "holds={d} hold_total_ns={d} hold_mean_ns={d} hold_min_ns={d} " ++
            "hold_p50_ns={d} hold_p90_ns={d} hold_p99_ns={d} hold_max_ns={d}",
        .{
            row.wait_count,
            row.total_wait_ns,
            row.wait_mean_ns,
            row.wait_min_ns,
            row.wait_p50_ns,
            row.wait_p90_ns,
            row.wait_p99_ns,
            row.max_wait_ns,
            row.hold_count,
            row.total_hold_ns,
            row.hold_mean_ns,
            row.hold_min_ns,
            row.hold_p50_ns,
            row.hold_p90_ns,
            row.hold_p99_ns,
            row.max_hold_ns,
        },
    );
}

pub fn writeSummaryDurationFields(object: pretty_json.Object, row: Summary) !void {
    try object.field("waits", row.wait_count);
    try object.field("wait_total_ns", row.total_wait_ns);
    try object.field("wait_mean_ns", row.wait_mean_ns);
    try object.field("wait_min_ns", row.wait_min_ns);
    try object.field("wait_p50_ns", row.wait_p50_ns);
    try object.field("wait_p90_ns", row.wait_p90_ns);
    try object.field("wait_p99_ns", row.wait_p99_ns);
    try object.field("wait_max_ns", row.max_wait_ns);
    try object.field("holds", row.hold_count);
    try object.field("hold_total_ns", row.total_hold_ns);
    try object.field("hold_mean_ns", row.hold_mean_ns);
    try object.field("hold_min_ns", row.hold_min_ns);
    try object.field("hold_p50_ns", row.hold_p50_ns);
    try object.field("hold_p90_ns", row.hold_p90_ns);
    try object.field("hold_p99_ns", row.hold_p99_ns);
    try object.field("hold_max_ns", row.max_hold_ns);
}

test "locks text aggregates wait and hold durations" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 90, .thread = 1, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .lock_announce, .time_ns = 100, .thread = 1, .id = 7, .name = "queue-lock", .file = "locks.zig", .function = "init", .line = 3, .lock_kind = "lock" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .lock_wait, .time_ns = 110, .thread = 1, .id = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .lock_obtain, .time_ns = 150, .thread = 1, .id = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .lock_mark, .time_ns = 155, .thread = 1, .id = 7, .file = "critical.zig", .function = "work", .line = 12 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .lock_release, .time_ns = 210, .thread = 1, .id = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .lock_terminate, .time_ns = 220, .thread = 1, .id = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 8, .kind = .stop, .time_ns = 230, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4, .occurrences = 4, .sort = .contention });
    const text = out.written();
    try expectLockContains(
        text,
        "events=8 waits=1 holds=1 wait_samples=1 hold_samples=1 " ++
            "pending_waits=0 pending_holds=0",
    );
    try expectLockContains(
        text,
        "wait_total_ns=40 wait_mean_ns=40 wait_min_ns=40 wait_p50_ns=40 " ++
            "wait_p90_ns=40 wait_p99_ns=40 wait_max_ns=40",
    );
    try expectLockContains(
        text,
        "hold_total_ns=60 hold_mean_ns=60 hold_min_ns=60 hold_p50_ns=60 " ++
            "hold_p90_ns=60 hold_p99_ns=60 hold_max_ns=60",
    );
    try expectLockContains(text, "mark=critical.zig:12");
    try expectLockContains(
        text,
        "occurrence kind=hold lock=7 mode=lock thread=1 start_ns=150 " ++
            "end_ns=210 duration_ns=60 name=\"queue-lock\"",
    );
    try expectLockContains(
        text,
        "occurrence kind=wait lock=7 mode=lock thread=1 start_ns=110 " ++
            "end_ns=150 duration_ns=40 name=\"queue-lock\"",
    );
}

test "locks jsonl filters shared waits by thread and window" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .lock_announce, .time_ns = 100, .thread = 1, .id = 2, .name = "cache", .lock_kind = "shared" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .lock_shared_wait, .time_ns = 120, .thread = 3, .id = 2 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .lock_shared_obtain, .time_ns = 170, .thread = 3, .id = 2 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .lock_shared_release, .time_ns = 220, .thread = 3, .id = 2 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .lock_shared_wait, .time_ns = 300, .thread = 4, .id = 2 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .lock_shared_obtain, .time_ns = 310, .thread = 4, .id = 2 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .lock_shared_release, .time_ns = 330, .thread = 4, .id = 2 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{
        .top = 4,
        .occurrences = 4,
        .kind = .wait,
        .mode = .shared,
        .thread = 3,
        .since_ns = 100,
        .until_ns = 200,
        .min_wait_ns = 40,
        .match = "CACHE",
        .ignore_case = true,
    });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.locks/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"summary\",\"locks\":1,\"rows\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"lock\",\"id\":2,\"name\":\"cache\",\"mode\":\"shared\",\"waits\":1,\"wait_total_ns\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"wait\",\"lock\":2,\"thread\":3,\"start_ns\":120,\"end_ns\":170,\"duration_ns\":50,\"mode\":\"shared\",\"name\":\"cache\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"thread\":4") == null);
}

test "locks preserve exact wait and hold distributions" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var seq: u64 = 1;
    try (event.TraceEvent{ .seq = seq, .kind = .start, .time_ns = 1 })
        .writeJsonLine(&trace.writer);
    seq += 1;
    var time_ns: u64 = 100;
    for ([_]u64{ 10, 20, 30, 40, 100 }, [_]u64{ 5, 15, 25, 35, 95 }) |
        wait_ns,
        hold_ns,
    | {
        try appendLockSample(&trace.writer, &seq, 1, 7, time_ns, wait_ns, hold_ns);
        time_ns += wait_ns + hold_ns + 10;
    }
    try appendLockSample(&trace.writer, &seq, 2, 8, time_ns, 200, 1);
    try (event.TraceEvent{ .seq = seq, .kind = .stop, .time_ns = time_ns + 210 })
        .writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqualStrings("complete", analyzer.durationEvidence());

    var wait_rows = try analyzer.collectRows(std.testing.allocator, .{ .sort = .wait_tail });
    defer wait_rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), wait_rows.items[0].id);
    const target = wait_rows.items[1];
    try std.testing.expectEqual(@as(u64, 5), target.wait_count);
    try std.testing.expectEqual(@as(u64, 40), target.wait_mean_ns);
    try std.testing.expectEqual(@as(u64, 10), target.wait_min_ns);
    try std.testing.expectEqual(@as(u64, 30), target.wait_p50_ns);
    try std.testing.expectEqual(@as(u64, 100), target.wait_p90_ns);
    try std.testing.expectEqual(@as(u64, 100), target.wait_p99_ns);
    try std.testing.expectEqual(@as(u64, 100), target.max_wait_ns);
    try std.testing.expectEqual(@as(u64, 35), target.hold_mean_ns);
    try std.testing.expectEqual(@as(u64, 25), target.hold_p50_ns);
    try std.testing.expectEqual(@as(u64, 95), target.hold_p99_ns);

    var hold_rows = try analyzer.collectRows(std.testing.allocator, .{ .sort = .hold_tail });
    defer hold_rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), hold_rows.items[0].id);
}

test "locks retain first state and mark invalid timing evidence" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var seq: u64 = 1;
    try appendLockEvent(&trace.writer, &seq, .start, 10, 0);
    try appendLockEvent(&trace.writer, &seq, .lock_wait, 100, 1);
    try appendLockEvent(&trace.writer, &seq, .lock_wait, 130, 1);
    try appendLockEvent(&trace.writer, &seq, .lock_obtain, 160, 1);
    try appendLockEvent(&trace.writer, &seq, .lock_obtain, 180, 1);
    try appendLockEvent(&trace.writer, &seq, .lock_release, 220, 1);
    try appendLockEvent(&trace.writer, &seq, .lock_wait, 300, 2);
    try appendLockEvent(&trace.writer, &seq, .lock_obtain, 250, 2);
    try appendLockEvent(&trace.writer, &seq, .lock_release, 240, 2);
    try appendLockEvent(&trace.writer, &seq, .stop, 400, 0);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.duplicate_waits);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.duplicate_obtains);
    try std.testing.expectEqual(@as(u64, 2), analyzer.counters.timestamp_regressions);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.wait_samples);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.hold_samples);
    try std.testing.expectEqualStrings("partial", analyzer.durationEvidence());

    var rows = try analyzer.collectRows(std.testing.allocator, .{ .sort = .wait_tail });
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqual(@as(u64, 60), rows.items[0].wait_p99_ns);
    try std.testing.expectEqual(@as(u64, 60), rows.items[0].hold_p99_ns);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{});
    try expectLockContains(out.written(), "\"duplicate_waits\":1");
    try expectLockContains(out.written(), "\"duration_evidence\":\"partial\"");
    try expectLockContains(out.written(), "\"valid_time\":false");
}

test "locks retain flight reports and sequence gaps" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 10 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .lock_wait, .time_ns = 20, .id = 1 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .lock_obtain, .time_ns = 30, .id = 1 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .lock_release, .time_ns = 40, .id = 1 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .stop, .time_ns = 50 })
        .writeJsonLine(&trace.writer);
    const flight_report = lockTestFlightReport();
    try flight_report.writeJsonl(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    const integrity = analyzer.captureIntegrity();
    try std.testing.expectEqualStrings("sequence_gaps", integrity.status);
    try std.testing.expectEqualDeep(flight_report, integrity.flight_report.?);
    try std.testing.expectEqualStrings("partial", analyzer.durationEvidence());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{});
    try expectLockContains(out.written(), "\"flight_report\":{");
}

test "locks release duration evidence on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        analyzeLockDurations,
        .{},
    );
}

fn analyzeLockDurations(allocator: std.mem.Allocator) !void {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var seq: u64 = 1;
    try appendLockEvent(&trace.writer, &seq, .start, 10, 0);
    try (event.TraceEvent{
        .seq = seq,
        .kind = .lock_announce,
        .time_ns = 20,
        .id = 7,
        .name = "queue",
        .file = "queue.zig",
        .function = "push",
    }).writeJsonLine(&trace.writer);
    seq += 1;
    try appendLockSample(&trace.writer, &seq, 7, 3, 30, 10, 20);
    try appendLockSample(&trace.writer, &seq, 7, 3, 70, 30, 40);
    try appendLockEvent(&trace.writer, &seq, .stop, 150, 0);
    try lockTestFlightReport().writeJsonl(&trace.writer);

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(allocator, &analyzer, &out.writer, .{ .sort = .hold_tail });
}

fn appendLockSample(
    writer: *std.Io.Writer,
    seq: *u64,
    lock: u64,
    thread: u64,
    start_ns: u64,
    wait_ns: u64,
    hold_ns: u64,
) !void {
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = .lock_wait,
        .time_ns = start_ns,
        .thread = thread,
        .id = lock,
    }).writeJsonLine(writer);
    seq.* += 1;
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = .lock_obtain,
        .time_ns = start_ns + wait_ns,
        .thread = thread,
        .id = lock,
    }).writeJsonLine(writer);
    seq.* += 1;
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = .lock_release,
        .time_ns = start_ns + wait_ns + hold_ns,
        .thread = thread,
        .id = lock,
    }).writeJsonLine(writer);
    seq.* += 1;
}

fn appendLockEvent(
    writer: *std.Io.Writer,
    seq: *u64,
    kind: event.Kind,
    time_ns: u64,
    lock: u64,
) !void {
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = kind,
        .time_ns = time_ns,
        .thread = 7,
        .id = lock,
    }).writeJsonLine(writer);
    seq.* += 1;
}

fn lockTestFlightReport() transport.Report {
    return .{
        .policy = .overwrite_oldest,
        .state = .accepting,
        .capacity_bytes = 64,
        .retained_bytes = 32,
        .event_capacity_bytes = 16,
        .writer_capacity_bytes = 8,
        .observed_events = 5,
        .stored_events = 5,
        .retained_events = 4,
        .overwritten_events = 1,
        .dropped_events = 0,
        .oversized_events = 0,
        .partial_event_bytes = 0,
        .discarding_oversized_event = false,
    };
}

fn expectLockContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
