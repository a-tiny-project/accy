const std = @import("std");
const pretty_json = @import("pretty").json;
const sys = @import("sys");
const capture_mod = @import("capture.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");
const transport = @import("transport.zig");

pub const schema = "tracy.tree/v0";
pub const CaptureIntegrity = capture_mod.Integrity;

pub const Options = struct {
    top: usize = 200,
    max_depth: usize = 16,
    min_duration_ns: u64 = 0,
    thread: ?u64 = null,
};

pub const Counters = struct {
    events: u64 = 0,
    started_zones: u64 = 0,
    completed_zones: u64 = 0,
    valid_duration_samples: u64 = 0,
    zone_timestamp_regressions: u64 = 0,
    open_zones: u64 = 0,
    unmatched_zone_ends: u64 = 0,
    duplicate_zone_begins: u64 = 0,
    out_of_order_zone_ends: u64 = 0,
    thread_names: u64 = 0,
    zone_texts: u64 = 0,
};

pub const SpanState = enum {
    open,
    complete,
    superseded,

    pub fn tag(self: SpanState) []const u8 {
        return @tagName(self);
    }
};

pub const Span = struct {
    id: u64,
    parent_id: ?u64 = null,
    name: []const u8,
    text: ?[]const u8 = null,
    file: ?[]const u8 = null,
    function: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    thread: u64 = 0,
    depth: usize = 0,
    start_ns: u64 = 0,
    end_ns: u64 = 0,
    total_ns: u64 = 0,
    self_ns: u64 = 0,
    child_ns: u64 = 0,
    children: u64 = 0,
    value: ?u64 = null,
    color: ?u32 = null,
    state: SpanState,
    duration_valid: bool,
};

const Node = struct {
    id: u64,
    parent: ?usize = null,
    first_child: ?usize = null,
    last_child: ?usize = null,
    next_sibling: ?usize = null,
    name: []u8,
    text: ?[]u8 = null,
    file: ?[]u8 = null,
    function: ?[]u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    thread: u64 = 0,
    start_ns: u64 = 0,
    end_ns: u64 = 0,
    child_ns: u64 = 0,
    child_count: u64 = 0,
    value: ?u64 = null,
    color: ?u32 = null,
    state: SpanState = .open,

    fn init(
        allocator: std.mem.Allocator,
        parsed: event.Parsed,
        parent: ?usize,
    ) !Node {
        var self: Node = .{
            .id = parsed.id,
            .parent = parent,
            .name = try allocator.dupe(u8, parsed.name orelse "<zone>"),
            .line = parsed.line,
            .column = parsed.column,
            .thread = parsed.thread,
            .start_ns = parsed.time_ns,
            .color = parsed.color,
        };
        errdefer self.deinit(allocator);
        self.file = try dupeOptional(allocator, parsed.file);
        self.function = try dupeOptional(allocator, parsed.function);
        return self;
    }

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.text) |text| allocator.free(text);
        if (self.file) |file| allocator.free(file);
        if (self.function) |function| allocator.free(function);
        self.* = undefined;
    }

    fn durationValid(self: Node) bool {
        return self.state == .complete and self.end_ns >= self.start_ns;
    }

    fn durationNs(self: Node) u64 {
        if (!self.durationValid()) return 0;
        return self.end_ns - self.start_ns;
    }

    fn selfNs(self: Node) u64 {
        const duration = self.durationNs();
        if (duration <= self.child_ns) return 0;
        return duration - self.child_ns;
    }
};

const ThreadState = struct {
    id: u64,
    name: ?[]u8 = null,
    stack: std.ArrayListUnmanaged(usize) = .empty,
    span_count: u64 = 0,
    root_count: u64 = 0,
    span_total_ns: u64 = 0,
    root_total_ns: u64 = 0,

    fn deinit(self: *ThreadState, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        self.stack.deinit(allocator);
        self.* = undefined;
    }
};

