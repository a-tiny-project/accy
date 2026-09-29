const std = @import("std");
const pretty_json = @import("pretty").json;
const report = @import("report.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");

pub const schema = "tracy.system/v0";

pub const Group = enum {
    kind,
    thread,
    cpu,
    address,
    topology,
    name,
    none,

    pub fn fromName(text: []const u8) ?Group {
        if (std.mem.eql(u8, text, "kind")) return .kind;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "cpu")) return .cpu;
        if (std.mem.eql(u8, text, "address")) return .address;
        if (std.mem.eql(u8, text, "topology")) return .topology;
        if (std.mem.eql(u8, text, "name")) return .name;
        if (std.mem.eql(u8, text, "none")) return .none;
        return null;
    }

    fn tag(self: Group) []const u8 {
        return switch (self) {
            .kind => "kind",
            .thread => "thread",
            .cpu => "cpu",
            .address => "address",
            .topology => "topology",
            .name => "name",
            .none => "none",
        };
    }
};

pub const Sort = enum {
    count,
    value,
    last,
    first,
    thread,
    cpu,
    address,
    label,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "count")) return .count;
        if (std.mem.eql(u8, text, "value")) return .value;
        if (std.mem.eql(u8, text, "last")) return .last;
        if (std.mem.eql(u8, text, "first")) return .first;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "cpu")) return .cpu;
        if (std.mem.eql(u8, text, "address")) return .address;
        if (std.mem.eql(u8, text, "label")) return .label;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .count => "count",
            .value => "value",
            .last => "last",
            .first => "first",
            .thread => "thread",
            .cpu => "cpu",
            .address => "address",
            .label => "label",
        };
    }
};

pub const Options = struct {
    top: usize = 20,
    occurrences: usize = 80,
    group: Group = .kind,
    sort: Sort = .count,
    thread: ?u64 = null,
    cpu: ?u32 = null,
    address: ?u64 = null,
    since_ns: ?u64 = null,
    until_ns: ?u64 = null,
    kind: ?[]const u8 = null,
    match: ?[]const u8 = null,
    ignore_case: bool = false,
};

pub const Counters = struct {
    events: u64 = 0,
    thread_contexts: u64 = 0,
    thread_pid_maps: u64 = 0,
    cpu_topology: u64 = 0,
    sys_time: u64 = 0,
    sys_power: u64 = 0,
    hw_samples: u64 = 0,
    computed_power: u64 = 0,
    filtered: u64 = 0,
    groups: u64 = 0,
    duration_ns: u64 = 0,
};

const OccurrenceKind = enum {
    thread_context,
    thread_pid,
    cpu_topology,
    sys_time,
    sys_power,
    hw_sample,

    fn tag(self: OccurrenceKind) []const u8 {
        return switch (self) {
            .thread_context => "thread-context",
            .thread_pid => "thread-pid",
            .cpu_topology => "cpu-topology",
            .sys_time => "sys-time",
            .sys_power => "sys-power",
            .hw_sample => "hw-sample",
        };
    }
};

const Occurrence = struct {
    kind: OccurrenceKind,
    seq: u64 = 0,
    time_ns: u64 = 0,
    thread: u64 = 0,
    pid: u64 = 0,
    cpu: ?u32 = null,
    cpu_package: ?u32 = null,
    cpu_die: ?u32 = null,
    cpu_core: ?u32 = null,
    address: u64 = 0,
    name: ?[]u8 = null,
    hw_sample_kind: ?[]u8 = null,
    value: ?f64 = null,
    power_delta_uj: ?u64 = null,

    fn deinit(self: *Occurrence, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.hw_sample_kind) |kind| allocator.free(kind);
        self.* = undefined;
    }
};

const OccurrenceView = struct {
    occurrence: *const Occurrence,
};

