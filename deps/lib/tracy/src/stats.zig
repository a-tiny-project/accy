const std = @import("std");
const pretty_json = @import("pretty").json;
const event = @import("event.zig");
const tree = @import("tree.zig");

pub const schema = "tracy.stats/v0";

pub const Sort = enum {
    self,
    total,
    mean,
    count,
    threads,
    name,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "self")) return .self;
        if (std.mem.eql(u8, text, "total")) return .total;
        if (std.mem.eql(u8, text, "mean")) return .mean;
        if (std.mem.eql(u8, text, "count")) return .count;
        if (std.mem.eql(u8, text, "threads")) return .threads;
        if (std.mem.eql(u8, text, "name")) return .name;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .self => "self",
            .total => "total",
            .mean => "mean",
            .count => "count",
            .threads => "threads",
            .name => "name",
        };
    }
};

pub const Options = struct {
    top: usize = 20,
    sort: Sort = .self,
    min_total_ns: u64 = 0,
    min_self_ns: u64 = 0,
    thread: ?u64 = null,
};

const Row = struct {
    name: []u8,
    file: ?[]u8 = null,
    function: ?[]u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    count: u64 = 0,
    total_ns: u64 = 0,
    self_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    min_self_ns: u64 = std.math.maxInt(u64),
    max_self_ns: u64 = 0,
    max_depth: usize = 0,
    threads: std.ArrayListUnmanaged(u64) = .empty,

    fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.file) |file| allocator.free(file);
        if (self.function) |function| allocator.free(function);
        self.threads.deinit(allocator);
        self.* = undefined;
    }

    fn meanNs(self: Row) u64 {
        if (self.count == 0) return 0;
        return self.total_ns / self.count;
    }

    fn meanSelfNs(self: Row) u64 {
        if (self.count == 0) return 0;
        return self.self_ns / self.count;
    }

    fn threadCount(self: Row) u64 {
        return @intCast(self.threads.items.len);
    }
};

const View = struct {
    name: []const u8,
    file: ?[]const u8,
    function: ?[]const u8,
    line: u32,
    column: u32,
    count: u64,
    total_ns: u64,
    self_ns: u64,
    min_ns: u64,
    max_ns: u64,
    min_self_ns: u64,
    max_self_ns: u64,
    mean_ns: u64,
    mean_self_ns: u64,
    max_depth: usize,
    threads: u64,
};

const Analyzer = struct {
    allocator: std.mem.Allocator,
    rows: std.StringHashMapUnmanaged(Row) = .{},
    spans: u64 = 0,
    matched_spans: u64 = 0,
    open_spans: u64 = 0,
    superseded_spans: u64 = 0,
    invalid_duration_spans: u64 = 0,
    zero_spans: u64 = 0,
    duration_ns: u64 = 0,
    evidence: ?tree.Evidence = null,

    fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Analyzer) void {
        var iter = self.rows.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    fn ingestTree(self: *Analyzer, trace: *tree.Analyzer, options: Options) !void {
        self.duration_ns = trace.durationNs();
        self.evidence = trace.evidence();
        var spans = try trace.collectSpans(self.allocator);
        defer spans.deinit(self.allocator);
        self.spans = @intCast(spans.items.len);
        for (spans.items) |span| {
            switch (span.state) {
                .open => {
                    self.open_spans += 1;
                    continue;
                },
                .superseded => {
                    self.superseded_spans += 1;
                    continue;
                },
                .complete => {},
            }
            if (!span.duration_valid) {
                self.invalid_duration_spans += 1;
                continue;
            }
            if (span.total_ns == 0) {
                self.zero_spans += 1;
                continue;
            }
            if (options.thread) |thread| {
                if (span.thread != thread) continue;
            }
            try self.record(span);
        }
    }

    fn record(self: *Analyzer, span: tree.Span) !void {
        var key_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer key_writer.deinit();
        try writeKey(&key_writer.writer, span);
        const key_text = key_writer.written();
        const entry = try self.rows.getOrPut(self.allocator, key_text);
        if (!entry.found_existing) {
            const owned_key = try self.allocator.dupe(u8, key_text);
            entry.key_ptr.* = owned_key;
            entry.value_ptr.* = .{
                .name = try self.allocator.dupe(u8, span.name),
                .file = try dupeOptional(self.allocator, span.file),
                .function = try dupeOptional(self.allocator, span.function),
                .line = span.line,
                .column = span.column,
            };
        }
        const row = entry.value_ptr;
        row.count += 1;
        row.total_ns +|= span.total_ns;
        row.self_ns +|= span.self_ns;
        row.min_ns = @min(row.min_ns, span.total_ns);
        row.max_ns = @max(row.max_ns, span.total_ns);
        row.min_self_ns = @min(row.min_self_ns, span.self_ns);
        row.max_self_ns = @max(row.max_self_ns, span.self_ns);
        row.max_depth = @max(row.max_depth, span.depth);
        try appendThread(self.allocator, &row.threads, span.thread);
        self.matched_spans += 1;
    }

    fn collect(self: *Analyzer, options: Options) !std.ArrayListUnmanaged(View) {
        var views: std.ArrayListUnmanaged(View) = .empty;
        var iter = self.rows.valueIterator();
        while (iter.next()) |row| {
            if (row.total_ns < options.min_total_ns) continue;
            if (row.self_ns < options.min_self_ns) continue;
            try views.append(self.allocator, .{
                .name = row.name,
                .file = row.file,
                .function = row.function,
                .line = row.line,
                .column = row.column,
                .count = row.count,
                .total_ns = row.total_ns,
                .self_ns = row.self_ns,
                .min_ns = if (row.min_ns == std.math.maxInt(u64)) 0 else row.min_ns,
                .max_ns = row.max_ns,
                .min_self_ns = if (row.min_self_ns == std.math.maxInt(u64)) 0 else row.min_self_ns,
                .max_self_ns = row.max_self_ns,
                .mean_ns = row.meanNs(),
                .mean_self_ns = row.meanSelfNs(),
                .max_depth = row.max_depth,
                .threads = row.threadCount(),
            });
        }
        sortViews(views.items, options.sort);
        return views;
    }
};