const ThreadView = struct {
    id: u64,
    name: ?[]const u8,
    span_count: u64,
    root_count: u64,
    span_total_ns: u64,
    root_total_ns: u64,
};

pub const Evidence = struct {
    status: []const u8,
    capture: CaptureIntegrity,
    started_zones: u64,
    completed_zones: u64,
    valid_duration_samples: u64,
    open_zones: u64,
    unmatched_zone_ends: u64,
    duplicate_zone_begins: u64,
    out_of_order_zone_ends: u64,
    zone_timestamp_regressions: u64,

    pub fn writeText(self: Evidence, writer: *std.Io.Writer) !void {
        try writer.print(
            "tracy tree_evidence={s} started_zones={d} completed_zones={d} " ++
                "valid_duration_samples={d} open_zones={d} " ++
                "unmatched_zone_ends={d} duplicate_zone_begins={d} " ++
                "out_of_order_zone_ends={d} zone_timestamp_regressions={d}\n",
            .{
                self.status,
                self.started_zones,
                self.completed_zones,
                self.valid_duration_samples,
                self.open_zones,
                self.unmatched_zone_ends,
                self.duplicate_zone_begins,
                self.out_of_order_zone_ends,
                self.zone_timestamp_regressions,
            },
        );
        try capture_mod.writeText(writer, self.capture);
    }

    pub fn writeFields(self: Evidence, object: pretty_json.Object) !void {
        const evidence = try object.object("tree_evidence");
        try evidence.field("status", self.status);
        try evidence.field("started_zones", self.started_zones);
        try evidence.field("completed_zones", self.completed_zones);
        try evidence.field("valid_duration_samples", self.valid_duration_samples);
        try evidence.field("open_zones", self.open_zones);
        try evidence.field("unmatched_zone_ends", self.unmatched_zone_ends);
        try evidence.field("duplicate_zone_begins", self.duplicate_zone_begins);
        try evidence.field("out_of_order_zone_ends", self.out_of_order_zone_ends);
        try evidence.field("zone_timestamp_regressions", self.zone_timestamp_regressions);
        try evidence.end();
        try capture_mod.writeFields(object, self.capture);
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    active: std.AutoHashMapUnmanaged(u64, usize) = .{},
    threads: std.AutoHashMapUnmanaged(u64, ThreadState) = .{},
    capture: capture_mod.Tracker = .{},
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.active.deinit(self.allocator);
        var thread_iter = self.threads.valueIterator();
        while (thread_iter.next()) |thread| thread.deinit(self.allocator);
        self.threads.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ingestJsonlBytes(self: *Analyzer, bytes: []const u8) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| try self.ingestJsonLine(line);
        self.finishOpenCount();
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

    pub fn recordFlightReport(self: *Analyzer, report_value: transport.Report) void {
        self.capture.recordFlightReport(report_value);
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
            .zone_begin => try self.recordZoneBegin(parsed),
            .zone_end => try self.recordZoneEnd(parsed),
            .zone_text => try self.recordZoneText(parsed),
            .zone_name => try self.recordZoneName(parsed),
            .zone_color => self.recordZoneColor(parsed),
            .zone_value => self.recordZoneValue(parsed),
            .thread_name => try self.recordThreadName(parsed),
            else => {},
        }
    }

    pub fn writeText(self: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
        self.finishOpenCount();
        var threads = try self.collectThreads();
        defer threads.deinit(self.allocator);
        try writer.print(
            "tracy tree spans={d} completed={d} open={d} threads={d} roots={d} unmatched_zone_ends={d} out_of_order_zone_ends={d} duration_ns={d}\n",
            .{
                self.counters.started_zones,
                self.counters.completed_zones,
                self.counters.open_zones,
                threads.items.len,
                rootCount(threads.items),
                self.counters.unmatched_zone_ends,
                self.counters.out_of_order_zone_ends,
                self.durationNs(),
            },
        );
        try self.evidence().writeText(writer);
        var shown: usize = 0;
        for (threads.items) |thread| {
            if (options.thread) |wanted| {
                if (thread.id != wanted) continue;
            }
            try writer.print("thread id={d} name=", .{thread.id});
            try pretty_json.writeString(writer, thread.name orelse "");
            try writer.print(
                " spans={d} roots={d} span_total_ns={d} root_total_ns={d}\n",
                .{ thread.span_count, thread.root_count, thread.span_total_ns, thread.root_total_ns },
            );
            for (self.nodes.items, 0..) |node, index| {
                if (node.parent != null or node.thread != thread.id) continue;
                try self.writeNodeText(writer, index, 0, options, &shown);
                if (shown >= options.top) break;
            }
            if (shown >= options.top) break;
        }
    }

    pub fn writeJsonl(self: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
        self.finishOpenCount();
        var threads = try self.collectThreads();
        defer threads.deinit(self.allocator);
        var summary_stream = pretty_json.Writer.init(writer, .minified);
        const summary = try summary_stream.object();
        try summary.field("schema", schema);
        try summary.field("kind", "summary");
        try summary.field("spans", self.counters.started_zones);
        try summary.field("completed", self.counters.completed_zones);
        try summary.field("open", self.counters.open_zones);
        try summary.field("threads", threads.items.len);
        try summary.field("roots", rootCount(threads.items));
        try summary.field("unmatched_zone_ends", self.counters.unmatched_zone_ends);
        try summary.field("out_of_order_zone_ends", self.counters.out_of_order_zone_ends);
        try summary.field("duration_ns", self.durationNs());
        try self.evidence().writeFields(summary);
        try summary.endLine();
        var shown: usize = 0;
        for (threads.items) |thread| {
            if (options.thread) |wanted| {
                if (thread.id != wanted) continue;
            }
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("schema", schema);
            try object.field("kind", "thread");
            try object.field("id", thread.id);
            if (thread.name) |name| try object.field("name", name);
            try object.field("spans", thread.span_count);
            try object.field("roots", thread.root_count);
            try object.field("span_total_ns", thread.span_total_ns);
            try object.field("root_total_ns", thread.root_total_ns);
            try object.endLine();
            for (self.nodes.items, 0..) |node, index| {
                if (node.parent != null or node.thread != thread.id) continue;
                try self.writeNodeJsonl(writer, index, 0, options, &shown);
                if (shown >= options.top) break;
            }
            if (shown >= options.top) break;
        }
    }

    pub fn durationNs(self: Analyzer) u64 {
        const start_ns = self.start_ns orelse return 0;
        const end_ns = self.end_ns orelse return 0;
        if (end_ns <= start_ns) return 0;
        return end_ns - start_ns;
    }

    pub fn evidence(self: *const Analyzer) Evidence {
        const open_zones: u64 = @intCast(self.active.count());
        const capture = self.capture.integrity(open_zones +| self.counters.unmatched_zone_ends);
        const anomalies = self.counters.duplicate_zone_begins +|
            self.counters.out_of_order_zone_ends +|
            self.counters.zone_timestamp_regressions;
        return .{
            .status = if (std.mem.eql(u8, capture.status, "complete") and anomalies == 0)
                "complete"
            else
                "partial",
            .capture = capture,
            .started_zones = self.counters.started_zones,
            .completed_zones = self.counters.completed_zones,
            .valid_duration_samples = self.counters.valid_duration_samples,
            .open_zones = open_zones,
            .unmatched_zone_ends = self.counters.unmatched_zone_ends,
            .duplicate_zone_begins = self.counters.duplicate_zone_begins,
            .out_of_order_zone_ends = self.counters.out_of_order_zone_ends,
            .zone_timestamp_regressions = self.counters.zone_timestamp_regressions,
        };
    }

    pub fn collectSpans(self: *Analyzer, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(Span) {
        var spans: std.ArrayListUnmanaged(Span) = .empty;
        try spans.ensureTotalCapacity(allocator, self.nodes.items.len);
        for (self.nodes.items, 0..) |_, index| {
            spans.appendAssumeCapacity(self.spanView(index));
        }
        return spans;
    }

    fn recordZoneBegin(self: *Analyzer, parsed: event.Parsed) !void {
        if (parsed.id == 0) return;
        if (self.active.fetchRemove(parsed.id)) |removed| {
            const old_index = removed.value;
            const old_thread = self.nodes.items[old_index].thread;
            self.nodes.items[old_index].state = .superseded;
            if (self.threads.getPtr(old_thread)) |thread| {
                discardFromStack(thread, old_index);
            }
            self.counters.duplicate_zone_begins += 1;
        }
        const thread = try self.threadState(parsed.thread);
        const parent = if (thread.stack.items.len == 0) null else thread.stack.items[thread.stack.items.len - 1];
        const index = self.nodes.items.len;
        var node = try Node.init(self.allocator, parsed, parent);
        var node_owned = true;
        errdefer if (node_owned) node.deinit(self.allocator);
        try self.nodes.append(self.allocator, node);
        node_owned = false;
        if (parent) |parent_index| {
            const parent_node = &self.nodes.items[parent_index];
            if (parent_node.last_child) |last_child| {
                self.nodes.items[last_child].next_sibling = index;
            } else {
                parent_node.first_child = index;
            }
            parent_node.last_child = index;
            parent_node.child_count += 1;
        } else {
            thread.root_count += 1;
        }
        thread.span_count += 1;
        try thread.stack.append(self.allocator, index);
        try self.active.put(self.allocator, parsed.id, index);
        self.counters.started_zones += 1;
    }

    fn recordZoneEnd(self: *Analyzer, parsed: event.Parsed) !void {
        const removed = self.active.fetchRemove(parsed.id) orelse {
            self.counters.unmatched_zone_ends += 1;
            return;
        };
        const index = removed.value;
        const node = &self.nodes.items[index];
        node.end_ns = parsed.time_ns;
        node.state = .complete;
        self.counters.completed_zones += 1;
        if (node.durationValid()) {
            self.counters.valid_duration_samples += 1;
        } else {
            self.counters.zone_timestamp_regressions += 1;
        }
        const duration = node.durationNs();
        if (node.parent) |parent| self.nodes.items[parent].child_ns +|= duration;
        const thread = try self.threadState(node.thread);
        thread.span_total_ns +|= duration;
        if (node.parent == null) thread.root_total_ns +|= duration;
        self.removeFromStack(thread, index);
    }

    fn recordZoneName(self: *Analyzer, parsed: event.Parsed) !void {
        const name = parsed.name orelse return;
        const index = self.active.get(parsed.id) orelse return;
        const node = &self.nodes.items[index];
        self.allocator.free(node.name);
        node.name = try self.allocator.dupe(u8, name);
    }

    fn recordZoneText(self: *Analyzer, parsed: event.Parsed) !void {
        const text = parsed.text orelse return;
        const index = self.active.get(parsed.id) orelse return;
        const node = &self.nodes.items[index];
        node.text = try appendText(self.allocator, node.text, text);
        self.counters.zone_texts += 1;
    }

    fn recordZoneColor(self: *Analyzer, parsed: event.Parsed) void {
        const color = parsed.color orelse return;
        const index = self.active.get(parsed.id) orelse return;
        self.nodes.items[index].color = color;
    }

    fn recordZoneValue(self: *Analyzer, parsed: event.Parsed) void {
        const value = parsed.value_u64 orelse return;
        const index = self.active.get(parsed.id) orelse return;
        self.nodes.items[index].value = value;
    }

    fn recordThreadName(self: *Analyzer, parsed: event.Parsed) !void {
        const name = parsed.name orelse return;
        const thread = try self.threadState(parsed.thread);
        if (thread.name) |old| self.allocator.free(old);
        thread.name = try self.allocator.dupe(u8, name);
        self.counters.thread_names += 1;
    }

    fn threadState(self: *Analyzer, id: u64) !*ThreadState {
        const entry = try self.threads.getOrPut(self.allocator, id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .id = id };
        return entry.value_ptr;
    }

    fn removeFromStack(self: *Analyzer, thread: *ThreadState, index: usize) void {
        if (thread.stack.items.len == 0) {
            self.counters.out_of_order_zone_ends += 1;
            return;
        }
        if (thread.stack.items[thread.stack.items.len - 1] == index) {
            _ = thread.stack.pop();
            return;
        }
        var cursor = thread.stack.items.len;
        while (cursor > 0) {
            cursor -= 1;
            if (thread.stack.items[cursor] == index) {
                _ = thread.stack.orderedRemove(cursor);
                self.counters.out_of_order_zone_ends += 1;
                return;
            }
        }
        self.counters.out_of_order_zone_ends += 1;
    }

    fn discardFromStack(thread: *ThreadState, index: usize) void {
        var cursor = thread.stack.items.len;
        while (cursor > 0) {
            cursor -= 1;
            if (thread.stack.items[cursor] != index) continue;
            _ = thread.stack.orderedRemove(cursor);
            return;
        }
    }

    fn finishOpenCount(self: *Analyzer) void {
        self.counters.open_zones = @intCast(self.active.count());
    }

    fn collectThreads(self: *Analyzer) !std.ArrayListUnmanaged(ThreadView) {
        var threads: std.ArrayListUnmanaged(ThreadView) = .empty;
        var iter = self.threads.valueIterator();
        while (iter.next()) |thread| {
            if (thread.span_count == 0 and thread.name == null) continue;
            try threads.append(self.allocator, .{
                .id = thread.id,
                .name = thread.name,
                .span_count = thread.span_count,
                .root_count = thread.root_count,
                .span_total_ns = thread.span_total_ns,
                .root_total_ns = thread.root_total_ns,
            });
        }
        std.mem.sort(ThreadView, threads.items, {}, threadLessThan);
        return threads;
    }

    fn spanView(self: *Analyzer, index: usize) Span {
        const node = self.nodes.items[index];
        return .{
            .id = node.id,
            .parent_id = if (node.parent) |parent| self.nodes.items[parent].id else null,
            .name = node.name,
            .text = node.text,
            .file = node.file,
            .function = node.function,
            .line = node.line,
            .column = node.column,
            .thread = node.thread,
            .depth = self.depthOf(index),
            .start_ns = node.start_ns,
            .end_ns = node.end_ns,
            .total_ns = node.durationNs(),
            .self_ns = node.selfNs(),
            .child_ns = node.child_ns,
            .children = node.child_count,
            .value = node.value,
            .color = node.color,
            .state = node.state,
            .duration_valid = node.durationValid(),
        };
    }

    fn depthOf(self: Analyzer, index: usize) usize {
        var depth: usize = 0;
        var cursor = self.nodes.items[index].parent;
        while (cursor) |parent| {
            depth += 1;
            cursor = self.nodes.items[parent].parent;
        }
        return depth;
    }

    fn writeNodeText(
        self: *Analyzer,
        writer: *std.Io.Writer,
        index: usize,
        depth: usize,
        options: Options,
        shown: *usize,
    ) !void {
        if (shown.* >= options.top or depth > options.max_depth) return;
        const node = self.nodes.items[index];
        if (node.durationNs() < options.min_duration_ns) return;
        for (0..depth) |_| try writer.writeAll("  ");
        try writer.print(
            "span id={d} depth={d} state={s} name=",
            .{ node.id, depth, node.state.tag() },
        );
        try pretty_json.writeString(writer, node.name);
        try writer.print(
            " total_ns={d} self_ns={d} child_ns={d} start_ns={d} end_ns={d} " ++
                "children={d} duration_valid={}",
            .{
                node.durationNs(),
                node.selfNs(),
                node.child_ns,
                node.start_ns,
                node.end_ns,
                node.child_count,
                node.durationValid(),
            },
        );
        if (node.file) |file| try writer.print(" file={s}:{d}", .{ file, node.line });
        if (node.function) |function| {
            try writer.writeAll(" function=");
            try pretty_json.writeString(writer, function);
        }
        if (node.text) |text| {
            try writer.writeAll(" text=");
            try pretty_json.writeString(writer, text);
        }
        if (node.value) |value| try writer.print(" value={d}", .{value});
        if (node.color) |color| try writer.print(" color={d}", .{color});
        try writer.writeByte('\n');
        shown.* += 1;
        var child = node.first_child;
        while (child) |child_index| {
            try self.writeNodeText(writer, child_index, depth + 1, options, shown);
            if (shown.* >= options.top) return;
            child = self.nodes.items[child_index].next_sibling;
        }
    }

    fn writeNodeJsonl(
        self: *Analyzer,
        writer: *std.Io.Writer,
        index: usize,
        depth: usize,
        options: Options,
        shown: *usize,
    ) !void {
        if (shown.* >= options.top or depth > options.max_depth) return;
        const node = self.nodes.items[index];
        if (node.durationNs() < options.min_duration_ns) return;
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "span");
        try object.field("id", node.id);
        if (node.parent) |parent| try object.field("parent_id", self.nodes.items[parent].id);
        try object.field("thread", node.thread);
        try object.field("depth", depth);
        try object.field("state", node.state.tag());
        try object.field("duration_valid", node.durationValid());
        try object.field("name", node.name);
        if (self.threads.get(node.thread)) |thread| {
            if (thread.name) |name| try object.field("thread_name", name);
        }
        try object.field("start_ns", node.start_ns);
        try object.field("end_ns", node.end_ns);
        try object.field("total_ns", node.durationNs());
        try object.field("self_ns", node.selfNs());
        try object.field("child_ns", node.child_ns);
        try object.field("children", node.child_count);
        if (node.file) |file| {
            try object.field("file", file);
            try object.field("line", node.line);
        }
        if (node.function) |function| try object.field("function", function);
        if (node.text) |text| try object.field("text", text);
        if (node.value) |value| try object.field("value", value);
        if (node.color) |color| try object.field("color", color);
        try object.endLine();
        shown.* += 1;
        var child = node.first_child;
        while (child) |child_index| {
            try self.writeNodeJsonl(writer, child_index, depth + 1, options, shown);
            if (shown.* >= options.top) return;
            child = self.nodes.items[child_index].next_sibling;
        }
    }
};