pub const Summary = struct {
    group: Group,
    label: []u8,
    count: u64 = 0,
    kind: ?[]u8 = null,
    thread: ?u64 = null,
    pid: ?u64 = null,
    cpu: ?u32 = null,
    cpu_package: ?u32 = null,
    cpu_die: ?u32 = null,
    cpu_core: ?u32 = null,
    address: ?u64 = null,
    value_count: u64 = 0,
    value_min: f64 = 0,
    value_max: f64 = 0,
    value_sum: f64 = 0,
    value_last: ?f64 = null,
    power_delta_uj: u64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.kind) |kind| allocator.free(kind);
        self.* = undefined;
    }

    pub fn valueMean(self: Summary) f64 {
        if (self.value_count == 0) return 0;
        return self.value_sum / @as(f64, @floatFromInt(self.value_count));
    }
};

const PowerLast = struct {
    time_ns: u64 = 0,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    occurrences: std.ArrayListUnmanaged(Occurrence) = .empty,
    power_last: std.StringHashMapUnmanaged(PowerLast) = .{},
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        for (self.occurrences.items) |*occurrence| occurrence.deinit(self.allocator);
        self.occurrences.deinit(self.allocator);
        var power_iter = self.power_last.iterator();
        while (power_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.power_last.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ingestJsonlBytes(self: *Analyzer, bytes: []const u8) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| try self.ingestJsonLine(line);
    }

    pub fn ingestJsonLine(self: *Analyzer, line: []const u8) !void {
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) return;
        var parsed = (try record_mod.parseEventLine(self.allocator, text)) orelse return;
        defer parsed.deinit();
        try self.ingest(parsed);
    }

    pub fn ingest(self: *Analyzer, parsed: event.Parsed) !void {
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
            .thread_context => try self.recordThreadContext(parsed),
            .thread_pid => try self.recordThreadPid(parsed),
            .cpu_topology => try self.recordCpuTopology(parsed),
            .sys_time => try self.recordSysTime(parsed),
            .sys_power => try self.recordSysPower(parsed),
            .hw_sample => try self.recordHwSample(parsed),
            else => {},
        }
    }

    pub fn collectSummaries(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Summary) {
        self.counters.filtered = 0;
        var summaries: std.ArrayListUnmanaged(Summary) = .empty;
        errdefer deinitSummaries(allocator, &summaries);
        if (options.group == .none) {
            for (self.occurrences.items) |occurrence| {
                if (!occurrenceMatches(occurrence, options)) {
                    self.counters.filtered += 1;
                    continue;
                }
                try summaries.append(allocator, try occurrenceSummary(allocator, occurrence));
            }
        } else {
            var groups: std.StringHashMapUnmanaged(Summary) = .{};
            defer {
                var iter = groups.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                groups.deinit(allocator);
            }
            for (self.occurrences.items) |occurrence| {
                if (!occurrenceMatches(occurrence, options)) {
                    self.counters.filtered += 1;
                    continue;
                }
                var key_writer = std.Io.Writer.Allocating.init(allocator);
                defer key_writer.deinit();
                try writeGroupKey(&key_writer.writer, occurrence, options.group);
                const key = key_writer.written();
                if (groups.getPtr(key)) |summary| {
                    try addOccurrenceToSummary(allocator, summary, occurrence);
                } else {
                    const owned_key = try allocator.dupe(u8, key);
                    errdefer allocator.free(owned_key);
                    var summary = try emptySummary(allocator, options.group, owned_key, occurrence);
                    errdefer summary.deinit(allocator);
                    try addOccurrenceToSummary(allocator, &summary, occurrence);
                    try groups.put(allocator, owned_key, summary);
                }
            }
            var iter = groups.valueIterator();
            while (iter.next()) |summary| {
                var copy = summary.*;
                copy.label = try allocator.dupe(u8, summary.label);
                errdefer allocator.free(copy.label);
                copy.kind = try dupeOptional(allocator, summary.kind);
                errdefer if (copy.kind) |kind| allocator.free(kind);
                try summaries.append(allocator, copy);
            }
        }
        self.counters.groups = @intCast(summaries.items.len);
        self.counters.duration_ns = self.durationNs();
        sortSummaries(summaries.items, options.sort);
        return summaries;
    }

    fn collectOccurrences(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(OccurrenceView) {
        var views: std.ArrayListUnmanaged(OccurrenceView) = .empty;
        for (self.occurrences.items) |*occurrence| {
            if (!occurrenceMatches(occurrence.*, options)) continue;
            try views.append(allocator, .{ .occurrence = occurrence });
        }
        sortOccurrences(views.items, options.sort);
        return views;
    }

    pub fn durationNs(self: Analyzer) u64 {
        const start_ns = self.start_ns orelse return 0;
        const end_ns = self.end_ns orelse return 0;
        if (end_ns <= start_ns) return 0;
        return end_ns - start_ns;
    }

    fn recordThreadContext(self: *Analyzer, parsed: event.Parsed) !void {
        self.counters.thread_contexts += 1;
        try self.recordOccurrence(.{
            .kind = .thread_context,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .thread = parsed.thread,
            .name = try dupeOptional(self.allocator, parsed.name),
        });
    }

    fn recordThreadPid(self: *Analyzer, parsed: event.Parsed) !void {
        self.counters.thread_pid_maps += 1;
        try self.recordOccurrence(.{
            .kind = .thread_pid,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .thread = parsed.thread,
            .pid = parsed.pid,
            .name = try dupeOptional(self.allocator, parsed.name),
        });
    }

    fn recordCpuTopology(self: *Analyzer, parsed: event.Parsed) !void {
        self.counters.cpu_topology += 1;
        try self.recordOccurrence(.{
            .kind = .cpu_topology,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .thread = parsed.thread,
            .cpu = parsed.cpu,
            .cpu_package = parsed.cpu_package,
            .cpu_die = parsed.cpu_die,
            .cpu_core = parsed.cpu_core,
        });
    }

    fn recordSysTime(self: *Analyzer, parsed: event.Parsed) !void {
        const value = parsed.value_f64 orelse return;
        if (!std.math.isFinite(value)) return;
        self.counters.sys_time += 1;
        try self.recordOccurrence(.{
            .kind = .sys_time,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .thread = parsed.thread,
            .cpu = parsed.cpu,
            .value = value,
        });
    }

    fn recordSysPower(self: *Analyzer, parsed: event.Parsed) !void {
        const name = parsed.name orelse "<power>";
        const delta = parsed.power_delta_uj orelse 0;
        const value = try self.powerValue(name, parsed.time_ns, delta);
        self.counters.sys_power += 1;
        if (value != null) self.counters.computed_power += 1;
        try self.recordOccurrence(.{
            .kind = .sys_power,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .thread = parsed.thread,
            .cpu = parsed.cpu,
            .name = try self.allocator.dupe(u8, name),
            .value = value,
            .power_delta_uj = parsed.power_delta_uj,
        });
    }

    fn recordHwSample(self: *Analyzer, parsed: event.Parsed) !void {
        self.counters.hw_samples += 1;
        try self.recordOccurrence(.{
            .kind = .hw_sample,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .thread = parsed.thread,
            .cpu = parsed.cpu,
            .address = parsed.address,
            .hw_sample_kind = try dupeOptional(self.allocator, parsed.hw_sample_kind),
            .name = try dupeOptional(self.allocator, parsed.name),
        });
    }

    fn powerValue(self: *Analyzer, name: []const u8, time_ns: u64, delta_uj: u64) !?f64 {
        if (self.power_last.getPtr(name)) |last| {
            const previous = last.time_ns;
            last.time_ns = time_ns;
            if (time_ns <= previous) return null;
            const dt = time_ns - previous;
            return @as(f64, @floatFromInt(delta_uj)) * 1000.0 / @as(f64, @floatFromInt(dt));
        } else {
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            try self.power_last.put(self.allocator, owned_name, .{ .time_ns = time_ns });
            return null;
        }
    }

    fn recordOccurrence(self: *Analyzer, occurrence: Occurrence) !void {
        var owned = occurrence;
        errdefer owned.deinit(self.allocator);
        try self.occurrences.append(self.allocator, owned);
    }
};