pub fn writeTextFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var trace = tree.Analyzer.init(allocator);
    defer trace.deinit();
    try tree.ingestPath(&trace, path);
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try analyzer.ingestTree(&trace, options);
    try writeText(allocator, &analyzer, writer, options);
}

pub fn writeJsonlFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var trace = tree.Analyzer.init(allocator);
    defer trace.deinit();
    try tree.ingestPath(&trace, path);
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try analyzer.ingestTree(&trace, options);
    try writeJsonl(allocator, &analyzer, writer, options);
}

fn writeText(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var views = try analyzer.collect(options);
    defer views.deinit(allocator);
    try writer.print(
        "tracy stats rows={d} spans={d} matched_spans={d} open_spans={d} " ++
            "superseded_spans={d} invalid_duration_spans={d} zero_spans={d} " ++
            "duration_ns={d} sort={s}\n",
        .{
            views.items.len,
            analyzer.spans,
            analyzer.matched_spans,
            analyzer.open_spans,
            analyzer.superseded_spans,
            analyzer.invalid_duration_spans,
            analyzer.zero_spans,
            analyzer.duration_ns,
            options.sort.tag(),
        },
    );
    try analyzer.evidence.?.writeText(writer);
    const limit = @min(options.top, views.items.len);
    for (views.items[0..limit]) |view| {
        try writer.writeAll("stat name=");
        try pretty_json.writeString(writer, view.name);
        try writer.print(
            " count={d} total_ns={d} self_ns={d} mean_ns={d} mean_self_ns={d} min_ns={d} max_ns={d} min_self_ns={d} max_self_ns={d} threads={d} max_depth={d}",
            .{
                view.count,
                view.total_ns,
                view.self_ns,
                view.mean_ns,
                view.mean_self_ns,
                view.min_ns,
                view.max_ns,
                view.min_self_ns,
                view.max_self_ns,
                view.threads,
                view.max_depth,
            },
        );
        if (view.file) |file| try writer.print(" file={s}:{d}", .{ file, view.line });
        if (view.function) |function| {
            try writer.writeAll(" function=");
            try pretty_json.writeString(writer, function);
        }
        try writer.writeByte('\n');
    }
}

fn writeJsonl(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var views = try analyzer.collect(options);
    defer views.deinit(allocator);
    var summary_stream = pretty_json.Writer.init(writer, .minified);
    const summary = try summary_stream.object();
    try summary.field("schema", schema);
    try summary.field("kind", "summary");
    try summary.field("rows", views.items.len);
    try summary.field("spans", analyzer.spans);
    try summary.field("matched_spans", analyzer.matched_spans);
    try summary.field("open_spans", analyzer.open_spans);
    try summary.field("superseded_spans", analyzer.superseded_spans);
    try summary.field("invalid_duration_spans", analyzer.invalid_duration_spans);
    try summary.field("zero_spans", analyzer.zero_spans);
    try summary.field("duration_ns", analyzer.duration_ns);
    try summary.field("sort", options.sort.tag());
    try analyzer.evidence.?.writeFields(summary);
    try summary.endLine();
    const limit = @min(options.top, views.items.len);
    for (views.items[0..limit]) |view| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "stat");
        try object.field("name", view.name);
        try object.field("count", view.count);
        try object.field("total_ns", view.total_ns);
        try object.field("self_ns", view.self_ns);
        try object.field("mean_ns", view.mean_ns);
        try object.field("mean_self_ns", view.mean_self_ns);
        try object.field("min_ns", view.min_ns);
        try object.field("max_ns", view.max_ns);
        try object.field("min_self_ns", view.min_self_ns);
        try object.field("max_self_ns", view.max_self_ns);
        try object.field("threads", view.threads);
        try object.field("max_depth", view.max_depth);
        if (view.file) |file| {
            try object.field("file", file);
            try object.field("line", view.line);
        }
        if (view.function) |function| try object.field("function", function);
        try object.endLine();
    }
}

