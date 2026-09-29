const std = @import("std");
const pretty_json = @import("pretty").json;
const capture_mod = @import("capture.zig");
const report = @import("report.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");
const transport = @import("transport.zig");

pub const schema = "tracy.plots/v0";
pub const CaptureIntegrity = capture_mod.Integrity;

pub const Sort = enum {
    samples,
    max,
    min,
    mean,
    range,
    last,
    name,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "samples")) return .samples;
        if (std.mem.eql(u8, text, "max")) return .max;
        if (std.mem.eql(u8, text, "min")) return .min;
        if (std.mem.eql(u8, text, "mean")) return .mean;
        if (std.mem.eql(u8, text, "range")) return .range;
        if (std.mem.eql(u8, text, "last")) return .last;
        if (std.mem.eql(u8, text, "name")) return .name;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .samples => "samples",
            .max => "max",
            .min => "min",
            .mean => "mean",
            .range => "range",
            .last => "last",
            .name => "name",
        };
    }
};

pub const Options = struct {
    top: usize = 20,
    sort: Sort = .samples,
    min_samples: u64 = 0,
    name: ?[]const u8 = null,
};

pub const Counters = struct {
    events: u64 = 0,
    samples: u64 = 0,
    series: u64 = 0,
    configurations: u64 = 0,
    configuration_conflicts: u64 = 0,
    ignored_missing_values: u64 = 0,
    ignored_nonfinite: u64 = 0,
};

pub const Summary = struct {
    name: []const u8,
    kind: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    configured: bool = false,
    step: bool = false,
    fill: bool = false,
    color: ?u32 = null,
    configurations: u64 = 0,
    configuration_conflicts: u64 = 0,
    count: u64 = 0,
    min: f64 = 0,
    p50: f64 = 0,
    p90: f64 = 0,
    p99: f64 = 0,
    max: f64 = 0,
    mean: f64 = 0,
    first: f64 = 0,
    last: f64 = 0,
    delta: f64 = 0,
    range: f64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,
    duration_ns: u64 = 0,
    threads: u64 = 0,
};

const Sample = struct {
    time_ns: u64,
    thread: u64,
    value: f64,
};

const Series = struct {
    name: []const u8,
    kind: ?[]u8 = null,
    unit: ?[]u8 = null,
    configured: bool = false,
    step: bool = false,
    fill: bool = false,
    color: ?u32 = null,
    configurations: u64 = 0,
    configuration_conflicts: u64 = 0,
    samples: std.ArrayListUnmanaged(Sample) = .empty,
    threads: std.ArrayListUnmanaged(u64) = .empty,
    sum: f64 = 0,
    min: f64 = std.math.inf(f64),
    max: f64 = -std.math.inf(f64),
    first: f64 = 0,
    last: f64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    fn deinit(self: *Series, allocator: std.mem.Allocator) void {
        if (self.kind) |kind| allocator.free(kind);
        if (self.unit) |unit| allocator.free(unit);
        self.samples.deinit(allocator);
        self.threads.deinit(allocator);
        self.* = undefined;
    }

    fn count(self: Series) u64 {
        return @intCast(self.samples.items.len);
    }

    fn mean(self: Series) f64 {
        if (self.samples.items.len == 0) return 0;
        return self.sum / @as(f64, @floatFromInt(self.samples.items.len));
    }

    fn range(self: Series) f64 {
        if (self.samples.items.len == 0) return 0;
        return self.max - self.min;
    }

    fn delta(self: Series) f64 {
        if (self.samples.items.len == 0) return 0;
        return self.last - self.first;
    }

    fn durationNs(self: Series) u64 {
        if (self.last_ns <= self.first_ns) return 0;
        return self.last_ns - self.first_ns;
    }
};

