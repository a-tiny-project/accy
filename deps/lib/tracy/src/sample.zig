const std = @import("std");
const pretty_json = @import("pretty").json;
const report = @import("report.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");

pub const schema = "tracy.samples/v0";

pub const Group = enum {
    source,
    symbol,
    stack,
    thread,
    kind,
    none,

    pub fn fromName(text: []const u8) ?Group {
        if (std.mem.eql(u8, text, "source")) return .source;
        if (std.mem.eql(u8, text, "symbol")) return .symbol;
        if (std.mem.eql(u8, text, "stack")) return .stack;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "kind")) return .kind;
        if (std.mem.eql(u8, text, "none")) return .none;
        return null;
    }

    fn tag(self: Group) []const u8 {
        return switch (self) {
            .source => "source",
            .symbol => "symbol",
            .stack => "stack",
            .thread => "thread",
            .kind => "kind",
            .none => "none",
        };
    }
};

pub const Sort = enum {
    samples,
    weight,
    last,
    first,
    thread,
    name,
    kind,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "samples")) return .samples;
        if (std.mem.eql(u8, text, "weight")) return .weight;
        if (std.mem.eql(u8, text, "last")) return .last;
        if (std.mem.eql(u8, text, "first")) return .first;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "name")) return .name;
        if (std.mem.eql(u8, text, "kind")) return .kind;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .samples => "samples",
            .weight => "weight",
            .last => "last",
            .first => "first",
            .thread => "thread",
            .name => "name",
            .kind => "kind",
        };
    }
};

pub const Options = struct {
    top: usize = 20,
    occurrences: usize = 80,
    group: Group = .source,
    sort: Sort = .samples,
    min_weight: u64 = 0,
    thread: ?u64 = null,
    since_ns: ?u64 = null,
    until_ns: ?u64 = null,
    kind: ?[]const u8 = null,
    match: ?[]const u8 = null,
    ignore_case: bool = false,
};

pub const Counters = struct {
    events: u64 = 0,
    samples: u64 = 0,
    frames: u64 = 0,
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

const Frame = struct {
    depth: u32 = 0,
    name: ?[]u8 = null,
    function: ?[]u8 = null,
    file: ?[]u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    address: u64 = 0,

    fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.function) |function| allocator.free(function);
        if (self.file) |file| allocator.free(file);
        self.* = undefined;
    }
};

const SourceView = struct {
    name: ?[]const u8 = null,
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    address: u64 = 0,
};

const Sample = struct {
    id: u64 = 0,
    seen: bool = false,
    seq: u64 = 0,
    time_ns: u64 = 0,
    thread: u64 = 0,
    name: ?[]u8 = null,
    sample_kind: ?[]u8 = null,
    function: ?[]u8 = null,
    file: ?[]u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    address: u64 = 0,
    weight: u64 = 1,
    frames: std.ArrayListUnmanaged(Frame) = .empty,

    fn deinit(self: *Sample, allocator: std.mem.Allocator) void {
        self.clearHeader(allocator);
        for (self.frames.items) |*frame| frame.deinit(allocator);
        self.frames.deinit(allocator);
        self.* = undefined;
    }

    fn clearHeader(self: *Sample, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.sample_kind) |sample_kind| allocator.free(sample_kind);
        if (self.function) |function| allocator.free(function);
        if (self.file) |file| allocator.free(file);
        self.name = null;
        self.sample_kind = null;
        self.function = null;
        self.file = null;
    }

    fn sortFrames(self: *Sample) void {
        std.mem.sort(Frame, self.frames.items, {}, frameLessThan);
    }

    fn kind(self: Sample) []const u8 {
        return self.sample_kind orelse "manual";
    }

    fn source(self: Sample) SourceView {
        if (self.file != null or self.function != null or self.address != 0) {
            return .{
                .name = self.name,
                .function = self.function,
                .file = self.file,
                .line = self.line,
                .column = self.column,
                .address = self.address,
            };
        }
        if (self.frames.items.len != 0) {
            const frame = self.frames.items[self.frames.items.len - 1];
            return .{
                .name = frame.name,
                .function = frame.function,
                .file = frame.file,
                .line = frame.line,
                .column = frame.column,
                .address = frame.address,
            };
        }
        return .{ .name = self.name, .address = self.address };
    }
};

