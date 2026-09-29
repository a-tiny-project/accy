const std = @import("std");
const pretty_json = @import("pretty").json;
const sys = @import("sys");
const event = @import("event.zig");
const record_mod = @import("record.zig");

pub const schema = "tracy.messages/v0";

pub const Kind = enum {
    all,
    message,
    app_info,

    pub fn fromName(text: []const u8) ?Kind {
        if (std.mem.eql(u8, text, "all")) return .all;
        if (std.mem.eql(u8, text, "message")) return .message;
        if (std.mem.eql(u8, text, "app-info")) return .app_info;
        return null;
    }

    fn tag(self: Kind) []const u8 {
        return switch (self) {
            .all => "all",
            .message => "message",
            .app_info => "app-info",
        };
    }
};

pub const Group = enum {
    thread,
    text,
    kind,
    none,

    pub fn fromName(text: []const u8) ?Group {
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "text")) return .text;
        if (std.mem.eql(u8, text, "kind")) return .kind;
        if (std.mem.eql(u8, text, "none")) return .none;
        return null;
    }

    fn tag(self: Group) []const u8 {
        return switch (self) {
            .thread => "thread",
            .text => "text",
            .kind => "kind",
            .none => "none",
        };
    }
};

pub const Sort = enum {
    time,
    count,
    last,
    thread,
    text,
    kind,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "time")) return .time;
        if (std.mem.eql(u8, text, "count")) return .count;
        if (std.mem.eql(u8, text, "last")) return .last;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "text")) return .text;
        if (std.mem.eql(u8, text, "kind")) return .kind;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .time => "time",
            .count => "count",
            .last => "last",
            .thread => "thread",
            .text => "text",
            .kind => "kind",
        };
    }
};

pub const Options = struct {
    top: usize = 20,
    occurrences: usize = 100,
    kind: Kind = .all,
    group: Group = .thread,
    sort: Sort = .time,
    thread: ?u64 = null,
    since_ns: ?u64 = null,
    until_ns: ?u64 = null,
    match: ?[]const u8 = null,
    ignore_case: bool = false,
};

pub const Counters = struct {
    events: u64 = 0,
    messages: u64 = 0,
    app_infos: u64 = 0,
    thread_names: u64 = 0,
    filtered: u64 = 0,
    groups: u64 = 0,
    duration_ns: u64 = 0,
};

const ThreadName = struct {
    name: []u8,

    fn deinit(self: *ThreadName, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

const Entry = struct {
    kind: Kind,
    seq: u64 = 0,
    time_ns: u64 = 0,
    thread: u64 = 0,
    thread_name: ?[]u8 = null,
    text: []u8,
    color: ?u32 = null,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.thread_name) |thread_name| allocator.free(thread_name);
        allocator.free(self.text);
        self.* = undefined;
    }
};

const GroupRow = struct {
    group: Group,
    label: []u8,
    kind: ?Kind = null,
    thread: ?u64 = null,
    thread_name: ?[]u8 = null,
    text: ?[]u8 = null,
    count: u64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    fn deinit(self: *GroupRow, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.thread_name) |thread_name| allocator.free(thread_name);
        if (self.text) |text| allocator.free(text);
        self.* = undefined;
    }
};

