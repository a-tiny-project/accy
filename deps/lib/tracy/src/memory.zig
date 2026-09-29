const std = @import("std");
const pretty_json = @import("pretty").json;
const capture_mod = @import("capture.zig");
const report = @import("report.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");
const transport = @import("transport.zig");

pub const schema = "tracy.memory/v1";
pub const CaptureIntegrity = capture_mod.Integrity;

pub const Sort = enum {
    live,
    high_water,
    allocated,
    lifetime_tail,
    allocs,
    frees,
    name,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "live")) return .live;
        if (std.mem.eql(u8, text, "high-water")) return .high_water;
        if (std.mem.eql(u8, text, "allocated")) return .allocated;
        if (std.mem.eql(u8, text, "lifetime-tail")) return .lifetime_tail;
        if (std.mem.eql(u8, text, "allocs")) return .allocs;
        if (std.mem.eql(u8, text, "frees")) return .frees;
        if (std.mem.eql(u8, text, "name")) return .name;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .live => "live",
            .high_water => "high-water",
            .allocated => "allocated",
            .lifetime_tail => "lifetime-tail",
            .allocs => "allocs",
            .frees => "frees",
            .name => "name",
        };
    }
};

pub const Options = struct {
    top: usize = 20,
    occurrences: usize = 40,
    sort: Sort = .live,
    min_live_bytes: u64 = 0,
    name: ?[]const u8 = null,
};

pub const Counters = struct {
    events: u64 = 0,
    allocations: u64 = 0,
    frees: u64 = 0,
    unmatched_frees: u64 = 0,
    duplicate_allocations: u64 = 0,
    completed_lifetimes: u64 = 0,
    lifetime_samples: u64 = 0,
    timestamp_regressions: u64 = 0,
    untracked_allocations: u64 = 0,
    size_mismatches: u64 = 0,
    allocated_bytes: u64 = 0,
    freed_bytes: u64 = 0,
    live_bytes: u64 = 0,
    high_water_live_bytes: u64 = 0,
    high_water_time_ns: u64 = 0,
};

pub const Summary = struct {
    name: []const u8,
    allocations: u64 = 0,
    frees: u64 = 0,
    unmatched_frees: u64 = 0,
    duplicate_allocations: u64 = 0,
    active_allocations: u64 = 0,
    completed_lifetimes: u64 = 0,
    lifetime_samples: u64 = 0,
    timestamp_regressions: u64 = 0,
    untracked_allocations: u64 = 0,
    size_mismatches: u64 = 0,
    allocated_bytes: u64 = 0,
    freed_bytes: u64 = 0,
    live_bytes: u64 = 0,
    high_water_live_bytes: u64 = 0,
    high_water_time_ns: u64 = 0,
    max_alloc_bytes: u64 = 0,
    total_lifetime_ns: u64 = 0,
    min_lifetime_ns: u64 = 0,
    p50_lifetime_ns: u64 = 0,
    p90_lifetime_ns: u64 = 0,
    p99_lifetime_ns: u64 = 0,
    max_lifetime_ns: u64 = 0,
    last_event_ns: u64 = 0,

    pub fn meanAllocBytes(self: Summary) u64 {
        if (self.allocations == 0) return 0;
        return self.allocated_bytes / self.allocations;
    }

    pub fn meanLifetimeNs(self: Summary) u64 {
        if (self.lifetime_samples == 0) return 0;
        return self.total_lifetime_ns / self.lifetime_samples;
    }
};

const Record = struct {
    name: []const u8,
    size: u64,
    allocated_ns: u64,
    thread: u64,
};

const LiveView = struct {
    name: []const u8,
    address: u64,
    size: u64,
    allocated_ns: u64,
    age_ns: u64,
    thread: u64,
};

pub const Lifetime = struct {
    name: []const u8,
    address: u64,
    size: u64,
    reported_free_size: u64,
    allocation_thread: u64,
    free_thread: u64,
    allocated_ns: u64,
    freed_ns: u64,
    lifetime_ns: u64,
    size_match: bool,
    valid_time: bool,
};

