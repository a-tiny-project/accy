const std = @import("std");
const pretty_json = @import("pretty").json;
const capture_mod = @import("capture.zig");
const report = @import("report.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");

pub const schema = "tracy.frames/v0";

pub const Sort = enum {
    max,
    total,
    mean,
    count,
    name,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "max")) return .max;
        if (std.mem.eql(u8, text, "total")) return .total;
        if (std.mem.eql(u8, text, "mean")) return .mean;
        if (std.mem.eql(u8, text, "count")) return .count;
        if (std.mem.eql(u8, text, "name")) return .name;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .max => "max",
            .total => "total",
            .mean => "mean",
            .count => "count",
            .name => "name",
        };
    }
};

pub const Options = struct {
    top: usize = 20,
    sort: Sort = .max,
    min_frame_ns: u64 = 0,
    budget_ns: ?u64 = null,
    set: ?[]const u8 = null,
};

pub const Counters = struct {
    marks: u64 = 0,
    frames: u64 = 0,
    out_of_order_marks: u64 = 0,
};

pub const CaptureIntegrity = capture_mod.Integrity;

const FrameRecord = struct {
    index: u64,
    start_ns: u64,
    end_ns: u64,
    duration_ns: u64,
    thread: u64,
};

const FrameSet = struct {
    name: []const u8,
    marks: u64 = 0,
    frames: std.ArrayListUnmanaged(FrameRecord) = .empty,
    threads: std.ArrayListUnmanaged(u64) = .empty,
    first_ns: ?u64 = null,
    last_ns: ?u64 = null,
    last_mark_ns: ?u64 = null,
    last_thread: u64 = 0,
    total_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,

    fn deinit(self: *FrameSet, allocator: std.mem.Allocator) void {
        self.frames.deinit(allocator);
        self.threads.deinit(allocator);
        self.* = undefined;
    }

    fn meanNs(self: FrameSet) u64 {
        if (self.frames.items.len == 0) return 0;
        return self.total_ns / self.frames.items.len;
    }

    fn threadCount(self: FrameSet) u64 {
        return @intCast(self.threads.items.len);
    }
};

pub const Summary = struct {
    name: []const u8,
    marks: u64,
    frames: u64,
    total_ns: u64,
    mean_ns: u64,
    min_ns: u64,
    p50_ns: u64,
    p90_ns: u64,
    p99_ns: u64,
    max_ns: u64,
    first_ns: u64,
    last_ns: u64,
    threads: u64,
    frame_time_discrepancy_ns: u64,
    budget: ?BudgetSummary,
};

const SlowFrameView = struct {
    set: []const u8,
    index: u64,
    start_ns: u64,
    end_ns: u64,
    duration_ns: u64,
    thread: u64,
    budget: ?FrameBudget,
};

pub const BudgetSummary = struct {
    budget_ns: u64,
    over_budget_frames: u64 = 0,
    estimated_missed_intervals: u64 = 0,
    total_overrun_ns: u64 = 0,
    max_overrun_ns: u64 = 0,
    longest_overrun_streak: u64 = 0,
    longest_overrun_start_index: u64 = 0,
    longest_overrun_end_index: u64 = 0,
    longest_overrun_start_ns: u64 = 0,
    longest_overrun_end_ns: u64 = 0,
    longest_overrun_set: ?[]const u8 = null,
};