const Spike = struct {
    name: []const u8,
    index: u64,
    time_ns: u64,
    thread: u64,
    value: f64,
    delta: f64,
    abs_delta: f64,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    capture: capture_mod.Tracker = .{},
    series: std.StringHashMapUnmanaged(Series) = .{},
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        var iter = self.series.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.series.deinit(self.allocator);
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
            .plot_config => try self.recordConfig(parsed),
            .plot => try self.recordPlot(parsed),
            else => {},
        }
    }

    pub fn collectSummaries(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Summary) {
        var rows: std.ArrayListUnmanaged(Summary) = .empty;
        errdefer rows.deinit(allocator);
        var iter = self.series.valueIterator();
        while (iter.next()) |item| {
            if (!seriesMatches(item.*, options)) continue;
            try rows.append(allocator, try summaryView(allocator, item.*));
        }
        sortSummaries(rows.items, options.sort);
        return rows;
    }

    fn collectSpikes(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Spike) {
        var rows: std.ArrayListUnmanaged(Spike) = .empty;
        errdefer rows.deinit(allocator);
        var iter = self.series.valueIterator();
        while (iter.next()) |item| {
            if (!seriesMatches(item.*, options)) continue;
            if (item.samples.items.len < 2) continue;
            for (item.samples.items[1..], 1..) |sample, index| {
                const previous = item.samples.items[index - 1];
                const delta = sample.value - previous.value;
                try rows.append(allocator, .{
                    .name = item.name,
                    .index = @intCast(index + 1),
                    .time_ns = sample.time_ns,
                    .thread = sample.thread,
                    .value = sample.value,
                    .delta = delta,
                    .abs_delta = absF64(delta),
                });
            }
        }
        std.mem.sort(Spike, rows.items, {}, spikeGreaterThan);
        return rows;
    }

    pub fn durationNs(self: Analyzer) u64 {
        const start_ns = self.start_ns orelse return 0;
        const end_ns = self.end_ns orelse return 0;
        if (end_ns <= start_ns) return 0;
        return end_ns - start_ns;
    }

    pub fn captureIntegrity(self: *const Analyzer) CaptureIntegrity {
        return self.capture.integrity(0);
    }

    pub fn recordFlightReport(self: *Analyzer, report_value: transport.Report) void {
        self.capture.recordFlightReport(report_value);
    }

    fn recordConfig(self: *Analyzer, parsed: event.Parsed) !void {
        const item = try self.seriesFor(parsed.name orelse "<plot>");
        const unit = parsed.plot_unit orelse "number";
        if (!item.configured) {
            const owned_unit = try self.allocator.dupe(u8, unit);
            item.unit = owned_unit;
            item.configured = true;
            item.step = parsed.plot_step;
            item.fill = parsed.plot_fill;
            item.color = parsed.color;
            item.configurations += 1;
            self.counters.configurations += 1;
            return;
        }
        if (!configMatches(item.*, unit, parsed)) {
            item.configuration_conflicts += 1;
            self.counters.configuration_conflicts += 1;
        }
        item.configurations += 1;
        self.counters.configurations += 1;
    }

    fn recordPlot(self: *Analyzer, parsed: event.Parsed) !void {
        const value = plotValue(parsed) orelse {
            self.counters.ignored_missing_values += 1;
            return;
        };
        if (!std.math.isFinite(value)) {
            self.counters.ignored_nonfinite += 1;
            return;
        }
        const item = try self.seriesFor(parsed.name orelse "<plot>");
        if (parsed.plot_kind) |kind| try self.recordKind(item, kind);
        if (item.samples.items.len == 0) {
            item.first = value;
            item.first_ns = parsed.time_ns;
        }
        try item.samples.append(self.allocator, .{
            .time_ns = parsed.time_ns,
            .thread = parsed.thread,
            .value = value,
        });
        try appendThread(self.allocator, &item.threads, parsed.thread);
        item.sum += value;
        item.min = @min(item.min, value);
        item.max = @max(item.max, value);
        item.last = value;
        item.last_ns = parsed.time_ns;
        self.counters.samples += 1;
    }

    fn recordKind(self: *Analyzer, item: *Series, kind: []const u8) !void {
        if (item.kind) |existing| {
            if (std.mem.eql(u8, existing, kind)) return;
            const owned_kind = try self.allocator.dupe(u8, kind);
            self.allocator.free(existing);
            item.kind = owned_kind;
            return;
        }
        item.kind = try self.allocator.dupe(u8, kind);
    }

    fn seriesFor(self: *Analyzer, name: []const u8) !*Series {
        const entry = try self.series.getOrPut(self.allocator, name);
        if (!entry.found_existing) {
            errdefer _ = self.series.fetchRemove(name);
            const owned_name = try self.allocator.dupe(u8, name);
            entry.key_ptr.* = owned_name;
            entry.value_ptr.* = .{ .name = owned_name };
            self.counters.series += 1;
        }
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
    var spikes = try analyzer.collectSpikes(allocator, options);
    defer spikes.deinit(allocator);

    try writer.print(
        "tracy plots series={d} samples={d} configurations={d} " ++
            "configuration_conflicts={d} ignored_missing_values={d} " ++
            "ignored_nonfinite={d} duration_ns={d} sort={s}\n",
        .{
            summaries.items.len,
            analyzer.counters.samples,
            analyzer.counters.configurations,
            analyzer.counters.configuration_conflicts,
            analyzer.counters.ignored_missing_values,
            analyzer.counters.ignored_nonfinite,
            analyzer.durationNs(),
            options.sort.tag(),
        },
    );
    try capture_mod.writeText(writer, analyzer.captureIntegrity());
    const summary_limit = @min(options.top, summaries.items.len);
    for (summaries.items[0..summary_limit]) |summary| try writeSummaryText(writer, summary);
    const spike_limit = @min(options.top, spikes.items.len);
    for (spikes.items[0..spike_limit]) |spike| {
        try writer.writeAll("plot-spike name=");
        try pretty_json.writeString(writer, spike.name);
        try writer.print(
            " index={d} time_ns={d} thread={d} value={d} delta={d} abs_delta={d}\n",
            .{ spike.index, spike.time_ns, spike.thread, spike.value, spike.delta, spike.abs_delta },
        );
    }
}