pub const Summary = struct {
    group: Group,
    label: []u8,
    count: u64 = 0,
    weight: u64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,
    thread: ?u64 = null,
    kind: ?[]const u8 = null,
    name: ?[]const u8 = null,
    file: ?[]const u8 = null,
    function: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    address: u64 = 0,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        self.* = undefined;
    }
};

const Occurrence = struct {
    sample: *const Sample,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    samples: std.AutoHashMapUnmanaged(u64, Sample) = .{},
    threads: std.AutoHashMapUnmanaged(u64, ThreadName) = .{},
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,
    next_anonymous_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        var sample_iter = self.samples.valueIterator();
        while (sample_iter.next()) |sample| sample.deinit(self.allocator);
        self.samples.deinit(self.allocator);
        var thread_iter = self.threads.valueIterator();
        while (thread_iter.next()) |thread| thread.deinit(self.allocator);
        self.threads.deinit(self.allocator);
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
            .sample => try self.recordSample(parsed),
            .sample_frame => try self.recordFrame(parsed),
            else => {},
        }
    }

    pub fn collectSummaries(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Summary) {
        self.prepareSamples();
        var summaries: std.ArrayListUnmanaged(Summary) = .empty;
        errdefer deinitSummaries(allocator, &summaries);
        var groups: std.StringHashMapUnmanaged(usize) = .{};
        defer groups.deinit(allocator);

        self.counters.filtered = 0;
        var iter = self.samples.valueIterator();
        while (iter.next()) |sample| {
            if (!sample.seen) continue;
            if (!self.sampleMatches(sample.*, options)) {
                self.counters.filtered += 1;
                continue;
            }
            const label = try self.groupLabel(allocator, sample.*, options.group);
            errdefer allocator.free(label);
            const group_entry = try groups.getOrPut(allocator, label);
            var summary_index: usize = undefined;
            if (group_entry.found_existing) {
                allocator.free(label);
                summary_index = group_entry.value_ptr.*;
            } else {
                group_entry.key_ptr.* = label;
                summary_index = summaries.items.len;
                group_entry.value_ptr.* = summary_index;
                const src = sample.source();
                try summaries.append(allocator, .{
                    .group = options.group,
                    .label = label,
                    .thread = if (options.group == .thread) sample.thread else null,
                    .kind = if (options.group == .kind) sample.kind() else null,
                    .name = src.name,
                    .file = src.file,
                    .function = src.function,
                    .line = src.line,
                    .column = src.column,
                    .address = src.address,
                });
            }
            const summary = &summaries.items[summary_index];
            summary.count += 1;
            summary.weight +|= sample.weight;
            if (summary.first_ns == 0 or sample.time_ns < summary.first_ns) summary.first_ns = sample.time_ns;
            summary.last_ns = @max(summary.last_ns, sample.time_ns);
            if (summary.kind == null) summary.kind = sample.kind();
            if (summary.thread == null and options.group == .thread) summary.thread = sample.thread;
        }

        self.counters.groups = @intCast(summaries.items.len);
        self.counters.duration_ns = self.durationNs();
        sortSummaries(summaries.items, options.sort);
        return summaries;
    }

    pub fn collectOccurrences(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Occurrence) {
        self.prepareSamples();
        var occurrences: std.ArrayListUnmanaged(Occurrence) = .empty;
        var iter = self.samples.valueIterator();
        while (iter.next()) |sample| {
            if (!sample.seen) continue;
            if (!self.sampleMatches(sample.*, options)) continue;
            try occurrences.append(allocator, .{ .sample = sample });
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

    fn recordThreadName(self: *Analyzer, parsed: event.Parsed) !void {
        const name = parsed.name orelse return;
        const entry = try self.threads.getOrPut(self.allocator, parsed.thread);
        if (entry.found_existing) entry.value_ptr.deinit(self.allocator);
        entry.value_ptr.* = .{ .name = try self.allocator.dupe(u8, name) };
    }

    fn recordSample(self: *Analyzer, parsed: event.Parsed) !void {
        const key = self.sampleKey(parsed);
        const entry = try self.samples.getOrPut(self.allocator, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .id = parsed.id };
        } else {
            entry.value_ptr.clearHeader(self.allocator);
        }
        entry.value_ptr.* = .{
            .id = parsed.id,
            .seen = true,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .thread = parsed.thread,
            .name = try dupeOptional(self.allocator, parsed.name),
            .sample_kind = try dupeOptional(self.allocator, parsed.sample_kind),
            .function = try dupeOptional(self.allocator, parsed.function),
            .file = try dupeOptional(self.allocator, parsed.file),
            .line = parsed.line,
            .column = parsed.column,
            .address = parsed.address,
            .weight = parsed.value_u64 orelse 1,
            .frames = entry.value_ptr.frames,
        };
        self.counters.samples += 1;
    }

    fn recordFrame(self: *Analyzer, parsed: event.Parsed) !void {
        if (parsed.id == 0) return;
        const entry = try self.samples.getOrPut(self.allocator, parsed.id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .id = parsed.id };
        try entry.value_ptr.frames.append(self.allocator, .{
            .depth = parsed.depth,
            .name = try dupeOptional(self.allocator, parsed.name),
            .function = try dupeOptional(self.allocator, parsed.function),
            .file = try dupeOptional(self.allocator, parsed.file),
            .line = parsed.line,
            .column = parsed.column,
            .address = parsed.address,
        });
        self.counters.frames += 1;
    }

    fn sampleKey(self: *Analyzer, parsed: event.Parsed) u64 {
        if (parsed.id != 0) return parsed.id;
        const key = std.math.maxInt(u64) - self.next_anonymous_id;
        self.next_anonymous_id +|= 1;
        return key;
    }

    fn prepareSamples(self: *Analyzer) void {
        var iter = self.samples.valueIterator();
        while (iter.next()) |sample| sample.sortFrames();
    }

    fn sampleMatches(self: *Analyzer, sample: Sample, options: Options) bool {
        if (options.thread) |thread| {
            if (sample.thread != thread) return false;
        }
        if (options.since_ns) |since_ns| {
            if (sample.time_ns < since_ns) return false;
        }
        if (options.until_ns) |until_ns| {
            if (sample.time_ns > until_ns) return false;
        }
        if (sample.weight < options.min_weight) return false;
        if (options.kind) |kind| {
            if (!textEquals(sample.kind(), kind, options.ignore_case)) return false;
        }
        if (options.match) |needle| {
            if (!self.sampleContains(sample, needle, options.ignore_case)) return false;
        }
        return true;
    }

    fn sampleContains(self: *Analyzer, sample: Sample, needle: []const u8, ignore_case: bool) bool {
        if (sample.name) |name| if (contains(name, needle, ignore_case)) return true;
        if (contains(sample.kind(), needle, ignore_case)) return true;
        if (sample.file) |file| if (contains(file, needle, ignore_case)) return true;
        if (sample.function) |function| if (contains(function, needle, ignore_case)) return true;
        if (self.threadName(sample.thread)) |thread_name| if (contains(thread_name, needle, ignore_case)) return true;
        for (sample.frames.items) |frame| {
            if (frame.name) |name| if (contains(name, needle, ignore_case)) return true;
            if (frame.file) |file| if (contains(file, needle, ignore_case)) return true;
            if (frame.function) |function| if (contains(function, needle, ignore_case)) return true;
        }
        return false;
    }

    fn groupLabel(self: *Analyzer, allocator: std.mem.Allocator, sample: Sample, group: Group) ![]u8 {
        var writer = std.Io.Writer.Allocating.init(allocator);
        defer writer.deinit();
        switch (group) {
            .source => try writeSourceLabel(&writer.writer, sample),
            .symbol => try writeSymbolLabel(&writer.writer, sample),
            .stack => try writeStackLabel(&writer.writer, sample),
            .thread => {
                try writer.writer.print("thread {d}", .{sample.thread});
                if (self.threadName(sample.thread)) |thread_name| {
                    try writer.writer.writeAll(" ");
                    try writer.writer.writeAll(thread_name);
                }
            },
            .kind => try writer.writer.writeAll(sample.kind()),
            .none => try writer.writer.print("sample {d} {d}", .{ sample.id, sample.time_ns }),
        }
        return try allocator.dupe(u8, writer.written());
    }

    fn threadName(self: *Analyzer, thread: u64) ?[]const u8 {
        const entry = self.threads.get(thread) orelse return null;
        return entry.name;
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
        "tracy samples groups={d} samples={d} frames={d} filtered={d} duration_ns={d} group={s} sort={s}\n",
        .{
            summaries.items.len,
            analyzer.counters.samples,
            analyzer.counters.frames,
            analyzer.counters.filtered,
            analyzer.durationNs(),
            options.group.tag(),
            options.sort.tag(),
        },
    );
    const summary_limit = @min(options.top, summaries.items.len);
    for (summaries.items[0..summary_limit]) |summary| {
        try writer.print("sample group={s} label=", .{summary.group.tag()});
        try pretty_json.writeString(writer, summary.label);
        try writer.print(" count={d} weight={d} first_ns={d} last_ns={d}", .{ summary.count, summary.weight, summary.first_ns, summary.last_ns });
        if (summary.kind) |kind| {
            try writer.writeAll(" kind=");
            try pretty_json.writeString(writer, kind);
        }
        if (summary.thread) |thread| try writer.print(" thread={d}", .{thread});
        if (summary.file) |file| try writer.print(" file={s}:{d}", .{ file, summary.line });
        if (summary.function) |function| {
            try writer.writeAll(" function=");
            try pretty_json.writeString(writer, function);
        }
        if (summary.address != 0) try writer.print(" address={d}", .{summary.address});
        try writer.writeByte('\n');
    }

    const occurrence_limit = @min(options.occurrences, occurrences.items.len);
    for (occurrences.items[0..occurrence_limit]) |occurrence| {
        const sample = occurrence.sample;
        try writer.print("sample-occurrence time_ns={d} thread={d}", .{ sample.time_ns, sample.thread });
        if (sample.id != 0) try writer.print(" id={d}", .{sample.id});
        if (sample.name) |name| {
            try writer.writeAll(" name=");
            try pretty_json.writeString(writer, name);
        }
        try writer.writeAll(" kind=");
        try pretty_json.writeString(writer, sample.kind());
        try writer.print(" weight={d}", .{sample.weight});
        try writeSourceText(writer, sample.*);
        if (sample.frames.items.len != 0) {
            const stack = try stackLabel(allocator, sample.*);
            defer allocator.free(stack);
            try writer.writeAll(" stack=");
            try pretty_json.writeString(writer, stack);
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
    var summaries = try analyzer.collectSummaries(allocator, options);
    defer deinitSummaries(allocator, &summaries);
    var occurrences = try analyzer.collectOccurrences(allocator, options);
    defer occurrences.deinit(allocator);

    var summary_stream = pretty_json.Writer.init(writer, .minified);
    const summary_record = try summary_stream.object();
    try summary_record.field("schema", schema);
    try summary_record.field("kind", "summary");
    try summary_record.field("groups", summaries.items.len);
    try summary_record.field("samples", analyzer.counters.samples);
    try summary_record.field("frames", analyzer.counters.frames);
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
        try object.field("weight", summary.weight);
        try object.field("first_ns", summary.first_ns);
        try object.field("last_ns", summary.last_ns);
        if (summary.kind) |kind| try object.field("sample_kind", kind);
        if (summary.thread) |thread| try object.field("thread", thread);
        if (summary.file) |file| {
            try object.field("file", file);
            try object.field("line", summary.line);
        }
        if (summary.function) |function| try object.field("function", function);
        if (summary.address != 0) try object.field("address", summary.address);
        try object.endLine();
    }

    const occurrence_limit = @min(options.occurrences, occurrences.items.len);
    for (occurrences.items[0..occurrence_limit]) |occurrence| {
        const sample = occurrence.sample;
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "sample");
        try object.field("time_ns", sample.time_ns);
        try object.field("thread", sample.thread);
        if (sample.id != 0) try object.field("id", sample.id);
        if (sample.name) |name| try object.field("name", name);
        try object.field("sample_kind", sample.kind());
        try object.field("weight", sample.weight);
        try writeSourceFields(object, sample.*);
        if (sample.frames.items.len != 0) {
            const stack = try stackLabel(allocator, sample.*);
            defer allocator.free(stack);
            try object.field("stack", stack);
        }
        try object.endLine();
    }
}