pub fn deinitSummaries(allocator: std.mem.Allocator, summaries: *std.ArrayListUnmanaged(Summary)) void {
    for (summaries.items) |*summary| summary.deinit(allocator);
    summaries.deinit(allocator);
}

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
    defer deinitSummaries(allocator, &summaries);
    var occurrences = try analyzer.collectOccurrences(allocator, options);
    defer occurrences.deinit(allocator);

    try writer.print(
        "tracy system groups={d} events={d} thread_contexts={d} thread_pid_maps={d} cpu_topology={d} sys_time={d} sys_power={d} computed_power={d} hw_samples={d} filtered={d} duration_ns={d} group={s} sort={s}\n",
        .{
            summaries.items.len,
            analyzer.counters.events,
            analyzer.counters.thread_contexts,
            analyzer.counters.thread_pid_maps,
            analyzer.counters.cpu_topology,
            analyzer.counters.sys_time,
            analyzer.counters.sys_power,
            analyzer.counters.computed_power,
            analyzer.counters.hw_samples,
            analyzer.counters.filtered,
            analyzer.durationNs(),
            options.group.tag(),
            options.sort.tag(),
        },
    );
    const summary_limit = @min(options.top, summaries.items.len);
    for (summaries.items[0..summary_limit]) |summary| {
        try writer.print("system group={s} label=", .{summary.group.tag()});
        try pretty_json.writeString(writer, summary.label);
        try writer.print(" count={d}", .{summary.count});
        try writeSummaryFieldsText(writer, summary);
        try writer.writeByte('\n');
    }

    const occurrence_limit = @min(options.occurrences, occurrences.items.len);
    for (occurrences.items[0..occurrence_limit]) |view| {
        const occurrence = view.occurrence.*;
        try writer.print("system-occurrence kind={s} time_ns={d}", .{ occurrence.kind.tag(), occurrence.time_ns });
        try writeOccurrenceFieldsText(writer, occurrence);
        try writer.writeByte('\n');
    }
}