pub fn writeTextFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try ingestPath(&analyzer, path);
    try analyzer.writeText(writer, options);
}

pub fn writeJsonlFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try ingestPath(&analyzer, path);
    try analyzer.writeJsonl(writer, options);
}

pub fn ingestPath(analyzer: *Analyzer, path: []const u8) !void {
    var file = try sys.fs.cwd().openFile(sys.fs.debugIo(), path, .{});
    defer file.close(sys.fs.debugIo());

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(sys.fs.debugIo(), &buffer);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        const actual = line orelse break;
        try analyzer.ingestJsonLine(actual);
    }
    analyzer.finishOpenCount();
}

fn rootCount(threads: []const ThreadView) u64 {
    var count: u64 = 0;
    for (threads) |thread| count += thread.root_count;
    return count;
}

fn threadLessThan(_: void, left: ThreadView, right: ThreadView) bool {
    return left.id < right.id;
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
}

fn appendText(allocator: std.mem.Allocator, existing: ?[]u8, addition: []const u8) ![]u8 {
    if (existing) |old| {
        const joined = try allocator.alloc(u8, old.len + 1 + addition.len);
        @memcpy(joined[0..old.len], old);
        joined[old.len] = '\n';
        @memcpy(joined[old.len + 1 ..], addition);
        allocator.free(old);
        return joined;
    }
    return try allocator.dupe(u8, addition);
}