fn writeSourceText(writer: *std.Io.Writer, sample: Sample) !void {
    const src = sample.source();
    if (src.file) |file| try writer.print(" file={s}:{d}", .{ file, src.line });
    if (src.function) |function| {
        try writer.writeAll(" function=");
        try pretty_json.writeString(writer, function);
    }
    if (src.address != 0) try writer.print(" address={d}", .{src.address});
}

fn writeSourceFields(object: pretty_json.Object, sample: Sample) !void {
    const src = sample.source();
    if (src.file) |file| {
        try object.field("file", file);
        try object.field("line", src.line);
    }
    if (src.function) |function| try object.field("function", function);
    if (src.address != 0) try object.field("address", src.address);
}

fn writeSourceLabel(writer: *std.Io.Writer, sample: Sample) !void {
    const src = sample.source();
    if (src.file) |file| {
        try writer.print("{s}:{d}", .{ file, src.line });
    } else {
        try writeSymbolLabel(writer, sample);
    }
}

fn writeSymbolLabel(writer: *std.Io.Writer, sample: Sample) !void {
    const src = sample.source();
    if (src.function) |function| {
        try writer.writeAll(function);
    } else if (src.name) |name| {
        try writer.writeAll(name);
    } else if (sample.name) |name| {
        try writer.writeAll(name);
    } else if (src.address != 0) {
        try writer.print("0x{x}", .{src.address});
    } else {
        try writer.writeAll("<sample>");
    }
}