const LifetimeSample = struct {
    row: usize,
    duration_ns: u64,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    capture: capture_mod.Tracker = .{},
    summaries: std.StringHashMapUnmanaged(Summary) = .{},
    active: std.AutoHashMapUnmanaged(u64, Record) = .{},
    lifetimes: std.ArrayListUnmanaged(Lifetime) = .empty,
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        var iter = self.summaries.iterator();
        while (iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.summaries.deinit(self.allocator);
        self.active.deinit(self.allocator);
        self.lifetimes.deinit(self.allocator);
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
            .alloc => try self.recordAlloc(parsed),
            .free => try self.recordFree(parsed),
            else => {},
        }
    }

    pub fn collectSummaries(
        self: *Analyzer,
        allocator: std.mem.Allocator,
        options: Options,
    ) !std.ArrayListUnmanaged(Summary) {
        var rows: std.ArrayListUnmanaged(Summary) = .empty;
        errdefer rows.deinit(allocator);
        var iter = self.summaries.valueIterator();
        while (iter.next()) |summary| {
            if (options.name) |wanted| {
                if (!std.mem.eql(u8, wanted, summary.name)) continue;
            }
            if (summary.live_bytes < options.min_live_bytes) continue;
            try rows.append(allocator, summary.*);
        }
        try applyLifetimeDistributions(allocator, rows.items, self.lifetimes.items);
        sortSummaries(rows.items, options.sort);
        return rows;
    }

    pub fn collectLive(
        self: *Analyzer,
        allocator: std.mem.Allocator,
        options: Options,
    ) !std.ArrayListUnmanaged(LiveView) {
        var rows: std.ArrayListUnmanaged(LiveView) = .empty;
        errdefer rows.deinit(allocator);
        const end_ns = self.end_ns orelse 0;
        var iter = self.active.iterator();
        while (iter.next()) |entry| {
            const record = entry.value_ptr.*;
            if (options.name) |wanted| {
                if (!std.mem.eql(u8, wanted, record.name)) continue;
            }
            if (record.size < options.min_live_bytes) continue;
            try rows.append(allocator, .{
                .name = record.name,
                .address = entry.key_ptr.*,
                .size = record.size,
                .allocated_ns = record.allocated_ns,
                .age_ns = if (end_ns >= record.allocated_ns) end_ns - record.allocated_ns else 0,
                .thread = record.thread,
            });
        }
        std.mem.sort(LiveView, rows.items, {}, liveGreaterThan);
        return rows;
    }

    pub fn collectLifetimes(
        self: *Analyzer,
        allocator: std.mem.Allocator,
        options: Options,
    ) !std.ArrayListUnmanaged(Lifetime) {
        var rows: std.ArrayListUnmanaged(Lifetime) = .empty;
        errdefer rows.deinit(allocator);
        for (self.lifetimes.items) |lifetime| {
            if (options.name) |wanted| {
                if (!std.mem.eql(u8, wanted, lifetime.name)) continue;
            }
            try rows.append(allocator, lifetime);
        }
        std.mem.sort(Lifetime, rows.items, {}, lifetimeGreaterThan);
        if (rows.items.len > options.occurrences) {
            rows.shrinkRetainingCapacity(options.occurrences);
        }
        return rows;
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

    pub fn lifetimeEvidence(self: Analyzer) []const u8 {
        if (!std.mem.eql(u8, self.captureIntegrity().status, "complete")) return "partial";
        if (self.counters.timestamp_regressions != 0) return "partial";
        if (self.counters.duplicate_allocations != 0) return "partial";
        if (self.counters.unmatched_frees != 0) return "partial";
        if (self.counters.untracked_allocations != 0) return "partial";
        if (self.counters.size_mismatches != 0) return "partial";
        if (self.active.count() != 0) return "partial";
        return "complete";
    }

    pub fn recordFlightReport(self: *Analyzer, report_value: transport.Report) void {
        self.capture.recordFlightReport(report_value);
    }

    fn recordAlloc(self: *Analyzer, parsed: event.Parsed) !void {
        const name = parsed.name orelse "default";
        const summary = try self.summaryFor(name);
        var tracked = false;
        if (parsed.address != 0) {
            const entry = try self.active.getOrPut(self.allocator, parsed.address);
            if (entry.found_existing) {
                self.recordDuplicate(entry.value_ptr.*);
            } else {
                entry.value_ptr.* = .{
                    .name = summary.name,
                    .size = parsed.size,
                    .allocated_ns = parsed.time_ns,
                    .thread = parsed.thread,
                };
                tracked = true;
            }
        } else {
            self.counters.untracked_allocations +|= 1;
            summary.untracked_allocations +|= 1;
        }

        self.counters.allocations +|= 1;
        self.counters.allocated_bytes +|= parsed.size;
        summary.allocations +|= 1;
        summary.allocated_bytes +|= parsed.size;
        summary.max_alloc_bytes = @max(summary.max_alloc_bytes, parsed.size);
        summary.last_event_ns = parsed.time_ns;
        if (tracked) self.addLive(summary, parsed.size, parsed.time_ns);
    }

    fn recordFree(self: *Analyzer, parsed: event.Parsed) !void {
        if (parsed.address != 0) {
            if (self.active.get(parsed.address)) |record| {
                try self.recordMatchedFree(parsed, record);
                return;
            }
        }
        try self.recordUnmatchedFree(parsed);
    }

    fn recordDuplicate(self: *Analyzer, record: Record) void {
        const summary = self.summaries.getPtr(record.name).?;
        self.counters.duplicate_allocations +|= 1;
        summary.duplicate_allocations +|= 1;
    }

    fn addLive(self: *Analyzer, summary: *Summary, size: u64, time_ns: u64) void {
        self.counters.live_bytes +|= size;
        summary.live_bytes +|= size;
        summary.active_allocations +|= 1;
        if (self.counters.live_bytes > self.counters.high_water_live_bytes) {
            self.counters.high_water_live_bytes = self.counters.live_bytes;
            self.counters.high_water_time_ns = time_ns;
        }
        if (summary.live_bytes > summary.high_water_live_bytes) {
            summary.high_water_live_bytes = summary.live_bytes;
            summary.high_water_time_ns = time_ns;
        }
    }

    fn removeLive(self: *Analyzer, summary: *Summary, size: u64) void {
        subtractCounterLive(&self.counters, size);
        _ = subtractSummaryLive(summary, size);
        if (summary.active_allocations != 0) summary.active_allocations -= 1;
    }

    fn recordMatchedFree(self: *Analyzer, parsed: event.Parsed, record: Record) !void {
        const valid_time = parsed.time_ns >= record.allocated_ns;
        try self.lifetimes.append(self.allocator, .{
            .name = record.name,
            .address = parsed.address,
            .size = record.size,
            .reported_free_size = parsed.size,
            .allocation_thread = record.thread,
            .free_thread = parsed.thread,
            .allocated_ns = record.allocated_ns,
            .freed_ns = parsed.time_ns,
            .lifetime_ns = duration(record.allocated_ns, parsed.time_ns),
            .size_match = parsed.size == 0 or parsed.size == record.size,
            .valid_time = valid_time,
        });
        _ = self.active.remove(parsed.address);
        const summary = self.summaries.getPtr(record.name).?;
        self.recordLifetime(summary, record, parsed, valid_time);
        self.removeLive(summary, record.size);
    }

    fn recordLifetime(
        self: *Analyzer,
        summary: *Summary,
        record: Record,
        parsed: event.Parsed,
        valid_time: bool,
    ) void {
        self.counters.frees +|= 1;
        self.counters.completed_lifetimes +|= 1;
        self.counters.freed_bytes +|= record.size;
        summary.frees +|= 1;
        summary.completed_lifetimes +|= 1;
        summary.freed_bytes +|= record.size;
        summary.last_event_ns = parsed.time_ns;
        if (parsed.size != 0 and parsed.size != record.size) self.recordSizeMismatch(summary);
        if (valid_time) {
            const lifetime_ns = duration(record.allocated_ns, parsed.time_ns);
            self.counters.lifetime_samples +|= 1;
            summary.lifetime_samples +|= 1;
            summary.total_lifetime_ns +|= lifetime_ns;
            summary.max_lifetime_ns = @max(summary.max_lifetime_ns, lifetime_ns);
        } else {
            self.counters.timestamp_regressions +|= 1;
            summary.timestamp_regressions +|= 1;
        }
    }

    fn recordSizeMismatch(self: *Analyzer, summary: *Summary) void {
        self.counters.size_mismatches +|= 1;
        summary.size_mismatches +|= 1;
    }

    fn recordUnmatchedFree(self: *Analyzer, parsed: event.Parsed) !void {
        const summary = try self.summaryFor(parsed.name orelse "default");
        self.counters.frees +|= 1;
        self.counters.freed_bytes +|= parsed.size;
        summary.frees +|= 1;
        summary.freed_bytes +|= parsed.size;
        summary.last_event_ns = parsed.time_ns;
        if (parsed.address == 0 and parsed.size == 0) return;
        self.counters.unmatched_frees +|= 1;
        summary.unmatched_frees +|= 1;
    }

    fn summaryFor(self: *Analyzer, name: []const u8) !*Summary {
        if (self.summaries.getPtr(name)) |summary| return summary;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const entry = try self.summaries.getOrPut(self.allocator, owned_name);
        std.debug.assert(!entry.found_existing);
        entry.key_ptr.* = owned_name;
        entry.value_ptr.* = .{ .name = owned_name };
        return entry.value_ptr;
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
    var summaries = try analyzer.collectSummaries(allocator, options);
    defer summaries.deinit(allocator);
    var lifetimes = try analyzer.collectLifetimes(allocator, options);
    defer lifetimes.deinit(allocator);
    var live = try analyzer.collectLive(allocator, options);
    defer live.deinit(allocator);
    try writeTextHeader(writer, analyzer, options, summaries.items.len);
    try capture_mod.writeText(writer, analyzer.captureIntegrity());
    const summary_limit = @min(options.top, summaries.items.len);
    for (summaries.items[0..summary_limit]) |summary| try writeTextMemory(writer, summary);
    for (lifetimes.items) |lifetime| try writeTextLifetime(writer, lifetime);
    const live_limit = @min(options.top, live.items.len);
    for (live.items[0..live_limit]) |item| try writeTextLive(writer, item);
}

fn writeTextHeader(
    writer: *std.Io.Writer,
    analyzer: *Analyzer,
    options: Options,
    names: usize,
) !void {
    try writer.print(
        "tracy memory names={d} allocations={d} frees={d} completed_lifetimes={d} " ++
            "lifetime_samples={d} right_censored_allocations={d} live_bytes={d} " ++
            "high_water_live_bytes={d} high_water_time_ns={d} allocated_bytes={d} " ++
            "freed_bytes={d} unmatched_frees={d} duplicate_allocations={d} " ++
            "timestamp_regressions={d} untracked_allocations={d} size_mismatches={d} " ++
            "lifetime_population=completed lifetime_evidence={s} duration_ns={d} sort={s}\n",
        .{
            names,
            analyzer.counters.allocations,
            analyzer.counters.frees,
            analyzer.counters.completed_lifetimes,
            analyzer.counters.lifetime_samples,
            analyzer.active.count(),
            analyzer.counters.live_bytes,
            analyzer.counters.high_water_live_bytes,
            analyzer.counters.high_water_time_ns,
            analyzer.counters.allocated_bytes,
            analyzer.counters.freed_bytes,
            analyzer.counters.unmatched_frees,
            analyzer.counters.duplicate_allocations,
            analyzer.counters.timestamp_regressions,
            analyzer.counters.untracked_allocations,
            analyzer.counters.size_mismatches,
            analyzer.lifetimeEvidence(),
            analyzer.durationNs(),
            options.sort.tag(),
        },
    );
}

fn writeTextMemory(writer: *std.Io.Writer, summary: Summary) !void {
    try writer.writeAll("memory name=");
    try pretty_json.writeString(writer, summary.name);
    try writer.print(
        " allocations={d} frees={d} right_censored_allocations={d} live_bytes={d} " ++
            "high_water_live_bytes={d} high_water_time_ns={d} allocated_bytes={d} " ++
            "freed_bytes={d} mean_alloc_bytes={d} max_alloc_bytes={d}",
        .{
            summary.allocations,           summary.frees,
            summary.active_allocations,    summary.live_bytes,
            summary.high_water_live_bytes, summary.high_water_time_ns,
            summary.allocated_bytes,       summary.freed_bytes,
            summary.meanAllocBytes(),      summary.max_alloc_bytes,
        },
    );
    try writer.print(
        " completed_lifetimes={d} lifetime_samples={d} lifetime_total_ns={d} " ++
            "lifetime_mean_ns={d} lifetime_min_ns={d} lifetime_p50_ns={d} " ++
            "lifetime_p90_ns={d} lifetime_p99_ns={d} lifetime_max_ns={d} " ++
            "unmatched_frees={d} duplicate_allocations={d} timestamp_regressions={d} " ++
            "untracked_allocations={d} size_mismatches={d} last_event_ns={d}\n",
        .{
            summary.completed_lifetimes,   summary.lifetime_samples,
            summary.total_lifetime_ns,     summary.meanLifetimeNs(),
            summary.min_lifetime_ns,       summary.p50_lifetime_ns,
            summary.p90_lifetime_ns,       summary.p99_lifetime_ns,
            summary.max_lifetime_ns,       summary.unmatched_frees,
            summary.duplicate_allocations, summary.timestamp_regressions,
            summary.untracked_allocations, summary.size_mismatches,
            summary.last_event_ns,
        },
    );
}

fn writeTextLifetime(writer: *std.Io.Writer, lifetime: Lifetime) !void {
    try writer.writeAll("lifetime name=");
    try pretty_json.writeString(writer, lifetime.name);
    try writer.print(
        " address={d} size={d} reported_free_size={d} size_match={} " ++
            "allocation_thread={d} free_thread={d} allocated_ns={d} freed_ns={d} " ++
            "lifetime_ns={d}",
        .{
            lifetime.address,            lifetime.size,
            lifetime.reported_free_size, lifetime.size_match,
            lifetime.allocation_thread,  lifetime.free_thread,
            lifetime.allocated_ns,       lifetime.freed_ns,
            lifetime.lifetime_ns,
        },
    );
    if (!lifetime.valid_time) try writer.writeAll(" valid_time=false");
    try writer.writeByte('\n');
}

fn writeTextLive(writer: *std.Io.Writer, item: LiveView) !void {
    try writer.writeAll("live name=");
    try pretty_json.writeString(writer, item.name);
    try writer.print(
        " address={d} size={d} allocated_ns={d} age_ns={d} thread={d}\n",
        .{ item.address, item.size, item.allocated_ns, item.age_ns, item.thread },
    );
}

fn writeJsonl(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var summaries = try analyzer.collectSummaries(allocator, options);
    defer summaries.deinit(allocator);
    var lifetimes = try analyzer.collectLifetimes(allocator, options);
    defer lifetimes.deinit(allocator);
    var live = try analyzer.collectLive(allocator, options);
    defer live.deinit(allocator);
    try writeJsonSummary(writer, analyzer, options, summaries.items.len);
    const summary_limit = @min(options.top, summaries.items.len);
    for (summaries.items[0..summary_limit]) |summary| try writeJsonMemory(writer, summary);
    for (lifetimes.items) |lifetime| try writeJsonLifetime(writer, lifetime);
    const live_limit = @min(options.top, live.items.len);
    for (live.items[0..live_limit]) |item| try writeJsonLive(writer, item);
}

fn writeJsonSummary(
    writer: *std.Io.Writer,
    analyzer: *Analyzer,
    options: Options,
    names: usize,
) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "summary");
    try object.field("names", names);
    try object.field("allocations", analyzer.counters.allocations);
    try object.field("frees", analyzer.counters.frees);
    try object.field("completed_lifetimes", analyzer.counters.completed_lifetimes);
    try object.field("lifetime_samples", analyzer.counters.lifetime_samples);
    try object.field("right_censored_allocations", analyzer.active.count());
    try object.field("live_bytes", analyzer.counters.live_bytes);
    try object.field("high_water_live_bytes", analyzer.counters.high_water_live_bytes);
    try object.field("high_water_time_ns", analyzer.counters.high_water_time_ns);
    try object.field("allocated_bytes", analyzer.counters.allocated_bytes);
    try object.field("freed_bytes", analyzer.counters.freed_bytes);
    try object.field("unmatched_frees", analyzer.counters.unmatched_frees);
    try object.field("duplicate_allocations", analyzer.counters.duplicate_allocations);
    try object.field("timestamp_regressions", analyzer.counters.timestamp_regressions);
    try object.field("untracked_allocations", analyzer.counters.untracked_allocations);
    try object.field("size_mismatches", analyzer.counters.size_mismatches);
    try object.field("duration_ns", analyzer.durationNs());
    try object.field("lifetime_population", "completed");
    try object.field("lifetime_evidence", analyzer.lifetimeEvidence());
    try object.field("sort", options.sort.tag());
    try capture_mod.writeFields(object, analyzer.captureIntegrity());
    try object.endLine();
}

