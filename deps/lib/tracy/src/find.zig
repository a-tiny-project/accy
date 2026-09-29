const std = @import("std");
const pretty_json = @import("pretty").json;
const event = @import("event.zig");
const tree = @import("tree.zig");

pub const schema = "tracy.find/v0";

pub const Group = enum {
    source,
    name,
    thread,
    parent,
    text,
    none,

    pub fn fromName(text: []const u8) ?Group {
        if (std.mem.eql(u8, text, "source")) return .source;
        if (std.mem.eql(u8, text, "name")) return .name;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "parent")) return .parent;
        if (std.mem.eql(u8, text, "text")) return .text;
        if (std.mem.eql(u8, text, "none")) return .none;
        return null;
    }

    fn tag(self: Group) []const u8 {
        return switch (self) {
            .source => "source",
            .name => "name",
            .thread => "thread",
            .parent => "parent",
            .text => "text",
            .none => "none",
        };
    }
};

pub const Sort = enum {
    total,
    self,
    count,
    mean,
    max,
    name,
    time,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "total")) return .total;
        if (std.mem.eql(u8, text, "self")) return .self;
        if (std.mem.eql(u8, text, "count")) return .count;
        if (std.mem.eql(u8, text, "mean")) return .mean;
        if (std.mem.eql(u8, text, "max")) return .max;
        if (std.mem.eql(u8, text, "name")) return .name;
        if (std.mem.eql(u8, text, "time")) return .time;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .total => "total",
            .self => "self",
            .count => "count",
            .mean => "mean",
            .max => "max",
            .name => "name",
            .time => "time",
        };
    }
};

pub const Options = struct {
    pattern: []const u8,
    top: usize = 20,
    occurrences: usize = 20,
    group: Group = .source,
    sort: Sort = .total,
    thread: ?u64 = null,
    since_ns: ?u64 = null,
    until_ns: ?u64 = null,
    min_duration_ns: u64 = 0,
    ignore_case: bool = false,
};

pub const Counters = struct {
    spans: u64 = 0,
    matched_spans: u64 = 0,
    open_spans: u64 = 0,
    superseded_spans: u64 = 0,
    invalid_duration_spans: u64 = 0,
    zero_duration_spans: u64 = 0,
    filtered_spans: u64 = 0,
    clipped_spans: u64 = 0,
    groups: u64 = 0,
    duration_ns: u64 = 0,
};

const GroupRow = struct {
    group: Group,
    label: []u8,
    name: ?[]u8 = null,
    text: ?[]u8 = null,
    file: ?[]u8 = null,
    function: ?[]u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    thread: ?u64 = null,
    parent_id: ?u64 = null,
    count: u64 = 0,
    total_ns: u64 = 0,
    self_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,
    samples: std.ArrayListUnmanaged(u64) = .empty,
    threads: std.ArrayListUnmanaged(u64) = .empty,

    fn deinit(self: *GroupRow, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.name) |name| allocator.free(name);
        if (self.text) |text| allocator.free(text);
        if (self.file) |file| allocator.free(file);
        if (self.function) |function| allocator.free(function);
        self.samples.deinit(allocator);
        self.threads.deinit(allocator);
        self.* = undefined;
    }

    fn meanNs(self: GroupRow) u64 {
        if (self.count == 0) return 0;
        return self.total_ns / self.count;
    }

    fn threadCount(self: GroupRow) u64 {
        return @intCast(self.threads.items.len);
    }
};

const Occurrence = struct {
    id: u64,
    parent_id: ?u64 = null,
    parent_name: ?[]u8 = null,
    name: []u8,
    text: ?[]u8 = null,
    file: ?[]u8 = null,
    function: ?[]u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    thread: u64 = 0,
    depth: usize = 0,
    start_ns: u64 = 0,
    end_ns: u64 = 0,
    duration_ns: u64 = 0,
    self_ns: u64 = 0,
    children: u64 = 0,

    fn deinit(self: *Occurrence, allocator: std.mem.Allocator) void {
        if (self.parent_name) |parent_name| allocator.free(parent_name);
        allocator.free(self.name);
        if (self.text) |text| allocator.free(text);
        if (self.file) |file| allocator.free(file);
        if (self.function) |function| allocator.free(function);
        self.* = undefined;
    }
};

