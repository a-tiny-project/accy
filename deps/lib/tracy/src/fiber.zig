const std = @import("std");
const pretty_json = @import("pretty").json;
const report = @import("report.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");

pub const schema = "tracy.fibers/v0";

pub const Group = enum {
    fiber,
    thread,
    transition,
    none,

    pub fn fromName(text: []const u8) ?Group {
        if (std.mem.eql(u8, text, "fiber")) return .fiber;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "transition")) return .transition;
        if (std.mem.eql(u8, text, "none")) return .none;
        return null;
    }

    fn tag(self: Group) []const u8 {
        return switch (self) {
            .fiber => "fiber",
            .thread => "thread",
            .transition => "transition",
            .none => "none",
        };
    }
};

pub const Sort = enum {
    running,
    enters,
    leaves,
    migrations,
    unmatched,
    last,
    fiber,
    thread,
    label,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "running")) return .running;
        if (std.mem.eql(u8, text, "enters")) return .enters;
        if (std.mem.eql(u8, text, "leaves")) return .leaves;
        if (std.mem.eql(u8, text, "migrations")) return .migrations;
        if (std.mem.eql(u8, text, "unmatched")) return .unmatched;
        if (std.mem.eql(u8, text, "last")) return .last;
        if (std.mem.eql(u8, text, "fiber")) return .fiber;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "label")) return .label;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .running => "running",
            .enters => "enters",
            .leaves => "leaves",
            .migrations => "migrations",
            .unmatched => "unmatched",
            .last => "last",
            .fiber => "fiber",
            .thread => "thread",
            .label => "label",
        };
    }
};

pub const Options = struct {
    top: usize = 20,
    occurrences: usize = 80,
    group: Group = .fiber,
    sort: Sort = .running,
    fiber: ?u64 = null,
    thread: ?u64 = null,
    since_ns: ?u64 = null,
    until_ns: ?u64 = null,
    match: ?[]const u8 = null,
    ignore_case: bool = false,
};

pub const Counters = struct {
    events: u64 = 0,
    enters: u64 = 0,
    leaves: u64 = 0,
    names: u64 = 0,
    thread_names: u64 = 0,
    unmatched_leaves: u64 = 0,
    filtered: u64 = 0,
    groups: u64 = 0,
    active_fibers: u64 = 0,
    duration_ns: u64 = 0,
};

const FiberState = struct {
    id: u64,
    name: ?[]u8 = null,
    group_hint: ?i64 = null,
    enters: u64 = 0,
    leaves: u64 = 0,
    running_ns: u64 = 0,
    migrations: u64 = 0,
    unmatched_leaves: u64 = 0,
    active_since_ns: ?u64 = null,
    active_thread: ?u64 = null,
    last_thread: ?u64 = null,
    threads: std.AutoHashMapUnmanaged(u64, void) = .{},
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    fn deinit(self: *FiberState, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        self.threads.deinit(allocator);
        self.* = undefined;
    }

    fn displayName(self: FiberState) []const u8 {
        return self.name orelse "";
    }
};

const ThreadState = struct {
    id: u64,
    name: ?[]u8 = null,
    enters: u64 = 0,
    leaves: u64 = 0,
    running_ns: u64 = 0,
    unmatched_leaves: u64 = 0,
    current_fiber: u64 = 0,
    current_since_ns: ?u64 = null,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    fn deinit(self: *ThreadState, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        self.* = undefined;
    }

    fn displayName(self: ThreadState) []const u8 {
        return self.name orelse "";
    }
};

const TransitionState = struct {
    label: []u8,
    from_thread: u64 = 0,
    to_thread: u64 = 0,
    fibers: std.AutoHashMapUnmanaged(u64, void) = .{},
    count: u64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    fn deinit(self: *TransitionState, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        self.fibers.deinit(allocator);
        self.* = undefined;
    }
};

const OccurrenceKind = enum {
    name,
    enter,
    leave,

    fn tag(self: OccurrenceKind) []const u8 {
        return switch (self) {
            .name => "name",
            .enter => "enter",
            .leave => "leave",
        };
    }
};

const Occurrence = struct {
    kind: OccurrenceKind,
    seq: u64 = 0,
    time_ns: u64 = 0,
    fiber: u64 = 0,
    thread: u64 = 0,
    name: ?[]u8 = null,
    group_hint: ?i64 = null,
    duration_ns: u64 = 0,
    unmatched: bool = false,

    fn deinit(self: *Occurrence, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        self.* = undefined;
    }
};