fn writeJsonMemory(writer: *std.Io.Writer, summary: Summary) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "memory");
    try object.field("name", summary.name);
    try object.field("allocations", summary.allocations);
    try object.field("frees", summary.frees);
    try object.field("right_censored_allocations", summary.active_allocations);
    try object.field("live_bytes", summary.live_bytes);
    try object.field("high_water_live_bytes", summary.high_water_live_bytes);
    try object.field("high_water_time_ns", summary.high_water_time_ns);
    try object.field("allocated_bytes", summary.allocated_bytes);
    try object.field("freed_bytes", summary.freed_bytes);
    try object.field("mean_alloc_bytes", summary.meanAllocBytes());
    try object.field("max_alloc_bytes", summary.max_alloc_bytes);
    try object.field("completed_lifetimes", summary.completed_lifetimes);
    try object.field("lifetime_samples", summary.lifetime_samples);
    try object.field("lifetime_total_ns", summary.total_lifetime_ns);
    try object.field("lifetime_mean_ns", summary.meanLifetimeNs());
    try object.field("lifetime_min_ns", summary.min_lifetime_ns);
    try object.field("lifetime_p50_ns", summary.p50_lifetime_ns);
    try object.field("lifetime_p90_ns", summary.p90_lifetime_ns);
    try object.field("lifetime_p99_ns", summary.p99_lifetime_ns);
    try object.field("lifetime_max_ns", summary.max_lifetime_ns);
    try object.field("unmatched_frees", summary.unmatched_frees);
    try object.field("duplicate_allocations", summary.duplicate_allocations);
    try object.field("timestamp_regressions", summary.timestamp_regressions);
    try object.field("untracked_allocations", summary.untracked_allocations);
    try object.field("size_mismatches", summary.size_mismatches);
    try object.field("last_event_ns", summary.last_event_ns);
    try object.endLine();
}