fn writeStackLabel(writer: *std.Io.Writer, sample: Sample) !void {
    if (sample.frames.items.len == 0) return try writeSymbolLabel(writer, sample);
    for (sample.frames.items, 0..) |frame, index| {
        if (index != 0) try writer.writeByte(';');
        try writeFrameLabel(writer, frame);
    }
}

fn writeFrameLabel(writer: *std.Io.Writer, frame: Frame) !void {
    if (frame.name) |name| {
        try writer.writeAll(name);
    } else if (frame.function) |function| {
        try writer.writeAll(function);
    } else if (frame.file) |file| {
        try writer.print("{s}:{d}", .{ file, frame.line });
    } else if (frame.address != 0) {
        try writer.print("0x{x}", .{frame.address});
    } else {
        try writer.writeAll("<frame>");
    }
}

fn stackLabel(allocator: std.mem.Allocator, sample: Sample) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try writeStackLabel(&writer.writer, sample);
    return try allocator.dupe(u8, writer.written());
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
}

fn frameLessThan(_: void, left: Frame, right: Frame) bool {
    if (left.depth != right.depth) return left.depth < right.depth;
    return left.address < right.address;
}

fn sortSummaries(items: []Summary, sort: Sort) void {
    std.mem.sort(Summary, items, sort, summaryLessThan);
}

