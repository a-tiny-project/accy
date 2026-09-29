const std = @import("std");
const pretty_json = @import("pretty").json;
const event = @import("event.zig");
const tree = @import("tree.zig");

pub const schema = "tracy.flame/v0";

pub const Sort = enum {
    time,
    name,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "time")) return .time;
        if (std.mem.eql(u8, text, "name")) return .name;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .time => "time",
            .name => "name",
        };
    }
};

pub const Options = struct {
    top: usize = 200,
    sort: Sort = .time,
    max_depth: usize = 64,
    min_ns: u64 = 0,
    thread: ?u64 = null,
    since_ns: ?u64 = null,
    until_ns: ?u64 = null,
    match: ?[]const u8 = null,
};

pub const Counters = struct {
    spans: u64 = 0,
    matched_spans: u64 = 0,
    open_spans: u64 = 0,
    superseded_spans: u64 = 0,
    invalid_duration_spans: u64 = 0,
    zero_duration_spans: u64 = 0,
    clipped_spans: u64 = 0,
    nodes: u64 = 0,
    max_depth: usize = 0,
    total_ns: u64 = 0,
    duration_ns: u64 = 0,
};

const Node = struct {
    name: []u8,
    file: ?[]u8 = null,
    function: ?[]u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    total_ns: u64 = 0,
    spans: u64 = 0,
    threads: std.ArrayListUnmanaged(u64) = .empty,
    children: std.ArrayListUnmanaged(Node) = .empty,

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.file) |file| allocator.free(file);
        if (self.function) |function| allocator.free(function);
        self.threads.deinit(allocator);
        for (self.children.items) |*child| child.deinit(allocator);
        self.children.deinit(allocator);
        self.* = undefined;
    }

    fn childNs(self: Node) u64 {
        var total: u64 = 0;
        for (self.children.items) |child| total +|= child.total_ns;
        return total;
    }

    fn selfNs(self: Node) u64 {
        const child_ns = self.childNs();
        if (self.total_ns <= child_ns) return 0;
        return self.total_ns - child_ns;
    }

    fn threadCount(self: Node) u64 {
        return @intCast(self.threads.items.len);
    }
};

