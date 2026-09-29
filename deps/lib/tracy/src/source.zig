const std = @import("std");
const pretty_json = @import("pretty").json;
const sys = @import("sys");
const event = @import("event.zig");
const tree = @import("tree.zig");

pub const schema = "tracy.source/v0";

const max_source_bytes = 8 * 1024 * 1024;

pub const Sort = enum {
    self,
    total,
    mean,
    count,
    file,
    name,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "self")) return .self;
        if (std.mem.eql(u8, text, "total")) return .total;
        if (std.mem.eql(u8, text, "mean")) return .mean;
        if (std.mem.eql(u8, text, "count")) return .count;
        if (std.mem.eql(u8, text, "file")) return .file;
        if (std.mem.eql(u8, text, "name")) return .name;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .self => "self",
            .total => "total",
            .mean => "mean",
            .count => "count",
            .file => "file",
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
    match: ?[]const u8 = null,
    root: ?[]const u8 = null,
    context: usize = 2,
    context_back: usize = 2,
    ignore_case: bool = false,
};

pub const Counters = struct {
    spans: u64 = 0,
    matched_spans: u64 = 0,
    open_spans: u64 = 0,
    superseded_spans: u64 = 0,
    invalid_duration_spans: u64 = 0,
    zero_spans: u64 = 0,
    no_file_spans: u64 = 0,
    filtered_spans: u64 = 0,
    rows: u64 = 0,
    duration_ns: u64 = 0,
};

const Row = struct {
    name: []u8,
    file: []u8,
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
        allocator.free(self.file);
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
    file: []const u8,
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

const SourceState = enum {
    found,
    missing,
    out_of_range,
    invalid_line,

    fn tag(self: SourceState) []const u8 {
        return switch (self) {
            .found => "found",
            .missing => "missing",
            .out_of_range => "out-of-range",
            .invalid_line => "invalid-line",
        };
    }
};

const SourceContext = struct {
    path: []u8,
    state: SourceState,
    excerpt: []u8,
    total_lines: u32 = 0,

    fn deinit(self: *SourceContext, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.excerpt);
        self.* = undefined;
    }
};