fn writeJsonLifetime(writer: *std.Io.Writer, lifetime: Lifetime) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "lifetime");
    try object.field("name", lifetime.name);
    try object.field("address", lifetime.address);
    try object.field("size", lifetime.size);
    try object.field("reported_free_size", lifetime.reported_free_size);
    try object.field("size_match", lifetime.size_match);
    try object.field("allocation_thread", lifetime.allocation_thread);
    try object.field("free_thread", lifetime.free_thread);
    try object.field("allocated_ns", lifetime.allocated_ns);
    try object.field("freed_ns", lifetime.freed_ns);
    try object.field("lifetime_ns", lifetime.lifetime_ns);
    try object.field("valid_time", lifetime.valid_time);
    try object.endLine();
}

fn writeJsonLive(writer: *std.Io.Writer, item: LiveView) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "live");
    try object.field("name", item.name);
    try object.field("address", item.address);
    try object.field("size", item.size);
    try object.field("allocated_ns", item.allocated_ns);
    try object.field("age_ns", item.age_ns);
    try object.field("thread", item.thread);
    try object.endLine();
}

fn subtractCounterLive(counters: *Counters, size: u64) void {
    if (counters.live_bytes >= size) {
        counters.live_bytes -= size;
    } else {
        counters.live_bytes = 0;
    }
}