const SpanRecord = struct {
    span: tree.Span,
    children: std.ArrayListUnmanaged(usize) = .empty,

    fn deinit(self: *SpanRecord, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
        self.* = undefined;
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    roots: std.ArrayListUnmanaged(Node) = .empty,
    counters: Counters = .{},
    evidence: ?tree.Evidence = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        for (self.roots.items) |*root| root.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ingestTree(self: *Analyzer, trace: *tree.Analyzer, options: Options) !void {
        self.counters.duration_ns = trace.durationNs();
        self.evidence = trace.evidence();
        var spans = try trace.collectSpans(self.allocator);
        defer spans.deinit(self.allocator);
        self.counters.spans = @intCast(spans.items.len);

        var records: std.ArrayListUnmanaged(SpanRecord) = .empty;
        defer {
            for (records.items) |*record| record.deinit(self.allocator);
            records.deinit(self.allocator);
        }
        try records.ensureTotalCapacity(self.allocator, spans.items.len);

        var ids: std.AutoHashMapUnmanaged(u64, usize) = .{};
        defer ids.deinit(self.allocator);
        try ids.ensureTotalCapacity(self.allocator, @intCast(spans.items.len));

        for (spans.items, 0..) |span, index| {
            records.appendAssumeCapacity(.{ .span = span });
            ids.putAssumeCapacity(span.id, index);
        }

        var root_indices: std.ArrayListUnmanaged(usize) = .empty;
        defer root_indices.deinit(self.allocator);
        for (records.items, 0..) |record, index| {
            if (record.span.parent_id) |parent_id| {
                if (ids.get(parent_id)) |parent_index| {
                    try records.items[parent_index].children.append(self.allocator, index);
                    continue;
                }
            }
            try root_indices.append(self.allocator, index);
        }

        for (root_indices.items) |root_index| try self.recordSpan(records.items, &self.roots, root_index, options);
        sortNodes(self.roots.items, options.sort);
        self.counters.nodes = countNodes(self.roots.items);
        self.counters.max_depth = maxDepth(self.roots.items, 0);
        self.counters.total_ns = totalNs(self.roots.items);
    }

    fn recordSpan(
        self: *Analyzer,
        records: []SpanRecord,
        siblings: *std.ArrayListUnmanaged(Node),
        index: usize,
        options: Options,
    ) !void {
        const span = records[index].span;
        var destination = siblings;
        switch (span.state) {
            .open => self.counters.open_spans += 1,
            .superseded => self.counters.superseded_spans += 1,
            .complete => if (!span.duration_valid) {
                self.counters.invalid_duration_spans += 1;
            } else if (spanMatches(span, options)) {
                if (span.total_ns == 0) self.counters.zero_duration_spans += 1;
                destination = try self.recordMatchedSpan(siblings, span, options);
            },
        }
        for (records[index].children.items) |child_index| {
            try self.recordSpan(records, destination, child_index, options);
        }
    }

    fn recordMatchedSpan(
        self: *Analyzer,
        siblings: *std.ArrayListUnmanaged(Node),
        span: tree.Span,
        options: Options,
    ) !*std.ArrayListUnmanaged(Node) {
        var destination = siblings;
        if (span.total_ns != 0) {
            if (clippedDuration(span, options)) |duration| {
                const node = try self.nodeFor(siblings, span);
                node.total_ns +|= duration;
                node.spans += 1;
                try appendThread(self.allocator, &node.threads, span.thread);
                destination = &node.children;
                self.counters.matched_spans += 1;
                if (duration != span.total_ns) self.counters.clipped_spans += 1;
            }
        }
        return destination;
    }

    fn nodeFor(self: *Analyzer, siblings: *std.ArrayListUnmanaged(Node), span: tree.Span) !*Node {
        for (siblings.items) |*node| {
            if (sameSource(node.*, span)) return node;
        }
        try siblings.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, span.name),
            .file = try dupeOptional(self.allocator, span.file),
            .function = try dupeOptional(self.allocator, span.function),
            .line = span.line,
            .column = span.column,
        });
        return &siblings.items[siblings.items.len - 1];
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
    try writeText(&analyzer, writer, options);
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
    try writeJsonl(&analyzer, writer, options);
}

pub fn writeFoldedFromJsonlPath(
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
    try writeFolded(allocator, &analyzer, writer, options);
}

fn writeText(analyzer: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
    try writer.print(
        "tracy flame nodes={d} spans={d} matched_spans={d} open_spans={d} " ++
            "superseded_spans={d} invalid_duration_spans={d} " ++
            "zero_duration_spans={d} clipped_spans={d} total_ns={d} " ++
            "duration_ns={d} max_depth={d} sort={s}\n",
        .{
            analyzer.counters.nodes,
            analyzer.counters.spans,
            analyzer.counters.matched_spans,
            analyzer.counters.open_spans,
            analyzer.counters.superseded_spans,
            analyzer.counters.invalid_duration_spans,
            analyzer.counters.zero_duration_spans,
            analyzer.counters.clipped_spans,
            analyzer.counters.total_ns,
            analyzer.counters.duration_ns,
            analyzer.counters.max_depth,
            options.sort.tag(),
        },
    );
    try analyzer.evidence.?.writeText(writer);
    var shown: usize = 0;
    try writeTextNodes(writer, analyzer.roots.items, 0, 0, options, &shown);
}