const GroupView = struct {
    group: Group,
    label: []const u8,
    name: ?[]const u8,
    text: ?[]const u8,
    file: ?[]const u8,
    function: ?[]const u8,
    line: u32,
    column: u32,
    thread: ?u64,
    parent_id: ?u64,
    count: u64,
    total_ns: u64,
    self_ns: u64,
    mean_ns: u64,
    min_ns: u64,
    p50_ns: u64,
    p90_ns: u64,
    p99_ns: u64,
    max_ns: u64,
    first_ns: u64,
    last_ns: u64,
    threads: u64,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    groups: std.StringHashMapUnmanaged(GroupRow) = .{},
    occurrences: std.ArrayListUnmanaged(Occurrence) = .empty,
    counters: Counters = .{},
    evidence: ?tree.Evidence = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        var iter = self.groups.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.groups.deinit(self.allocator);
        for (self.occurrences.items) |*occurrence| occurrence.deinit(self.allocator);
        self.occurrences.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ingestTree(self: *Analyzer, trace: *tree.Analyzer, options: Options) !void {
        self.counters.duration_ns = trace.durationNs();
        self.evidence = trace.evidence();
        var spans = try trace.collectSpans(self.allocator);
        defer spans.deinit(self.allocator);
        self.counters.spans = @intCast(spans.items.len);
        for (spans.items) |span| {
            switch (span.state) {
                .open => {
                    self.counters.open_spans += 1;
                    continue;
                },
                .superseded => {
                    self.counters.superseded_spans += 1;
                    continue;
                },
                .complete => {},
            }
            if (!span.duration_valid) {
                self.counters.invalid_duration_spans += 1;
                continue;
            }
            if (!spanMatches(span, options)) {
                self.counters.filtered_spans += 1;
                continue;
            }
            const duration = clippedDuration(span, options) orelse {
                if (span.total_ns == 0) self.counters.zero_duration_spans += 1;
                self.counters.filtered_spans += 1;
                continue;
            };
            if (duration < options.min_duration_ns) {
                self.counters.filtered_spans += 1;
                continue;
            }
            const parent = parentSpan(spans.items, span.parent_id);
            try self.record(span, parent, duration, options);
            self.counters.matched_spans += 1;
            if (duration != span.total_ns) self.counters.clipped_spans += 1;
        }
        self.counters.groups = @intCast(self.groups.count());
        sortOccurrences(self.occurrences.items, options.sort);
    }

    fn record(self: *Analyzer, span: tree.Span, parent: ?tree.Span, duration: u64, options: Options) !void {
        var key_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer key_writer.deinit();
        try writeGroupKey(&key_writer.writer, span, parent, options);
        const key_text = key_writer.written();
        const entry = try self.groups.getOrPut(self.allocator, key_text);
        if (!entry.found_existing) {
            const owned_key = try self.allocator.dupe(u8, key_text);
            entry.key_ptr.* = owned_key;
            entry.value_ptr.* = try self.newGroup(span, parent, options);
        }
        const row = entry.value_ptr;
        row.count += 1;
        row.total_ns +|= duration;
        row.self_ns +|= @min(span.self_ns, duration);
        row.min_ns = @min(row.min_ns, duration);
        row.max_ns = @max(row.max_ns, duration);
        if (row.count == 1 or span.start_ns < row.first_ns) row.first_ns = span.start_ns;
        if (span.end_ns > row.last_ns) row.last_ns = span.end_ns;
        try row.samples.append(self.allocator, duration);
        try appendThread(self.allocator, &row.threads, span.thread);
        try self.occurrences.append(self.allocator, try occurrenceView(self.allocator, span, parent, duration));
    }

    fn newGroup(self: *Analyzer, span: tree.Span, parent: ?tree.Span, options: Options) !GroupRow {
        const label = try groupLabel(self.allocator, span, parent, options.group);
        return .{
            .group = options.group,
            .label = label,
            .name = try dupeOptional(self.allocator, span.name),
            .text = try dupeOptional(self.allocator, span.text),
            .file = try dupeOptional(self.allocator, span.file),
            .function = try dupeOptional(self.allocator, span.function),
            .line = span.line,
            .column = span.column,
            .thread = if (options.group == .thread) span.thread else null,
            .parent_id = if (options.group == .parent) span.parent_id else null,
        };
    }

    fn collectGroups(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(GroupView) {
        var views: std.ArrayListUnmanaged(GroupView) = .empty;
        var iter = self.groups.valueIterator();
        while (iter.next()) |row| {
            std.mem.sort(u64, row.samples.items, {}, u64LessThan);
            try views.append(allocator, .{
                .group = row.group,
                .label = row.label,
                .name = row.name,
                .text = row.text,
                .file = row.file,
                .function = row.function,
                .line = row.line,
                .column = row.column,
                .thread = row.thread,
                .parent_id = row.parent_id,
                .count = row.count,
                .total_ns = row.total_ns,
                .self_ns = row.self_ns,
                .mean_ns = row.meanNs(),
                .min_ns = if (row.min_ns == std.math.maxInt(u64)) 0 else row.min_ns,
                .p50_ns = percentile(row.samples.items, 50),
                .p90_ns = percentile(row.samples.items, 90),
                .p99_ns = percentile(row.samples.items, 99),
                .max_ns = row.max_ns,
                .first_ns = row.first_ns,
                .last_ns = row.last_ns,
                .threads = row.threadCount(),
            });
        }
        sortGroups(views.items, options.sort);
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

fn writeText(allocator: std.mem.Allocator, analyzer: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
    var groups = try analyzer.collectGroups(allocator, options);
    defer groups.deinit(allocator);
    try writer.writeAll("tracy find pattern=");
    try pretty_json.writeString(writer, options.pattern);
    try writer.print(
        " groups={d} occurrences={d} spans={d} matched_spans={d} " ++
            "open_spans={d} superseded_spans={d} invalid_duration_spans={d} " ++
            "zero_duration_spans={d} filtered_spans={d} clipped_spans={d} " ++
            "duration_ns={d} group={s} sort={s}\n",
        .{
            groups.items.len,
            analyzer.occurrences.items.len,
            analyzer.counters.spans,
            analyzer.counters.matched_spans,
            analyzer.counters.open_spans,
            analyzer.counters.superseded_spans,
            analyzer.counters.invalid_duration_spans,
            analyzer.counters.zero_duration_spans,
            analyzer.counters.filtered_spans,
            analyzer.counters.clipped_spans,
            analyzer.counters.duration_ns,
            options.group.tag(),
            options.sort.tag(),
        },
    );
    try analyzer.evidence.?.writeText(writer);
    const group_limit = @min(options.top, groups.items.len);
    for (groups.items[0..group_limit]) |group| {
        try writer.print("find-group group={s} label=", .{group.group.tag()});
        try pretty_json.writeString(writer, group.label);
        try writer.print(
            " count={d} total_ns={d} self_ns={d} mean_ns={d} min_ns={d} p50_ns={d} p90_ns={d} p99_ns={d} max_ns={d} first_ns={d} last_ns={d} threads={d}",
            .{
                group.count,
                group.total_ns,
                group.self_ns,
                group.mean_ns,
                group.min_ns,
                group.p50_ns,
                group.p90_ns,
                group.p99_ns,
                group.max_ns,
                group.first_ns,
                group.last_ns,
                group.threads,
            },
        );
        try writeGroupMetadataText(writer, group);
        try writer.writeByte('\n');
    }
    const occurrence_limit = @min(options.occurrences, analyzer.occurrences.items.len);
    for (analyzer.occurrences.items[0..occurrence_limit]) |occurrence| {
        try writeOccurrenceText(writer, occurrence);
    }
}

fn writeJsonl(allocator: std.mem.Allocator, analyzer: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
    var groups = try analyzer.collectGroups(allocator, options);
    defer groups.deinit(allocator);
    var summary_stream = pretty_json.Writer.init(writer, .minified);
    const summary_record = try summary_stream.object();
    try summary_record.field("schema", schema);
    try summary_record.field("kind", "summary");
    try summary_record.field("pattern", options.pattern);
    try summary_record.field("groups", groups.items.len);
    try summary_record.field("occurrences", analyzer.occurrences.items.len);
    try summary_record.field("spans", analyzer.counters.spans);
    try summary_record.field("matched_spans", analyzer.counters.matched_spans);
    try summary_record.field("open_spans", analyzer.counters.open_spans);
    try summary_record.field("superseded_spans", analyzer.counters.superseded_spans);
    try summary_record.field("invalid_duration_spans", analyzer.counters.invalid_duration_spans);
    try summary_record.field("zero_duration_spans", analyzer.counters.zero_duration_spans);
    try summary_record.field("filtered_spans", analyzer.counters.filtered_spans);
    try summary_record.field("clipped_spans", analyzer.counters.clipped_spans);
    try summary_record.field("duration_ns", analyzer.counters.duration_ns);
    try summary_record.field("group", options.group.tag());
    try summary_record.field("sort", options.sort.tag());
    try analyzer.evidence.?.writeFields(summary_record);
    try summary_record.endLine();
    const group_limit = @min(options.top, groups.items.len);
    for (groups.items[0..group_limit]) |group| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "group");
        try object.field("group", group.group.tag());
        try object.field("label", group.label);
        try object.field("count", group.count);
        try object.field("total_ns", group.total_ns);
        try object.field("self_ns", group.self_ns);
        try object.field("mean_ns", group.mean_ns);
        try object.field("min_ns", group.min_ns);
        try object.field("p50_ns", group.p50_ns);
        try object.field("p90_ns", group.p90_ns);
        try object.field("p99_ns", group.p99_ns);
        try object.field("max_ns", group.max_ns);
        try object.field("first_ns", group.first_ns);
        try object.field("last_ns", group.last_ns);
        try object.field("threads", group.threads);
        try writeGroupMetadataFields(object, group);
        try object.endLine();
    }
    const occurrence_limit = @min(options.occurrences, analyzer.occurrences.items.len);
    for (analyzer.occurrences.items[0..occurrence_limit]) |occurrence| {
        try writeOccurrenceJson(writer, occurrence);
    }
}

fn writeOccurrenceText(writer: *std.Io.Writer, occurrence: Occurrence) !void {
    try writer.print(
        "find-zone id={d} start_ns={d} end_ns={d} duration_ns={d} self_ns={d} thread={d} depth={d} children={d} name=",
        .{ occurrence.id, occurrence.start_ns, occurrence.end_ns, occurrence.duration_ns, occurrence.self_ns, occurrence.thread, occurrence.depth, occurrence.children },
    );
    try pretty_json.writeString(writer, occurrence.name);
    if (occurrence.parent_id) |parent_id| try writer.print(" parent_id={d}", .{parent_id});
    if (occurrence.parent_name) |parent_name| {
        try writer.writeAll(" parent=");
        try pretty_json.writeString(writer, parent_name);
    }
    if (occurrence.text) |text| {
        try writer.writeAll(" text=");
        try pretty_json.writeString(writer, text);
    }
    if (occurrence.file) |file| try writer.print(" file={s}:{d}", .{ file, occurrence.line });
    if (occurrence.function) |function| {
        try writer.writeAll(" function=");
        try pretty_json.writeString(writer, function);
    }
    try writer.writeByte('\n');
}

fn writeOccurrenceJson(writer: *std.Io.Writer, occurrence: Occurrence) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "zone");
    try object.field("id", occurrence.id);
    try object.field("start_ns", occurrence.start_ns);
    try object.field("end_ns", occurrence.end_ns);
    try object.field("duration_ns", occurrence.duration_ns);
    try object.field("self_ns", occurrence.self_ns);
    try object.field("thread", occurrence.thread);
    try object.field("depth", occurrence.depth);
    try object.field("children", occurrence.children);
    try object.field("name", occurrence.name);
    if (occurrence.parent_id) |parent_id| try object.field("parent_id", parent_id);
    if (occurrence.parent_name) |parent_name| try object.field("parent_name", parent_name);
    if (occurrence.text) |text| try object.field("text", text);
    if (occurrence.file) |file| {
        try object.field("file", file);
        try object.field("line", occurrence.line);
    }
    if (occurrence.function) |function| try object.field("function", function);
    try object.endLine();
}