fn subtractSummaryLive(summary: *Summary, size: u64) u64 {
    const removed = @min(summary.live_bytes, size);
    if (summary.live_bytes >= size) {
        summary.live_bytes -= size;
    } else {
        summary.live_bytes = 0;
    }
    return removed;
}

fn duration(start_ns: u64, end_ns: u64) u64 {
    if (end_ns <= start_ns) return 0;
    return end_ns - start_ns;
}

fn applyLifetimeDistributions(
    allocator: std.mem.Allocator,
    rows: []Summary,
    lifetimes: []const Lifetime,
) !void {
    var row_index: std.StringHashMapUnmanaged(usize) = .{};
    defer row_index.deinit(allocator);
    for (rows, 0..) |row, index| try row_index.put(allocator, row.name, index);
    var samples: std.ArrayListUnmanaged(LifetimeSample) = .empty;
    defer samples.deinit(allocator);
    for (lifetimes) |lifetime| {
        if (!lifetime.valid_time) continue;
        const row = row_index.get(lifetime.name) orelse continue;
        try samples.append(allocator, .{ .row = row, .duration_ns = lifetime.lifetime_ns });
    }
    std.mem.sort(LifetimeSample, samples.items, {}, lifetimeSampleLessThan);
    var start: usize = 0;
    while (start < samples.items.len) {
        var end = start + 1;
        while (end < samples.items.len and samples.items[end].row == samples.items[start].row) {
            end += 1;
        }
        applyLifetimeDistribution(&rows[samples.items[start].row], samples.items[start..end]);
        start = end;
    }
}