pub const Summary = struct {
    group: Group,
    label: []u8,
    count: u64 = 0,
    fiber: ?u64 = null,
    thread: ?u64 = null,
    from_thread: u64 = 0,
    to_thread: u64 = 0,
    group_hint: ?i64 = null,
    enters: u64 = 0,
    leaves: u64 = 0,
    running_ns: u64 = 0,
    migrations: u64 = 0,
    unmatched_leaves: u64 = 0,
    active: bool = false,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        self.* = undefined;
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    fibers: std.AutoHashMapUnmanaged(u64, FiberState) = .{},
    threads: std.AutoHashMapUnmanaged(u64, ThreadState) = .{},
    transitions: std.StringHashMapUnmanaged(TransitionState) = .{},
    occurrences: std.ArrayListUnmanaged(Occurrence) = .empty,
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        var fiber_iter = self.fibers.valueIterator();
        while (fiber_iter.next()) |fiber_state| fiber_state.deinit(self.allocator);
        self.fibers.deinit(self.allocator);
        var thread_iter = self.threads.valueIterator();
        while (thread_iter.next()) |thread_state| thread_state.deinit(self.allocator);
        self.threads.deinit(self.allocator);
        var transition_iter = self.transitions.iterator();
        while (transition_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.transitions.deinit(self.allocator);
        for (self.occurrences.items) |*occurrence| occurrence.deinit(self.allocator);
        self.occurrences.deinit(self.allocator);
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
            .thread_name => try self.recordThreadName(parsed),
            .fiber_name => try self.recordFiberName(parsed),
            .fiber_enter => try self.recordEnter(parsed),
            .fiber_leave => try self.recordLeave(parsed),
            else => {},
        }
    }

    pub fn collectSummaries(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Summary) {
        var summaries: std.ArrayListUnmanaged(Summary) = .empty;
        errdefer deinitSummaries(allocator, &summaries);
        self.counters.filtered = 0;
        self.counters.active_fibers = self.activeCount();
        switch (options.group) {
            .fiber => {
                var iter = self.fibers.valueIterator();
                while (iter.next()) |fiber_state| {
                    if (!self.fiberMatches(fiber_state.*, options)) {
                        self.counters.filtered += 1;
                        continue;
                    }
                    try summaries.append(allocator, try fiberSummary(allocator, fiber_state.*, self.end_ns));
                }
            },
            .thread => {
                var iter = self.threads.valueIterator();
                while (iter.next()) |thread_state| {
                    if (!threadMatches(thread_state.*, options)) {
                        self.counters.filtered += 1;
                        continue;
                    }
                    try summaries.append(allocator, try threadSummary(allocator, thread_state.*, self.end_ns));
                }
            },
            .transition => {
                var iter = self.transitions.valueIterator();
                while (iter.next()) |transition| {
                    if (!transitionMatches(transition.*, options)) {
                        self.counters.filtered += 1;
                        continue;
                    }
                    try summaries.append(allocator, try transitionSummary(allocator, transition.*));
                }
            },
            .none => {
                for (self.occurrences.items) |occurrence| {
                    if (!occurrenceMatches(occurrence, options)) {
                        self.counters.filtered += 1;
                        continue;
                    }
                    try summaries.append(allocator, try occurrenceSummary(allocator, occurrence));
                }
            },
        }
        self.counters.groups = @intCast(summaries.items.len);
        self.counters.duration_ns = self.durationNs();
        sortSummaries(summaries.items, options.sort);
        return summaries;
    }

    pub fn collectOccurrences(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Occurrence) {
        var occurrences: std.ArrayListUnmanaged(Occurrence) = .empty;
        for (self.occurrences.items) |occurrence| {
            if (!occurrenceMatches(occurrence, options)) continue;
            try occurrences.append(allocator, occurrence);
        }
        sortOccurrences(occurrences.items, options.sort);
        return occurrences;
    }

    pub fn durationNs(self: Analyzer) u64 {
        const start_ns = self.start_ns orelse return 0;
        const end_ns = self.end_ns orelse return 0;
        if (end_ns <= start_ns) return 0;
        return end_ns - start_ns;
    }

    pub fn runningNs(self: Analyzer) u64 {
        var total: u64 = 0;
        var iter = self.fibers.valueIterator();
        while (iter.next()) |fiber_state| total +|= effectiveFiberRunning(fiber_state.*, self.end_ns);
        return total;
    }

    fn recordThreadName(self: *Analyzer, parsed: event.Parsed) !void {
        const name = parsed.name orelse return;
        const thread_state = try self.threadState(parsed.thread);
        if (thread_state.name) |old| self.allocator.free(old);
        thread_state.name = try self.allocator.dupe(u8, name);
        self.counters.thread_names += 1;
    }

    fn recordFiberName(self: *Analyzer, parsed: event.Parsed) !void {
        const id = parsed.id;
        if (id == 0) return;
        const fiber_state = try self.fiberState(id);
        try self.setFiberName(fiber_state, parsed.name);
        fiber_state.group_hint = parsed.group_hint;
        noteRange(&fiber_state.first_ns, &fiber_state.last_ns, parsed.time_ns);
        self.counters.names += 1;
        try self.recordOccurrence(.{
            .kind = .name,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .fiber = id,
            .thread = parsed.thread,
            .name = try dupeOptional(self.allocator, parsed.name),
            .group_hint = parsed.group_hint,
        });
    }

    fn recordEnter(self: *Analyzer, parsed: event.Parsed) !void {
        const id = parsed.id;
        if (id == 0) return;
        self.counters.enters += 1;
        const thread_state = try self.threadState(parsed.thread);
        closeCurrentThreadFiber(self, thread_state, parsed.time_ns) catch |err| return err;
        const fiber_state = try self.fiberState(id);
        if (parsed.name != null) try self.setFiberName(fiber_state, parsed.name);
        if (parsed.group_hint) |group_hint| fiber_state.group_hint = group_hint;
        if (fiber_state.active_since_ns) |active_since| {
            if (parsed.time_ns >= active_since) fiber_state.running_ns +|= parsed.time_ns - active_since;
        }
        if (fiber_state.last_thread) |last_thread| {
            if (last_thread != parsed.thread) {
                fiber_state.migrations += 1;
                try self.recordTransition(id, last_thread, parsed.thread, parsed.time_ns);
            }
        }
        fiber_state.enters += 1;
        fiber_state.active_since_ns = parsed.time_ns;
        fiber_state.active_thread = parsed.thread;
        fiber_state.last_thread = parsed.thread;
        try fiber_state.threads.put(self.allocator, parsed.thread, {});
        noteRange(&fiber_state.first_ns, &fiber_state.last_ns, parsed.time_ns);
        thread_state.enters += 1;
        thread_state.current_fiber = id;
        thread_state.current_since_ns = parsed.time_ns;
        noteRange(&thread_state.first_ns, &thread_state.last_ns, parsed.time_ns);
        try self.recordOccurrence(.{
            .kind = .enter,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .fiber = id,
            .thread = parsed.thread,
            .name = try dupeOptional(self.allocator, fiber_state.name orelse parsed.name),
            .group_hint = fiber_state.group_hint,
        });
    }

    fn recordLeave(self: *Analyzer, parsed: event.Parsed) !void {
        self.counters.leaves += 1;
        const thread_state = try self.threadState(parsed.thread);
        const id = if (parsed.id != 0) parsed.id else thread_state.current_fiber;
        var unmatched = false;
        var duration: u64 = 0;
        if (id == 0) {
            unmatched = true;
            thread_state.unmatched_leaves += 1;
            self.counters.unmatched_leaves += 1;
        } else {
            const fiber_state = try self.fiberState(id);
            fiber_state.leaves += 1;
            noteRange(&fiber_state.first_ns, &fiber_state.last_ns, parsed.time_ns);
            if (fiber_state.active_since_ns) |active_since| {
                if (fiber_state.active_thread == parsed.thread and parsed.time_ns >= active_since) {
                    duration = parsed.time_ns - active_since;
                    fiber_state.running_ns +|= duration;
                    fiber_state.active_since_ns = null;
                    fiber_state.active_thread = null;
                } else {
                    unmatched = true;
                }
            } else {
                unmatched = true;
            }
            if (thread_state.current_fiber == id and thread_state.current_since_ns != null) {
                const current_since = thread_state.current_since_ns.?;
                if (parsed.time_ns >= current_since) thread_state.running_ns +|= parsed.time_ns - current_since;
                thread_state.current_fiber = 0;
                thread_state.current_since_ns = null;
            } else if (unmatched) {
                thread_state.unmatched_leaves += 1;
            }
            if (unmatched) {
                fiber_state.unmatched_leaves += 1;
                self.counters.unmatched_leaves += 1;
            }
            thread_state.leaves += 1;
            noteRange(&thread_state.first_ns, &thread_state.last_ns, parsed.time_ns);
        }
        try self.recordOccurrence(.{
            .kind = .leave,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .fiber = id,
            .thread = parsed.thread,
            .duration_ns = duration,
            .unmatched = unmatched,
        });
    }

    fn setFiberName(self: *Analyzer, fiber_state: *FiberState, name: ?[]const u8) !void {
        const actual = name orelse return;
        if (fiber_state.name) |old| self.allocator.free(old);
        fiber_state.name = try self.allocator.dupe(u8, actual);
    }

    fn fiberState(self: *Analyzer, id: u64) !*FiberState {
        const entry = try self.fibers.getOrPut(self.allocator, id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .id = id };
        return entry.value_ptr;
    }

    fn threadState(self: *Analyzer, id: u64) !*ThreadState {
        const entry = try self.threads.getOrPut(self.allocator, id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .id = id };
        return entry.value_ptr;
    }

    fn recordTransition(self: *Analyzer, fiber: u64, from_thread: u64, to_thread: u64, time_ns: u64) !void {
        var label_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer label_writer.deinit();
        try label_writer.writer.print("thread {d}->{d}", .{ from_thread, to_thread });
        const label = label_writer.written();
        const entry = try self.transitions.getOrPut(self.allocator, label);
        if (!entry.found_existing) {
            const owned_label = try self.allocator.dupe(u8, label);
            entry.key_ptr.* = owned_label;
            entry.value_ptr.* = .{
                .label = try self.allocator.dupe(u8, owned_label),
                .from_thread = from_thread,
                .to_thread = to_thread,
            };
        }
        entry.value_ptr.count += 1;
        try entry.value_ptr.fibers.put(self.allocator, fiber, {});
        noteRange(&entry.value_ptr.first_ns, &entry.value_ptr.last_ns, time_ns);
    }

    fn recordOccurrence(self: *Analyzer, occurrence: Occurrence) !void {
        try self.occurrences.append(self.allocator, occurrence);
    }

    pub fn activeCount(self: Analyzer) u64 {
        var count: u64 = 0;
        var iter = self.fibers.valueIterator();
        while (iter.next()) |fiber_state| {
            if (fiber_state.active_since_ns != null) count += 1;
        }
        return count;
    }

    fn fiberMatches(self: Analyzer, fiber_state: FiberState, options: Options) bool {
        if (options.fiber) |fiber_filter| if (fiber_state.id != fiber_filter) return false;
        if (options.thread) |thread_filter| if (!fiber_state.threads.contains(thread_filter)) return false;
        if (!rangeMatches(fiber_state.first_ns, fiber_state.last_ns, options)) return false;
        if (options.match) |needle| {
            if (contains(fiber_state.displayName(), needle, options.ignore_case)) return true;
            var buffer: [32]u8 = undefined;
            const id_text = std.fmt.bufPrint(&buffer, "{d}", .{fiber_state.id}) catch "";
            if (contains(id_text, needle, options.ignore_case)) return true;
            return false;
        }
        _ = self;
        return true;
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
        "tracy fibers groups={d} fibers={d} threads={d} enters={d} leaves={d} names={d} running_ns={d} migrations={d} unmatched_leaves={d} active={d} filtered={d} duration_ns={d} group={s} sort={s}\n",
        .{
            summaries.items.len,
            analyzer.fibers.count(),
            analyzer.threads.count(),
            analyzer.counters.enters,
            analyzer.counters.leaves,
            analyzer.counters.names,
            analyzer.runningNs(),
            totalMigrations(analyzer),
            analyzer.counters.unmatched_leaves,
            analyzer.counters.active_fibers,
            analyzer.counters.filtered,
            analyzer.durationNs(),
            options.group.tag(),
            options.sort.tag(),
        },
    );
    const summary_limit = @min(options.top, summaries.items.len);
    for (summaries.items[0..summary_limit]) |summary| {
        try writer.print("fiber group={s} label=", .{summary.group.tag()});
        try pretty_json.writeString(writer, summary.label);
        try writer.print(" count={d}", .{summary.count});
        try writeSummaryFieldsText(writer, summary);
        try writer.writeByte('\n');
    }

    const occurrence_limit = @min(options.occurrences, occurrences.items.len);
    for (occurrences.items[0..occurrence_limit]) |occurrence| {
        try writer.print("fiber-occurrence kind={s} time_ns={d} thread={d}", .{ occurrence.kind.tag(), occurrence.time_ns, occurrence.thread });
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
    try summary_record.field("fibers", analyzer.fibers.count());
    try summary_record.field("threads", analyzer.threads.count());
    try summary_record.field("enters", analyzer.counters.enters);
    try summary_record.field("leaves", analyzer.counters.leaves);
    try summary_record.field("names", analyzer.counters.names);
    try summary_record.field("running_ns", analyzer.runningNs());
    try summary_record.field("migrations", totalMigrations(analyzer));
    try summary_record.field("unmatched_leaves", analyzer.counters.unmatched_leaves);
    try summary_record.field("active", analyzer.counters.active_fibers);
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
    for (occurrences.items[0..occurrence_limit]) |occurrence| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", occurrence.kind.tag());
        try object.field("time_ns", occurrence.time_ns);
        try object.field("thread", occurrence.thread);
        try writeOccurrenceFields(object, occurrence);
        try object.endLine();
    }
}