fn summaryLessThan(sort: Sort, left: Summary, right: Summary) bool {
    return switch (sort) {
        .samples => summarySamplesGreaterThan({}, left, right),
        .weight => summaryWeightGreaterThan({}, left, right),
        .last => summaryLastGreaterThan({}, left, right),
        .first => summaryFirstLessThan({}, left, right),
        .thread => summaryThreadLessThan({}, left, right),
        .name => summaryNameLessThan({}, left, right),
        .kind => summaryKindLessThan({}, left, right),
    };
}

fn summarySamplesGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.count != right.count) return left.count > right.count;
    if (left.weight != right.weight) return left.weight > right.weight;
    return std.mem.lessThan(u8, left.label, right.label);
}

fn summaryWeightGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.weight != right.weight) return left.weight > right.weight;
    return summarySamplesGreaterThan({}, left, right);
}

fn summaryLastGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.last_ns != right.last_ns) return left.last_ns > right.last_ns;
    return summarySamplesGreaterThan({}, left, right);
}

fn summaryFirstLessThan(_: void, left: Summary, right: Summary) bool {
    if (left.first_ns != right.first_ns) return left.first_ns < right.first_ns;
    return summarySamplesGreaterThan({}, left, right);
}

fn summaryThreadLessThan(_: void, left: Summary, right: Summary) bool {
    const left_thread = left.thread orelse 0;
    const right_thread = right.thread orelse 0;
    if (left_thread != right_thread) return left_thread < right_thread;
    return summarySamplesGreaterThan({}, left, right);
}