fn writeJsonl(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var summaries = try analyzer.collectSummaries(allocator, options);
    defer deinitSummaries(allocator, &summaries);
    var occurrences = try analyzer.collectOccurrences(allocator, options);
    defer occurrences.deinit(allocator);

    var summary_stream = pretty_json.Writer.init(writer, .minified);
    const summary_record = try summary_stream.object();
    try summary_record.field("schema", schema);
    try summary_record.field("kind", "summary");
    try summary_record.field("groups", summaries.items.len);
    try summary_record.field("events", analyzer.counters.events);
    try summary_record.field("thread_contexts", analyzer.counters.thread_contexts);
    try summary_record.field("thread_pid_maps", analyzer.counters.thread_pid_maps);
    try summary_record.field("cpu_topology", analyzer.counters.cpu_topology);
    try summary_record.field("sys_time", analyzer.counters.sys_time);
    try summary_record.field("sys_power", analyzer.counters.sys_power);
    try summary_record.field("computed_power", analyzer.counters.computed_power);
    try summary_record.field("hw_samples", analyzer.counters.hw_samples);
    try summary_record.field("filtered", analyzer.counters.filtered);
    try summary_record.field("duration_ns", analyzer.durationNs());
    try summary_record.field("group", options.group.tag());
    try summary_record.field("sort", options.sort.tag());
    try summary_record.endLine();

    const summary_limit = @min(options.top, summaries.items.len);
    for (summaries.items[0..summary_limit]) |summary| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "group");
        try object.field("group", summary.group.tag());
        try object.field("label", summary.label);
        try object.field("count", summary.count);
        try writeSummaryFields(object, summary);
        try object.endLine();
    }

    const occurrence_limit = @min(options.occurrences, occurrences.items.len);
    for (occurrences.items[0..occurrence_limit]) |view| {
        const occurrence = view.occurrence.*;
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", occurrence.kind.tag());
        try object.field("time_ns", occurrence.time_ns);
        try writeOccurrenceFields(object, occurrence);
        try object.endLine();
    }
}

fn emptySummary(allocator: std.mem.Allocator, group: Group, label: []const u8, occurrence: Occurrence) !Summary {
    var summary = Summary{
        .group = group,
        .label = try allocator.dupe(u8, label),
        .thread = if (group == .thread) occurrence.thread else null,
        .cpu = if (group == .cpu) occurrence.cpu else null,
        .address = if (group == .address) occurrence.address else null,
        .cpu_package = if (group == .topology) occurrence.cpu_package else null,
        .cpu_die = if (group == .topology) occurrence.cpu_die else null,
        .cpu_core = if (group == .topology) occurrence.cpu_core else null,
    };
    errdefer summary.deinit(allocator);
    summary.kind = try allocator.dupe(u8, occurrence.kind.tag());
    return summary;
}