fn writeGroupMetadataText(writer: *std.Io.Writer, group: GroupView) !void {
    if (group.thread) |thread| try writer.print(" thread={d}", .{thread});
    if (group.parent_id) |parent_id| try writer.print(" parent_id={d}", .{parent_id});
    if (group.name) |name| {
        try writer.writeAll(" name=");
        try pretty_json.writeString(writer, name);
    }
    if (group.text) |text| {
        try writer.writeAll(" text=");
        try pretty_json.writeString(writer, text);
    }
    if (group.file) |file| try writer.print(" file={s}:{d}", .{ file, group.line });
    if (group.function) |function| {
        try writer.writeAll(" function=");
        try pretty_json.writeString(writer, function);
    }
}

fn writeGroupMetadataFields(object: pretty_json.Object, group: GroupView) !void {
    if (group.thread) |thread| try object.field("thread", thread);
    if (group.parent_id) |parent_id| try object.field("parent_id", parent_id);
    if (group.name) |name| try object.field("name", name);
    if (group.text) |text| try object.field("text", text);
    if (group.file) |file| {
        try object.field("file", file);
        try object.field("line", group.line);
    }
    if (group.function) |function| try object.field("function", function);
}

fn occurrenceView(allocator: std.mem.Allocator, span: tree.Span, parent: ?tree.Span, duration: u64) !Occurrence {
    return .{
        .id = span.id,
        .parent_id = span.parent_id,
        .parent_name = if (parent) |actual| try allocator.dupe(u8, actual.name) else null,
        .name = try allocator.dupe(u8, span.name),
        .text = try dupeOptional(allocator, span.text),
        .file = try dupeOptional(allocator, span.file),
        .function = try dupeOptional(allocator, span.function),
        .line = span.line,
        .column = span.column,
        .thread = span.thread,
        .depth = span.depth,
        .start_ns = span.start_ns,
        .end_ns = span.end_ns,
        .duration_ns = duration,
        .self_ns = @min(span.self_ns, duration),
        .children = span.children,
    };
}