const FrameBudget = struct {
    budget_ns: u64,
    over_budget: bool,
    overrun_ns: u64,
    estimated_missed_intervals: u64,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    capture: capture_mod.Tracker = .{},
    sets: std.StringHashMapUnmanaged(FrameSet) = .{},
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        var iter = self.sets.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.sets.deinit(self.allocator);
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
            .flight => |report_value| self.capture.recordFlightReport(report_value),
        }
    }

    pub fn ingest(self: *Analyzer, parsed: event.Parsed) !void {
        self.capture.record(parsed);
        if (self.start_ns == null and parsed.time_ns != 0) self.start_ns = parsed.time_ns;
        if (parsed.time_ns != 0) self.end_ns = parsed.time_ns;
        switch (parsed.kind) {
            .start => {
                if (parsed.time_ns != 0) self.start_ns = parsed.time_ns;
            },
            .stop => {
                if (parsed.time_ns != 0) self.end_ns = parsed.time_ns;
            },
            .frame => try self.recordFrame(parsed),
            else => {},
        }
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

    fn recordFrame(self: *Analyzer, parsed: event.Parsed) !void {
        const name = parsed.name orelse "default";
        const set = try self.frameSet(name);
        set.marks += 1;
        std.debug.assert(set.marks > 0);
        try appendThread(self.allocator, &set.threads, parsed.thread);
        if (set.first_ns == null) set.first_ns = parsed.time_ns;
        if (set.last_mark_ns) |last_mark_ns| {
            if (parsed.time_ns < last_mark_ns) {
                self.counters.out_of_order_marks += 1;
                self.counters.marks += 1;
                return;
            }
            const duration = parsed.time_ns - last_mark_ns;
            const index: u64 = @intCast(set.frames.items.len + 1);
            try set.frames.append(self.allocator, .{
                .index = index,
                .start_ns = last_mark_ns,
                .end_ns = parsed.time_ns,
                .duration_ns = duration,
                .thread = set.last_thread,
            });
            std.debug.assert(set.frames.items[set.frames.items.len - 1].end_ns >= last_mark_ns);
            set.total_ns +|= duration;
            set.min_ns = @min(set.min_ns, duration);
            set.max_ns = @max(set.max_ns, duration);
            self.counters.frames += 1;
            std.debug.assert(set.frames.items.len <= set.marks);
        }
        set.last_mark_ns = parsed.time_ns;
        set.last_thread = parsed.thread;
        set.last_ns = parsed.time_ns;
        self.counters.marks += 1;
    }

    fn frameSet(self: *Analyzer, name: []const u8) !*FrameSet {
        const entry = try self.sets.getOrPut(self.allocator, name);
        if (!entry.found_existing) {
            const owned_name = try self.allocator.dupe(u8, name);
            entry.key_ptr.* = owned_name;
            entry.value_ptr.* = .{ .name = owned_name };
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
    try validateOptions(options);
    var sets = try collectSummaries(allocator, analyzer, options);
    defer sets.deinit(allocator);
    var slow_frames = try collectSlowFrames(allocator, analyzer, options);
    defer slow_frames.deinit(allocator);
    const budget = combinedBudget(sets.items, options.budget_ns);

    try writer.print(
        "tracy frames sets={d} marks={d} frames={d} out_of_order_marks={d}" ++
            " duration_ns={d} sort={s}",
        .{
            sets.items.len,
            analyzer.counters.marks,
            analyzer.counters.frames,
            analyzer.counters.out_of_order_marks,
            analyzer.durationNs(),
            options.sort.tag(),
        },
    );
    try writeBudgetText(writer, budget);
    try writer.writeByte('\n');
    try capture_mod.writeText(writer, analyzer.captureIntegrity());
    const set_limit = @min(options.top, sets.items.len);
    for (sets.items[0..set_limit]) |set| {
        try writer.writeAll("frame-set name=");
        try pretty_json.writeString(writer, set.name);
        try writer.print(
            " marks={d} frames={d} total_ns={d} mean_ns={d} min_ns={d}" ++
                " p50_ns={d} p90_ns={d} p99_ns={d} max_ns={d}" ++
                " first_ns={d} last_ns={d} threads={d}" ++
                " frame_time_discrepancy_ns={d}",
            .{
                set.marks,
                set.frames,
                set.total_ns,
                set.mean_ns,
                set.min_ns,
                set.p50_ns,
                set.p90_ns,
                set.p99_ns,
                set.max_ns,
                set.first_ns,
                set.last_ns,
                set.threads,
                set.frame_time_discrepancy_ns,
            },
        );
        try writeBudgetText(writer, set.budget);
        try writer.writeByte('\n');
    }
    const slow_limit = @min(options.top, slow_frames.items.len);
    for (slow_frames.items[0..slow_limit]) |frame| {
        try writer.writeAll("slow-frame set=");
        try pretty_json.writeString(writer, frame.set);
        try writer.print(
            " index={d} duration_ns={d} start_ns={d} end_ns={d} thread={d}",
            .{ frame.index, frame.duration_ns, frame.start_ns, frame.end_ns, frame.thread },
        );
        try writeFrameBudgetText(writer, frame.budget);
        try writer.writeByte('\n');
    }
}

fn writeJsonl(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    try validateOptions(options);
    var sets = try collectSummaries(allocator, analyzer, options);
    defer sets.deinit(allocator);
    var slow_frames = try collectSlowFrames(allocator, analyzer, options);
    defer slow_frames.deinit(allocator);
    const budget = combinedBudget(sets.items, options.budget_ns);

    try writeJsonSummary(writer, analyzer, sets.items.len, options.sort, budget);

    const set_limit = @min(options.top, sets.items.len);
    for (sets.items[0..set_limit]) |set| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "set");
        try object.field("name", set.name);
        try object.field("marks", set.marks);
        try object.field("frames", set.frames);
        try object.field("total_ns", set.total_ns);
        try object.field("mean_ns", set.mean_ns);
        try object.field("min_ns", set.min_ns);
        try object.field("p50_ns", set.p50_ns);
        try object.field("p90_ns", set.p90_ns);
        try object.field("p99_ns", set.p99_ns);
        try object.field("max_ns", set.max_ns);
        try object.field("first_ns", set.first_ns);
        try object.field("last_ns", set.last_ns);
        try object.field("threads", set.threads);
        try object.field("frame_time_discrepancy_ns", set.frame_time_discrepancy_ns);
        try writeBudgetField(object, set.budget);
        try object.endLine();
    }

    const slow_limit = @min(options.top, slow_frames.items.len);
    for (slow_frames.items[0..slow_limit]) |frame| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "slow_frame");
        try object.field("set", frame.set);
        try object.field("index", frame.index);
        try object.field("duration_ns", frame.duration_ns);
        try object.field("start_ns", frame.start_ns);
        try object.field("end_ns", frame.end_ns);
        try object.field("thread", frame.thread);
        try writeFrameBudgetField(object, frame.budget);
        try object.endLine();
    }
}