fn writeJsonl(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var summaries = try analyzer.collectSummaries(allocator, options);
    defer summaries.deinit(allocator);
    var spikes = try analyzer.collectSpikes(allocator, options);
    defer spikes.deinit(allocator);

    var summary_stream = pretty_json.Writer.init(writer, .minified);
    const summary_record = try summary_stream.object();
    try summary_record.field("schema", schema);
    try summary_record.field("kind", "summary");
    try summary_record.field("series", summaries.items.len);
    try summary_record.field("samples", analyzer.counters.samples);
    try summary_record.field("configurations", analyzer.counters.configurations);
    try summary_record.field("configuration_conflicts", analyzer.counters.configuration_conflicts);
    try summary_record.field("ignored_missing_values", analyzer.counters.ignored_missing_values);
    try summary_record.field("ignored_nonfinite", analyzer.counters.ignored_nonfinite);
    try summary_record.field("duration_ns", analyzer.durationNs());
    try summary_record.field("sort", options.sort.tag());
    try capture_mod.writeFields(summary_record, analyzer.captureIntegrity());
    try summary_record.endLine();

    const summary_limit = @min(options.top, summaries.items.len);
    for (summaries.items[0..summary_limit]) |summary| try writeSummaryJson(writer, summary);

    const spike_limit = @min(options.top, spikes.items.len);
    for (spikes.items[0..spike_limit]) |spike| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "spike");
        try object.field("name", spike.name);
        try object.field("index", spike.index);
        try object.field("time_ns", spike.time_ns);
        try object.field("thread", spike.thread);
        try object.field("value", spike.value);
        try object.field("delta", spike.delta);
        try object.field("abs_delta", spike.abs_delta);
        try object.endLine();
    }
}

fn writeSummaryText(writer: *std.Io.Writer, summary: Summary) !void {
    try writer.writeAll("plot name=");
    try pretty_json.writeString(writer, summary.name);
    try writer.print(
        " samples={d} min={d} p50={d} p90={d} p99={d} max={d} mean={d} " ++
            "first={d} last={d} delta={d} range={d} first_ns={d} last_ns={d} " ++
            "duration_ns={d} threads={d}",
        .{
            summary.count,   summary.min,         summary.p50,
            summary.p90,     summary.p99,         summary.max,
            summary.mean,    summary.first,       summary.last,
            summary.delta,   summary.range,       summary.first_ns,
            summary.last_ns, summary.duration_ns, summary.threads,
        },
    );
    if (summary.kind) |kind| {
        try writer.writeAll(" kind=");
        try pretty_json.writeString(writer, kind);
    }
    try writeConfigText(writer, summary);
    try writer.writeByte('\n');
}