fn spanMatches(span: tree.Span, options: Options) bool {
    if (options.thread) |thread| {
        if (span.thread != thread) return false;
    }
    const pattern = options.pattern;
    if (pattern.len == 0) return true;
    if (contains(span.name, pattern, options.ignore_case)) return true;
    if (span.text) |text| if (contains(text, pattern, options.ignore_case)) return true;
    if (span.file) |file| if (contains(file, pattern, options.ignore_case)) return true;
    if (span.function) |function| if (contains(function, pattern, options.ignore_case)) return true;
    return false;
}

fn clippedDuration(span: tree.Span, options: Options) ?u64 {
    var start_ns = span.start_ns;
    var end_ns = span.end_ns;
    if (options.since_ns) |since_ns| start_ns = @max(start_ns, since_ns);
    if (options.until_ns) |until_ns| end_ns = @min(end_ns, until_ns);
    if (end_ns <= start_ns) return null;
    return end_ns - start_ns;
}

fn parentSpan(spans: []const tree.Span, parent_id: ?u64) ?tree.Span {
    const id = parent_id orelse return null;
    for (spans) |span| {
        if (span.id == id) return span;
    }
    return null;
}

fn writeGroupKey(writer: *std.Io.Writer, span: tree.Span, parent: ?tree.Span, options: Options) !void {
    switch (options.group) {
        .source => {
            try writer.writeAll(span.name);
            try writer.writeByte('\x1f');
            if (span.file) |file| try writer.writeAll(file);
            try writer.writeByte('\x1f');
            if (span.function) |function| try writer.writeAll(function);
            try writer.print("\x1f{d}:{d}", .{ span.line, span.column });
        },
        .name => try writer.writeAll(span.name),
        .thread => try writer.print("thread:{d}", .{span.thread}),
        .parent => {
            if (parent) |actual| {
                try writer.print("parent:{d}:", .{actual.id});
                try writer.writeAll(actual.name);
            } else {
                try writer.writeAll("parent:root");
            }
        },
        .text => try writer.writeAll(span.text orelse ""),
        .none => try writer.print("zone:{d}", .{span.id}),
    }
}