fn closeCurrentThreadFiber(analyzer: *Analyzer, thread_state: *ThreadState, time_ns: u64) !void {
    if (thread_state.current_fiber == 0) return;
    if (thread_state.current_since_ns) |current_since| {
        if (time_ns >= current_since) thread_state.running_ns +|= time_ns - current_since;
    }
    const fiber_state = try analyzer.fiberState(thread_state.current_fiber);
    if (fiber_state.active_since_ns) |active_since| {
        if (time_ns >= active_since) fiber_state.running_ns +|= time_ns - active_since;
        fiber_state.active_since_ns = null;
        fiber_state.active_thread = null;
    }
    thread_state.current_fiber = 0;
    thread_state.current_since_ns = null;
}

fn fiberSummary(allocator: std.mem.Allocator, fiber_state: FiberState, end_ns: ?u64) !Summary {
    var label = std.Io.Writer.Allocating.init(allocator);
    defer label.deinit();
    try label.writer.print("fiber {d}", .{fiber_state.id});
    if (fiber_state.name) |name| {
        try label.writer.writeByte(' ');
        try label.writer.writeAll(name);
    }
    return .{
        .group = .fiber,
        .label = try allocator.dupe(u8, label.written()),
        .count = fiber_state.enters + fiber_state.leaves,
        .fiber = fiber_state.id,
        .thread = fiber_state.last_thread,
        .group_hint = fiber_state.group_hint,
        .enters = fiber_state.enters,
        .leaves = fiber_state.leaves,
        .running_ns = effectiveFiberRunning(fiber_state, end_ns),
        .migrations = fiber_state.migrations,
        .unmatched_leaves = fiber_state.unmatched_leaves,
        .active = fiber_state.active_since_ns != null,
        .first_ns = fiber_state.first_ns,
        .last_ns = fiber_state.last_ns,
    };
}