fn writeJsonl(analyzer: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "summary");
    try object.field("nodes", analyzer.counters.nodes);
    try object.field("spans", analyzer.counters.spans);
    try object.field("matched_spans", analyzer.counters.matched_spans);
    try object.field("open_spans", analyzer.counters.open_spans);
    try object.field("superseded_spans", analyzer.counters.superseded_spans);
    try object.field("invalid_duration_spans", analyzer.counters.invalid_duration_spans);
    try object.field("zero_duration_spans", analyzer.counters.zero_duration_spans);
    try object.field("clipped_spans", analyzer.counters.clipped_spans);
    try object.field("total_ns", analyzer.counters.total_ns);
    try object.field("duration_ns", analyzer.counters.duration_ns);
    try object.field("max_depth", analyzer.counters.max_depth);
    try object.field("sort", options.sort.tag());
    try analyzer.evidence.?.writeFields(object);
    try object.endLine();
    var shown: usize = 0;
    var next_id: u64 = 1;
    try writeJsonlNodes(writer, analyzer.roots.items, 0, 0, null, options, &shown, &next_id);
}

fn writeFolded(allocator: std.mem.Allocator, analyzer: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
    var path: std.ArrayListUnmanaged(*const Node) = .empty;
    defer path.deinit(allocator);
    var shown: usize = 0;
    for (analyzer.roots.items) |*root| {
        try writeFoldedNode(allocator, writer, root, &path, 0, options, &shown);
        if (shown >= options.top) return;
    }
}

fn writeTextNodes(
    writer: *std.Io.Writer,
    nodes: []const Node,
    depth: usize,
    base_offset_ns: u64,
    options: Options,
    shown: *usize,
) !void {
    var offset_ns = base_offset_ns;
    for (nodes) |node| {
        const current_offset_ns = offset_ns;
        offset_ns +|= node.total_ns;
        const visible = outputMatches(node, depth, options);
        if (visible and shown.* < options.top) {
            for (0..depth) |_| try writer.writeAll("  ");
            try writer.print("flame depth={d} offset_ns={d} total_ns={d} self_ns={d} child_ns={d} spans={d} threads={d} children={d} name=", .{
                depth,
                current_offset_ns,
                node.total_ns,
                node.selfNs(),
                node.childNs(),
                node.spans,
                node.threadCount(),
                node.children.items.len,
            });
            try pretty_json.writeString(writer, node.name);
            if (node.file) |file| try writer.print(" file={s}:{d}", .{ file, node.line });
            if (node.function) |function| {
                try writer.writeAll(" function=");
                try pretty_json.writeString(writer, function);
            }
            try writer.writeByte('\n');
            shown.* += 1;
        }
        if (shown.* >= options.top) return;
        if (depth < options.max_depth) try writeTextNodes(writer, node.children.items, depth + 1, current_offset_ns, options, shown);
        if (shown.* >= options.top) return;
    }
}

fn writeJsonlNodes(
    writer: *std.Io.Writer,
    nodes: []const Node,
    depth: usize,
    base_offset_ns: u64,
    parent_id: ?u64,
    options: Options,
    shown: *usize,
    next_id: *u64,
) !void {
    var offset_ns = base_offset_ns;
    for (nodes) |node| {
        const current_offset_ns = offset_ns;
        offset_ns +|= node.total_ns;
        var row_id: ?u64 = null;
        const visible = outputMatches(node, depth, options);
        if (visible and shown.* < options.top) {
            const id = next_id.*;
            next_id.* += 1;
            row_id = id;
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("schema", schema);
            try object.field("kind", "node");
            try object.field("id", id);
            if (parent_id) |parent| try object.field("parent_id", parent);
            try object.field("depth", depth);
            try object.field("offset_ns", current_offset_ns);
            try object.field("total_ns", node.total_ns);
            try object.field("self_ns", node.selfNs());
            try object.field("child_ns", node.childNs());
            try object.field("spans", node.spans);
            try object.field("threads", node.threadCount());
            try object.field("children", node.children.items.len);
            try object.field("name", node.name);
            if (node.file) |file| {
                try object.field("file", file);
                try object.field("line", node.line);
            }
            if (node.function) |function| try object.field("function", function);
            try object.endLine();
            shown.* += 1;
        }
        if (shown.* >= options.top) return;
        if (depth < options.max_depth) try writeJsonlNodes(writer, node.children.items, depth + 1, current_offset_ns, row_id orelse parent_id, options, shown, next_id);
        if (shown.* >= options.top) return;
    }
}