fn writeJsonSummary(
    writer: *std.Io.Writer,
    analyzer: *Analyzer,
    set_count: usize,
    sort: Sort,
    budget: ?BudgetSummary,
) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "summary");
    try object.field("sets", set_count);
    try object.field("marks", analyzer.counters.marks);
    try object.field("frames", analyzer.counters.frames);
    try object.field("out_of_order_marks", analyzer.counters.out_of_order_marks);
    try object.field("duration_ns", analyzer.durationNs());
    try object.field("sort", sort.tag());
    try writeBudgetField(object, budget);
    try capture_mod.writeFields(object, analyzer.captureIntegrity());
    try object.endLine();
}

pub fn collectSummaries(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    options: Options,
) !std.ArrayListUnmanaged(Summary) {
    if (options.budget_ns) |budget| std.debug.assert(budget > 0);
    var views: std.ArrayListUnmanaged(Summary) = .empty;
    errdefer views.deinit(allocator);
    var iter = analyzer.sets.valueIterator();
    while (iter.next()) |set| {
        if (options.set) |wanted| {
            if (!std.mem.eql(u8, wanted, set.name)) continue;
        }
        const view = try setView(allocator, set.*, options.budget_ns);
        if (view.frames == 0 and options.min_frame_ns != 0) continue;
        if (view.max_ns < options.min_frame_ns) continue;
        try views.append(allocator, view);
    }
    sortSetViews(views.items, options.sort);
    return views;
}

fn collectSlowFrames(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    options: Options,
) !std.ArrayListUnmanaged(SlowFrameView) {
    if (options.budget_ns) |budget| std.debug.assert(budget > 0);
    var rows: std.ArrayListUnmanaged(SlowFrameView) = .empty;
    errdefer rows.deinit(allocator);
    var iter = analyzer.sets.valueIterator();
    while (iter.next()) |set| {
        if (options.set) |wanted| {
            if (!std.mem.eql(u8, wanted, set.name)) continue;
        }
        for (set.frames.items) |frame| {
            if (frame.duration_ns < options.min_frame_ns) continue;
            try rows.append(allocator, .{
                .set = set.name,
                .index = frame.index,
                .start_ns = frame.start_ns,
                .end_ns = frame.end_ns,
                .duration_ns = frame.duration_ns,
                .thread = frame.thread,
                .budget = frameBudget(frame.duration_ns, options.budget_ns),
            });
        }
    }
    std.mem.sort(SlowFrameView, rows.items, {}, slowFrameGreaterThan);
    return rows;
}