fn threadSummary(allocator: std.mem.Allocator, thread_state: ThreadState, end_ns: ?u64) !Summary {
    var label = std.Io.Writer.Allocating.init(allocator);
    defer label.deinit();
    try label.writer.print("thread {d}", .{thread_state.id});
    if (thread_state.name) |name| {
        try label.writer.writeByte(' ');
        try label.writer.writeAll(name);
    }
    return .{
        .group = .thread,
        .label = try allocator.dupe(u8, label.written()),
        .count = thread_state.enters + thread_state.leaves,
        .thread = thread_state.id,
        .enters = thread_state.enters,
        .leaves = thread_state.leaves,
        .running_ns = effectiveThreadRunning(thread_state, end_ns),
        .unmatched_leaves = thread_state.unmatched_leaves,
        .active = thread_state.current_fiber != 0,
        .first_ns = thread_state.first_ns,
        .last_ns = thread_state.last_ns,
    };
}

fn transitionSummary(allocator: std.mem.Allocator, transition: TransitionState) !Summary {
    return .{
        .group = .transition,
        .label = try allocator.dupe(u8, transition.label),
        .count = transition.count,
        .from_thread = transition.from_thread,
        .to_thread = transition.to_thread,
        .migrations = transition.count,
        .first_ns = transition.first_ns,
        .last_ns = transition.last_ns,
    };
}