fn occurrenceSummary(allocator: std.mem.Allocator, occurrence: Occurrence) !Summary {
    var label_writer = std.Io.Writer.Allocating.init(allocator);
    defer label_writer.deinit();
    try label_writer.writer.print("{s} @ {d}", .{ occurrence.kind.tag(), occurrence.time_ns });
    var summary = Summary{
        .group = .none,
        .label = try allocator.dupe(u8, label_writer.written()),
    };
    errdefer summary.deinit(allocator);
    summary.kind = try allocator.dupe(u8, occurrence.kind.tag());
    try addOccurrenceToSummary(allocator, &summary, occurrence);
    return summary;
}

fn addOccurrenceToSummary(allocator: std.mem.Allocator, summary: *Summary, occurrence: Occurrence) !void {
    summary.count += 1;
    if (summary.kind == null) summary.kind = try allocator.dupe(u8, occurrence.kind.tag());
    if (summary.thread == null and occurrence.thread != 0) summary.thread = occurrence.thread;
    if (summary.pid == null and occurrence.pid != 0) summary.pid = occurrence.pid;
    if (summary.cpu == null) summary.cpu = occurrence.cpu;
    if (summary.cpu_package == null) summary.cpu_package = occurrence.cpu_package;
    if (summary.cpu_die == null) summary.cpu_die = occurrence.cpu_die;
    if (summary.cpu_core == null) summary.cpu_core = occurrence.cpu_core;
    if (summary.address == null and occurrence.address != 0) summary.address = occurrence.address;
    if (occurrence.value) |value| {
        if (summary.value_count == 0) {
            summary.value_min = value;
            summary.value_max = value;
        } else {
            summary.value_min = @min(summary.value_min, value);
            summary.value_max = @max(summary.value_max, value);
        }
        summary.value_count += 1;
        summary.value_sum += value;
        summary.value_last = value;
    }
    if (occurrence.power_delta_uj) |delta| summary.power_delta_uj +|= delta;
    noteRange(&summary.first_ns, &summary.last_ns, occurrence.time_ns);
}

fn writeGroupKey(writer: *std.Io.Writer, occurrence: Occurrence, group: Group) !void {
    switch (group) {
        .kind => try writer.writeAll(occurrenceKindLabel(occurrence)),
        .thread => try writer.print("thread {d}", .{occurrence.thread}),
        .cpu => try writer.print("cpu {d}", .{occurrence.cpu orelse 0}),
        .address => try writer.print("0x{x}", .{occurrence.address}),
        .topology => try writer.print("package {d} die {d} core {d}", .{ occurrence.cpu_package orelse 0, occurrence.cpu_die orelse 0, occurrence.cpu_core orelse 0 }),
        .name => {
            if (occurrence.name) |name| {
                try writer.writeAll(name);
            } else if (occurrence.hw_sample_kind) |kind| {
                try writer.writeAll(kind);
            } else {
                try writer.writeAll(occurrence.kind.tag());
            }
        },
        .none => unreachable,
    }
}

fn occurrenceKindLabel(occurrence: Occurrence) []const u8 {
    if (occurrence.kind == .hw_sample) return occurrence.hw_sample_kind orelse "hw-sample";
    if (occurrence.kind == .sys_power) return occurrence.name orelse "sys-power";
    return occurrence.kind.tag();
}

fn occurrenceMatches(occurrence: Occurrence, options: Options) bool {
    if (options.thread) |thread| if (occurrence.thread != thread) return false;
    if (options.cpu) |cpu| {
        const actual = occurrence.cpu orelse return false;
        if (actual != cpu) return false;
    }
    if (options.address) |address| if (occurrence.address != address) return false;
    if (options.since_ns) |since_ns| if (occurrence.time_ns < since_ns) return false;
    if (options.until_ns) |until_ns| if (occurrence.time_ns > until_ns) return false;
    if (options.kind) |wanted| if (!contains(occurrence.kind.tag(), wanted, options.ignore_case) and !contains(occurrenceKindLabel(occurrence), wanted, options.ignore_case)) return false;
    if (options.match) |needle| {
        if (contains(occurrence.kind.tag(), needle, options.ignore_case)) return true;
        if (contains(occurrenceKindLabel(occurrence), needle, options.ignore_case)) return true;
        if (occurrence.name) |name| if (contains(name, needle, options.ignore_case)) return true;
        if (occurrence.hw_sample_kind) |kind| if (contains(kind, needle, options.ignore_case)) return true;
        return false;
    }
    return true;
}