const GroupView = struct {
    group: Group,
    label: []const u8,
    kind: ?Kind,
    thread: ?u64,
    thread_name: ?[]const u8,
    text: ?[]const u8,
    count: u64,
    first_ns: u64,
    last_ns: u64,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    groups: std.StringHashMapUnmanaged(GroupRow) = .{},
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    threads: std.AutoHashMapUnmanaged(u64, ThreadName) = .{},
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        var group_iter = self.groups.iterator();
        while (group_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.groups.deinit(self.allocator);
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        var thread_iter = self.threads.valueIterator();
        while (thread_iter.next()) |thread| thread.deinit(self.allocator);
        self.threads.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ingestJsonlBytes(self: *Analyzer, bytes: []const u8, options: Options) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| try self.ingestJsonLine(line, options);
        self.finish(options);
    }

    pub fn ingestJsonLine(self: *Analyzer, line: []const u8, options: Options) !void {
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) return;
        var parsed = (try record_mod.parseEventLine(self.allocator, text)) orelse return;
        defer parsed.deinit();
        try self.ingest(parsed, options);
    }

    pub fn ingest(self: *Analyzer, parsed: event.Parsed, options: Options) !void {
        self.counters.events += 1;
        if (self.start_ns == null and parsed.time_ns != 0) self.start_ns = parsed.time_ns;
        if (parsed.time_ns != 0) self.end_ns = parsed.time_ns;
        switch (parsed.kind) {
            .thread_name => try self.recordThreadName(parsed),
            .message => {
                self.counters.messages += 1;
                try self.recordEntry(.message, parsed, options);
            },
            .app_info => {
                self.counters.app_infos += 1;
                try self.recordEntry(.app_info, parsed, options);
            },
            else => {},
        }
    }

    pub fn finish(self: *Analyzer, options: Options) void {
        self.counters.groups = @intCast(self.groups.count());
        self.counters.duration_ns = self.durationNs();
        sortEntries(self.entries.items, options.sort);
    }

    fn recordThreadName(self: *Analyzer, parsed: event.Parsed) !void {
        const name = parsed.name orelse return;
        const entry = try self.threads.getOrPut(self.allocator, parsed.thread);
        if (entry.found_existing) entry.value_ptr.deinit(self.allocator);
        entry.value_ptr.* = .{ .name = try self.allocator.dupe(u8, name) };
        self.counters.thread_names += 1;
    }

    fn recordEntry(self: *Analyzer, kind: Kind, parsed: event.Parsed, options: Options) !void {
        const text = parsed.text orelse "";
        if (!entryMatches(kind, parsed, text, options)) {
            self.counters.filtered += 1;
            return;
        }
        const thread_name = self.threadName(parsed.thread);
        var entry = Entry{
            .kind = kind,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .thread = parsed.thread,
            .thread_name = try dupeOptional(self.allocator, thread_name),
            .text = try self.allocator.dupe(u8, text),
            .color = parsed.color,
        };
        var owns_entry = true;
        errdefer if (owns_entry) entry.deinit(self.allocator);
        try self.recordGroup(entry, options);
        try self.entries.append(self.allocator, entry);
        owns_entry = false;
    }

    fn recordGroup(self: *Analyzer, entry: Entry, options: Options) !void {
        var key_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer key_writer.deinit();
        try writeGroupKey(&key_writer.writer, entry, options.group);
        const key_text = key_writer.written();
        const group_entry = try self.groups.getOrPut(self.allocator, key_text);
        if (!group_entry.found_existing) {
            const owned_key = try self.allocator.dupe(u8, key_text);
            group_entry.key_ptr.* = owned_key;
            group_entry.value_ptr.* = try self.newGroup(entry, options.group);
        }
        const row = group_entry.value_ptr;
        row.count += 1;
        if (row.count == 1 or entry.time_ns < row.first_ns) row.first_ns = entry.time_ns;
        if (entry.time_ns > row.last_ns) row.last_ns = entry.time_ns;
    }

    fn newGroup(self: *Analyzer, entry: Entry, group: Group) !GroupRow {
        const label = try groupLabel(self.allocator, entry, group);
        errdefer self.allocator.free(label);
        const thread_name = if (group == .thread) try dupeOptional(self.allocator, entry.thread_name) else null;
        errdefer if (thread_name) |actual| self.allocator.free(actual);
        const text = if (group == .text) try self.allocator.dupe(u8, entry.text) else null;
        errdefer if (text) |actual| self.allocator.free(actual);
        return .{
            .group = group,
            .label = label,
            .kind = if (group == .kind) entry.kind else null,
            .thread = if (group == .thread) entry.thread else null,
            .thread_name = thread_name,
            .text = text,
        };
    }

    fn collectGroups(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(GroupView) {
        var views: std.ArrayListUnmanaged(GroupView) = .empty;
        var iter = self.groups.valueIterator();
        while (iter.next()) |row| {
            try views.append(allocator, .{
                .group = row.group,
                .label = row.label,
                .kind = row.kind,
                .thread = row.thread,
                .thread_name = row.thread_name,
                .text = row.text,
                .count = row.count,
                .first_ns = row.first_ns,
                .last_ns = row.last_ns,
            });
        }
        sortGroups(views.items, options.sort);
        return views;
    }

    fn threadName(self: Analyzer, thread: u64) ?[]const u8 {
        if (self.threads.get(thread)) |name| return name.name;
        return null;
    }

    fn durationNs(self: Analyzer) u64 {
        const start_ns = self.start_ns orelse return 0;
        const end_ns = self.end_ns orelse return 0;
        if (end_ns <= start_ns) return 0;
        return end_ns - start_ns;
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
    try ingestPath(&analyzer, path, options);
    try writeText(allocator, &analyzer, writer, options);
}

pub fn writeJsonlFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try ingestPath(&analyzer, path, options);
    try writeJsonl(allocator, &analyzer, writer, options);
}