fn writeFoldedNode(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    node: *const Node,
    path: *std.ArrayListUnmanaged(*const Node),
    depth: usize,
    options: Options,
    shown: *usize,
) !void {
    try path.append(allocator, node);
    defer _ = path.pop();

    if (depth >= options.max_depth) {
        try writeFoldedPath(writer, path.items, node.total_ns, options, shown);
        return;
    }

    const self_ns = node.selfNs();
    if (self_ns != 0) try writeFoldedPath(writer, path.items, self_ns, options, shown);
    if (shown.* >= options.top) return;
    for (node.children.items) |*child| {
        try writeFoldedNode(allocator, writer, child, path, depth + 1, options, shown);
        if (shown.* >= options.top) return;
    }
}

fn writeFoldedPath(
    writer: *std.Io.Writer,
    path: []const *const Node,
    value: u64,
    options: Options,
    shown: *usize,
) !void {
    if (value < options.min_ns) return;
    if (!pathMatches(path, options)) return;
    if (shown.* >= options.top) return;
    for (path, 0..) |node, index| {
        if (index != 0) try writer.writeByte(';');
        try writeFoldedFrame(writer, node.name);
    }
    try writer.print(" {d}\n", .{value});
    shown.* += 1;
}

fn clippedDuration(span: tree.Span, options: Options) ?u64 {
    var start_ns = span.start_ns;
    var end_ns = span.end_ns;
    if (options.since_ns) |since_ns| start_ns = @max(start_ns, since_ns);
    if (options.until_ns) |until_ns| end_ns = @min(end_ns, until_ns);
    if (end_ns <= start_ns) return null;
    return end_ns - start_ns;
}

fn spanMatches(span: tree.Span, options: Options) bool {
    if (options.thread) |thread| {
        if (span.thread != thread) return false;
    }
    return true;
}

fn outputMatches(node: Node, depth: usize, options: Options) bool {
    if (depth > options.max_depth) return false;
    if (node.total_ns < options.min_ns) return false;
    if (options.match) |needle| {
        if (!nodeContains(node, needle)) return false;
    }
    return true;
}

fn pathMatches(path: []const *const Node, options: Options) bool {
    if (options.match) |needle| {
        for (path) |node| {
            if (nodeContains(node.*, needle)) return true;
        }
        return false;
    }
    return true;
}