fn occurrenceSummary(allocator: std.mem.Allocator, occurrence: Occurrence) !Summary {
    var label = std.Io.Writer.Allocating.init(allocator);
    defer label.deinit();
    try label.writer.print("{s} {d}", .{ occurrence.kind.tag(), occurrence.time_ns });
    return .{
        .group = .none,
        .label = try allocator.dupe(u8, label.written()),
        .count = 1,
        .fiber = if (occurrence.fiber == 0) null else occurrence.fiber,
        .thread = occurrence.thread,
        .group_hint = occurrence.group_hint,
        .running_ns = occurrence.duration_ns,
        .unmatched_leaves = if (occurrence.unmatched) 1 else 0,
        .first_ns = occurrence.time_ns,
        .last_ns = occurrence.time_ns,
    };
}

fn effectiveFiberRunning(fiber_state: FiberState, end_ns: ?u64) u64 {
    var total = fiber_state.running_ns;
    if (fiber_state.active_since_ns) |active_since| {
        if (end_ns) |end| {
            if (end >= active_since) total +|= end - active_since;
        }
    }
    return total;
}

fn effectiveThreadRunning(thread_state: ThreadState, end_ns: ?u64) u64 {
    var total = thread_state.running_ns;
    if (thread_state.current_since_ns) |current_since| {
        if (end_ns) |end| {
            if (end >= current_since) total +|= end - current_since;
        }
    }
    return total;
}