test "tree reconstructs nested spans and self time" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 100, .thread = 1, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .thread_name, .time_ns = 105, .thread = 1, .name = "main" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_begin, .time_ns = 110, .thread = 1, .id = 1, .name = "root", .file = "root.zig", .line = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .zone_begin, .time_ns = 120, .thread = 1, .id = 2, .name = "child" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .zone_end, .time_ns = 150, .thread = 1, .id = 2 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .zone_end, .time_ns = 180, .thread = 1, .id = 1 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .stop, .time_ns = 190, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try analyzer.writeText(&out.writer, .{ .top = 8 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "thread id=1 name=\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "span id=1 depth=0 state=complete name=\"root\" total_ns=70 self_ns=40 child_ns=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "span id=2 depth=1 state=complete name=\"child\" total_ns=30 self_ns=30 child_ns=0") != null);
}

test "tree jsonl emits parent ids and dynamic metadata" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .zone_begin, .time_ns = 100, .thread = 2, .id = 1, .name = "root" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .zone_begin, .time_ns = 120, .thread = 2, .id = 2, .name = "child" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_name, .time_ns = 125, .thread = 2, .id = 2, .name = "renamed" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .zone_value, .time_ns = 126, .thread = 2, .id = 2, .value_u64 = 42 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .zone_color, .time_ns = 127, .thread = 2, .id = 2, .color = 0x112233 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .zone_text, .time_ns = 128, .thread = 2, .id = 2, .text = "first note" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .zone_text, .time_ns = 129, .thread = 2, .id = 2, .text = "second note" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 8, .kind = .zone_end, .time_ns = 160, .thread = 2, .id = 2 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 9, .kind = .zone_end, .time_ns = 200, .thread = 2, .id = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try analyzer.writeJsonl(&out.writer, .{ .top = 8 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.tree/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"thread\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"parent_id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"renamed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"text\":\"first note\\nsecond note\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"value\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"color\":1122867") != null);

    var text_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text_out.deinit();
    try analyzer.writeText(&text_out.writer, .{ .top = 8 });
    try std.testing.expect(std.mem.indexOf(u8, text_out.written(), "text=\"first note\\nsecond note\"") != null);
}