fn ingestPath(analyzer: *Analyzer, path: []const u8, options: Options) !void {
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
        try analyzer.ingestJsonLine(actual, options);
    }
    analyzer.finish(options);
}

fn writeText(allocator: std.mem.Allocator, analyzer: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
    var groups = try analyzer.collectGroups(allocator, options);
    defer groups.deinit(allocator);
    try writer.print(
        "tracy messages groups={d} entries={d} events={d} messages={d} app_infos={d} thread_names={d} filtered={d} duration_ns={d} kind={s} group={s} sort={s}",
        .{
            groups.items.len,
            analyzer.entries.items.len,
            analyzer.counters.events,
            analyzer.counters.messages,
            analyzer.counters.app_infos,
            analyzer.counters.thread_names,
            analyzer.counters.filtered,
            analyzer.counters.duration_ns,
            options.kind.tag(),
            options.group.tag(),
            options.sort.tag(),
        },
    );
    if (options.thread) |thread| try writer.print(" thread={d}", .{thread});
    if (options.since_ns) |since_ns| try writer.print(" since_ns={d}", .{since_ns});
    if (options.until_ns) |until_ns| try writer.print(" until_ns={d}", .{until_ns});
    if (options.match) |pattern| {
        try writer.writeAll(" match=");
        try pretty_json.writeString(writer, pattern);
    }
    try writer.writeByte('\n');
    const group_limit = @min(options.top, groups.items.len);
    for (groups.items[0..group_limit]) |group| {
        try writer.print("message-group group={s} label=", .{group.group.tag()});
        try pretty_json.writeString(writer, group.label);
        try writer.print(" count={d} first_ns={d} last_ns={d}", .{ group.count, group.first_ns, group.last_ns });
        if (group.kind) |kind| try writer.print(" kind={s}", .{kind.tag()});
        if (group.thread) |thread| try writer.print(" thread={d}", .{thread});
        if (group.thread_name) |thread_name| {
            try writer.writeAll(" thread_name=");
            try pretty_json.writeString(writer, thread_name);
        }
        if (group.text) |text| {
            try writer.writeAll(" text=");
            try pretty_json.writeString(writer, text);
        }
        try writer.writeByte('\n');
    }
    const occurrence_limit = @min(options.occurrences, analyzer.entries.items.len);
    for (analyzer.entries.items[0..occurrence_limit]) |entry| {
        try writer.print("message kind={s} seq={d} time_ns={d} thread={d}", .{ entry.kind.tag(), entry.seq, entry.time_ns, entry.thread });
        if (entry.thread_name) |thread_name| {
            try writer.writeAll(" thread_name=");
            try pretty_json.writeString(writer, thread_name);
        }
        try writer.writeAll(" text=");
        try pretty_json.writeString(writer, entry.text);
        if (entry.color) |color| try writer.print(" color={d}", .{color});
        try writer.writeByte('\n');
    }
}