fn totalMigrations(analyzer: *Analyzer) u64 {
    var total: u64 = 0;
    var iter = analyzer.fibers.valueIterator();
    while (iter.next()) |fiber_state| total +|= fiber_state.migrations;
    return total;
}

fn threadMatches(thread_state: ThreadState, options: Options) bool {
    if (options.thread) |thread_filter| if (thread_state.id != thread_filter) return false;
    if (!rangeMatches(thread_state.first_ns, thread_state.last_ns, options)) return false;
    if (options.match) |needle| {
        if (contains(thread_state.displayName(), needle, options.ignore_case)) return true;
        var buffer: [32]u8 = undefined;
        const thread_text = std.fmt.bufPrint(&buffer, "{d}", .{thread_state.id}) catch "";
        if (contains(thread_text, needle, options.ignore_case)) return true;
        return false;
    }
    return true;
}

fn transitionMatches(transition: TransitionState, options: Options) bool {
    if (options.fiber) |fiber_filter| if (!transition.fibers.contains(fiber_filter)) return false;
    if (options.thread) |thread_filter| {
        if (transition.from_thread != thread_filter and transition.to_thread != thread_filter) return false;
    }
    if (!rangeMatches(transition.first_ns, transition.last_ns, options)) return false;
    if (options.match) |needle| return contains(transition.label, needle, options.ignore_case);
    return true;
}

fn occurrenceMatches(occurrence: Occurrence, options: Options) bool {
    if (options.fiber) |fiber_filter| if (occurrence.fiber != fiber_filter) return false;
    if (options.thread) |thread_filter| if (occurrence.thread != thread_filter) return false;
    if (options.since_ns) |since_ns| if (occurrence.time_ns < since_ns) return false;
    if (options.until_ns) |until_ns| if (occurrence.time_ns > until_ns) return false;
    if (options.match) |needle| {
        if (contains(occurrence.kind.tag(), needle, options.ignore_case)) return true;
        if (occurrence.name) |name| if (contains(name, needle, options.ignore_case)) return true;
        var buffer: [32]u8 = undefined;
        const fiber_text = std.fmt.bufPrint(&buffer, "{d}", .{occurrence.fiber}) catch "";
        if (contains(fiber_text, needle, options.ignore_case)) return true;
        return false;
    }
    return true;
}

fn rangeMatches(first_ns: u64, last_ns: u64, options: Options) bool {
    if (options.since_ns) |since_ns| if (last_ns != 0 and last_ns < since_ns) return false;
    if (options.until_ns) |until_ns| if (first_ns != 0 and first_ns > until_ns) return false;
    return true;
}