test "tree distinguishes lifecycle and duration evidence" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try writeTreeIntegrityFixture(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    const evidence_value = analyzer.evidence();
    try std.testing.expectEqualStrings("partial", evidence_value.status);
    try std.testing.expectEqualStrings("complete", evidence_value.capture.status);
    try std.testing.expectEqual(@as(u64, 6), evidence_value.started_zones);
    try std.testing.expectEqual(@as(u64, 5), evidence_value.completed_zones);
    try std.testing.expectEqual(@as(u64, 4), evidence_value.valid_duration_samples);
    try std.testing.expectEqual(@as(u64, 1), evidence_value.duplicate_zone_begins);
    try std.testing.expectEqual(@as(u64, 1), evidence_value.out_of_order_zone_ends);
    try std.testing.expectEqual(@as(u64, 1), evidence_value.zone_timestamp_regressions);
    try std.testing.expectEqual(
        @as(u64, 2),
        evidence_value.capture.flight_report.?.overwritten_events,
    );

    var spans = try analyzer.collectSpans(std.testing.allocator);
    defer spans.deinit(std.testing.allocator);
    try expectTreeIntegritySpanStates(spans.items);
}

fn writeTreeIntegrityFixture(writer: *std.Io.Writer) !void {
    const rows = [_]event.TraceEvent{
        .{ .seq = 1, .kind = .start, .time_ns = 80 },
        .{ .seq = 2, .kind = .zone_begin, .time_ns = 100, .thread = 1, .id = 1 },
        .{ .seq = 3, .kind = .zone_begin, .time_ns = 110, .thread = 1, .id = 2 },
        .{ .seq = 4, .kind = .zone_end, .time_ns = 120, .thread = 1, .id = 1 },
        .{ .seq = 5, .kind = .zone_end, .time_ns = 130, .thread = 1, .id = 2 },
        .{ .seq = 6, .kind = .zone_begin, .time_ns = 140, .thread = 1, .id = 3 },
        .{ .seq = 7, .kind = .zone_begin, .time_ns = 150, .thread = 1, .id = 3 },
        .{ .seq = 8, .kind = .zone_end, .time_ns = 160, .thread = 1, .id = 3 },
        .{ .seq = 9, .kind = .zone_begin, .time_ns = 180, .thread = 1, .id = 4 },
        .{ .seq = 10, .kind = .zone_end, .time_ns = 170, .thread = 1, .id = 4 },
        .{ .seq = 11, .kind = .zone_begin, .time_ns = 190, .thread = 1, .id = 5 },
        .{ .seq = 12, .kind = .zone_end, .time_ns = 190, .thread = 1, .id = 5 },
        .{ .seq = 13, .kind = .stop, .time_ns = 200 },
    };
    for (rows) |row| try row.writeJsonLine(writer);
    try treeIntegrityFlightReport().writeJsonl(writer);
}