fn setView(
    allocator: std.mem.Allocator,
    set: FrameSet,
    budget_ns: ?u64,
) !Summary {
    std.debug.assert(set.frames.items.len <= set.marks);
    var durations = try allocator.alloc(u64, set.frames.items.len);
    defer allocator.free(durations);
    for (set.frames.items, 0..) |frame, index| durations[index] = frame.duration_ns;
    std.mem.sort(u64, durations, {}, std.sort.asc(u64));
    return .{
        .name = set.name,
        .marks = set.marks,
        .frames = @intCast(set.frames.items.len),
        .total_ns = set.total_ns,
        .mean_ns = set.meanNs(),
        .min_ns = if (set.min_ns == std.math.maxInt(u64)) 0 else set.min_ns,
        .p50_ns = percentile(durations, 50),
        .p90_ns = percentile(durations, 90),
        .p99_ns = percentile(durations, 99),
        .max_ns = set.max_ns,
        .first_ns = set.first_ns orelse 0,
        .last_ns = set.last_ns orelse 0,
        .threads = set.threadCount(),
        .frame_time_discrepancy_ns = frameTimeDiscrepancyNs(set.frames.items),
        .budget = budgetStats(set.frames.items, budget_ns),
    };
}

fn validateOptions(options: Options) !void {
    if (options.budget_ns == 0) return error.InvalidBudget;
}

fn frameBudget(duration_ns: u64, budget_ns: ?u64) ?FrameBudget {
    const budget = budget_ns orelse return null;
    std.debug.assert(budget > 0);
    const overrun = duration_ns -| budget;
    return .{
        .budget_ns = budget,
        .over_budget = duration_ns > budget,
        .overrun_ns = overrun,
        .estimated_missed_intervals = estimatedMissedIntervals(duration_ns, budget),
    };
}

fn budgetStats(frames: []const FrameRecord, budget_ns: ?u64) ?BudgetSummary {
    const budget = budget_ns orelse return null;
    std.debug.assert(budget > 0);
    var result = BudgetSummary{ .budget_ns = budget };
    var streak: u64 = 0;
    var streak_start: u64 = 0;
    var streak_start_ns: u64 = 0;
    for (frames) |frame| {
        std.debug.assert(frame.end_ns >= frame.start_ns);
        std.debug.assert(frame.duration_ns == frame.end_ns - frame.start_ns);
        if (frame.duration_ns <= budget) {
            streak = 0;
            streak_start = 0;
            streak_start_ns = 0;
            continue;
        }
        const overrun = frame.duration_ns - budget;
        result.over_budget_frames +|= 1;
        result.estimated_missed_intervals +|= estimatedMissedIntervals(
            frame.duration_ns,
            budget,
        );
        result.total_overrun_ns +|= overrun;
        result.max_overrun_ns = @max(result.max_overrun_ns, overrun);
        if (streak == 0) {
            streak_start = frame.index;
            streak_start_ns = frame.start_ns;
        }
        streak +|= 1;
        if (streak > result.longest_overrun_streak) {
            result.longest_overrun_streak = streak;
            result.longest_overrun_start_index = streak_start;
            result.longest_overrun_end_index = frame.index;
            result.longest_overrun_start_ns = streak_start_ns;
            result.longest_overrun_end_ns = frame.end_ns;
        }
    }
    if (std.math.cast(u64, frames.len)) |frame_count| {
        std.debug.assert(result.over_budget_frames <= frame_count);
    }
    return result;
}