fn writeSummaryFieldsText(writer: *std.Io.Writer, summary: Summary) !void {
    if (summary.fiber) |fiber| try writer.print(" fiber={d}", .{fiber});
    if (summary.thread) |thread| try writer.print(" thread={d}", .{thread});
    if (summary.from_thread != 0 or summary.to_thread != 0) try writer.print(" from_thread={d} to_thread={d}", .{ summary.from_thread, summary.to_thread });
    if (summary.group_hint) |group_hint| try writer.print(" group_hint={d}", .{group_hint});
    if (summary.enters != 0) try writer.print(" enters={d}", .{summary.enters});
    if (summary.leaves != 0) try writer.print(" leaves={d}", .{summary.leaves});
    if (summary.running_ns != 0) try writer.print(" running_ns={d}", .{summary.running_ns});
    if (summary.migrations != 0) try writer.print(" migrations={d}", .{summary.migrations});
    if (summary.unmatched_leaves != 0) try writer.print(" unmatched_leaves={d}", .{summary.unmatched_leaves});
    if (summary.active) try writer.writeAll(" active=true");
    if (summary.first_ns != 0) try writer.print(" first_ns={d}", .{summary.first_ns});
    if (summary.last_ns != 0) try writer.print(" last_ns={d}", .{summary.last_ns});
}

fn writeSummaryFields(object: pretty_json.Object, summary: Summary) !void {
    if (summary.fiber) |fiber| try object.field("fiber", fiber);
    if (summary.thread) |thread| try object.field("thread", thread);
    if (summary.from_thread != 0 or summary.to_thread != 0) {
        try object.field("from_thread", summary.from_thread);
        try object.field("to_thread", summary.to_thread);
    }
    if (summary.group_hint) |group_hint| try object.field("group_hint", group_hint);
    if (summary.enters != 0) try object.field("enters", summary.enters);
    if (summary.leaves != 0) try object.field("leaves", summary.leaves);
    if (summary.running_ns != 0) try object.field("running_ns", summary.running_ns);
    if (summary.migrations != 0) try object.field("migrations", summary.migrations);
    if (summary.unmatched_leaves != 0) try object.field("unmatched_leaves", summary.unmatched_leaves);
    if (summary.active) try object.field("active", true);
    if (summary.first_ns != 0) try object.field("first_ns", summary.first_ns);
    if (summary.last_ns != 0) try object.field("last_ns", summary.last_ns);
}

fn writeOccurrenceFieldsText(writer: *std.Io.Writer, occurrence: Occurrence) !void {
    if (occurrence.fiber != 0) try writer.print(" fiber={d}", .{occurrence.fiber});
    if (occurrence.name) |name| {
        try writer.writeAll(" name=");
        try pretty_json.writeString(writer, name);
    }
    if (occurrence.group_hint) |group_hint| try writer.print(" group_hint={d}", .{group_hint});
    if (occurrence.duration_ns != 0) try writer.print(" duration_ns={d}", .{occurrence.duration_ns});
    if (occurrence.unmatched) try writer.writeAll(" unmatched=true");
}

fn writeOccurrenceFields(object: pretty_json.Object, occurrence: Occurrence) !void {
    if (occurrence.fiber != 0) try object.field("fiber", occurrence.fiber);
    if (occurrence.name) |name| try object.field("name", name);
    if (occurrence.group_hint) |group_hint| try object.field("group_hint", group_hint);
    if (occurrence.duration_ns != 0) try object.field("duration_ns", occurrence.duration_ns);
    if (occurrence.unmatched) try object.field("unmatched", true);
}

fn sortSummaries(items: []Summary, sort: Sort) void {
    std.mem.sort(Summary, items, sort, summaryLessThan);
}

fn summaryLessThan(sort: Sort, left: Summary, right: Summary) bool {
    return switch (sort) {
        .running => summaryRunningGreaterThan({}, left, right),
        .enters => summaryEntersGreaterThan({}, left, right),
        .leaves => summaryLeavesGreaterThan({}, left, right),
        .migrations => summaryMigrationsGreaterThan({}, left, right),
        .unmatched => summaryUnmatchedGreaterThan({}, left, right),
        .last => summaryLastGreaterThan({}, left, right),
        .fiber => summaryFiberLessThan({}, left, right),
        .thread => summaryThreadLessThan({}, left, right),
        .label => summaryLabelLessThan({}, left, right),
    };
}

fn summaryRunningGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.running_ns != right.running_ns) return left.running_ns > right.running_ns;
    return summaryEntersGreaterThan({}, left, right);
}

fn summaryEntersGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.enters != right.enters) return left.enters > right.enters;
    if (left.count != right.count) return left.count > right.count;
    return std.mem.lessThan(u8, left.label, right.label);
}

fn summaryLeavesGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.leaves != right.leaves) return left.leaves > right.leaves;
    return summaryEntersGreaterThan({}, left, right);
}