fn groupLabel(allocator: std.mem.Allocator, span: tree.Span, parent: ?tree.Span, group: Group) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    switch (group) {
        .source => try writer.writer.writeAll(span.name),
        .name => try writer.writer.writeAll(span.name),
        .thread => try writer.writer.print("thread {d}", .{span.thread}),
        .parent => {
            if (parent) |actual| {
                try writer.writer.writeAll(actual.name);
            } else {
                try writer.writer.writeAll("<root>");
            }
        },
        .text => try writer.writer.writeAll(span.text orelse ""),
        .none => try writer.writer.print("{s}#{d}", .{ span.name, span.id }),
    }
    return try allocator.dupe(u8, writer.written());
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

fn appendThread(allocator: std.mem.Allocator, threads: *std.ArrayListUnmanaged(u64), thread: u64) !void {
    for (threads.items) |existing| {
        if (existing == thread) return;
    }
    try threads.append(allocator, thread);
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
}

fn percentile(sorted: []const u64, percent: usize) u64 {
    if (sorted.len == 0) return 0;
    const index = @min(sorted.len - 1, (sorted.len - 1) * percent / 100);
    return sorted[index];
}

fn sortGroups(items: []GroupView, sort: Sort) void {
    switch (sort) {
        .total => std.mem.sort(GroupView, items, {}, groupTotalGreaterThan),
        .self => std.mem.sort(GroupView, items, {}, groupSelfGreaterThan),
        .count => std.mem.sort(GroupView, items, {}, groupCountGreaterThan),
        .mean => std.mem.sort(GroupView, items, {}, groupMeanGreaterThan),
        .max => std.mem.sort(GroupView, items, {}, groupMaxGreaterThan),
        .name => std.mem.sort(GroupView, items, {}, groupNameLessThan),
        .time => std.mem.sort(GroupView, items, {}, groupTimeLessThan),
    }
}