fn nodeContains(node: Node, needle: []const u8) bool {
    if (contains(node.name, needle)) return true;
    if (node.file) |file| if (contains(file, needle)) return true;
    if (node.function) |function| if (contains(function, needle)) return true;
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn sameSource(node: Node, span: tree.Span) bool {
    if (!std.mem.eql(u8, node.name, span.name)) return false;
    if (!optionalEql(node.file, span.file)) return false;
    if (!optionalEql(node.function, span.function)) return false;
    return node.line == span.line and node.column == span.column;
}

fn optionalEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
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

fn sortNodes(nodes: []Node, sort: Sort) void {
    switch (sort) {
        .time => std.mem.sort(Node, nodes, {}, nodeTimeGreaterThan),
        .name => std.mem.sort(Node, nodes, {}, nodeNameLessThan),
    }
    for (nodes) |node| sortNodes(node.children.items, sort);
}

fn nodeTimeGreaterThan(_: void, left: Node, right: Node) bool {
    if (left.total_ns != right.total_ns) return left.total_ns > right.total_ns;
    return nodeNameLessThan({}, left, right);
}

fn nodeNameLessThan(_: void, left: Node, right: Node) bool {
    const name_cmp = std.mem.order(u8, left.name, right.name);
    if (name_cmp != .eq) return name_cmp == .lt;
    const left_file = left.file orelse "";
    const right_file = right.file orelse "";
    const file_cmp = std.mem.order(u8, left_file, right_file);
    if (file_cmp != .eq) return file_cmp == .lt;
    return left.line < right.line;
}

fn countNodes(nodes: []const Node) u64 {
    var count: u64 = 0;
    for (nodes) |node| count += 1 + countNodes(node.children.items);
    return count;
}

fn maxDepth(nodes: []const Node, depth: usize) usize {
    var result: usize = 0;
    for (nodes) |node| {
        result = @max(result, depth);
        result = @max(result, maxDepth(node.children.items, depth + 1));
    }
    return result;
}

fn totalNs(nodes: []const Node) u64 {
    var total: u64 = 0;
    for (nodes) |node| total +|= node.total_ns;
    return total;
}

fn writeFoldedFrame(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            ';' => try writer.writeAll("\\;"),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
}

test "flame aggregates instrumentation zones into merged trees" {
    var trace_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace_bytes.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 90, .thread = 1, .name = "test" }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .zone_begin, .time_ns = 100, .thread = 1, .id = 1, .name = "root", .file = "root.zig", .line = 1 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_begin, .time_ns = 120, .thread = 1, .id = 2, .name = "child", .file = "child.zig", .line = 2 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .zone_end, .time_ns = 150, .thread = 1, .id = 2 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .zone_end, .time_ns = 200, .thread = 1, .id = 1 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .zone_begin, .time_ns = 210, .thread = 2, .id = 3, .name = "root", .file = "root.zig", .line = 1 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .zone_begin, .time_ns = 220, .thread = 2, .id = 4, .name = "other", .file = "other.zig", .line = 3 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 8, .kind = .zone_end, .time_ns = 260, .thread = 2, .id = 4 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 9, .kind = .zone_end, .time_ns = 280, .thread = 2, .id = 3 }).writeJsonLine(&trace_bytes.writer);

    var trace = tree.Analyzer.init(std.testing.allocator);
    defer trace.deinit();
    try trace.ingestJsonlBytes(trace_bytes.written());

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestTree(&trace, .{});

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(&analyzer, &out.writer, .{ .top = 8 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy flame nodes=3 spans=4 matched_spans=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "flame depth=0 offset_ns=0 total_ns=170 self_ns=100 child_ns=70 spans=2 threads=2 children=2 name=\"root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "flame depth=1 offset_ns=0 total_ns=40 self_ns=40 child_ns=0 spans=1 threads=1 children=0 name=\"other\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "flame depth=1 offset_ns=40 total_ns=30 self_ns=30 child_ns=0 spans=1 threads=1 children=0 name=\"child\"") != null);
}

test "flame jsonl and folded output preserve clipped paths" {
    var trace_bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace_bytes.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .zone_begin, .time_ns = 100, .thread = 7, .id = 1, .name = "root" }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .zone_begin, .time_ns = 125, .thread = 7, .id = 2, .name = "child;one" }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_end, .time_ns = 175, .thread = 7, .id = 2 }).writeJsonLine(&trace_bytes.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .zone_end, .time_ns = 220, .thread = 7, .id = 1 }).writeJsonLine(&trace_bytes.writer);

    var trace = tree.Analyzer.init(std.testing.allocator);
    defer trace.deinit();
    try trace.ingestJsonlBytes(trace_bytes.written());

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    const options = Options{ .top = 8, .since_ns = 110, .until_ns = 180 };
    try analyzer.ingestTree(&trace, options);

    var jsonl = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer jsonl.deinit();
    try writeJsonl(&analyzer, &jsonl.writer, options);
    try std.testing.expect(std.mem.indexOf(u8, jsonl.written(), "\"schema\":\"tracy.flame/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl.written(), "\"clipped_spans\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl.written(), "\"name\":\"child;one\"") != null);

    var folded = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer folded.deinit();
    try writeFolded(std.testing.allocator, &analyzer, &folded.writer, options);
    const folded_text = folded.written();
    try std.testing.expect(std.mem.indexOf(u8, folded_text, "root 20") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded_text, "root;child\\;one 50") != null);
}