fn writeSummaryFieldsText(writer: *std.Io.Writer, summary: Summary) !void {
    if (summary.kind) |kind| {
        try writer.writeAll(" kind=");
        try pretty_json.writeString(writer, kind);
    }
    if (summary.thread) |thread| try writer.print(" thread={d}", .{thread});
    if (summary.pid) |pid| try writer.print(" pid={d}", .{pid});
    if (summary.cpu) |cpu| try writer.print(" cpu={d}", .{cpu});
    if (summary.cpu_package) |package| try writer.print(" package={d}", .{package});
    if (summary.cpu_die) |die| try writer.print(" die={d}", .{die});
    if (summary.cpu_core) |core| try writer.print(" core={d}", .{core});
    if (summary.address) |address| try writer.print(" address=0x{x}", .{address});
    if (summary.value_count != 0) try writer.print(" values={d} value_min={d} value_max={d} value_mean={d}", .{ summary.value_count, summary.value_min, summary.value_max, summary.valueMean() });
    if (summary.value_last) |value| try writer.print(" value_last={d}", .{value});
    if (summary.power_delta_uj != 0) try writer.print(" power_delta_uj={d}", .{summary.power_delta_uj});
    if (summary.first_ns != 0) try writer.print(" first_ns={d}", .{summary.first_ns});
    if (summary.last_ns != 0) try writer.print(" last_ns={d}", .{summary.last_ns});
}

fn writeSummaryFields(object: pretty_json.Object, summary: Summary) !void {
    if (summary.kind) |kind| try object.field("system_kind", kind);
    if (summary.thread) |thread| try object.field("thread", thread);
    if (summary.pid) |pid| try object.field("pid", pid);
    if (summary.cpu) |cpu| try object.field("cpu", cpu);
    if (summary.cpu_package) |package| try object.field("cpu_package", package);
    if (summary.cpu_die) |die| try object.field("cpu_die", die);
    if (summary.cpu_core) |core| try object.field("cpu_core", core);
    if (summary.address) |address| try object.field("address", address);
    if (summary.value_count != 0) {
        try object.field("values", summary.value_count);
        try object.field("value_min", summary.value_min);
        try object.field("value_max", summary.value_max);
        try object.field("value_mean", summary.valueMean());
    }
    if (summary.value_last) |value| try object.field("value_last", value);
    if (summary.power_delta_uj != 0) try object.field("power_delta_uj", summary.power_delta_uj);
    if (summary.first_ns != 0) try object.field("first_ns", summary.first_ns);
    if (summary.last_ns != 0) try object.field("last_ns", summary.last_ns);
}

fn writeOccurrenceFieldsText(writer: *std.Io.Writer, occurrence: Occurrence) !void {
    if (occurrence.thread != 0) try writer.print(" thread={d}", .{occurrence.thread});
    if (occurrence.pid != 0) try writer.print(" pid={d}", .{occurrence.pid});
    if (occurrence.cpu) |cpu| try writer.print(" cpu={d}", .{cpu});
    if (occurrence.cpu_package) |package| try writer.print(" package={d}", .{package});
    if (occurrence.cpu_die) |die| try writer.print(" die={d}", .{die});
    if (occurrence.cpu_core) |core| try writer.print(" core={d}", .{core});
    if (occurrence.address != 0) try writer.print(" address=0x{x}", .{occurrence.address});
    if (occurrence.name) |name| {
        try writer.writeAll(" name=");
        try pretty_json.writeString(writer, name);
    }
    if (occurrence.hw_sample_kind) |kind| {
        try writer.writeAll(" hw_sample_kind=");
        try pretty_json.writeString(writer, kind);
    }
    if (occurrence.value) |value| try writer.print(" value={d}", .{value});
    if (occurrence.power_delta_uj) |delta| try writer.print(" power_delta_uj={d}", .{delta});
}