fn writeConfigText(writer: *std.Io.Writer, summary: Summary) !void {
    try writer.print(
        " configured={} configurations={d} configuration_conflicts={d} unit=",
        .{ summary.configured, summary.configurations, summary.configuration_conflicts },
    );
    if (summary.unit) |unit| try pretty_json.writeString(writer, unit) else try writer.writeAll("none");
    try writer.print(" step={} fill={} color=", .{ summary.step, summary.fill });
    if (summary.color) |color| try writer.print("{d}", .{color}) else try writer.writeAll("none");
}

fn writeSummaryJson(writer: *std.Io.Writer, summary: Summary) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "plot");
    try object.field("name", summary.name);
    if (summary.kind) |kind| try object.field("plot_kind", kind);
    try writeConfigFields(object, summary);
    try object.field("samples", summary.count);
    try object.field("min", summary.min);
    try object.field("p50", summary.p50);
    try object.field("p90", summary.p90);
    try object.field("p99", summary.p99);
    try object.field("max", summary.max);
    try object.field("mean", summary.mean);
    try object.field("first", summary.first);
    try object.field("last", summary.last);
    try object.field("delta", summary.delta);
    try object.field("range", summary.range);
    try object.field("first_ns", summary.first_ns);
    try object.field("last_ns", summary.last_ns);
    try object.field("duration_ns", summary.duration_ns);
    try object.field("threads", summary.threads);
    try object.endLine();
}

fn writeConfigFields(object: pretty_json.Object, summary: Summary) !void {
    try object.field("unit", summary.unit);
    try object.field("configured", summary.configured);
    try object.field("step", summary.step);
    try object.field("fill", summary.fill);
    try object.field("color", summary.color);
    try object.field("configurations", summary.configurations);
    try object.field("configuration_conflicts", summary.configuration_conflicts);
}

fn seriesMatches(item: Series, options: Options) bool {
    if (options.name) |wanted| {
        if (!std.mem.eql(u8, wanted, item.name)) return false;
    }
    return item.count() >= options.min_samples;
}

fn summaryView(allocator: std.mem.Allocator, item: Series) !Summary {
    var values = try allocator.alloc(f64, item.samples.items.len);
    defer allocator.free(values);
    for (item.samples.items, 0..) |sample, index| values[index] = sample.value;
    std.mem.sort(f64, values, {}, f64LessThan);
    return .{
        .name = item.name,
        .kind = item.kind,
        .unit = item.unit,
        .configured = item.configured,
        .step = item.step,
        .fill = item.fill,
        .color = item.color,
        .configurations = item.configurations,
        .configuration_conflicts = item.configuration_conflicts,
        .count = item.count(),
        .min = if (item.samples.items.len == 0) 0 else item.min,
        .p50 = percentile(values, 50),
        .p90 = percentile(values, 90),
        .p99 = percentile(values, 99),
        .max = if (item.samples.items.len == 0) 0 else item.max,
        .mean = item.mean(),
        .first = item.first,
        .last = item.last,
        .delta = item.delta(),
        .range = item.range(),
        .first_ns = item.first_ns,
        .last_ns = item.last_ns,
        .duration_ns = item.durationNs(),
        .threads = @intCast(item.threads.items.len),
    };
}

fn configMatches(item: Series, unit: []const u8, parsed: event.Parsed) bool {
    const existing_unit = item.unit orelse return false;
    if (!std.mem.eql(u8, existing_unit, unit)) return false;
    if (item.step != parsed.plot_step) return false;
    if (item.fill != parsed.plot_fill) return false;
    return item.color == parsed.color;
}

fn percentile(sorted: []const f64, percent: u64) f64 {
    if (sorted.len == 0) return 0;
    const rank: usize = @intCast((@as(u128, percent) * sorted.len + 99) / 100);
    const index = @min(@max(rank, 1) - 1, sorted.len - 1);
    return sorted[index];
}