fn sortOccurrences(items: []Occurrence, sort: Sort) void {
    switch (sort) {
        .time => std.mem.sort(Occurrence, items, {}, occurrenceTimeLessThan),
        .name => std.mem.sort(Occurrence, items, {}, occurrenceNameLessThan),
        else => std.mem.sort(Occurrence, items, {}, occurrenceDurationGreaterThan),
    }
}

fn groupTotalGreaterThan(_: void, left: GroupView, right: GroupView) bool {
    if (left.total_ns != right.total_ns) return left.total_ns > right.total_ns;
    return groupNameLessThan({}, left, right);
}

fn groupSelfGreaterThan(_: void, left: GroupView, right: GroupView) bool {
    if (left.self_ns != right.self_ns) return left.self_ns > right.self_ns;
    return groupTotalGreaterThan({}, left, right);
}

fn groupCountGreaterThan(_: void, left: GroupView, right: GroupView) bool {
    if (left.count != right.count) return left.count > right.count;
    return groupTotalGreaterThan({}, left, right);
}

fn groupMeanGreaterThan(_: void, left: GroupView, right: GroupView) bool {
    if (left.mean_ns != right.mean_ns) return left.mean_ns > right.mean_ns;
    return groupTotalGreaterThan({}, left, right);
}

fn groupMaxGreaterThan(_: void, left: GroupView, right: GroupView) bool {
    if (left.max_ns != right.max_ns) return left.max_ns > right.max_ns;
    return groupTotalGreaterThan({}, left, right);
}