fn applyLifetimeDistribution(summary: *Summary, samples: []const LifetimeSample) void {
    std.debug.assert(samples.len > 0);
    std.debug.assert(summary.lifetime_samples == samples.len);
    summary.min_lifetime_ns = lifetimePercentile(samples, 0);
    summary.p50_lifetime_ns = lifetimePercentile(samples, 50);
    summary.p90_lifetime_ns = lifetimePercentile(samples, 90);
    summary.p99_lifetime_ns = lifetimePercentile(samples, 99);
    summary.max_lifetime_ns = lifetimePercentile(samples, 100);
}

fn lifetimePercentile(samples: []const LifetimeSample, percent: u64) u64 {
    std.debug.assert(samples.len > 0);
    const rank: usize = @intCast((@as(u128, @min(percent, 100)) * samples.len + 99) / 100);
    const index = @min(@max(rank, 1) - 1, samples.len - 1);
    return samples[index].duration_ns;
}

fn lifetimeSampleLessThan(_: void, left: LifetimeSample, right: LifetimeSample) bool {
    if (left.row != right.row) return left.row < right.row;
    return left.duration_ns < right.duration_ns;
}

fn sortSummaries(items: []Summary, sort: Sort) void {
    std.mem.sort(Summary, items, sort, summaryLessThan);
}

fn summaryLessThan(sort: Sort, left: Summary, right: Summary) bool {
    return switch (sort) {
        .live => summaryLiveGreaterThan({}, left, right),
        .high_water => summaryHighGreaterThan({}, left, right),
        .allocated => summaryAllocatedGreaterThan({}, left, right),
        .lifetime_tail => summaryLifetimeGreaterThan({}, left, right),
        .allocs => summaryAllocsGreaterThan({}, left, right),
        .frees => summaryFreesGreaterThan({}, left, right),
        .name => summaryNameLessThan({}, left, right),
    };
}

fn summaryLiveGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.live_bytes != right.live_bytes) return left.live_bytes > right.live_bytes;
    return summaryHighGreaterThan({}, left, right);
}

fn summaryHighGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.high_water_live_bytes != right.high_water_live_bytes) return left.high_water_live_bytes > right.high_water_live_bytes;
    return summaryNameLessThan({}, left, right);
}

fn summaryAllocatedGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.allocated_bytes != right.allocated_bytes) return left.allocated_bytes > right.allocated_bytes;
    return summaryNameLessThan({}, left, right);
}

fn summaryLifetimeGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.p99_lifetime_ns != right.p99_lifetime_ns) {
        return left.p99_lifetime_ns > right.p99_lifetime_ns;
    }
    if (left.max_lifetime_ns != right.max_lifetime_ns) {
        return left.max_lifetime_ns > right.max_lifetime_ns;
    }
    return summaryNameLessThan({}, left, right);
}

fn summaryAllocsGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.allocations != right.allocations) return left.allocations > right.allocations;
    return summaryAllocatedGreaterThan({}, left, right);
}

fn summaryFreesGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.frees != right.frees) return left.frees > right.frees;
    return summaryAllocatedGreaterThan({}, left, right);
}

fn summaryNameLessThan(_: void, left: Summary, right: Summary) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn liveGreaterThan(_: void, left: LiveView, right: LiveView) bool {
    if (left.size != right.size) return left.size > right.size;
    const name_cmp = std.mem.order(u8, left.name, right.name);
    if (name_cmp != .eq) return name_cmp == .lt;
    return left.address < right.address;
}