const LineScan = struct {
    total_lines: u32 = 0,
    target_found: bool = false,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    rows: std.StringHashMapUnmanaged(Row) = .{},
    counters: Counters = .{},
    evidence: ?tree.Evidence = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        var iter = self.rows.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.rows.deinit(self.allocator);
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
            if (span.total_ns == 0) {
                self.counters.zero_spans += 1;
                continue;
            }
            if (options.thread) |thread| {
                if (span.thread != thread) {
                    self.counters.filtered_spans += 1;
                    continue;
                }
            }
            if (!spanMatches(span, options)) {
                self.counters.filtered_spans += 1;
                continue;
            }
            const file = span.file orelse {
                self.counters.no_file_spans += 1;
                continue;
            };
            if (file.len == 0) {
                self.counters.no_file_spans += 1;
                continue;
            }
            try self.record(span, file);
            self.counters.matched_spans += 1;
        }
        self.counters.rows = @intCast(self.rows.count());
    }

    fn record(self: *Analyzer, span: tree.Span, file: []const u8) !void {
        var key_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer key_writer.deinit();
        try key_writer.writer.writeAll(file);
        try key_writer.writer.writeByte('\x1f');
        if (span.function) |function| try key_writer.writer.writeAll(function);
        try key_writer.writer.print("\x1f{d}:{d}", .{ span.line, span.column });
        const key_text = key_writer.written();
        const entry = try self.rows.getOrPut(self.allocator, key_text);
        if (!entry.found_existing) {
            const owned_key = try self.allocator.dupe(u8, key_text);
            entry.key_ptr.* = owned_key;
            entry.value_ptr.* = .{
                .name = try self.allocator.dupe(u8, span.name),
                .file = try self.allocator.dupe(u8, file),
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
    }

    fn collect(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(View) {
        var views: std.ArrayListUnmanaged(View) = .empty;
        var iter = self.rows.valueIterator();
        while (iter.next()) |row| {
            if (row.total_ns < options.min_total_ns) continue;
            if (row.self_ns < options.min_self_ns) continue;
            try views.append(allocator, .{
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

fn writeText(allocator: std.mem.Allocator, analyzer: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
    var rows = try analyzer.collect(allocator, options);
    defer rows.deinit(allocator);
    try writer.print(
        "tracy source rows={d} spans={d} matched_spans={d} open_spans={d} " ++
            "superseded_spans={d} invalid_duration_spans={d} zero_spans={d} " ++
            "no_file_spans={d} filtered_spans={d} duration_ns={d} sort={s}",
        .{
            rows.items.len,
            analyzer.counters.spans,
            analyzer.counters.matched_spans,
            analyzer.counters.open_spans,
            analyzer.counters.superseded_spans,
            analyzer.counters.invalid_duration_spans,
            analyzer.counters.zero_spans,
            analyzer.counters.no_file_spans,
            analyzer.counters.filtered_spans,
            analyzer.counters.duration_ns,
            options.sort.tag(),
        },
    );
    if (options.root) |root| {
        try writer.writeAll(" root=");
        try pretty_json.writeString(writer, root);
    }
    if (options.match) |pattern| {
        try writer.writeAll(" match=");
        try pretty_json.writeString(writer, pattern);
    }
    try writer.writeByte('\n');
    try analyzer.evidence.?.writeText(writer);
    const limit = @min(options.top, rows.items.len);
    for (rows.items[0..limit]) |row| {
        var source_context = try loadSourceContext(allocator, row.file, row.line, options);
        defer source_context.deinit(allocator);
        try writer.writeAll("source-location name=");
        try pretty_json.writeString(writer, row.name);
        try writer.print(
            " count={d} total_ns={d} self_ns={d} mean_ns={d} mean_self_ns={d} min_ns={d} max_ns={d} min_self_ns={d} max_self_ns={d} max_depth={d} threads={d} file={s}:{d}:{d} source_state={s} path=",
            .{
                row.count,
                row.total_ns,
                row.self_ns,
                row.mean_ns,
                row.mean_self_ns,
                row.min_ns,
                row.max_ns,
                row.min_self_ns,
                row.max_self_ns,
                row.max_depth,
                row.threads,
                row.file,
                row.line,
                row.column,
                source_context.state.tag(),
            },
        );
        try pretty_json.writeString(writer, source_context.path);
        try writer.print(" total_lines={d}", .{source_context.total_lines});
        if (row.function) |function| {
            try writer.writeAll(" function=");
            try pretty_json.writeString(writer, function);
        }
        if (source_context.excerpt.len != 0) {
            try writer.writeAll(" excerpt=");
            try pretty_json.writeString(writer, source_context.excerpt);
        }
        try writer.writeByte('\n');
    }
}

fn writeJsonl(allocator: std.mem.Allocator, analyzer: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
    var rows = try analyzer.collect(allocator, options);
    defer rows.deinit(allocator);
    try writeJsonSummary(analyzer, writer, options, rows.items.len);
    const limit = @min(options.top, rows.items.len);
    for (rows.items[0..limit]) |row| {
        var source_context = try loadSourceContext(allocator, row.file, row.line, options);
        defer source_context.deinit(allocator);
        try writeJsonLocation(writer, row, source_context);
    }
}

fn writeJsonSummary(
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
    rows: usize,
) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "summary");
    try object.field("rows", rows);
    try object.field("spans", analyzer.counters.spans);
    try object.field("matched_spans", analyzer.counters.matched_spans);
    try object.field("open_spans", analyzer.counters.open_spans);
    try object.field("superseded_spans", analyzer.counters.superseded_spans);
    try object.field("invalid_duration_spans", analyzer.counters.invalid_duration_spans);
    try object.field("zero_spans", analyzer.counters.zero_spans);
    try object.field("no_file_spans", analyzer.counters.no_file_spans);
    try object.field("filtered_spans", analyzer.counters.filtered_spans);
    try object.field("duration_ns", analyzer.counters.duration_ns);
    try object.field("sort", options.sort.tag());
    if (options.root) |root| try object.field("root", root);
    if (options.match) |pattern| try object.field("match", pattern);
    try analyzer.evidence.?.writeFields(object);
    try object.endLine();
}

fn writeJsonLocation(writer: *std.Io.Writer, row: View, source_context: SourceContext) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "location");
    try object.field("name", row.name);
    try object.field("count", row.count);
    try object.field("total_ns", row.total_ns);
    try object.field("self_ns", row.self_ns);
    try object.field("mean_ns", row.mean_ns);
    try object.field("mean_self_ns", row.mean_self_ns);
    try object.field("min_ns", row.min_ns);
    try object.field("max_ns", row.max_ns);
    try object.field("min_self_ns", row.min_self_ns);
    try object.field("max_self_ns", row.max_self_ns);
    try object.field("max_depth", row.max_depth);
    try object.field("threads", row.threads);
    try object.field("file", row.file);
    try object.field("line", row.line);
    try object.field("column", row.column);
    try object.field("source_state", source_context.state.tag());
    try object.field("path", source_context.path);
    try object.field("total_lines", source_context.total_lines);
    if (row.function) |function| try object.field("function", function);
    if (source_context.excerpt.len != 0) try object.field("excerpt", source_context.excerpt);
    try object.endLine();
}

fn loadSourceContext(allocator: std.mem.Allocator, file: []const u8, line: u32, options: Options) !SourceContext {
    const path = try resolvePath(allocator, file, options.root);
    errdefer allocator.free(path);
    if (line == 0) {
        return .{
            .path = path,
            .state = .invalid_line,
            .excerpt = try allocator.dupe(u8, ""),
        };
    }
    const contents = sys.fs.cwd().readFileAlloc(sys.fs.debugIo(), path, allocator, .limited(max_source_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{
            .path = path,
            .state = .missing,
            .excerpt = try allocator.dupe(u8, ""),
        },
    };
    defer allocator.free(contents);
    var excerpt = std.Io.Writer.Allocating.init(allocator);
    defer excerpt.deinit();
    const start_line = if (line > options.context_back) line - @as(u32, @intCast(@min(options.context_back, line - 1))) else 1;
    const after = @as(u32, @intCast(@min(options.context, std.math.maxInt(u32) - line)));
    const end_line = line + after;
    const scan = try appendSourceLines(&excerpt.writer, contents, start_line, end_line, line);
    return .{
        .path = path,
        .state = if (scan.target_found) .found else .out_of_range,
        .excerpt = try allocator.dupe(u8, excerpt.written()),
        .total_lines = scan.total_lines,
    };
}

fn resolvePath(allocator: std.mem.Allocator, file: []const u8, root: ?[]const u8) ![]u8 {
    if (std.fs.path.isAbsolute(file)) return try allocator.dupe(u8, file);
    const actual_root = root orelse return try allocator.dupe(u8, file);
    if (actual_root.len == 0) return try allocator.dupe(u8, file);
    return try std.fs.path.join(allocator, &.{ actual_root, file });
}

fn appendSourceLines(writer: *std.Io.Writer, contents: []const u8, start_line: u32, end_line: u32, target_line: u32) !LineScan {
    if (contents.len == 0) return .{};
    var scan: LineScan = .{};
    var line_no: u32 = 1;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= contents.len) : (index += 1) {
        if (index == contents.len) {
            if (start == contents.len) break;
        } else if (contents[index] != '\n') {
            continue;
        }
        var line = contents[start..index];
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line_no >= start_line and line_no <= end_line) {
            try writer.print("{d}:{s}\n", .{ line_no, line });
        }
        if (line_no == target_line) scan.target_found = true;
        scan.total_lines = line_no;
        if (line_no == std.math.maxInt(u32)) break;
        line_no += 1;
        start = index + 1;
    }
    return scan;
}

fn spanMatches(span: tree.Span, options: Options) bool {
    const pattern = options.match orelse return true;
    if (pattern.len == 0) return true;
    if (contains(span.name, pattern, options.ignore_case)) return true;
    if (span.text) |text| if (contains(text, pattern, options.ignore_case)) return true;
    if (span.file) |file| if (contains(file, pattern, options.ignore_case)) return true;
    if (span.function) |function| if (contains(function, pattern, options.ignore_case)) return true;
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

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
}

fn appendThread(allocator: std.mem.Allocator, threads: *std.ArrayListUnmanaged(u64), thread: u64) !void {
    for (threads.items) |existing| {
        if (existing == thread) return;
    }
    try threads.append(allocator, thread);
}

fn sortViews(items: []View, sort: Sort) void {
    switch (sort) {
        .self => std.mem.sort(View, items, {}, selfGreaterThan),
        .total => std.mem.sort(View, items, {}, totalGreaterThan),
        .mean => std.mem.sort(View, items, {}, meanGreaterThan),
        .count => std.mem.sort(View, items, {}, countGreaterThan),
        .file => std.mem.sort(View, items, {}, fileLessThan),
        .name => std.mem.sort(View, items, {}, nameLessThan),
    }
}

fn selfGreaterThan(_: void, left: View, right: View) bool {
    if (left.self_ns != right.self_ns) return left.self_ns > right.self_ns;
    return totalGreaterThan({}, left, right);
}

fn totalGreaterThan(_: void, left: View, right: View) bool {
    if (left.total_ns != right.total_ns) return left.total_ns > right.total_ns;
    return fileLessThan({}, left, right);
}

fn meanGreaterThan(_: void, left: View, right: View) bool {
    if (left.mean_ns != right.mean_ns) return left.mean_ns > right.mean_ns;
    return totalGreaterThan({}, left, right);
}

fn countGreaterThan(_: void, left: View, right: View) bool {
    if (left.count != right.count) return left.count > right.count;
    return totalGreaterThan({}, left, right);
}

fn fileLessThan(_: void, left: View, right: View) bool {
    const file_cmp = std.mem.order(u8, left.file, right.file);
    if (file_cmp != .eq) return file_cmp == .lt;
    if (left.line != right.line) return left.line < right.line;
    if (left.column != right.column) return left.column < right.column;
    const name_cmp = std.mem.order(u8, left.name, right.name);
    return name_cmp == .lt;
}

fn nameLessThan(_: void, left: View, right: View) bool {
    const name_cmp = std.mem.order(u8, left.name, right.name);
    if (name_cmp != .eq) return name_cmp == .lt;
    const file_cmp = std.mem.order(u8, left.file, right.file);
    if (file_cmp != .eq) return file_cmp == .lt;
    if (left.line != right.line) return left.line < right.line;
    return left.column < right.column;
}

test "source annotates hot locations with local context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "phase.zig" });
    defer std.testing.allocator.free(source_path);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{
        .sub_path = source_path,
        .data = "const x = 1;\nconst y = 2;\nfn work() void {}\nconst z = 4;\n",
    });

    var trace_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace_bytes.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .zone_begin, .time_ns = 100, .thread = 1, .id = 1, .name = "work", .file = "phase.zig", .function = "work", .line = 3 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .zone_end, .time_ns = 180, .thread = 1, .id = 1 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_begin, .time_ns = 190, .thread = 1, .id = 2, .name = "work", .file = "phase.zig", .function = "work", .line = 3 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .zone_end, .time_ns = 230, .thread = 1, .id = 2 }).writeJsonLine(&trace_bytes.writer);

    var trace = tree.Analyzer.init(std.testing.allocator);
    defer trace.deinit();
    try trace.ingestJsonlBytes(trace_bytes.written());

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    const options = Options{ .root = root, .context = 1, .context_back = 1 };
    try analyzer.ingestTree(&trace, options);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, options);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy source rows=1 spans=2 matched_spans=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "source_state=found") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "count=2 total_ns=120 self_ns=120") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "excerpt=\"2:const y = 2;\\n3:fn work() void {}\\n4:const z = 4;\\n\"") != null);
}

test "source jsonl reports out of range source lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(sys.fs.debugIo(), tmp.sub_path[0..], std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "short.zig" });
    defer std.testing.allocator.free(source_path);
    try sys.fs.cwd().writeFile(sys.fs.debugIo(), .{ .sub_path = source_path, .data = "const only = 1;\n" });

    var trace_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace_bytes.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .zone_begin, .time_ns = 100, .thread = 1, .id = 1, .name = "short", .file = "short.zig", .function = "short", .line = 8 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .zone_end, .time_ns = 140, .thread = 1, .id = 1 }).writeJsonLine(&trace_bytes.writer);

    var trace = tree.Analyzer.init(std.testing.allocator);
    defer trace.deinit();
    try trace.ingestJsonlBytes(trace_bytes.written());

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    const options = Options{ .root = root };
    try analyzer.ingestTree(&trace, options);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, options);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.source/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"source_state\":\"out-of-range\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"total_lines\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"excerpt\":\"\"") == null);
}