fn summaryMigrationsGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.migrations != right.migrations) return left.migrations > right.migrations;
    return summaryEntersGreaterThan({}, left, right);
}

fn summaryUnmatchedGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.unmatched_leaves != right.unmatched_leaves) return left.unmatched_leaves > right.unmatched_leaves;
    return summaryEntersGreaterThan({}, left, right);
}

fn summaryLastGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.last_ns != right.last_ns) return left.last_ns > right.last_ns;
    return summaryEntersGreaterThan({}, left, right);
}

fn summaryFiberLessThan(_: void, left: Summary, right: Summary) bool {
    const left_fiber = left.fiber orelse 0;
    const right_fiber = right.fiber orelse 0;
    if (left_fiber != right_fiber) return left_fiber < right_fiber;
    return summaryEntersGreaterThan({}, left, right);
}

fn summaryThreadLessThan(_: void, left: Summary, right: Summary) bool {
    const left_thread = left.thread orelse left.from_thread;
    const right_thread = right.thread orelse right.from_thread;
    if (left_thread != right_thread) return left_thread < right_thread;
    return summaryEntersGreaterThan({}, left, right);
}

fn summaryLabelLessThan(_: void, left: Summary, right: Summary) bool {
    return std.mem.lessThan(u8, left.label, right.label);
}

fn sortOccurrences(items: []Occurrence, sort: Sort) void {
    switch (sort) {
        .last => std.mem.sort(Occurrence, items, {}, occurrenceTimeGreaterThan),
        else => std.mem.sort(Occurrence, items, {}, occurrenceTimeLessThan),
    }
}

fn occurrenceTimeLessThan(_: void, left: Occurrence, right: Occurrence) bool {
    if (left.time_ns != right.time_ns) return left.time_ns < right.time_ns;
    return left.seq < right.seq;
}

fn occurrenceTimeGreaterThan(_: void, left: Occurrence, right: Occurrence) bool {
    if (left.time_ns != right.time_ns) return left.time_ns > right.time_ns;
    return left.seq > right.seq;
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

test "fiber analyzer derives running time migrations and unmatched leaves" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 90, .thread = 1, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .thread_name, .time_ns = 95, .thread = 100, .name = "worker-a" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .thread_name, .time_ns = 96, .thread = 101, .name = "worker-b" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .fiber_name, .time_ns = 100, .thread = 100, .id = 7, .name = "job.parse", .group_hint = 3 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .fiber_enter, .time_ns = 110, .thread = 100, .id = 7, .name = "job.parse", .group_hint = 3 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .fiber_leave, .time_ns = 150, .thread = 100, .id = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .fiber_enter, .time_ns = 180, .thread = 101, .id = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 8, .kind = .fiber_leave, .time_ns = 230, .thread = 101, .id = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 9, .kind = .fiber_leave, .time_ns = 240, .thread = 101, .id = 9 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 10, .kind = .stop, .time_ns = 260, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 2), analyzer.counters.enters);
    try std.testing.expectEqual(@as(u64, 3), analyzer.counters.leaves);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.unmatched_leaves);
    try std.testing.expectEqual(@as(u64, 90), analyzer.fibers.get(7).?.running_ns);
    try std.testing.expectEqual(@as(u64, 1), analyzer.fibers.get(7).?.migrations);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .group = .fiber, .sort = .running, .top = 4, .occurrences = 8 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy fibers groups=2 fibers=2 threads=2 enters=2 leaves=3 names=1 running_ns=90 migrations=1 unmatched_leaves=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fiber group=fiber label=\"fiber 7 job.parse\" count=4 fiber=7 thread=101 group_hint=3 enters=2 leaves=2 running_ns=90 migrations=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fiber-occurrence kind=leave time_ns=240 thread=101 fiber=9 unmatched=true") != null);
}

test "fiber jsonl filters by thread fiber and name" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .fiber_name, .time_ns = 100, .thread = 100, .id = 7, .name = "job.parse" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .fiber_enter, .time_ns = 110, .thread = 100, .id = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .fiber_leave, .time_ns = 150, .thread = 100, .id = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .fiber_name, .time_ns = 160, .thread = 101, .id = 8, .name = "job.render" }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{ .group = .fiber, .fiber = 7, .thread = 100, .match = "PARSE", .ignore_case = true });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.fibers/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"summary\",\"groups\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"label\":\"fiber 7 job.parse\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"running_ns\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "job.render") == null);
}