fn writeJsonl(allocator: std.mem.Allocator, analyzer: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
    var groups = try analyzer.collectGroups(allocator, options);
    defer groups.deinit(allocator);
    var summary_stream = pretty_json.Writer.init(writer, .minified);
    const summary = try summary_stream.object();
    try summary.field("schema", schema);
    try summary.field("kind", "summary");
    try summary.field("groups", groups.items.len);
    try summary.field("entries", analyzer.entries.items.len);
    try summary.field("events", analyzer.counters.events);
    try summary.field("messages", analyzer.counters.messages);
    try summary.field("app_infos", analyzer.counters.app_infos);
    try summary.field("thread_names", analyzer.counters.thread_names);
    try summary.field("filtered", analyzer.counters.filtered);
    try summary.field("duration_ns", analyzer.counters.duration_ns);
    try summary.field("filter_kind", options.kind.tag());
    try summary.field("group", options.group.tag());
    try summary.field("sort", options.sort.tag());
    if (options.thread) |thread| try summary.field("thread", thread);
    if (options.since_ns) |since_ns| try summary.field("since_ns", since_ns);
    if (options.until_ns) |until_ns| try summary.field("until_ns", until_ns);
    if (options.match) |pattern| try summary.field("match", pattern);
    try summary.endLine();
    const group_limit = @min(options.top, groups.items.len);
    for (groups.items[0..group_limit]) |group| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "group");
        try object.field("group", group.group.tag());
        try object.field("label", group.label);
        try object.field("count", group.count);
        try object.field("first_ns", group.first_ns);
        try object.field("last_ns", group.last_ns);
        if (group.kind) |kind| try object.field("message_kind", kind.tag());
        if (group.thread) |thread| try object.field("thread", thread);
        if (group.thread_name) |name| try object.field("thread_name", name);
        if (group.text) |text| try object.field("text", text);
        try object.endLine();
    }
    const occurrence_limit = @min(options.occurrences, analyzer.entries.items.len);
    for (analyzer.entries.items[0..occurrence_limit]) |entry| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "message");
        try object.field("message_kind", entry.kind.tag());
        try object.field("seq", entry.seq);
        try object.field("time_ns", entry.time_ns);
        try object.field("thread", entry.thread);
        if (entry.thread_name) |name| try object.field("thread_name", name);
        try object.field("text", entry.text);
        if (entry.color) |color| try object.field("color", color);
        try object.endLine();
    }
}

fn entryMatches(kind: Kind, parsed: event.Parsed, text: []const u8, options: Options) bool {
    switch (options.kind) {
        .all => {},
        .message => if (kind != .message) return false,
        .app_info => if (kind != .app_info) return false,
    }
    if (options.thread) |thread| {
        if (parsed.thread != thread) return false;
    }
    if (options.since_ns) |since_ns| {
        if (parsed.time_ns < since_ns) return false;
    }
    if (options.until_ns) |until_ns| {
        if (parsed.time_ns > until_ns) return false;
    }
    if (options.match) |pattern| {
        if (!contains(text, pattern, options.ignore_case)) return false;
    }
    return true;
}

fn writeGroupKey(writer: *std.Io.Writer, entry: Entry, group: Group) !void {
    switch (group) {
        .thread => try writer.print("thread:{d}", .{entry.thread}),
        .text => try writer.writeAll(entry.text),
        .kind => try writer.writeAll(entry.kind.tag()),
        .none => try writer.print("message:{d}:{d}:{d}", .{ entry.time_ns, entry.seq, entry.thread }),
    }
}

fn groupLabel(allocator: std.mem.Allocator, entry: Entry, group: Group) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    switch (group) {
        .thread => {
            if (entry.thread_name) |thread_name| {
                try writer.writer.print("{s} ({d})", .{ thread_name, entry.thread });
            } else {
                try writer.writer.print("thread {d}", .{entry.thread});
            }
        },
        .text => try writer.writer.writeAll(entry.text),
        .kind => try writer.writer.writeAll(entry.kind.tag()),
        .none => try writer.writer.print("{s}#{d}", .{ entry.kind.tag(), entry.seq }),
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

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
}

fn sortGroups(items: []GroupView, sort: Sort) void {
    switch (sort) {
        .time => std.mem.sort(GroupView, items, {}, groupTimeLessThan),
        .count => std.mem.sort(GroupView, items, {}, groupCountGreaterThan),
        .last => std.mem.sort(GroupView, items, {}, groupLastGreaterThan),
        .thread => std.mem.sort(GroupView, items, {}, groupThreadLessThan),
        .text => std.mem.sort(GroupView, items, {}, groupTextLessThan),
        .kind => std.mem.sort(GroupView, items, {}, groupKindLessThan),
    }
}

fn sortEntries(items: []Entry, sort: Sort) void {
    switch (sort) {
        .time, .count, .last => std.mem.sort(Entry, items, {}, entryTimeLessThan),
        .thread => std.mem.sort(Entry, items, {}, entryThreadLessThan),
        .text => std.mem.sort(Entry, items, {}, entryTextLessThan),
        .kind => std.mem.sort(Entry, items, {}, entryKindLessThan),
    }
}