fn summaryNameLessThan(_: void, left: Summary, right: Summary) bool {
    return std.mem.lessThan(u8, left.label, right.label);
}

fn summaryKindLessThan(_: void, left: Summary, right: Summary) bool {
    const left_kind = left.kind orelse "";
    const right_kind = right.kind orelse "";
    if (!std.mem.eql(u8, left_kind, right_kind)) return std.mem.lessThan(u8, left_kind, right_kind);
    return summarySamplesGreaterThan({}, left, right);
}

fn sortOccurrences(items: []Occurrence, sort: Sort) void {
    switch (sort) {
        .last, .weight => std.mem.sort(Occurrence, items, {}, occurrenceTimeGreaterThan),
        else => std.mem.sort(Occurrence, items, {}, occurrenceTimeLessThan),
    }
}

fn occurrenceTimeLessThan(_: void, left: Occurrence, right: Occurrence) bool {
    if (left.sample.time_ns != right.sample.time_ns) return left.sample.time_ns < right.sample.time_ns;
    return left.sample.seq < right.sample.seq;
}

fn occurrenceTimeGreaterThan(_: void, left: Occurrence, right: Occurrence) bool {
    if (left.sample.time_ns != right.sample.time_ns) return left.sample.time_ns > right.sample.time_ns;
    return left.sample.seq > right.sample.seq;
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

fn textEquals(left: []const u8, right: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.eql(u8, left, right);
    return asciiEqlIgnoreCase(left, right);
}

fn asciiEqlIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

test "samples aggregate stacks and source locations" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 90, .thread = 7, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .thread_name, .time_ns = 95, .thread = 7, .name = "worker" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .sample, .time_ns = 100, .thread = 7, .id = 1, .name = "tick", .function = "leaf", .file = "leaf.zig", .line = 9, .sample_kind = "cpu" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .sample_frame, .time_ns = 100, .thread = 7, .id = 1, .depth = 0, .name = "root", .function = "root", .file = "root.zig", .line = 1 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .sample_frame, .time_ns = 100, .thread = 7, .id = 1, .depth = 1, .name = "leaf", .function = "leaf", .file = "leaf.zig", .line = 9 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .sample, .time_ns = 120, .thread = 7, .id = 2, .name = "tick", .function = "leaf", .file = "leaf.zig", .line = 9, .value_u64 = 2, .sample_kind = "cpu" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .sample_frame, .time_ns = 120, .thread = 7, .id = 2, .depth = 0, .name = "root" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 8, .kind = .sample_frame, .time_ns = 120, .thread = 7, .id = 2, .depth = 1, .name = "leaf" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 9, .kind = .stop, .time_ns = 130, .thread = 7 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 2), analyzer.counters.samples);
    try std.testing.expectEqual(@as(u64, 4), analyzer.counters.frames);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .group = .stack, .sort = .samples, .top = 4, .occurrences = 4 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy samples groups=1 samples=2 frames=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "label=\"root;leaf\" count=2 weight=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sample-occurrence time_ns=100 thread=7 id=1 name=\"tick\" kind=\"cpu\" weight=1 file=leaf.zig:9 function=\"leaf\" stack=\"root;leaf\"") != null);
}

test "samples jsonl filters by kind thread and match text" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .sample, .time_ns = 100, .thread = 1, .id = 1, .name = "idle", .function = "idle", .file = "idle.zig", .line = 1, .sample_kind = "wall" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .sample, .time_ns = 110, .thread = 2, .id = 2, .name = "parse", .function = "parse", .file = "parse.zig", .line = 7, .sample_kind = "cpu" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .sample_frame, .time_ns = 110, .thread = 2, .id = 2, .name = "parse" }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{ .group = .source, .kind = "cpu", .thread = 2, .match = "PARSE", .ignore_case = true });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.samples/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"summary\",\"groups\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"label\":\"parse.zig:7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"idle\"") == null);
}