fn combinedBudget(sets: []const Summary, budget_ns: ?u64) ?BudgetSummary {
    const budget = budget_ns orelse return null;
    var result = BudgetSummary{ .budget_ns = budget };
    for (sets) |set| {
        const current = set.budget orelse continue;
        std.debug.assert(current.budget_ns == budget);
        result.over_budget_frames +|= current.over_budget_frames;
        result.estimated_missed_intervals +|= current.estimated_missed_intervals;
        result.total_overrun_ns +|= current.total_overrun_ns;
        result.max_overrun_ns = @max(result.max_overrun_ns, current.max_overrun_ns);
        if (preferLongestOverrun(current, set.name, result)) {
            result.longest_overrun_streak = current.longest_overrun_streak;
            result.longest_overrun_start_index = current.longest_overrun_start_index;
            result.longest_overrun_end_index = current.longest_overrun_end_index;
            result.longest_overrun_start_ns = current.longest_overrun_start_ns;
            result.longest_overrun_end_ns = current.longest_overrun_end_ns;
            result.longest_overrun_set = set.name;
        }
    }
    return result;
}

fn preferLongestOverrun(
    current: BudgetSummary,
    set_name: []const u8,
    selected: BudgetSummary,
) bool {
    if (current.longest_overrun_streak > selected.longest_overrun_streak) return true;
    if (current.longest_overrun_streak < selected.longest_overrun_streak) return false;
    if (current.longest_overrun_streak == 0) return false;
    const selected_name = selected.longest_overrun_set orelse return true;
    return std.mem.lessThan(u8, set_name, selected_name);
}

fn estimatedMissedIntervals(duration_ns: u64, budget_ns: u64) u64 {
    std.debug.assert(budget_ns > 0);
    if (duration_ns <= budget_ns) return 0;
    return (duration_ns - 1) / budget_ns;
}

fn frameTimeDiscrepancyNs(frames: []const FrameRecord) u64 {
    if (frames.len == 0) return 0;
    const first_ns = frames[0].start_ns;
    const last_ns = frames[frames.len - 1].end_ns;
    if (last_ns <= first_ns) return 0;
    const range: i256 = @intCast(last_ns - first_ns);
    const intervals: i256 = @intCast(frames.len);
    const denominator = 2 * intervals;
    var minimum = -range;
    var maximum = range;
    var previous_ns = first_ns;
    for (frames, 0..) |frame, frame_index| {
        std.debug.assert(frame.start_ns == previous_ns);
        std.debug.assert(frame.end_ns >= frame.start_ns);
        std.debug.assert(frame.duration_ns == frame.end_ns - frame.start_ns);
        previous_ns = frame.end_ns;
        const point: i256 = @as(i256, @intCast(frame_index)) + 2;
        const time_ns = frame.end_ns;
        const offset: i256 = @intCast(time_ns - first_ns);
        const time_term = denominator * offset;
        const before = (2 * point - 3) * range - time_term;
        const after = (2 * point - 1) * range - time_term;
        minimum = @min(minimum, before);
        maximum = @max(maximum, after);
    }
    const spread = maximum - minimum;
    const rounded = @divTrunc(spread + denominator - 1, denominator);
    return @intCast(@min(rounded, std.math.maxInt(u64)));
}

fn percentile(sorted: []const u64, percent: u64) u64 {
    if (sorted.len == 0) return 0;
    const rank: usize = @intCast((@as(u128, percent) * sorted.len + 99) / 100);
    const index = @min(@max(rank, 1) - 1, sorted.len - 1);
    return sorted[index];
}

fn appendThread(
    allocator: std.mem.Allocator,
    threads: *std.ArrayListUnmanaged(u64),
    thread: u64,
) !void {
    for (threads.items) |existing| {
        if (existing == thread) return;
    }
    try threads.append(allocator, thread);
}

fn sortSetViews(items: []Summary, sort: Sort) void {
    switch (sort) {
        .max => std.mem.sort(Summary, items, {}, setMaxGreaterThan),
        .total => std.mem.sort(Summary, items, {}, setTotalGreaterThan),
        .mean => std.mem.sort(Summary, items, {}, setMeanGreaterThan),
        .count => std.mem.sort(Summary, items, {}, setCountGreaterThan),
        .name => std.mem.sort(Summary, items, {}, setNameLessThan),
    }
}

fn setMaxGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.max_ns != right.max_ns) return left.max_ns > right.max_ns;
    return setNameLessThan({}, left, right);
}