fn groupTimeLessThan(_: void, left: GroupView, right: GroupView) bool {
    if (left.first_ns != right.first_ns) return left.first_ns < right.first_ns;
    return groupTextLessThan({}, left, right);
}

fn groupCountGreaterThan(_: void, left: GroupView, right: GroupView) bool {
    if (left.count != right.count) return left.count > right.count;
    return groupTimeLessThan({}, left, right);
}

fn groupLastGreaterThan(_: void, left: GroupView, right: GroupView) bool {
    if (left.last_ns != right.last_ns) return left.last_ns > right.last_ns;
    return groupTimeLessThan({}, left, right);
}

fn groupThreadLessThan(_: void, left: GroupView, right: GroupView) bool {
    const left_thread = left.thread orelse 0;
    const right_thread = right.thread orelse 0;
    if (left_thread != right_thread) return left_thread < right_thread;
    return groupTextLessThan({}, left, right);
}

fn groupTextLessThan(_: void, left: GroupView, right: GroupView) bool {
    const cmp = std.mem.order(u8, left.label, right.label);
    if (cmp != .eq) return cmp == .lt;
    return left.first_ns < right.first_ns;
}

fn groupKindLessThan(_: void, left: GroupView, right: GroupView) bool {
    const left_kind = if (left.kind) |kind| kind.tag() else "";
    const right_kind = if (right.kind) |kind| kind.tag() else "";
    const cmp = std.mem.order(u8, left_kind, right_kind);
    if (cmp != .eq) return cmp == .lt;
    return groupTextLessThan({}, left, right);
}

fn entryTimeLessThan(_: void, left: Entry, right: Entry) bool {
    if (left.time_ns != right.time_ns) return left.time_ns < right.time_ns;
    return left.seq < right.seq;
}

fn entryThreadLessThan(_: void, left: Entry, right: Entry) bool {
    if (left.thread != right.thread) return left.thread < right.thread;
    return entryTimeLessThan({}, left, right);
}

fn entryTextLessThan(_: void, left: Entry, right: Entry) bool {
    const cmp = std.mem.order(u8, left.text, right.text);
    if (cmp != .eq) return cmp == .lt;
    return entryTimeLessThan({}, left, right);
}

fn entryKindLessThan(_: void, left: Entry, right: Entry) bool {
    const cmp = std.mem.order(u8, left.kind.tag(), right.kind.tag());
    if (cmp != .eq) return cmp == .lt;
    return entryTimeLessThan({}, left, right);
}

test "messages groups text output by thread" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 90, .thread = 1, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .thread_name, .time_ns = 95, .thread = 1, .name = "main" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .message, .time_ns = 100, .thread = 1, .text = "queue ready" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .message, .time_ns = 130, .thread = 1, .text = "queue drained" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .message, .time_ns = 140, .thread = 2, .text = "other" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .stop, .time_ns = 180, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    const options = Options{ .match = "queue", .group = .thread, .sort = .count, .ignore_case = true };
    try analyzer.ingestJsonlBytes(trace.written(), options);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, options);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy messages groups=1 entries=2 events=6 messages=3 app_infos=0 thread_names=1 filtered=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "message-group group=thread label=\"main (1)\" count=2 first_ns=100 last_ns=130 thread=1 thread_name=\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "message kind=message seq=3 time_ns=100 thread=1 thread_name=\"main\" text=\"queue ready\"") != null);
}

test "messages jsonl groups app info by text in time window" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .app_info, .time_ns = 100, .thread = 1, .text = "build debug" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .app_info, .time_ns = 120, .thread = 1, .text = "build debug" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .message, .time_ns = 130, .thread = 1, .text = "skip" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .app_info, .time_ns = 200, .thread = 1, .text = "outside" }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    const options = Options{ .kind = .app_info, .group = .text, .sort = .count, .since_ns = 90, .until_ns = 150, .occurrences = 4 };
    try analyzer.ingestJsonlBytes(trace.written(), options);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, options);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.messages/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"summary\",\"groups\":1,\"entries\":2,\"events\":4,\"messages\":1,\"app_infos\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"group\",\"group\":\"text\",\"label\":\"build debug\",\"count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"message\",\"message_kind\":\"app-info\",\"seq\":2") != null);
}