fn treeIntegrityFlightReport() transport.Report {
    return .{
        .policy = .overwrite_oldest,
        .state = .accepting,
        .capacity_bytes = 64,
        .retained_bytes = 32,
        .event_capacity_bytes = 16,
        .writer_capacity_bytes = 8,
        .observed_events = 5,
        .stored_events = 5,
        .retained_events = 3,
        .overwritten_events = 2,
        .dropped_events = 0,
        .oversized_events = 0,
        .partial_event_bytes = 0,
        .discarding_oversized_event = false,
    };
}

fn expectTreeIntegritySpanStates(spans: []const Span) !void {
    var superseded: u64 = 0;
    var invalid: u64 = 0;
    var valid_zero: u64 = 0;
    for (spans) |span| {
        if (span.state == .superseded) superseded += 1;
        if (span.state == .complete and !span.duration_valid) invalid += 1;
        if (span.duration_valid and span.total_ns == 0) valid_zero += 1;
    }
    try std.testing.expectEqual(@as(u64, 1), superseded);
    try std.testing.expectEqual(@as(u64, 1), invalid);
    try std.testing.expectEqual(@as(u64, 1), valid_zero);
}

test "tree releases integrity evidence on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        analyzeTreeIntegrity,
        .{},
    );
}

/// Sizes its output up front so the output never grows. Whether a growth
/// remaps in place depends on the testing allocator's history, and a remap
/// that fails in one run and succeeds in the next changes the allocation
/// count the allocation failure test depends on.
fn analyzeTreeIntegrity(allocator: std.mem.Allocator) !void {
    const trace =
        "{\"v\":0,\"seq\":1,\"kind\":\"start\",\"time_ns\":80}\n" ++
        "{\"v\":0,\"seq\":2,\"kind\":\"zone.begin\",\"time_ns\":100," ++
        "\"thread\":1,\"id\":1,\"name\":\"work\"}\n" ++
        "{\"v\":0,\"seq\":3,\"kind\":\"zone.end\",\"time_ns\":90," ++
        "\"thread\":1,\"id\":1}\n" ++
        "{\"v\":0,\"seq\":4,\"kind\":\"stop\",\"time_ns\":110}\n";
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace);
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 16 * 1024);
    defer output.deinit();
    analyzer.writeJsonl(&output.writer, .{}) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
}