fn lifetimeGreaterThan(_: void, left: Lifetime, right: Lifetime) bool {
    if (left.lifetime_ns != right.lifetime_ns) return left.lifetime_ns > right.lifetime_ns;
    if (left.valid_time != right.valid_time) return left.valid_time;
    const name_cmp = std.mem.order(u8, left.name, right.name);
    if (name_cmp != .eq) return name_cmp == .lt;
    return left.address < right.address;
}

test "memory tracks live allocations and high water by name" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 90, .thread = 1, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .alloc, .time_ns = 100, .thread = 1, .name = "arena", .address = 4096, .size = 64 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .alloc, .time_ns = 110, .thread = 2, .name = "arena", .address = 8192, .size = 32 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .free, .time_ns = 120, .thread = 1, .name = "arena", .address = 4096 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .free, .time_ns = 130, .thread = 1, .name = "external", .address = 12288, .size = 16 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .free, .time_ns = 140, .thread = 1, .name = "arena", .address = 16384 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .stop, .time_ns = 160, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 2), analyzer.counters.allocations);
    try std.testing.expectEqual(@as(u64, 3), analyzer.counters.frees);
    try std.testing.expectEqual(@as(u64, 2), analyzer.counters.unmatched_frees);
    try std.testing.expectEqual(@as(u64, 96), analyzer.counters.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 80), analyzer.counters.freed_bytes);
    try std.testing.expectEqual(@as(u64, 32), analyzer.counters.live_bytes);
    try std.testing.expectEqual(@as(u64, 96), analyzer.counters.high_water_live_bytes);
    try std.testing.expectEqual(@as(u64, 110), analyzer.counters.high_water_time_ns);
    try std.testing.expectEqual(@as(usize, 1), analyzer.active.count());

    const arena = analyzer.summaries.get("arena").?;
    try std.testing.expectEqual(@as(u64, 32), arena.live_bytes);
    try std.testing.expectEqual(@as(u64, 96), arena.high_water_live_bytes);
    try std.testing.expectEqual(@as(u64, 1), arena.unmatched_frees);
    try std.testing.expectEqual(@as(u64, 48), arena.meanAllocBytes());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "completed_lifetimes=1 lifetime_samples=1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "right_censored_allocations=1 live_bytes=32",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "live name=\"arena\" address=8192 size=32 allocated_ns=110 age_ns=50 thread=2") != null);
}

test "memory jsonl filters names and live rows" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .alloc, .time_ns = 100, .thread = 1, .name = "arena", .address = 4096, .size = 64 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .alloc, .time_ns = 110, .thread = 1, .name = "scratch", .address = 8192, .size = 8 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .stop, .time_ns = 150, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4, .name = "arena", .min_live_bytes = 32 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.memory/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"arena\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"live\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"address\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"scratch\"") == null);
}

test "memory handles duplicate allocation addresses as anomalies" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .alloc, .time_ns = 100, .thread = 1, .name = "arena", .address = 4096, .size = 64 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .alloc, .time_ns = 110, .thread = 1, .name = "arena", .address = 4096, .size = 16 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.duplicate_allocations);
    try std.testing.expectEqual(@as(u64, 64), analyzer.counters.live_bytes);
    try std.testing.expectEqual(@as(usize, 1), analyzer.active.count());
}

test "memory preserves completed lifetime distributions and worst occurrences" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var seq: u64 = 1;
    try (event.TraceEvent{ .seq = seq, .kind = .start, .time_ns = 1 })
        .writeJsonLine(&trace.writer);
    seq += 1;
    var time_ns: u64 = 100;
    for ([_]u64{ 10, 20, 30, 40, 100 }, 0..) |lifetime_ns, index| {
        try appendLifetimePair(
            &trace.writer,
            &seq,
            "arena",
            @intCast(index + 1),
            time_ns,
            lifetime_ns,
            16,
        );
        time_ns += lifetime_ns + 10;
    }
    try appendLifetimePair(&trace.writer, &seq, "cache", 20, time_ns, 200, 64);
    try (event.TraceEvent{ .seq = seq, .kind = .stop, .time_ns = time_ns + 210 })
        .writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 6), analyzer.counters.completed_lifetimes);
    try std.testing.expectEqual(@as(u64, 6), analyzer.counters.lifetime_samples);
    try std.testing.expectEqualStrings("complete", analyzer.lifetimeEvidence());

    var rows = try analyzer.collectSummaries(
        std.testing.allocator,
        .{ .sort = .lifetime_tail },
    );
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cache", rows.items[0].name);
    const arena = rows.items[1];
    try std.testing.expectEqual(@as(u64, 5), arena.lifetime_samples);
    try std.testing.expectEqual(@as(u64, 200), arena.total_lifetime_ns);
    try std.testing.expectEqual(@as(u64, 40), arena.meanLifetimeNs());
    try std.testing.expectEqual(@as(u64, 10), arena.min_lifetime_ns);
    try std.testing.expectEqual(@as(u64, 30), arena.p50_lifetime_ns);
    try std.testing.expectEqual(@as(u64, 100), arena.p90_lifetime_ns);
    try std.testing.expectEqual(@as(u64, 100), arena.p99_lifetime_ns);
    try std.testing.expectEqual(@as(u64, 100), arena.max_lifetime_ns);

    var lifetimes = try analyzer.collectLifetimes(
        std.testing.allocator,
        .{ .occurrences = 2 },
    );
    defer lifetimes.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), lifetimes.items.len);
    try std.testing.expectEqual(@as(u64, 200), lifetimes.items[0].lifetime_ns);
    try std.testing.expectEqual(@as(u64, 100), lifetimes.items[1].lifetime_ns);
}