fn setTotalGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.total_ns != right.total_ns) return left.total_ns > right.total_ns;
    return setNameLessThan({}, left, right);
}

fn setMeanGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.mean_ns != right.mean_ns) return left.mean_ns > right.mean_ns;
    return setTotalGreaterThan({}, left, right);
}

fn setCountGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.frames != right.frames) return left.frames > right.frames;
    return setTotalGreaterThan({}, left, right);
}

fn setNameLessThan(_: void, left: Summary, right: Summary) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn slowFrameGreaterThan(_: void, left: SlowFrameView, right: SlowFrameView) bool {
    if (left.duration_ns != right.duration_ns) return left.duration_ns > right.duration_ns;
    const set_cmp = std.mem.order(u8, left.set, right.set);
    if (set_cmp != .eq) return set_cmp == .lt;
    return left.index < right.index;
}

fn writeBudgetText(writer: *std.Io.Writer, budget: ?BudgetSummary) !void {
    const value = budget orelse {
        try writer.writeAll(" budget=none");
        return;
    };
    try writer.print(
        " budget_ns={d} over_budget_frames={d} estimated_missed_intervals={d}" ++
            " total_overrun_ns={d} max_overrun_ns={d} longest_overrun_streak={d}" ++
            " longest_overrun_start_index={d} longest_overrun_end_index={d}" ++
            " longest_overrun_start_ns={d} longest_overrun_end_ns={d}",
        .{
            value.budget_ns,
            value.over_budget_frames,
            value.estimated_missed_intervals,
            value.total_overrun_ns,
            value.max_overrun_ns,
            value.longest_overrun_streak,
            value.longest_overrun_start_index,
            value.longest_overrun_end_index,
            value.longest_overrun_start_ns,
            value.longest_overrun_end_ns,
        },
    );
    if (value.longest_overrun_set) |set| {
        try writer.writeAll(" longest_overrun_set=");
        try pretty_json.writeString(writer, set);
    }
}

fn writeFrameBudgetText(writer: *std.Io.Writer, budget: ?FrameBudget) !void {
    const value = budget orelse {
        try writer.writeAll(" budget=none");
        return;
    };
    try writer.print(
        " budget_ns={d} over_budget={} overrun_ns={d} estimated_missed_intervals={d}",
        .{
            value.budget_ns,
            value.over_budget,
            value.overrun_ns,
            value.estimated_missed_intervals,
        },
    );
}

fn writeBudgetField(object: pretty_json.Object, budget: ?BudgetSummary) !void {
    const value = budget orelse {
        try object.field("budget", null);
        return;
    };
    const budget_object = try object.object("budget");
    try budget_object.field("budget_ns", value.budget_ns);
    try budget_object.field("over_budget_frames", value.over_budget_frames);
    try budget_object.field("estimated_missed_intervals", value.estimated_missed_intervals);
    try budget_object.field("total_overrun_ns", value.total_overrun_ns);
    try budget_object.field("max_overrun_ns", value.max_overrun_ns);
    try budget_object.field("longest_overrun_streak", value.longest_overrun_streak);
    try budget_object.field("longest_overrun_start_index", value.longest_overrun_start_index);
    try budget_object.field("longest_overrun_end_index", value.longest_overrun_end_index);
    try budget_object.field("longest_overrun_start_ns", value.longest_overrun_start_ns);
    try budget_object.field("longest_overrun_end_ns", value.longest_overrun_end_ns);
    if (value.longest_overrun_set) |set| try budget_object.field("longest_overrun_set", set);
    try budget_object.end();
}

fn writeFrameBudgetField(object: pretty_json.Object, budget: ?FrameBudget) !void {
    const value = budget orelse {
        try object.field("budget", null);
        return;
    };
    const budget_object = try object.object("budget");
    try budget_object.field("budget_ns", value.budget_ns);
    try budget_object.field("over_budget", value.over_budget);
    try budget_object.field("overrun_ns", value.overrun_ns);
    try budget_object.field("estimated_missed_intervals", value.estimated_missed_intervals);
    try budget_object.end();
}