fn writeKey(writer: *std.Io.Writer, span: tree.Span) !void {
    try writer.writeAll(span.name);
    try writer.writeByte('\x1f');
    if (span.file) |file| try writer.writeAll(file);
    try writer.writeByte('\x1f');
    if (span.function) |function| try writer.writeAll(function);
    try writer.writeByte('\x1f');
    try writer.print("{d}:{d}", .{ span.line, span.column });
}

fn appendThread(allocator: std.mem.Allocator, threads: *std.ArrayListUnmanaged(u64), thread: u64) !void {
    for (threads.items) |existing| {
        if (existing == thread) return;
    }
    try threads.append(allocator, thread);
}

fn sortViews(items: []View, sort: Sort) void {
    switch (sort) {
        .self => std.mem.sort(View, items, {}, viewSelfGreaterThan),
        .total => std.mem.sort(View, items, {}, viewTotalGreaterThan),
        .mean => std.mem.sort(View, items, {}, viewMeanGreaterThan),
        .count => std.mem.sort(View, items, {}, viewCountGreaterThan),
        .threads => std.mem.sort(View, items, {}, viewThreadsGreaterThan),
        .name => std.mem.sort(View, items, {}, viewNameLessThan),
    }
}

fn viewSelfGreaterThan(_: void, left: View, right: View) bool {
    if (left.self_ns != right.self_ns) return left.self_ns > right.self_ns;
    return viewTotalGreaterThan({}, left, right);
}

fn viewTotalGreaterThan(_: void, left: View, right: View) bool {
    if (left.total_ns != right.total_ns) return left.total_ns > right.total_ns;
    return viewNameLessThan({}, left, right);
}

fn viewMeanGreaterThan(_: void, left: View, right: View) bool {
    if (left.mean_ns != right.mean_ns) return left.mean_ns > right.mean_ns;
    return viewTotalGreaterThan({}, left, right);
}

fn viewCountGreaterThan(_: void, left: View, right: View) bool {
    if (left.count != right.count) return left.count > right.count;
    return viewTotalGreaterThan({}, left, right);
}

fn viewThreadsGreaterThan(_: void, left: View, right: View) bool {
    if (left.threads != right.threads) return left.threads > right.threads;
    return viewTotalGreaterThan({}, left, right);
}

fn viewNameLessThan(_: void, left: View, right: View) bool {
    const name_cmp = std.mem.order(u8, left.name, right.name);
    if (name_cmp != .eq) return name_cmp == .lt;
    const left_file = left.file orelse "";
    const right_file = right.file orelse "";
    const file_cmp = std.mem.order(u8, left_file, right_file);
    if (file_cmp != .eq) return file_cmp == .lt;
    return left.line < right.line;
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
}

test "stats aggregates inclusive and self time by source location" {
    var trace_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace_bytes.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .zone_begin, .time_ns = 100, .thread = 1, .id = 1, .name = "root", .file = "root.zig", .line = 1 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .zone_begin, .time_ns = 120, .thread = 1, .id = 2, .name = "child", .file = "child.zig", .line = 2 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_end, .time_ns = 150, .thread = 1, .id = 2 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .zone_end, .time_ns = 200, .thread = 1, .id = 1 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .zone_begin, .time_ns = 210, .thread = 2, .id = 3, .name = "child", .file = "child.zig", .line = 2 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .zone_end, .time_ns = 260, .thread = 2, .id = 3 }).writeJsonLine(&trace_bytes.writer);

    var trace = tree.Analyzer.init(std.testing.allocator);
    defer trace.deinit();
    try trace.ingestJsonlBytes(trace_bytes.written());

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestTree(&trace, .{});

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4, .sort = .self });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy stats rows=2 spans=3 matched_spans=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stat name=\"child\" count=2 total_ns=80 self_ns=80 mean_ns=40 mean_self_ns=40") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "threads=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stat name=\"root\" count=1 total_ns=100 self_ns=70") != null);
}

test "stats jsonl emits filtered machine rows" {
    var trace_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace_bytes.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .zone_begin, .time_ns = 100, .thread = 7, .id = 1, .name = "phase", .file = "phase.zig", .line = 9 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .zone_end, .time_ns = 150, .thread = 7, .id = 1 }).writeJsonLine(&trace_bytes.writer);

    var trace = tree.Analyzer.init(std.testing.allocator);
    defer trace.deinit();
    try trace.ingestJsonlBytes(trace_bytes.written());

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestTree(&trace, .{ .thread = 7 });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{ .top = 2, .sort = .total, .min_total_ns = 10 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.stats/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"stat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"phase\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"total_ns\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"threads\":1") != null);
}