fn writeOccurrenceFields(object: pretty_json.Object, occurrence: Occurrence) !void {
    if (occurrence.thread != 0) try object.field("thread", occurrence.thread);
    if (occurrence.pid != 0) try object.field("pid", occurrence.pid);
    if (occurrence.cpu) |cpu| try object.field("cpu", cpu);
    if (occurrence.cpu_package) |package| try object.field("cpu_package", package);
    if (occurrence.cpu_die) |die| try object.field("cpu_die", die);
    if (occurrence.cpu_core) |core| try object.field("cpu_core", core);
    if (occurrence.address != 0) try object.field("address", occurrence.address);
    if (occurrence.name) |name| try object.field("name", name);
    if (occurrence.hw_sample_kind) |kind| try object.field("hw_sample_kind", kind);
    if (occurrence.value) |value| try object.field("value", value);
    if (occurrence.power_delta_uj) |delta| try object.field("power_delta_uj", delta);
}

fn sortSummaries(items: []Summary, sort: Sort) void {
    std.mem.sort(Summary, items, sort, summaryLessThan);
}

fn summaryLessThan(sort: Sort, left: Summary, right: Summary) bool {
    return switch (sort) {
        .count => summaryCountGreaterThan({}, left, right),
        .value => summaryValueGreaterThan({}, left, right),
        .last => summaryLastGreaterThan({}, left, right),
        .first => summaryFirstLessThan({}, left, right),
        .thread => summaryThreadLessThan({}, left, right),
        .cpu => summaryCpuLessThan({}, left, right),
        .address => summaryAddressLessThan({}, left, right),
        .label => summaryLabelLessThan({}, left, right),
    };
}

fn summaryCountGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.count != right.count) return left.count > right.count;
    return summaryLabelLessThan({}, left, right);
}