fn plotValue(parsed: event.Parsed) ?f64 {
    if (parsed.value_f64) |value| return value;
    if (parsed.value_i64) |value| return @floatFromInt(value);
    if (parsed.value_u64) |value| return @floatFromInt(value);
    return null;
}

fn appendThread(allocator: std.mem.Allocator, threads: *std.ArrayListUnmanaged(u64), thread: u64) !void {
    for (threads.items) |existing| {
        if (existing == thread) return;
    }
    try threads.append(allocator, thread);
}

fn sortSummaries(items: []Summary, sort: Sort) void {
    std.mem.sort(Summary, items, sort, summaryLessThan);
}

fn summaryLessThan(sort: Sort, left: Summary, right: Summary) bool {
    return switch (sort) {
        .samples => summarySamplesGreaterThan({}, left, right),
        .max => summaryMaxGreaterThan({}, left, right),
        .min => summaryMinLessThan({}, left, right),
        .mean => summaryMeanGreaterThan({}, left, right),
        .range => summaryRangeGreaterThan({}, left, right),
        .last => summaryLastGreaterThan({}, left, right),
        .name => summaryNameLessThan({}, left, right),
    };
}

fn summarySamplesGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.count != right.count) return left.count > right.count;
    return summaryNameLessThan({}, left, right);
}

fn summaryMaxGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.max != right.max) return left.max > right.max;
    return summaryNameLessThan({}, left, right);
}

fn summaryMinLessThan(_: void, left: Summary, right: Summary) bool {
    if (left.min != right.min) return left.min < right.min;
    return summaryNameLessThan({}, left, right);
}

fn summaryMeanGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.mean != right.mean) return left.mean > right.mean;
    return summaryNameLessThan({}, left, right);
}

fn summaryRangeGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.range != right.range) return left.range > right.range;
    return summaryNameLessThan({}, left, right);
}

fn summaryLastGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.last != right.last) return left.last > right.last;
    return summaryNameLessThan({}, left, right);
}

fn summaryNameLessThan(_: void, left: Summary, right: Summary) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn spikeGreaterThan(_: void, left: Spike, right: Spike) bool {
    if (left.abs_delta != right.abs_delta) return left.abs_delta > right.abs_delta;
    const name_cmp = std.mem.order(u8, left.name, right.name);
    if (name_cmp != .eq) return name_cmp == .lt;
    return left.index < right.index;
}

fn f64LessThan(_: void, left: f64, right: f64) bool {
    return left < right;
}

fn absF64(value: f64) f64 {
    if (value < 0) return -value;
    return value;
}

test "plots aggregate series percentiles and spikes" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 90, .thread = 1, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .plot, .time_ns = 100, .thread = 1, .name = "latency.ns", .value_i64 = 10, .plot_kind = "int" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .plot, .time_ns = 110, .thread = 1, .name = "latency.ns", .value_i64 = 14, .plot_kind = "int" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .plot, .time_ns = 120, .thread = 2, .name = "queue.depth", .value_i64 = 3, .plot_kind = "int" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .plot, .time_ns = 130, .thread = 1, .name = "latency.ns", .value_i64 = 30, .plot_kind = "int" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .plot, .time_ns = 140, .thread = 1, .name = "latency.ns", .value_i64 = 22, .plot_kind = "int" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .plot, .time_ns = 150, .thread = 2, .name = "queue.depth", .value_i64 = 5, .plot_kind = "int" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 8, .kind = .stop, .time_ns = 160, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 6), analyzer.counters.samples);
    try std.testing.expectEqual(@as(u64, 2), analyzer.counters.series);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4, .sort = .samples });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy plots series=2 samples=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "plot name=\"latency.ns\" samples=4 min=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "p50=14") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "p90=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mean=19") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "delta=12 range=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "plot-spike name=\"latency.ns\" index=3 time_ns=130 thread=1 value=30 delta=16 abs_delta=16") != null);
}