test "frames aggregate named and default continuous marks" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 90, .thread = 1, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .frame, .time_ns = 100, .thread = 1, .name = "main" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .frame, .time_ns = 125, .thread = 2 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .frame, .time_ns = 130, .thread = 1, .name = "main" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .frame, .time_ns = 170, .thread = 1, .name = "main" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .frame, .time_ns = 225, .thread = 2 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .frame, .time_ns = 250, .thread = 1, .name = "main" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 8, .kind = .stop, .time_ns = 260, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 6), analyzer.counters.marks);
    try std.testing.expectEqual(@as(u64, 4), analyzer.counters.frames);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4, .sort = .name });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy frames sets=2 marks=6 frames=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "capture_integrity=complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "budget=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "frame-set name=\"main\" marks=4 frames=3 total_ns=150 mean_ns=50 min_ns=30 p50_ns=40 p90_ns=80 p99_ns=80 max_ns=80 first_ns=100 last_ns=250 threads=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "frame-set name=\"default\" marks=2 frames=1 total_ns=100 mean_ns=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "slow-frame set=\"default\" index=1 duration_ns=100 start_ns=125 end_ns=225 thread=2") != null);

    var json = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &json.writer, .{ .top = 0 });
    try std.testing.expect(std.mem.indexOf(u8, json.written(), "\"budget\":null") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json.written(),
        "\"capture_integrity\":{\"method\":\"tracy_event_sequence_and_lifecycle_v1\"",
    ) != null);
}

test "frames keep partial cadence evidence beside its capture caveat" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .frame, .time_ns = 100 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .frame, .time_ns = 125 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .stop }).writeJsonLine(&trace.writer);
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var text = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text.deinit();
    try writeText(std.testing.allocator, &analyzer, &text.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "frames=1") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text.written(),
        "capture_integrity=sequence_gaps",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text.written(),
        "action=inspect_loss_counters_or_increase_capacity",
    ) != null);

    var json = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &json.writer, .{ .top = 0 });
    try std.testing.expect(std.mem.indexOf(u8, json.written(), "\"frames\":1") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json.written(),
        "\"status\":\"sequence_gaps\"",
    ) != null);
}

test "frames jsonl emits filtered set and slow frame rows" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .frame, .time_ns = 100, .thread = 1, .name = "main" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .frame, .time_ns = 110, .thread = 1, .name = "other" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .frame, .time_ns = 190, .thread = 1, .name = "main" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .frame, .time_ns = 210, .thread = 1, .name = "other" }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{
        .top = 4,
        .set = "main",
        .min_frame_ns = 80,
        .budget_ns = 80,
    });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.frames/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"duration_ns\":90") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"slow_frame\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"over_budget_frames\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"longest_overrun_set\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"overrun_ns\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"estimated_missed_intervals\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"other\"") == null);

    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            line,
            .{},
        );
        parsed.deinit();
        line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), line_count);
}

test "frames budget counts severity and consecutive overruns" {
    const frames = [_]FrameRecord{
        .{ .index = 1, .start_ns = 0, .end_ns = 10, .duration_ns = 10, .thread = 1 },
        .{ .index = 2, .start_ns = 10, .end_ns = 31, .duration_ns = 21, .thread = 1 },
        .{ .index = 3, .start_ns = 31, .end_ns = 76, .duration_ns = 45, .thread = 1 },
        .{ .index = 4, .start_ns = 76, .end_ns = 86, .duration_ns = 10, .thread = 1 },
        .{ .index = 5, .start_ns = 86, .end_ns = 117, .duration_ns = 31, .thread = 1 },
        .{ .index = 6, .start_ns = 117, .end_ns = 149, .duration_ns = 32, .thread = 1 },
        .{ .index = 7, .start_ns = 149, .end_ns = 182, .duration_ns = 33, .thread = 1 },
        .{ .index = 8, .start_ns = 182, .end_ns = 192, .duration_ns = 10, .thread = 1 },
    };
    const budget = budgetStats(&frames, 20).?;
    try std.testing.expectEqual(@as(u64, 5), budget.over_budget_frames);
    try std.testing.expectEqual(@as(u64, 6), budget.estimated_missed_intervals);
    try std.testing.expectEqual(@as(u64, 62), budget.total_overrun_ns);
    try std.testing.expectEqual(@as(u64, 25), budget.max_overrun_ns);
    try std.testing.expectEqual(@as(u64, 3), budget.longest_overrun_streak);
    try std.testing.expectEqual(@as(u64, 5), budget.longest_overrun_start_index);
    try std.testing.expectEqual(@as(u64, 7), budget.longest_overrun_end_index);
    try std.testing.expectEqual(@as(u64, 86), budget.longest_overrun_start_ns);
    try std.testing.expectEqual(@as(u64, 182), budget.longest_overrun_end_ns);
}