fn groupTimeLessThan(_: void, left: GroupView, right: GroupView) bool {
    if (left.first_ns != right.first_ns) return left.first_ns < right.first_ns;
    return groupNameLessThan({}, left, right);
}

fn groupNameLessThan(_: void, left: GroupView, right: GroupView) bool {
    const label_cmp = std.mem.order(u8, left.label, right.label);
    if (label_cmp != .eq) return label_cmp == .lt;
    return left.first_ns < right.first_ns;
}

fn occurrenceDurationGreaterThan(_: void, left: Occurrence, right: Occurrence) bool {
    if (left.duration_ns != right.duration_ns) return left.duration_ns > right.duration_ns;
    return occurrenceTimeLessThan({}, left, right);
}

fn occurrenceTimeLessThan(_: void, left: Occurrence, right: Occurrence) bool {
    if (left.start_ns != right.start_ns) return left.start_ns < right.start_ns;
    return left.id < right.id;
}

fn occurrenceNameLessThan(_: void, left: Occurrence, right: Occurrence) bool {
    const name_cmp = std.mem.order(u8, left.name, right.name);
    if (name_cmp != .eq) return name_cmp == .lt;
    return occurrenceTimeLessThan({}, left, right);
}

fn u64LessThan(_: void, left: u64, right: u64) bool {
    return left < right;
}

test "find aggregates matched zones by source" {
    var trace_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace_bytes.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .zone_begin, .time_ns = 100, .thread = 1, .id = 1, .name = "root", .file = "root.zig", .line = 1 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .zone_begin, .time_ns = 120, .thread = 1, .id = 2, .name = "child phase", .file = "child.zig", .line = 2 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_end, .time_ns = 150, .thread = 1, .id = 2 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .zone_end, .time_ns = 200, .thread = 1, .id = 1 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .zone_begin, .time_ns = 210, .thread = 2, .id = 3, .name = "Child phase", .file = "child.zig", .line = 2 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .zone_end, .time_ns = 260, .thread = 2, .id = 3 }).writeJsonLine(&trace_bytes.writer);

    var trace = tree.Analyzer.init(std.testing.allocator);
    defer trace.deinit();
    try trace.ingestJsonlBytes(trace_bytes.written());

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    const options = Options{ .pattern = "child", .ignore_case = true };
    try analyzer.ingestTree(&trace, options);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, options);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy find pattern=\"child\" groups=2 occurrences=2 spans=3 matched_spans=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "find-group group=source label=\"Child phase\" count=1 total_ns=50") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "find-group group=source label=\"child phase\" count=1 total_ns=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "find-zone id=3 start_ns=210 end_ns=260 duration_ns=50 self_ns=50 thread=2") != null);
}

test "find jsonl groups by parent and clips windowed matches" {
    var trace_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace_bytes.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .zone_begin, .time_ns = 100, .thread = 1, .id = 1, .name = "root" }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .zone_begin, .time_ns = 120, .thread = 1, .id = 2, .name = "leaf" }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_text, .time_ns = 125, .thread = 1, .id = 2, .text = "queue wait" }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .zone_end, .time_ns = 180, .thread = 1, .id = 2 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .zone_end, .time_ns = 220, .thread = 1, .id = 1 }).writeJsonLine(&trace_bytes.writer);

    var trace = tree.Analyzer.init(std.testing.allocator);
    defer trace.deinit();
    try trace.ingestJsonlBytes(trace_bytes.written());

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    const options = Options{ .pattern = "queue", .group = .parent, .since_ns = 130, .until_ns = 170, .occurrences = 4 };
    try analyzer.ingestTree(&trace, options);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, options);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.find/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"summary\",\"pattern\":\"queue\",\"groups\":1,\"occurrences\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"group\":\"parent\",\"label\":\"root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"clipped_spans\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"duration_ns\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"text\":\"queue wait\"") != null);
}