test "plots jsonl filters series and emits spike rows" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .plot, .time_ns = 100, .thread = 1, .name = "latency.ns", .value_f64 = 1.5, .plot_kind = "float" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .plot, .time_ns = 110, .thread = 1, .name = "other", .value_i64 = 9, .plot_kind = "int" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .plot, .time_ns = 120, .thread = 1, .name = "latency.ns", .value_f64 = 5.5, .plot_kind = "float" }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{ .top = 2, .sort = .name, .min_samples = 2, .name = "latency.ns" });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.plots/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"plot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"latency.ns\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"plot_kind\":\"float\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"samples\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"spike\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"delta\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"other\"") == null);
}

test "plots preserve first configuration and expose conflicts" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try appendConfiguredTrace(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 3), analyzer.counters.configurations);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.configuration_conflicts);

    var summaries = try analyzer.collectSummaries(std.testing.allocator, .{});
    defer summaries.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    const summary = summaries.items[0];
    try std.testing.expectEqualStrings("bytes", summary.unit.?);
    try std.testing.expect(summary.configured);
    try std.testing.expect(summary.step);
    try std.testing.expect(summary.fill);
    try std.testing.expectEqual(@as(?u32, 0x44aa88), summary.color);
    try std.testing.expectEqual(@as(u64, 3), summary.configurations);
    try std.testing.expectEqual(@as(u64, 1), summary.configuration_conflicts);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{});
    const jsonl = out.written();
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"unit\":\"bytes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"configured\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"configuration_conflicts\":1") != null);
}

test "plots retain flight reports and sequence integrity" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .plot, .name = "load", .value_i64 = 1 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .stop }).writeJsonLine(&trace.writer);
    const flight_report = testFlightReport();
    try flight_report.writeJsonl(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    const integrity = analyzer.captureIntegrity();
    try std.testing.expectEqualStrings("sequence_gaps", integrity.status);
    try std.testing.expectEqualDeep(flight_report, integrity.flight_report.?);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"flight_report\":{") != null);
}

test "plots release configuration evidence on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        analyzeConfiguredPlots,
        .{},
    );
}

fn analyzeConfiguredPlots(allocator: std.mem.Allocator) !void {
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    const trace =
        "{\"v\":0,\"kind\":\"plot.config\",\"name\":\"heap\"," ++
        "\"plot_unit\":\"bytes\",\"plot_step\":true}\n" ++
        "{\"v\":0,\"kind\":\"plot\",\"name\":\"heap\",\"value_i64\":64," ++
        "\"plot_kind\":\"int\"}\n";
    try analyzer.ingestJsonlBytes(trace);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(allocator, &analyzer, &out.writer, .{});
}

fn appendConfiguredTrace(writer: *std.Io.Writer) !void {
    try (event.TraceEvent{ .seq = 1, .kind = .start }).writeJsonLine(writer);
    const config = event.TraceEvent{
        .seq = 2,
        .kind = .plot_config,
        .name = "heap",
        .color = 0x44aa88,
        .plot_unit = "bytes",
        .plot_step = true,
        .plot_fill = true,
    };
    try config.writeJsonLine(writer);
    var repeated = config;
    repeated.seq = 3;
    try repeated.writeJsonLine(writer);
    var conflicting = config;
    conflicting.seq = 4;
    conflicting.plot_unit = "nanoseconds";
    try conflicting.writeJsonLine(writer);
    try (event.TraceEvent{ .seq = 5, .kind = .plot, .name = "heap", .value_i64 = 64 })
        .writeJsonLine(writer);
    try (event.TraceEvent{ .seq = 6, .kind = .stop }).writeJsonLine(writer);
}

fn testFlightReport() transport.Report {
    return .{
        .policy = .overwrite_oldest,
        .state = .accepting,
        .capacity_bytes = 64,
        .retained_bytes = 32,
        .event_capacity_bytes = 16,
        .writer_capacity_bytes = 8,
        .observed_events = 4,
        .stored_events = 4,
        .retained_events = 3,
        .overwritten_events = 1,
        .dropped_events = 0,
        .oversized_events = 0,
        .partial_event_bytes = 0,
        .discarding_oversized_event = false,
    };
}