fn summaryValueGreaterThan(_: void, left: Summary, right: Summary) bool {
    const left_value = left.value_last orelse left.valueMean();
    const right_value = right.value_last orelse right.valueMean();
    if (left_value != right_value) return left_value > right_value;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryLastGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.last_ns != right.last_ns) return left.last_ns > right.last_ns;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryFirstLessThan(_: void, left: Summary, right: Summary) bool {
    if (left.first_ns != right.first_ns) return left.first_ns < right.first_ns;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryThreadLessThan(_: void, left: Summary, right: Summary) bool {
    const left_thread = left.thread orelse 0;
    const right_thread = right.thread orelse 0;
    if (left_thread != right_thread) return left_thread < right_thread;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryCpuLessThan(_: void, left: Summary, right: Summary) bool {
    const left_cpu = left.cpu orelse 0;
    const right_cpu = right.cpu orelse 0;
    if (left_cpu != right_cpu) return left_cpu < right_cpu;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryAddressLessThan(_: void, left: Summary, right: Summary) bool {
    const left_address = left.address orelse 0;
    const right_address = right.address orelse 0;
    if (left_address != right_address) return left_address < right_address;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryLabelLessThan(_: void, left: Summary, right: Summary) bool {
    return std.mem.lessThan(u8, left.label, right.label);
}

fn sortOccurrences(items: []OccurrenceView, sort: Sort) void {
    switch (sort) {
        .last => std.mem.sort(OccurrenceView, items, {}, occurrenceTimeGreaterThan),
        .address => std.mem.sort(OccurrenceView, items, {}, occurrenceAddressLessThan),
        .thread => std.mem.sort(OccurrenceView, items, {}, occurrenceThreadLessThan),
        .cpu => std.mem.sort(OccurrenceView, items, {}, occurrenceCpuLessThan),
        else => std.mem.sort(OccurrenceView, items, {}, occurrenceTimeLessThan),
    }
}

fn occurrenceTimeLessThan(_: void, left: OccurrenceView, right: OccurrenceView) bool {
    if (left.occurrence.time_ns != right.occurrence.time_ns) return left.occurrence.time_ns < right.occurrence.time_ns;
    return left.occurrence.seq < right.occurrence.seq;
}

fn occurrenceTimeGreaterThan(_: void, left: OccurrenceView, right: OccurrenceView) bool {
    if (left.occurrence.time_ns != right.occurrence.time_ns) return left.occurrence.time_ns > right.occurrence.time_ns;
    return left.occurrence.seq > right.occurrence.seq;
}

fn occurrenceAddressLessThan(_: void, left: OccurrenceView, right: OccurrenceView) bool {
    if (left.occurrence.address != right.occurrence.address) return left.occurrence.address < right.occurrence.address;
    return occurrenceTimeLessThan({}, left, right);
}

fn occurrenceThreadLessThan(_: void, left: OccurrenceView, right: OccurrenceView) bool {
    if (left.occurrence.thread != right.occurrence.thread) return left.occurrence.thread < right.occurrence.thread;
    return occurrenceTimeLessThan({}, left, right);
}

fn occurrenceCpuLessThan(_: void, left: OccurrenceView, right: OccurrenceView) bool {
    const left_cpu = left.occurrence.cpu orelse 0;
    const right_cpu = right.occurrence.cpu orelse 0;
    if (left_cpu != right_cpu) return left_cpu < right_cpu;
    return occurrenceTimeLessThan({}, left, right);
}

fn noteRange(first_ns: *u64, last_ns: *u64, time_ns: u64) void {
    if (time_ns == 0) return;
    if (first_ns.* == 0 or time_ns < first_ns.*) first_ns.* = time_ns;
    last_ns.* = @max(last_ns.*, time_ns);
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
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

test "system analyzer aggregates topology power and hardware samples" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 90, .thread = 1, .name = "system" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .thread_context, .time_ns = 100, .thread = 42, .name = "worker" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .thread_pid, .time_ns = 105, .thread = 42, .pid = 900 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .cpu_topology, .time_ns = 110, .thread = 1, .cpu = 7, .cpu_package = 1, .cpu_die = 0, .cpu_core = 3 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .sys_time, .time_ns = 120, .thread = 1, .value_f64 = 0.25 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .sys_power, .time_ns = 130, .thread = 1, .name = "package", .power_delta_uj = 0 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .sys_power, .time_ns = 1130, .thread = 1, .name = "package", .power_delta_uj = 2000 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 8, .kind = .hw_sample, .time_ns = 1140, .thread = 42, .cpu = 7, .address = 0xabc, .hw_sample_kind = "cache-miss" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 9, .kind = .stop, .time_ns = 1200, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.thread_contexts);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.thread_pid_maps);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.cpu_topology);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.sys_time);
    try std.testing.expectEqual(@as(u64, 2), analyzer.counters.sys_power);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.computed_power);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.hw_samples);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .group = .kind, .sort = .count, .top = 8, .occurrences = 8 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy system groups=6 events=9 thread_contexts=1 thread_pid_maps=1 cpu_topology=1 sys_time=1 sys_power=2 computed_power=1 hw_samples=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "system group=kind label=\"package\" count=2 kind=\"sys-power\" thread=1 values=1 value_min=2000 value_max=2000 value_mean=2000 value_last=2000 power_delta_uj=2000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "system-occurrence kind=hw-sample time_ns=1140 thread=42 cpu=7 address=0xabc hw_sample_kind=\"cache-miss\"") != null);
}

test "system jsonl filters hardware samples by address and match" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .hw_sample, .time_ns = 100, .thread = 2, .cpu = 1, .address = 0x1000, .hw_sample_kind = "cpu-cycle" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .hw_sample, .time_ns = 110, .thread = 2, .cpu = 1, .address = 0x2000, .hw_sample_kind = "cache-miss" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .hw_sample, .time_ns = 120, .thread = 3, .cpu = 2, .address = 0x2000, .hw_sample_kind = "cache-miss" }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{ .group = .address, .address = 0x2000, .match = "CACHE", .ignore_case = true });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.system/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"summary\",\"groups\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"label\":\"0x2000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"address\":8192") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"hw-sample\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"cpu-cycle\"") == null);
}