test "frames do not classify exact budget equality as an overrun" {
    const exact = frameBudget(20, 20).?;
    try std.testing.expect(!exact.over_budget);
    try std.testing.expectEqual(@as(u64, 0), exact.overrun_ns);
    try std.testing.expectEqual(@as(u64, 0), exact.estimated_missed_intervals);
    try std.testing.expectEqual(@as(u64, 1), estimatedMissedIntervals(40, 20));
    try std.testing.expectEqual(@as(u64, 2), estimatedMissedIntervals(41, 20));
}

test "frames break longest overrun ties by set name" {
    var selected = BudgetSummary{
        .budget_ns = 20,
        .longest_overrun_streak = 2,
        .longest_overrun_set = "render",
    };
    const current = BudgetSummary{ .budget_ns = 20, .longest_overrun_streak = 2 };
    try std.testing.expect(preferLongestOverrun(current, "physics", selected));
    selected.longest_overrun_set = "physics";
    try std.testing.expect(!preferLongestOverrun(current, "render", selected));
}

test "frames discrepancy distinguishes clustered intervals" {
    const uniform = [_]FrameRecord{
        .{ .index = 1, .start_ns = 0, .end_ns = 10, .duration_ns = 10, .thread = 1 },
        .{ .index = 2, .start_ns = 10, .end_ns = 20, .duration_ns = 10, .thread = 1 },
        .{ .index = 3, .start_ns = 20, .end_ns = 30, .duration_ns = 10, .thread = 1 },
        .{ .index = 4, .start_ns = 30, .end_ns = 40, .duration_ns = 10, .thread = 1 },
    };
    const separated = [_]FrameRecord{
        .{ .index = 1, .start_ns = 0, .end_ns = 20, .duration_ns = 20, .thread = 1 },
        .{ .index = 2, .start_ns = 20, .end_ns = 30, .duration_ns = 10, .thread = 1 },
        .{ .index = 3, .start_ns = 30, .end_ns = 50, .duration_ns = 20, .thread = 1 },
        .{ .index = 4, .start_ns = 50, .end_ns = 60, .duration_ns = 10, .thread = 1 },
    };
    const clustered = [_]FrameRecord{
        .{ .index = 1, .start_ns = 0, .end_ns = 20, .duration_ns = 20, .thread = 1 },
        .{ .index = 2, .start_ns = 20, .end_ns = 40, .duration_ns = 20, .thread = 1 },
        .{ .index = 3, .start_ns = 40, .end_ns = 50, .duration_ns = 10, .thread = 1 },
        .{ .index = 4, .start_ns = 50, .end_ns = 60, .duration_ns = 10, .thread = 1 },
    };
    try std.testing.expectEqual(@as(u64, 10), frameTimeDiscrepancyNs(&uniform));
    try std.testing.expectEqual(@as(u64, 20), frameTimeDiscrepancyNs(&separated));
    try std.testing.expectEqual(@as(u64, 25), frameTimeDiscrepancyNs(&clustered));
}

test "frames ignore out of order marks without shifting the cadence" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .frame, .time_ns = 100, .thread = 1 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .frame, .time_ns = 90, .thread = 1 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .frame, .time_ns = 120, .thread = 1 })
        .writeJsonLine(&trace.writer);
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.frames);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.out_of_order_marks);
    const set = analyzer.sets.get("default").?;
    try std.testing.expectEqual(@as(u64, 20), set.frames.items[0].duration_ns);
}

test "frames reject a zero direct budget" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    var scratch: [1]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&scratch);
    try std.testing.expectError(
        error.InvalidBudget,
        writeText(std.testing.allocator, &analyzer, &out.writer, .{ .budget_ns = 0 }),
    );
}