test "memory separates censored allocations and invalid lifetime evidence" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 1 })
        .writeJsonLine(&trace.writer);
    try appendMemoryEvent(&trace.writer, 2, .alloc, 100, 1, 64);
    try appendMemoryEvent(&trace.writer, 3, .alloc, 110, 1, 16);
    try appendMemoryEvent(&trace.writer, 4, .free, 90, 1, 32);
    try appendMemoryEvent(&trace.writer, 5, .alloc, 120, 2, 32);
    try appendMemoryEvent(&trace.writer, 6, .alloc, 130, 0, 8);
    try appendMemoryEvent(&trace.writer, 7, .free, 140, 3, 4);
    try (event.TraceEvent{ .seq = 8, .kind = .stop, .time_ns = 150 })
        .writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.completed_lifetimes);
    try std.testing.expectEqual(@as(u64, 0), analyzer.counters.lifetime_samples);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.duplicate_allocations);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.timestamp_regressions);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.untracked_allocations);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.size_mismatches);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.unmatched_frees);
    try std.testing.expectEqual(@as(u64, 32), analyzer.counters.live_bytes);
    try std.testing.expectEqual(@as(usize, 1), analyzer.active.count());
    try std.testing.expectEqualStrings("partial", analyzer.lifetimeEvidence());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{});
    try expectMemoryJsonl(out.written());
    try expectMemoryContains(out.written(), "\"right_censored_allocations\":1");
    try expectMemoryContains(out.written(), "\"lifetime_evidence\":\"partial\"");
    try expectMemoryContains(out.written(), "\"size_match\":false");
    try expectMemoryContains(out.written(), "\"valid_time\":false");
}

test "memory retains flight reports and sequence gaps" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 1 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .alloc, .time_ns = 10, .address = 1, .size = 8 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .free, .time_ns = 20, .address = 1 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .stop, .time_ns = 30 })
        .writeJsonLine(&trace.writer);
    const flight_report = memoryTestFlightReport();
    try flight_report.writeJsonl(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    const integrity = analyzer.captureIntegrity();
    try std.testing.expectEqualStrings("sequence_gaps", integrity.status);
    try std.testing.expectEqualDeep(flight_report, integrity.flight_report.?);
    try std.testing.expectEqualStrings("partial", analyzer.lifetimeEvidence());
}

test "memory releases lifetime evidence on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        analyzeMemoryLifetimes,
        .{},
    );
}

fn analyzeMemoryLifetimes(allocator: std.mem.Allocator) !void {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var seq: u64 = 1;
    try (event.TraceEvent{ .seq = seq, .kind = .start, .time_ns = 1 })
        .writeJsonLine(&trace.writer);
    seq += 1;
    try appendLifetimePair(&trace.writer, &seq, "arena", 1, 10, 20, 64);
    try appendLifetimePair(&trace.writer, &seq, "arena", 2, 40, 30, 32);
    try (event.TraceEvent{ .seq = seq, .kind = .stop, .time_ns = 80 })
        .writeJsonLine(&trace.writer);
    try memoryTestFlightReport().writeJsonl(&trace.writer);

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(allocator, &analyzer, &out.writer, .{ .sort = .lifetime_tail });
}

fn appendLifetimePair(
    writer: *std.Io.Writer,
    seq: *u64,
    name: []const u8,
    address: u64,
    allocated_ns: u64,
    lifetime_ns: u64,
    size: u64,
) !void {
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = .alloc,
        .time_ns = allocated_ns,
        .thread = 1,
        .name = name,
        .address = address,
        .size = size,
    }).writeJsonLine(writer);
    seq.* += 1;
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = .free,
        .time_ns = allocated_ns + lifetime_ns,
        .thread = 2,
        .name = name,
        .address = address,
        .size = size,
    }).writeJsonLine(writer);
    seq.* += 1;
}

fn appendMemoryEvent(
    writer: *std.Io.Writer,
    seq: u64,
    kind: event.Kind,
    time_ns: u64,
    address: u64,
    size: u64,
) !void {
    try (event.TraceEvent{
        .seq = seq,
        .kind = kind,
        .time_ns = time_ns,
        .thread = if (kind == .alloc) 1 else 2,
        .name = "arena",
        .address = address,
        .size = size,
    }).writeJsonLine(writer);
}

fn memoryTestFlightReport() transport.Report {
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

fn expectMemoryContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectMemoryJsonl(bytes: []const u8) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            line,
            .{},
        );
        parsed.deinit();
    }
}
