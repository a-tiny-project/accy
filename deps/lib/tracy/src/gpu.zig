const std = @import("std");
const pretty_json = @import("pretty").json;
const capture_mod = @import("capture.zig");
const report = @import("report.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");
const transport = @import("transport.zig");

pub const schema = "tracy.gpu/v1";
pub const CaptureIntegrity = capture_mod.Integrity;

pub const Group = enum {
    context,
    name,
    thread,
    annotation,
    none,

    pub fn fromName(text: []const u8) ?Group {
        if (std.mem.eql(u8, text, "context")) return .context;
        if (std.mem.eql(u8, text, "name")) return .name;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "annotation")) return .annotation;
        if (std.mem.eql(u8, text, "none")) return .none;
        return null;
    }

    fn tag(self: Group) []const u8 {
        return switch (self) {
            .context => "context",
            .name => "name",
            .thread => "thread",
            .annotation => "annotation",
            .none => "none",
        };
    }
};

pub const Sort = enum {
    gpu,
    gpu_tail,
    cpu,
    cpu_tail,
    count,
    annotations,
    last,
    context,
    thread,
    label,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "gpu")) return .gpu;
        if (std.mem.eql(u8, text, "gpu-tail")) return .gpu_tail;
        if (std.mem.eql(u8, text, "cpu")) return .cpu;
        if (std.mem.eql(u8, text, "cpu-tail")) return .cpu_tail;
        if (std.mem.eql(u8, text, "count")) return .count;
        if (std.mem.eql(u8, text, "annotations")) return .annotations;
        if (std.mem.eql(u8, text, "last")) return .last;
        if (std.mem.eql(u8, text, "context")) return .context;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "label")) return .label;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .gpu => "gpu",
            .gpu_tail => "gpu-tail",
            .cpu => "cpu",
            .cpu_tail => "cpu-tail",
            .count => "count",
            .annotations => "annotations",
            .last => "last",
            .context => "context",
            .thread => "thread",
            .label => "label",
        };
    }
};

pub const Options = struct {
    top: usize = 20,
    occurrences: usize = 80,
    group: Group = .name,
    sort: Sort = .gpu,
    context: ?u32 = null,
    thread: ?u64 = null,
    since_ns: ?u64 = null,
    until_ns: ?u64 = null,
    min_gpu_ns: u64 = 0,
    match: ?[]const u8 = null,
    ignore_case: bool = false,
};

pub const Counters = struct {
    events: u64 = 0,
    contexts: u64 = 0,
    context_names: u64 = 0,
    zone_begins: u64 = 0,
    zone_ends: u64 = 0,
    completed_zones: u64 = 0,
    gpu_times: u64 = 0,
    calibrations: u64 = 0,
    syncs: u64 = 0,
    annotation_names: u64 = 0,
    annotations: u64 = 0,
    unmatched_ends: u64 = 0,
    unmatched_times: u64 = 0,
    duplicate_queries: u64 = 0,
    duplicate_times: u64 = 0,
    gpu_duration_samples: u64 = 0,
    cpu_duration_samples: u64 = 0,
    gpu_timestamp_regressions: u64 = 0,
    cpu_timestamp_regressions: u64 = 0,
    filtered: u64 = 0,
    groups: u64 = 0,
    duration_ns: u64 = 0,
};

const QuerySide = enum {
    start,
    end,
};

const QueryRef = struct {
    zone: usize,
    side: QuerySide,
};

const StackKey = struct {
    context: u32,
    thread: u64,
};

const AnnotationKey = struct {
    context: u32,
    annotation_id: i64,
};

const StackState = struct {
    zones: std.ArrayListUnmanaged(usize) = .empty,

    fn deinit(self: *StackState, allocator: std.mem.Allocator) void {
        self.zones.deinit(allocator);
        self.* = undefined;
    }
};

const ContextState = struct {
    id: u32,
    name: ?[]u8 = null,
    context_type: ?[]u8 = null,
    period: f64 = 1.0,
    has_calibration: bool = false,
    time_diff_ns: i64 = 0,
    calibrated_gpu_time: f64 = 0,
    calibrated_cpu_time_ns: i64 = 0,
    calibration_mod: f64 = 1.0,
    zones: u64 = 0,
    completed_zones: u64 = 0,
    gpu_ns: u64 = 0,
    cpu_ns: u64 = 0,
    gpu_times: u64 = 0,
    calibrations: u64 = 0,
    syncs: u64 = 0,
    annotations: u64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    fn deinit(self: *ContextState, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.context_type) |context_type| allocator.free(context_type);
        self.* = undefined;
    }

    fn displayName(self: ContextState) []const u8 {
        return self.name orelse "";
    }

    fn scaleGpuTime(self: ContextState, gpu_time: i64) f64 {
        return @as(f64, @floatFromInt(gpu_time)) * self.period;
    }

    fn convertGpuTime(self: ContextState, gpu_time: i64) i64 {
        const scaled = self.scaleGpuTime(gpu_time);
        if (self.has_calibration) {
            return floatToI64((scaled - self.calibrated_gpu_time) * self.calibration_mod + @as(f64, @floatFromInt(self.calibrated_cpu_time_ns)));
        }
        return floatToI64(scaled) + self.time_diff_ns;
    }
};

const ZoneState = struct {
    context: u32,
    begin_query: u32,
    end_query: u32 = 0,
    thread: u64,
    name: []u8,
    file: ?[]u8 = null,
    function: ?[]u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    color: ?u32 = null,
    cpu_start_ns: u64,
    cpu_end_ns: ?u64 = null,
    gpu_start_ns: ?i64 = null,
    gpu_end_ns: ?i64 = null,
    annotations: u64 = 0,
    serial: bool = false,
    accounted: bool = false,

    fn deinit(self: *ZoneState, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.file) |file| allocator.free(file);
        if (self.function) |function| allocator.free(function);
        self.* = undefined;
    }
};

const DurationSample = struct {
    row: usize,
    duration_ns: u64,
};

const AnnotationName = struct {
    name: []u8,

    fn deinit(self: *AnnotationName, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

const AnnotationState = struct {
    label: []u8,
    context: u32,
    id: i64,
    count: u64 = 0,
    min: f64 = 0,
    max: f64 = 0,
    last: f64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    fn deinit(self: *AnnotationState, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        self.* = undefined;
    }
};

const OccurrenceKind = enum {
    context,
    context_name,
    zone_begin,
    zone_end,
    gpu_time,
    calibration,
    time_sync,
    annotation,
    annotation_name,
    zone,

    fn tag(self: OccurrenceKind) []const u8 {
        return switch (self) {
            .context => "context",
            .context_name => "context-name",
            .zone_begin => "zone-begin",
            .zone_end => "zone-end",
            .gpu_time => "gpu-time",
            .calibration => "calibration",
            .time_sync => "time-sync",
            .annotation => "annotation",
            .annotation_name => "annotation-name",
            .zone => "zone",
        };
    }
};

const Occurrence = struct {
    kind: OccurrenceKind,
    seq: u64 = 0,
    time_ns: u64 = 0,
    context: ?u32 = null,
    query: ?u32 = null,
    thread: u64 = 0,
    name: ?[]u8 = null,
    gpu_time: ?i64 = null,
    converted_gpu_ns: ?i64 = null,
    annotation_id: ?i64 = null,
    value: ?f64 = null,
    unmatched: bool = false,
    duplicate_query: bool = false,
    duplicate_time: bool = false,
    end_query: ?u32 = null,
    cpu_start_ns: ?u64 = null,
    cpu_end_ns: ?u64 = null,
    gpu_start_ns: ?i64 = null,
    gpu_end_ns: ?i64 = null,
    gpu_duration_ns: ?u64 = null,
    cpu_duration_ns: ?u64 = null,

    fn deinit(self: *Occurrence, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        self.* = undefined;
    }
};

pub const Summary = struct {
    group: Group,
    label: []u8,
    count: u64 = 0,
    context: ?u32 = null,
    thread: ?u64 = null,
    zones: u64 = 0,
    completed_zones: u64 = 0,
    gpu_ns: u64 = 0,
    cpu_ns: u64 = 0,
    gpu_duration_samples: u64 = 0,
    gpu_timestamp_regressions: u64 = 0,
    gpu_min_ns: u64 = 0,
    gpu_p50_ns: u64 = 0,
    gpu_p90_ns: u64 = 0,
    gpu_p99_ns: u64 = 0,
    gpu_max_ns: u64 = 0,
    cpu_duration_samples: u64 = 0,
    cpu_timestamp_regressions: u64 = 0,
    cpu_min_ns: u64 = 0,
    cpu_p50_ns: u64 = 0,
    cpu_p90_ns: u64 = 0,
    cpu_p99_ns: u64 = 0,
    cpu_max_ns: u64 = 0,
    gpu_times: u64 = 0,
    calibrations: u64 = 0,
    syncs: u64 = 0,
    annotations: u64 = 0,
    annotation_id: ?i64 = null,
    annotation_min: ?f64 = null,
    annotation_max: ?f64 = null,
    annotation_last: ?f64 = null,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        self.* = undefined;
    }

    pub fn meanGpuNs(self: Summary) u64 {
        if (self.gpu_duration_samples == 0) return 0;
        return self.gpu_ns / self.gpu_duration_samples;
    }

    pub fn meanCpuNs(self: Summary) u64 {
        if (self.cpu_duration_samples == 0) return 0;
        return self.cpu_ns / self.cpu_duration_samples;
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    capture: capture_mod.Tracker = .{},
    contexts: std.AutoHashMapUnmanaged(u32, ContextState) = .{},
    stacks: std.AutoHashMapUnmanaged(StackKey, StackState) = .{},
    query_refs: std.AutoHashMapUnmanaged(u64, QueryRef) = .{},
    annotation_names: std.AutoHashMapUnmanaged(AnnotationKey, AnnotationName) = .{},
    annotations: std.AutoHashMapUnmanaged(AnnotationKey, AnnotationState) = .{},
    zones: std.ArrayListUnmanaged(ZoneState) = .empty,
    occurrences: std.ArrayListUnmanaged(Occurrence) = .empty,
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        var context_iter = self.contexts.valueIterator();
        while (context_iter.next()) |context| context.deinit(self.allocator);
        self.contexts.deinit(self.allocator);
        var stack_iter = self.stacks.valueIterator();
        while (stack_iter.next()) |stack| stack.deinit(self.allocator);
        self.stacks.deinit(self.allocator);
        self.query_refs.deinit(self.allocator);
        var annotation_name_iter = self.annotation_names.valueIterator();
        while (annotation_name_iter.next()) |annotation_name| annotation_name.deinit(self.allocator);
        self.annotation_names.deinit(self.allocator);
        var annotation_iter = self.annotations.valueIterator();
        while (annotation_iter.next()) |annotation| annotation.deinit(self.allocator);
        self.annotations.deinit(self.allocator);
        for (self.zones.items) |*zone| zone.deinit(self.allocator);
        self.zones.deinit(self.allocator);
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
            .gpu_context => try self.recordContext(parsed),
            .gpu_context_name => try self.recordContextName(parsed),
            .gpu_zone_begin => try self.recordZoneBegin(parsed),
            .gpu_zone_end => try self.recordZoneEnd(parsed),
            .gpu_time => try self.recordGpuTime(parsed),
            .gpu_calibration => try self.recordCalibration(parsed),
            .gpu_time_sync => try self.recordTimeSync(parsed),
            .gpu_annotation_name => try self.recordAnnotationName(parsed),
            .gpu_annotation => try self.recordAnnotation(parsed),
            else => {},
        }
    }

    pub fn collectSummaries(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Summary) {
        var summaries: std.ArrayListUnmanaged(Summary) = .empty;
        errdefer deinitSummaries(allocator, &summaries);
        self.counters.filtered = 0;
        switch (options.group) {
            .context => {
                var iter = self.contexts.valueIterator();
                while (iter.next()) |context| {
                    if (!contextMatches(context.*, options)) {
                        self.counters.filtered += 1;
                        continue;
                    }
                    try summaries.append(allocator, try contextSummary(allocator, context.*));
                }
            },
            .name => try self.collectZoneGroups(allocator, &summaries, options, .name),
            .thread => try self.collectZoneGroups(allocator, &summaries, options, .thread),
            .annotation => {
                var iter = self.annotations.valueIterator();
                while (iter.next()) |annotation| {
                    if (!annotationMatches(annotation.*, options)) {
                        self.counters.filtered += 1;
                        continue;
                    }
                    try summaries.append(allocator, try annotationSummary(allocator, annotation.*));
                }
            },
            .none => {
                for (self.zones.items) |zone| {
                    if (!zoneMatches(zone, options)) {
                        self.counters.filtered += 1;
                        continue;
                    }
                    try summaries.append(allocator, try zoneSummary(allocator, zone));
                }
            },
        }
        if (options.group != .annotation) {
            try self.applyDurationDistributions(allocator, summaries.items, options);
        }
        self.counters.groups = @intCast(summaries.items.len);
        self.counters.duration_ns = self.durationNs();
        sortSummaries(summaries.items, options.sort);
        return summaries;
    }

    pub fn collectOccurrences(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Occurrence) {
        var occurrences: std.ArrayListUnmanaged(Occurrence) = .empty;
        errdefer occurrences.deinit(allocator);
        if (options.sort == .gpu_tail or options.sort == .cpu_tail) {
            try occurrences.ensureTotalCapacity(allocator, self.zones.items.len);
            for (self.zones.items) |zone| {
                if (!zone.accounted or !zoneMatches(zone, options)) continue;
                occurrences.appendAssumeCapacity(zoneOccurrence(zone));
            }
            sortOccurrences(occurrences.items, options.sort);
            return occurrences;
        }
        try occurrences.ensureTotalCapacity(allocator, self.occurrences.items.len);
        for (self.occurrences.items) |occurrence| {
            if (!occurrenceMatches(occurrence, options)) continue;
            occurrences.appendAssumeCapacity(occurrence);
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

    pub fn gpuNs(self: Analyzer) u64 {
        var total: u64 = 0;
        var iter = self.contexts.valueIterator();
        while (iter.next()) |context| total +|= context.gpu_ns;
        return total;
    }

    pub fn cpuNs(self: Analyzer) u64 {
        var total: u64 = 0;
        var iter = self.contexts.valueIterator();
        while (iter.next()) |context| total +|= context.cpu_ns;
        return total;
    }

    pub fn incompleteZoneCount(self: Analyzer) u64 {
        return self.counters.zone_begins -| self.counters.completed_zones;
    }

    pub fn captureIntegrity(self: Analyzer) CaptureIntegrity {
        var unbalanced = self.incompleteZoneCount();
        unbalanced +|= self.counters.unmatched_ends;
        unbalanced +|= self.counters.unmatched_times;
        return self.capture.integrity(unbalanced);
    }

    pub fn durationPairsComplete(self: Analyzer) bool {
        if (self.incompleteZoneCount() != 0) return false;
        if (self.counters.unmatched_ends != 0) return false;
        if (self.counters.unmatched_times != 0) return false;
        if (self.counters.duplicate_queries != 0) return false;
        if (self.counters.duplicate_times != 0) return false;
        if (self.counters.gpu_timestamp_regressions != 0) return false;
        return self.counters.cpu_timestamp_regressions == 0;
    }

    pub fn durationEvidence(self: Analyzer) []const u8 {
        if (!std.mem.eql(u8, self.captureIntegrity().status, "complete")) return "partial";
        return if (self.durationPairsComplete()) "complete" else "partial";
    }

    pub fn recordFlightReport(self: *Analyzer, report_value: transport.Report) void {
        self.capture.recordFlightReport(report_value);
    }

    fn recordContext(self: *Analyzer, parsed: event.Parsed) !void {
        const context_id = parsed.gpu_context orelse 0;
        const context = try self.contextState(context_id);
        try replaceOptional(self.allocator, &context.name, parsed.name);
        try replaceOptional(self.allocator, &context.context_type, parsed.gpu_context_type);
        if (parsed.gpu_period) |period| context.period = period;
        context.has_calibration = parsed.gpu_has_calibration;
        const raw_gpu = parsed.gpu_time orelse 0;
        const scaled_gpu = context.scaleGpuTime(raw_gpu);
        context.time_diff_ns = @as(i64, @intCast(parsed.time_ns)) - floatToI64(scaled_gpu);
        context.calibrated_gpu_time = scaled_gpu;
        context.calibrated_cpu_time_ns = @intCast(parsed.time_ns);
        context.calibration_mod = 1.0;
        noteRange(&context.first_ns, &context.last_ns, parsed.time_ns);
        self.counters.contexts += 1;
        try self.recordOccurrence(.{
            .kind = .context,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .context = context_id,
            .thread = parsed.thread,
            .name = try dupeOptional(self.allocator, parsed.name),
            .gpu_time = parsed.gpu_time,
        });
    }

    fn recordContextName(self: *Analyzer, parsed: event.Parsed) !void {
        const context_id = parsed.gpu_context orelse 0;
        const context = try self.contextState(context_id);
        try replaceOptional(self.allocator, &context.name, parsed.name);
        noteRange(&context.first_ns, &context.last_ns, parsed.time_ns);
        self.counters.context_names += 1;
        try self.recordOccurrence(.{
            .kind = .context_name,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .context = context_id,
            .thread = parsed.thread,
            .name = try dupeOptional(self.allocator, parsed.name),
        });
    }

    fn recordZoneBegin(self: *Analyzer, parsed: event.Parsed) !void {
        const context_id = parsed.gpu_context orelse 0;
        const query = parsed.gpu_query orelse 0;
        const context = try self.contextState(context_id);
        context.zones += 1;
        noteRange(&context.first_ns, &context.last_ns, parsed.time_ns);
        const name = parsed.name orelse "<gpu>";
        const index = self.zones.items.len;
        const zone = try initZoneState(self.allocator, parsed, context_id, query, name);
        self.zones.append(self.allocator, zone) catch |err| {
            var owned = zone;
            owned.deinit(self.allocator);
            return err;
        };
        const duplicate_query = if (query == 0)
            false
        else
            try self.bindQuery(context_id, query, .{ .zone = index, .side = .start });
        const stack = try self.stackState(context_id, parsed.thread);
        try stack.zones.append(self.allocator, index);
        self.counters.zone_begins += 1;
        try self.recordOccurrence(.{
            .kind = .zone_begin,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .context = context_id,
            .query = query,
            .thread = parsed.thread,
            .name = try self.allocator.dupe(u8, name),
            .duplicate_query = duplicate_query,
        });
    }

    fn recordZoneEnd(self: *Analyzer, parsed: event.Parsed) !void {
        const context_id = parsed.gpu_context orelse 0;
        const query = parsed.gpu_query orelse 0;
        const stack = try self.stackState(context_id, parsed.thread);
        const index = stack.zones.pop() orelse {
            self.counters.unmatched_ends += 1;
            try self.recordOccurrence(.{
                .kind = .zone_end,
                .seq = parsed.seq,
                .time_ns = parsed.time_ns,
                .context = context_id,
                .query = query,
                .thread = parsed.thread,
                .unmatched = true,
            });
            return;
        };
        const zone = &self.zones.items[index];
        zone.cpu_end_ns = parsed.time_ns;
        zone.end_query = query;
        zone.serial = zone.serial or parsed.gpu_serial;
        const duplicate_query = if (query == 0)
            false
        else
            try self.bindQuery(context_id, query, .{ .zone = index, .side = .end });
        const context = try self.contextState(context_id);
        noteRange(&context.first_ns, &context.last_ns, parsed.time_ns);
        self.counters.zone_ends += 1;
        try self.accountZoneIfComplete(index);
        try self.recordOccurrence(.{
            .kind = .zone_end,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .context = context_id,
            .query = query,
            .thread = parsed.thread,
            .duplicate_query = duplicate_query,
        });
    }

    fn recordGpuTime(self: *Analyzer, parsed: event.Parsed) !void {
        const context_id = parsed.gpu_context orelse 0;
        const query = parsed.gpu_query orelse 0;
        const raw_gpu = parsed.gpu_time orelse return;
        const context = try self.contextState(context_id);
        context.gpu_times += 1;
        self.counters.gpu_times += 1;
        const converted = context.convertGpuTime(raw_gpu);
        const query_ref = self.query_refs.get(queryKey(context_id, query));
        var duplicate_time = false;
        if (query_ref) |reference| {
            const zone = &self.zones.items[reference.zone];
            const slot = switch (reference.side) {
                .start => &zone.gpu_start_ns,
                .end => &zone.gpu_end_ns,
            };
            if (slot.* == null) {
                slot.* = converted;
                try self.accountZoneIfComplete(reference.zone);
            } else {
                duplicate_time = true;
                self.counters.duplicate_times +|= 1;
            }
        } else {
            self.counters.unmatched_times +|= 1;
        }
        noteRange(&context.first_ns, &context.last_ns, parsed.time_ns);
        try self.recordOccurrence(.{
            .kind = .gpu_time,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .context = context_id,
            .query = query,
            .thread = parsed.thread,
            .gpu_time = raw_gpu,
            .converted_gpu_ns = converted,
            .unmatched = query_ref == null,
            .duplicate_time = duplicate_time,
        });
    }

    fn recordCalibration(self: *Analyzer, parsed: event.Parsed) !void {
        const context_id = parsed.gpu_context orelse 0;
        const raw_gpu = parsed.gpu_time orelse return;
        const context = try self.contextState(context_id);
        const scaled_gpu = context.scaleGpuTime(raw_gpu);
        const gpu_delta = scaled_gpu - context.calibrated_gpu_time;
        if (gpu_delta != 0) {
            const cpu_delta = parsed.gpu_cpu_delta_ns orelse 0;
            context.calibration_mod = @as(f64, @floatFromInt(cpu_delta)) / gpu_delta;
            context.calibrated_gpu_time = scaled_gpu;
            context.calibrated_cpu_time_ns = @intCast(parsed.time_ns);
        }
        context.calibrations += 1;
        self.counters.calibrations += 1;
        noteRange(&context.first_ns, &context.last_ns, parsed.time_ns);
        try self.recordOccurrence(.{
            .kind = .calibration,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .context = context_id,
            .thread = parsed.thread,
            .gpu_time = raw_gpu,
        });
    }

    fn recordTimeSync(self: *Analyzer, parsed: event.Parsed) !void {
        const context_id = parsed.gpu_context orelse 0;
        const raw_gpu = parsed.gpu_time orelse return;
        const context = try self.contextState(context_id);
        const scaled_gpu = context.scaleGpuTime(raw_gpu);
        context.time_diff_ns = @as(i64, @intCast(parsed.time_ns)) - floatToI64(scaled_gpu);
        context.syncs += 1;
        self.counters.syncs += 1;
        noteRange(&context.first_ns, &context.last_ns, parsed.time_ns);
        try self.recordOccurrence(.{
            .kind = .time_sync,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .context = context_id,
            .thread = parsed.thread,
            .gpu_time = raw_gpu,
        });
    }

    fn recordAnnotationName(self: *Analyzer, parsed: event.Parsed) !void {
        const context_id = parsed.gpu_context orelse 0;
        const annotation_id = parsed.gpu_annotation_id orelse return;
        const name = parsed.name orelse return;
        const key = AnnotationKey{ .context = context_id, .annotation_id = annotation_id };
        const owned_name = try self.allocator.dupe(u8, name);
        const entry = self.annotation_names.getOrPut(self.allocator, key) catch |err| {
            self.allocator.free(owned_name);
            return err;
        };
        if (entry.found_existing) entry.value_ptr.deinit(self.allocator);
        entry.value_ptr.* = .{ .name = owned_name };
        self.counters.annotation_names += 1;
        try self.recordOccurrence(.{
            .kind = .annotation_name,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .context = context_id,
            .thread = parsed.thread,
            .name = try self.allocator.dupe(u8, name),
            .annotation_id = annotation_id,
        });
    }

    fn recordAnnotation(self: *Analyzer, parsed: event.Parsed) !void {
        const context_id = parsed.gpu_context orelse 0;
        const annotation_id = parsed.gpu_annotation_id orelse return;
        const value = parsed.value_f64 orelse return;
        const key = AnnotationKey{ .context = context_id, .annotation_id = annotation_id };
        const label = if (self.annotation_names.get(key)) |named| named.name else null;
        const annotation = self.annotations.getPtr(key) orelse create: {
            const owned_label = try self.annotationLabel(context_id, annotation_id, label);
            errdefer self.allocator.free(owned_label);
            const entry = try self.annotations.getOrPut(self.allocator, key);
            std.debug.assert(!entry.found_existing);
            entry.value_ptr.* = .{
                .label = owned_label,
                .context = context_id,
                .id = annotation_id,
            };
            break :create entry.value_ptr;
        };
        if (annotation.count == 0) {
            annotation.min = value;
            annotation.max = value;
        } else {
            annotation.min = @min(annotation.min, value);
            annotation.max = @max(annotation.max, value);
        }
        annotation.count += 1;
        annotation.last = value;
        noteRange(&annotation.first_ns, &annotation.last_ns, parsed.time_ns);
        const context = try self.contextState(context_id);
        context.annotations += 1;
        self.counters.annotations += 1;
        if (parsed.gpu_query) |query| {
            if (self.query_refs.get(queryKey(context_id, query))) |query_ref| {
                self.zones.items[query_ref.zone].annotations += 1;
            }
        }
        try self.recordOccurrence(.{
            .kind = .annotation,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .context = context_id,
            .query = parsed.gpu_query,
            .thread = parsed.thread,
            .name = try dupeOptional(self.allocator, label),
            .annotation_id = annotation_id,
            .value = value,
        });
    }

    fn collectZoneGroups(
        self: *Analyzer,
        allocator: std.mem.Allocator,
        summaries: *std.ArrayListUnmanaged(Summary),
        options: Options,
        group: Group,
    ) !void {
        var groups: std.StringHashMapUnmanaged(usize) = .{};
        defer groups.deinit(allocator);
        const zone_capacity = std.math.cast(u32, self.zones.items.len) orelse
            return error.TooManyGpuZones;
        try groups.ensureTotalCapacity(allocator, zone_capacity);
        for (self.zones.items) |zone| {
            if (!zoneMatches(zone, options)) {
                self.counters.filtered += 1;
                continue;
            }
            var thread_buffer: [32]u8 = undefined;
            const key = switch (group) {
                .name => zone.name,
                .thread => try std.fmt.bufPrint(&thread_buffer, "thread {d}", .{zone.thread}),
                else => unreachable,
            };
            const entry = groups.getOrPutAssumeCapacity(key);
            var summary_index: usize = undefined;
            if (!entry.found_existing) {
                const label = try allocator.dupe(u8, key);
                errdefer allocator.free(label);
                summary_index = summaries.items.len;
                try summaries.append(allocator, .{
                    .group = group,
                    .label = label,
                    .thread = if (group == .thread) zone.thread else null,
                });
                entry.key_ptr.* = label;
                entry.value_ptr.* = summary_index;
            } else {
                summary_index = entry.value_ptr.*;
            }
            addZoneToSummary(&summaries.items[summary_index], zone);
        }
    }

    fn applyDurationDistributions(
        self: *Analyzer,
        allocator: std.mem.Allocator,
        summaries: []Summary,
        options: Options,
    ) !void {
        var names: std.StringHashMapUnmanaged(usize) = .{};
        defer names.deinit(allocator);
        var ids: std.AutoHashMapUnmanaged(u64, usize) = .{};
        defer ids.deinit(allocator);
        const group_capacity = std.math.cast(u32, summaries.len) orelse
            return error.TooManyGpuGroups;
        switch (options.group) {
            .context, .thread => try ids.ensureTotalCapacity(allocator, group_capacity),
            .name => try names.ensureTotalCapacity(allocator, group_capacity),
            .none, .annotation => {},
        }
        for (summaries, 0..) |summary, index| switch (options.group) {
            .context => ids.putAssumeCapacity(summary.context.?, index),
            .name => names.putAssumeCapacity(summary.label, index),
            .thread => ids.putAssumeCapacity(summary.thread.?, index),
            .none => {},
            .annotation => unreachable,
        };

        var gpu_samples: std.ArrayListUnmanaged(DurationSample) = .empty;
        defer gpu_samples.deinit(allocator);
        var cpu_samples: std.ArrayListUnmanaged(DurationSample) = .empty;
        defer cpu_samples.deinit(allocator);
        try gpu_samples.ensureTotalCapacity(allocator, self.zones.items.len);
        try cpu_samples.ensureTotalCapacity(allocator, self.zones.items.len);
        var none_index: usize = 0;
        for (self.zones.items) |zone| {
            const row = durationRow(
                zone,
                options,
                summaries.len,
                &none_index,
                &names,
                &ids,
            ) orelse continue;
            if (!zone.accounted) continue;
            if (zoneGpuDuration(zone)) |duration_ns| {
                gpu_samples.appendAssumeCapacity(.{ .row = row, .duration_ns = duration_ns });
            } else {
                summaries[row].gpu_timestamp_regressions +|= 1;
            }
            if (zoneCpuDuration(zone)) |duration_ns| {
                cpu_samples.appendAssumeCapacity(.{ .row = row, .duration_ns = duration_ns });
            } else {
                summaries[row].cpu_timestamp_regressions +|= 1;
            }
        }
        applyDurationSamples(summaries, gpu_samples.items, .gpu);
        applyDurationSamples(summaries, cpu_samples.items, .cpu);
    }

    fn contextState(self: *Analyzer, id: u32) !*ContextState {
        const entry = try self.contexts.getOrPut(self.allocator, id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .id = id };
        return entry.value_ptr;
    }

    fn stackState(self: *Analyzer, context: u32, thread: u64) !*StackState {
        const entry = try self.stacks.getOrPut(self.allocator, .{ .context = context, .thread = thread });
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }

    fn annotationLabel(self: *Analyzer, context: u32, id: i64, name: ?[]const u8) ![]u8 {
        if (name) |actual| return try self.allocator.dupe(u8, actual);
        return try std.fmt.allocPrint(self.allocator, "context {d} annotation {d}", .{ context, id });
    }

    fn accountZoneIfComplete(self: *Analyzer, index: usize) !void {
        const zone = &self.zones.items[index];
        if (zone.accounted) return;
        if (zone.cpu_end_ns == null or zone.gpu_start_ns == null or zone.gpu_end_ns == null) return;
        zone.accounted = true;
        const context = try self.contextState(zone.context);
        context.completed_zones +|= 1;
        self.counters.completed_zones +|= 1;
        if (zoneCpuDuration(zone.*)) |duration_ns| {
            context.cpu_ns +|= duration_ns;
            self.counters.cpu_duration_samples +|= 1;
        } else {
            self.counters.cpu_timestamp_regressions +|= 1;
        }
        if (zoneGpuDuration(zone.*)) |duration_ns| {
            context.gpu_ns +|= duration_ns;
            self.counters.gpu_duration_samples +|= 1;
        } else {
            self.counters.gpu_timestamp_regressions +|= 1;
        }
    }

    fn bindQuery(self: *Analyzer, context: u32, query: u32, query_ref: QueryRef) !bool {
        const entry = try self.query_refs.getOrPut(self.allocator, queryKey(context, query));
        if (entry.found_existing) {
            self.counters.duplicate_queries +|= 1;
            return true;
        }
        entry.value_ptr.* = query_ref;
        return false;
    }

    fn recordOccurrence(self: *Analyzer, occurrence: Occurrence) !void {
        self.occurrences.append(self.allocator, occurrence) catch |err| {
            var owned = occurrence;
            owned.deinit(self.allocator);
            return err;
        };
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
    try writeTextHeader(writer, analyzer, options, summaries.items.len);
    try capture_mod.writeText(writer, analyzer.captureIntegrity());
    const summary_limit = @min(options.top, summaries.items.len);
    for (summaries.items[0..summary_limit]) |summary| {
        try writer.print("gpu group={s} label=", .{summary.group.tag()});
        try pretty_json.writeString(writer, summary.label);
        try writer.print(" count={d}", .{summary.count});
        try writeSummaryFieldsText(writer, summary);
        try writer.writeByte('\n');
    }

    const occurrence_limit = @min(options.occurrences, occurrences.items.len);
    for (occurrences.items[0..occurrence_limit]) |occurrence| {
        try writer.print("gpu-occurrence kind={s} time_ns={d}", .{ occurrence.kind.tag(), occurrence.time_ns });
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

    try writeJsonHeader(writer, analyzer, options, summaries.items.len);

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
        try writeOccurrenceFields(object, occurrence);
        try object.endLine();
    }
}

fn writeTextHeader(
    writer: *std.Io.Writer,
    analyzer: *Analyzer,
    options: Options,
    groups: usize,
) !void {
    const counters = analyzer.counters;
    try writer.print(
        "tracy gpu groups={d} contexts={d} zones={d} completed_zones={d} " ++
            "gpu_duration_samples={d} cpu_duration_samples={d} gpu_times={d} " ++
            "annotations={d} calibrations={d} syncs={d} gpu_ns={d} cpu_ns={d} " ++
            "unmatched_ends={d} unmatched_times={d} duplicate_queries={d} " ++
            "duplicate_times={d} gpu_timestamp_regressions={d} " ++
            "cpu_timestamp_regressions={d} filtered={d} duration_ns={d} " ++
            "duration_population=completed_valid_pairs duration_evidence={s} " ++
            "group={s} sort={s}\n",
        .{
            groups,                             analyzer.contexts.count(),
            analyzer.counters.zone_begins,      analyzer.counters.completed_zones,
            counters.gpu_duration_samples,      counters.cpu_duration_samples,
            counters.gpu_times,                 counters.annotations,
            counters.calibrations,              counters.syncs,
            analyzer.gpuNs(),                   analyzer.cpuNs(),
            counters.unmatched_ends,            counters.unmatched_times,
            counters.duplicate_queries,         counters.duplicate_times,
            counters.gpu_timestamp_regressions, counters.cpu_timestamp_regressions,
            counters.filtered,                  analyzer.durationNs(),
            analyzer.durationEvidence(),        options.group.tag(),
            options.sort.tag(),
        },
    );
}

fn writeJsonHeader(
    writer: *std.Io.Writer,
    analyzer: *Analyzer,
    options: Options,
    groups: usize,
) !void {
    const counters = analyzer.counters;
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "summary");
    try object.field("groups", groups);
    try object.field("contexts", analyzer.contexts.count());
    try object.field("zones", analyzer.counters.zone_begins);
    try object.field("completed_zones", analyzer.counters.completed_zones);
    try object.field("gpu_duration_samples", counters.gpu_duration_samples);
    try object.field("cpu_duration_samples", counters.cpu_duration_samples);
    try object.field("gpu_times", counters.gpu_times);
    try object.field("annotations", counters.annotations);
    try object.field("calibrations", counters.calibrations);
    try object.field("syncs", counters.syncs);
    try object.field("gpu_ns", analyzer.gpuNs());
    try object.field("cpu_ns", analyzer.cpuNs());
    try object.field("unmatched_ends", counters.unmatched_ends);
    try object.field("unmatched_times", counters.unmatched_times);
    try object.field("duplicate_queries", counters.duplicate_queries);
    try object.field("duplicate_times", counters.duplicate_times);
    try object.field("gpu_timestamp_regressions", counters.gpu_timestamp_regressions);
    try object.field("cpu_timestamp_regressions", counters.cpu_timestamp_regressions);
    try object.field("filtered", counters.filtered);
    try object.field("duration_ns", analyzer.durationNs());
    try object.field("duration_population", "completed_valid_pairs");
    try object.field("duration_evidence", analyzer.durationEvidence());
    try object.field("group", options.group.tag());
    try object.field("sort", options.sort.tag());
    try capture_mod.writeFields(object, analyzer.captureIntegrity());
    try object.endLine();
}

fn contextSummary(allocator: std.mem.Allocator, context: ContextState) !Summary {
    var label = std.Io.Writer.Allocating.init(allocator);
    defer label.deinit();
    try label.writer.print("context {d}", .{context.id});
    if (context.name) |name| {
        try label.writer.writeByte(' ');
        try label.writer.writeAll(name);
    }
    return .{
        .group = .context,
        .label = try allocator.dupe(u8, label.written()),
        .count = context.zones,
        .context = context.id,
        .zones = context.zones,
        .completed_zones = context.completed_zones,
        .gpu_ns = context.gpu_ns,
        .cpu_ns = context.cpu_ns,
        .gpu_times = context.gpu_times,
        .calibrations = context.calibrations,
        .syncs = context.syncs,
        .annotations = context.annotations,
        .first_ns = context.first_ns,
        .last_ns = context.last_ns,
    };
}

fn zoneSummary(allocator: std.mem.Allocator, zone: ZoneState) !Summary {
    return .{
        .group = .none,
        .label = try allocator.dupe(u8, zone.name),
        .count = 1,
        .context = zone.context,
        .thread = zone.thread,
        .zones = 1,
        .completed_zones = if (zone.accounted) 1 else 0,
        .gpu_ns = if (zone.accounted) zoneGpuNs(zone) else 0,
        .cpu_ns = if (zone.accounted) zoneCpuNs(zone) else 0,
        .annotations = zone.annotations,
        .first_ns = zone.cpu_start_ns,
        .last_ns = zone.cpu_end_ns orelse zone.cpu_start_ns,
    };
}

fn annotationSummary(allocator: std.mem.Allocator, annotation: AnnotationState) !Summary {
    return .{
        .group = .annotation,
        .label = try allocator.dupe(u8, annotation.label),
        .count = annotation.count,
        .context = annotation.context,
        .annotations = annotation.count,
        .annotation_id = annotation.id,
        .annotation_min = annotation.min,
        .annotation_max = annotation.max,
        .annotation_last = annotation.last,
        .first_ns = annotation.first_ns,
        .last_ns = annotation.last_ns,
    };
}

fn addZoneToSummary(summary: *Summary, zone: ZoneState) void {
    summary.count += 1;
    summary.zones += 1;
    summary.completed_zones += if (zone.accounted) 1 else 0;
    if (zone.accounted) {
        summary.gpu_ns +|= zoneGpuNs(zone);
        summary.cpu_ns +|= zoneCpuNs(zone);
    }
    summary.annotations +|= zone.annotations;
    if (summary.context == null) summary.context = zone.context;
    if (summary.thread == null) summary.thread = zone.thread;
    noteRange(&summary.first_ns, &summary.last_ns, zone.cpu_start_ns);
    if (zone.cpu_end_ns) |end_ns| noteRange(&summary.first_ns, &summary.last_ns, end_ns);
}

fn durationRow(
    zone: ZoneState,
    options: Options,
    row_count: usize,
    none_index: *usize,
    names: *const std.StringHashMapUnmanaged(usize),
    ids: *const std.AutoHashMapUnmanaged(u64, usize),
) ?usize {
    return switch (options.group) {
        .context => ids.get(zone.context),
        .name => if (zoneMatches(zone, options)) names.get(zone.name) else null,
        .thread => if (zoneMatches(zone, options)) ids.get(zone.thread) else null,
        .none => if (zoneMatches(zone, options)) nextDurationRow(row_count, none_index) else null,
        .annotation => null,
    };
}

fn nextDurationRow(row_count: usize, index: *usize) ?usize {
    if (index.* >= row_count) return null;
    const row = index.*;
    index.* += 1;
    return row;
}

const DurationKind = enum {
    gpu,
    cpu,
};

fn applyDurationSamples(rows: []Summary, samples: []DurationSample, kind: DurationKind) void {
    std.mem.sort(DurationSample, samples, {}, durationSampleLessThan);
    var start: usize = 0;
    while (start < samples.len) {
        var end = start + 1;
        while (end < samples.len and samples[end].row == samples[start].row) : (end += 1) {}
        applyDurationDistribution(&rows[samples[start].row], samples[start..end], kind);
        start = end;
    }
}

fn applyDurationDistribution(
    summary: *Summary,
    samples: []const DurationSample,
    kind: DurationKind,
) void {
    std.debug.assert(samples.len > 0);
    const count: u64 = @intCast(samples.len);
    switch (kind) {
        .gpu => {
            summary.gpu_duration_samples = count;
            summary.gpu_min_ns = durationPercentile(samples, 0);
            summary.gpu_p50_ns = durationPercentile(samples, 50);
            summary.gpu_p90_ns = durationPercentile(samples, 90);
            summary.gpu_p99_ns = durationPercentile(samples, 99);
            summary.gpu_max_ns = durationPercentile(samples, 100);
        },
        .cpu => {
            summary.cpu_duration_samples = count;
            summary.cpu_min_ns = durationPercentile(samples, 0);
            summary.cpu_p50_ns = durationPercentile(samples, 50);
            summary.cpu_p90_ns = durationPercentile(samples, 90);
            summary.cpu_p99_ns = durationPercentile(samples, 99);
            summary.cpu_max_ns = durationPercentile(samples, 100);
        },
    }
}

fn durationPercentile(samples: []const DurationSample, percent: u64) u64 {
    std.debug.assert(samples.len > 0);
    const rank: usize = @intCast((@as(u128, @min(percent, 100)) * samples.len + 99) / 100);
    const index = @min(@max(rank, 1) - 1, samples.len - 1);
    return samples[index].duration_ns;
}

fn durationSampleLessThan(_: void, left: DurationSample, right: DurationSample) bool {
    if (left.row != right.row) return left.row < right.row;
    return left.duration_ns < right.duration_ns;
}

fn zoneOccurrence(zone: ZoneState) Occurrence {
    return .{
        .kind = .zone,
        .time_ns = zone.cpu_end_ns orelse zone.cpu_start_ns,
        .context = zone.context,
        .query = zone.begin_query,
        .end_query = zone.end_query,
        .thread = zone.thread,
        .name = zone.name,
        .cpu_start_ns = zone.cpu_start_ns,
        .cpu_end_ns = zone.cpu_end_ns,
        .gpu_start_ns = zone.gpu_start_ns,
        .gpu_end_ns = zone.gpu_end_ns,
        .gpu_duration_ns = zoneGpuDuration(zone),
        .cpu_duration_ns = zoneCpuDuration(zone),
    };
}

fn initZoneState(
    allocator: std.mem.Allocator,
    parsed: event.Parsed,
    context: u32,
    query: u32,
    name: []const u8,
) !ZoneState {
    var zone = ZoneState{
        .context = context,
        .begin_query = query,
        .thread = parsed.thread,
        .name = try allocator.dupe(u8, name),
        .line = parsed.line,
        .column = parsed.column,
        .color = parsed.color,
        .cpu_start_ns = parsed.time_ns,
        .serial = parsed.gpu_serial,
    };
    errdefer zone.deinit(allocator);
    zone.file = try dupeOptional(allocator, parsed.file);
    zone.function = try dupeOptional(allocator, parsed.function);
    return zone;
}

fn zoneCpuDuration(zone: ZoneState) ?u64 {
    const end_ns = zone.cpu_end_ns orelse return null;
    if (end_ns < zone.cpu_start_ns) return null;
    return end_ns - zone.cpu_start_ns;
}

fn zoneGpuDuration(zone: ZoneState) ?u64 {
    const start_ns = zone.gpu_start_ns orelse return null;
    const end_ns = zone.gpu_end_ns orelse return null;
    return gpuTimestampDuration(start_ns, end_ns);
}

fn gpuTimestampDuration(start_ns: i64, end_ns: i64) ?u64 {
    if (end_ns < start_ns) return null;
    return @intCast(@as(i128, end_ns) - @as(i128, start_ns));
}

fn zoneCpuNs(zone: ZoneState) u64 {
    return zoneCpuDuration(zone) orelse 0;
}

fn zoneGpuNs(zone: ZoneState) u64 {
    return zoneGpuDuration(zone) orelse 0;
}

fn contextMatches(context: ContextState, options: Options) bool {
    if (options.context) |context_filter| if (context.id != context_filter) return false;
    if (!rangeMatches(context.first_ns, context.last_ns, options)) return false;
    if (options.match) |needle| {
        if (contains(context.displayName(), needle, options.ignore_case)) return true;
        if (context.context_type) |context_type| if (contains(context_type, needle, options.ignore_case)) return true;
        var buffer: [32]u8 = undefined;
        const context_text = std.fmt.bufPrint(&buffer, "{d}", .{context.id}) catch "";
        if (contains(context_text, needle, options.ignore_case)) return true;
        return false;
    }
    return true;
}

fn zoneMatches(zone: ZoneState, options: Options) bool {
    if (options.context) |context_filter| if (zone.context != context_filter) return false;
    if (options.thread) |thread_filter| if (zone.thread != thread_filter) return false;
    if (options.min_gpu_ns != 0 and zoneGpuNs(zone) < options.min_gpu_ns) return false;
    const last_ns = zone.cpu_end_ns orelse zone.cpu_start_ns;
    if (!rangeMatches(zone.cpu_start_ns, last_ns, options)) return false;
    if (options.match) |needle| {
        if (contains(zone.name, needle, options.ignore_case)) return true;
        if (zone.file) |file| if (contains(file, needle, options.ignore_case)) return true;
        if (zone.function) |function| if (contains(function, needle, options.ignore_case)) return true;
        return false;
    }
    return true;
}

fn annotationMatches(annotation: AnnotationState, options: Options) bool {
    if (options.context) |context_filter| if (annotation.context != context_filter) return false;
    if (!rangeMatches(annotation.first_ns, annotation.last_ns, options)) return false;
    if (options.match) |needle| return contains(annotation.label, needle, options.ignore_case);
    return true;
}

fn occurrenceMatches(occurrence: Occurrence, options: Options) bool {
    if (options.context) |context_filter| {
        const context = occurrence.context orelse return false;
        if (context != context_filter) return false;
    }
    if (options.thread) |thread_filter| if (occurrence.thread != thread_filter) return false;
    if (options.since_ns) |since_ns| if (occurrence.time_ns < since_ns) return false;
    if (options.until_ns) |until_ns| if (occurrence.time_ns > until_ns) return false;
    if (options.match) |needle| {
        if (contains(occurrence.kind.tag(), needle, options.ignore_case)) return true;
        if (occurrence.name) |name| if (contains(name, needle, options.ignore_case)) return true;
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
    if (summary.context) |context| try writer.print(" context={d}", .{context});
    if (summary.thread) |thread| try writer.print(" thread={d}", .{thread});
    if (summary.zones != 0) try writer.print(" zones={d}", .{summary.zones});
    if (summary.completed_zones != 0) try writer.print(" completed_zones={d}", .{summary.completed_zones});
    if (summary.gpu_ns != 0) try writer.print(" gpu_ns={d}", .{summary.gpu_ns});
    if (summary.cpu_ns != 0) try writer.print(" cpu_ns={d}", .{summary.cpu_ns});
    if (summary.zones != 0) try writeDurationFieldsText(writer, summary);
    if (summary.gpu_times != 0) try writer.print(" gpu_times={d}", .{summary.gpu_times});
    if (summary.calibrations != 0) try writer.print(" calibrations={d}", .{summary.calibrations});
    if (summary.syncs != 0) try writer.print(" syncs={d}", .{summary.syncs});
    if (summary.annotations != 0) try writer.print(" annotations={d}", .{summary.annotations});
    if (summary.annotation_id) |annotation_id| try writer.print(" annotation_id={d}", .{annotation_id});
    if (summary.annotation_min) |value| try writer.print(" annotation_min={d}", .{value});
    if (summary.annotation_max) |value| try writer.print(" annotation_max={d}", .{value});
    if (summary.annotation_last) |value| try writer.print(" annotation_last={d}", .{value});
    if (summary.first_ns != 0) try writer.print(" first_ns={d}", .{summary.first_ns});
    if (summary.last_ns != 0) try writer.print(" last_ns={d}", .{summary.last_ns});
}

fn writeSummaryFields(object: pretty_json.Object, summary: Summary) !void {
    if (summary.context) |context| try object.field("context", context);
    if (summary.thread) |thread| try object.field("thread", thread);
    if (summary.zones != 0) try object.field("zones", summary.zones);
    if (summary.completed_zones != 0) try object.field("completed_zones", summary.completed_zones);
    if (summary.gpu_ns != 0) try object.field("gpu_ns", summary.gpu_ns);
    if (summary.cpu_ns != 0) try object.field("cpu_ns", summary.cpu_ns);
    if (summary.zones != 0) try writeDurationFields(object, summary);
    if (summary.gpu_times != 0) try object.field("gpu_times", summary.gpu_times);
    if (summary.calibrations != 0) try object.field("calibrations", summary.calibrations);
    if (summary.syncs != 0) try object.field("syncs", summary.syncs);
    if (summary.annotations != 0) try object.field("annotations", summary.annotations);
    if (summary.annotation_id) |annotation_id| try object.field("annotation_id", annotation_id);
    if (summary.annotation_min) |value| try object.field("annotation_min", value);
    if (summary.annotation_max) |value| try object.field("annotation_max", value);
    if (summary.annotation_last) |value| try object.field("annotation_last", value);
    if (summary.first_ns != 0) try object.field("first_ns", summary.first_ns);
    if (summary.last_ns != 0) try object.field("last_ns", summary.last_ns);
}

fn writeOccurrenceFieldsText(writer: *std.Io.Writer, occurrence: Occurrence) !void {
    if (occurrence.context) |context| try writer.print(" context={d}", .{context});
    if (occurrence.query) |query| try writer.print(" query={d}", .{query});
    if (occurrence.thread != 0) try writer.print(" thread={d}", .{occurrence.thread});
    if (occurrence.name) |name| {
        try writer.writeAll(" name=");
        try pretty_json.writeString(writer, name);
    }
    if (occurrence.gpu_time) |gpu_time| try writer.print(" gpu_time={d}", .{gpu_time});
    if (occurrence.converted_gpu_ns) |converted| try writer.print(" gpu_ns={d}", .{converted});
    if (occurrence.annotation_id) |annotation_id| try writer.print(" annotation_id={d}", .{annotation_id});
    if (occurrence.value) |value| try writer.print(" value={d}", .{value});
    if (occurrence.unmatched) try writer.writeAll(" unmatched=true");
    if (occurrence.duplicate_query) try writer.writeAll(" duplicate_query=true");
    if (occurrence.duplicate_time) try writer.writeAll(" duplicate_time=true");
    if (occurrence.kind == .zone) try writeZoneOccurrenceText(writer, occurrence);
}

fn writeOccurrenceFields(object: pretty_json.Object, occurrence: Occurrence) !void {
    if (occurrence.context) |context| try object.field("context", context);
    if (occurrence.query) |query| try object.field("query", query);
    if (occurrence.thread != 0) try object.field("thread", occurrence.thread);
    if (occurrence.name) |name| try object.field("name", name);
    if (occurrence.gpu_time) |gpu_time| try object.field("gpu_time", gpu_time);
    if (occurrence.converted_gpu_ns) |converted| try object.field("gpu_ns", converted);
    if (occurrence.annotation_id) |annotation_id| try object.field("annotation_id", annotation_id);
    if (occurrence.value) |value| try object.field("value", value);
    if (occurrence.unmatched) try object.field("unmatched", true);
    if (occurrence.duplicate_query) try object.field("duplicate_query", true);
    if (occurrence.duplicate_time) try object.field("duplicate_time", true);
    if (occurrence.kind == .zone) try writeZoneOccurrenceFields(object, occurrence);
}

pub fn writeDurationFieldsText(writer: *std.Io.Writer, summary: Summary) !void {
    try writer.print(
        " gpu_duration_samples={d} gpu_mean_ns={d} gpu_min_ns={d} " ++
            "gpu_p50_ns={d} gpu_p90_ns={d} gpu_p99_ns={d} gpu_max_ns={d} " ++
            "gpu_timestamp_regressions={d}",
        .{
            summary.gpu_duration_samples,
            summary.meanGpuNs(),
            summary.gpu_min_ns,
            summary.gpu_p50_ns,
            summary.gpu_p90_ns,
            summary.gpu_p99_ns,
            summary.gpu_max_ns,
            summary.gpu_timestamp_regressions,
        },
    );
    try writer.print(
        " cpu_duration_samples={d} cpu_mean_ns={d} cpu_min_ns={d} " ++
            "cpu_p50_ns={d} cpu_p90_ns={d} cpu_p99_ns={d} cpu_max_ns={d} " ++
            "cpu_timestamp_regressions={d}",
        .{
            summary.cpu_duration_samples,
            summary.meanCpuNs(),
            summary.cpu_min_ns,
            summary.cpu_p50_ns,
            summary.cpu_p90_ns,
            summary.cpu_p99_ns,
            summary.cpu_max_ns,
            summary.cpu_timestamp_regressions,
        },
    );
}

pub fn writeDurationFields(object: pretty_json.Object, summary: Summary) !void {
    try object.field("gpu_duration_samples", summary.gpu_duration_samples);
    try object.field("gpu_mean_ns", summary.meanGpuNs());
    try object.field("gpu_min_ns", summary.gpu_min_ns);
    try object.field("gpu_p50_ns", summary.gpu_p50_ns);
    try object.field("gpu_p90_ns", summary.gpu_p90_ns);
    try object.field("gpu_p99_ns", summary.gpu_p99_ns);
    try object.field("gpu_max_ns", summary.gpu_max_ns);
    try object.field("gpu_timestamp_regressions", summary.gpu_timestamp_regressions);
    try object.field("cpu_duration_samples", summary.cpu_duration_samples);
    try object.field("cpu_mean_ns", summary.meanCpuNs());
    try object.field("cpu_min_ns", summary.cpu_min_ns);
    try object.field("cpu_p50_ns", summary.cpu_p50_ns);
    try object.field("cpu_p90_ns", summary.cpu_p90_ns);
    try object.field("cpu_p99_ns", summary.cpu_p99_ns);
    try object.field("cpu_max_ns", summary.cpu_max_ns);
    try object.field("cpu_timestamp_regressions", summary.cpu_timestamp_regressions);
}

fn writeZoneOccurrenceText(writer: *std.Io.Writer, occurrence: Occurrence) !void {
    if (occurrence.end_query) |query| try writer.print(" end_query={d}", .{query});
    if (occurrence.cpu_start_ns) |time_ns| try writer.print(" cpu_start_ns={d}", .{time_ns});
    if (occurrence.cpu_end_ns) |time_ns| try writer.print(" cpu_end_ns={d}", .{time_ns});
    if (occurrence.gpu_start_ns) |time_ns| try writer.print(" gpu_start_ns={d}", .{time_ns});
    if (occurrence.gpu_end_ns) |time_ns| try writer.print(" gpu_end_ns={d}", .{time_ns});
    if (occurrence.gpu_duration_ns) |duration_ns| {
        try writer.print(" gpu_duration_ns={d}", .{duration_ns});
    }
    if (occurrence.cpu_duration_ns) |duration_ns| {
        try writer.print(" cpu_duration_ns={d}", .{duration_ns});
    }
    try writer.print(
        " gpu_duration_valid={} cpu_duration_valid={}",
        .{ occurrence.gpu_duration_ns != null, occurrence.cpu_duration_ns != null },
    );
}

fn writeZoneOccurrenceFields(object: pretty_json.Object, occurrence: Occurrence) !void {
    if (occurrence.end_query) |query| try object.field("end_query", query);
    if (occurrence.cpu_start_ns) |time_ns| try object.field("cpu_start_ns", time_ns);
    if (occurrence.cpu_end_ns) |time_ns| try object.field("cpu_end_ns", time_ns);
    if (occurrence.gpu_start_ns) |time_ns| try object.field("gpu_start_ns", time_ns);
    if (occurrence.gpu_end_ns) |time_ns| try object.field("gpu_end_ns", time_ns);
    if (occurrence.gpu_duration_ns) |duration_ns| try object.field("gpu_duration_ns", duration_ns);
    if (occurrence.cpu_duration_ns) |duration_ns| try object.field("cpu_duration_ns", duration_ns);
    try object.field("gpu_duration_valid", occurrence.gpu_duration_ns != null);
    try object.field("cpu_duration_valid", occurrence.cpu_duration_ns != null);
}

fn sortSummaries(items: []Summary, sort: Sort) void {
    std.mem.sort(Summary, items, sort, summaryLessThan);
}

fn summaryLessThan(sort: Sort, left: Summary, right: Summary) bool {
    return switch (sort) {
        .gpu => summaryGpuGreaterThan({}, left, right),
        .gpu_tail => summaryGpuTailGreaterThan({}, left, right),
        .cpu => summaryCpuGreaterThan({}, left, right),
        .cpu_tail => summaryCpuTailGreaterThan({}, left, right),
        .count => summaryCountGreaterThan({}, left, right),
        .annotations => summaryAnnotationsGreaterThan({}, left, right),
        .last => summaryLastGreaterThan({}, left, right),
        .context => summaryContextLessThan({}, left, right),
        .thread => summaryThreadLessThan({}, left, right),
        .label => summaryLabelLessThan({}, left, right),
    };
}

fn summaryGpuTailGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.gpu_p99_ns != right.gpu_p99_ns) return left.gpu_p99_ns > right.gpu_p99_ns;
    if (left.gpu_max_ns != right.gpu_max_ns) return left.gpu_max_ns > right.gpu_max_ns;
    return summaryGpuGreaterThan({}, left, right);
}

fn summaryCpuTailGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.cpu_p99_ns != right.cpu_p99_ns) return left.cpu_p99_ns > right.cpu_p99_ns;
    if (left.cpu_max_ns != right.cpu_max_ns) return left.cpu_max_ns > right.cpu_max_ns;
    return summaryCpuGreaterThan({}, left, right);
}

fn summaryGpuGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.gpu_ns != right.gpu_ns) return left.gpu_ns > right.gpu_ns;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryCpuGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.cpu_ns != right.cpu_ns) return left.cpu_ns > right.cpu_ns;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryCountGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.count != right.count) return left.count > right.count;
    return std.mem.lessThan(u8, left.label, right.label);
}

fn summaryAnnotationsGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.annotations != right.annotations) return left.annotations > right.annotations;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryLastGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.last_ns != right.last_ns) return left.last_ns > right.last_ns;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryContextLessThan(_: void, left: Summary, right: Summary) bool {
    const left_context = left.context orelse 0;
    const right_context = right.context orelse 0;
    if (left_context != right_context) return left_context < right_context;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryThreadLessThan(_: void, left: Summary, right: Summary) bool {
    const left_thread = left.thread orelse 0;
    const right_thread = right.thread orelse 0;
    if (left_thread != right_thread) return left_thread < right_thread;
    return summaryCountGreaterThan({}, left, right);
}

fn summaryLabelLessThan(_: void, left: Summary, right: Summary) bool {
    return std.mem.lessThan(u8, left.label, right.label);
}

fn sortOccurrences(items: []Occurrence, sort: Sort) void {
    switch (sort) {
        .gpu_tail => std.mem.sort(Occurrence, items, {}, occurrenceGpuGreaterThan),
        .cpu_tail => std.mem.sort(Occurrence, items, {}, occurrenceCpuGreaterThan),
        .last => std.mem.sort(Occurrence, items, {}, occurrenceTimeGreaterThan),
        else => std.mem.sort(Occurrence, items, {}, occurrenceTimeLessThan),
    }
}

fn occurrenceGpuGreaterThan(_: void, left: Occurrence, right: Occurrence) bool {
    if ((left.gpu_duration_ns != null) != (right.gpu_duration_ns != null)) {
        return left.gpu_duration_ns != null;
    }
    const left_ns = left.gpu_duration_ns orelse 0;
    const right_ns = right.gpu_duration_ns orelse 0;
    if (left_ns != right_ns) return left_ns > right_ns;
    return occurrenceTimeLessThan({}, left, right);
}

fn occurrenceCpuGreaterThan(_: void, left: Occurrence, right: Occurrence) bool {
    if ((left.cpu_duration_ns != null) != (right.cpu_duration_ns != null)) {
        return left.cpu_duration_ns != null;
    }
    const left_ns = left.cpu_duration_ns orelse 0;
    const right_ns = right.cpu_duration_ns orelse 0;
    if (left_ns != right_ns) return left_ns > right_ns;
    return occurrenceTimeLessThan({}, left, right);
}

fn occurrenceTimeLessThan(_: void, left: Occurrence, right: Occurrence) bool {
    if (left.time_ns != right.time_ns) return left.time_ns < right.time_ns;
    return left.seq < right.seq;
}

fn occurrenceTimeGreaterThan(_: void, left: Occurrence, right: Occurrence) bool {
    if (left.time_ns != right.time_ns) return left.time_ns > right.time_ns;
    return left.seq > right.seq;
}

fn queryKey(context: u32, query: u32) u64 {
    return (@as(u64, context) << 32) | query;
}

fn noteRange(first_ns: *u64, last_ns: *u64, time_ns: u64) void {
    if (time_ns == 0) return;
    if (first_ns.* == 0 or time_ns < first_ns.*) first_ns.* = time_ns;
    last_ns.* = @max(last_ns.*, time_ns);
}

fn floatToI64(value: f64) i64 {
    if (!std.math.isFinite(value)) return 0;
    if (value <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return std.math.minInt(i64);
    if (value >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
    return @intFromFloat(value);
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
}

fn replaceOptional(allocator: std.mem.Allocator, slot: *?[]u8, text: ?[]const u8) !void {
    const replacement = try dupeOptional(allocator, text);
    if (slot.*) |old| allocator.free(old);
    slot.* = replacement;
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

test "gpu analyzer converts timestamp pairs into completed zones" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 900, .thread = 1, .name = "gpu" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .gpu_context, .time_ns = 1000, .thread = 10, .name = "render", .gpu_context = 2, .gpu_time = 100, .gpu_period = 2.0, .gpu_context_type = "vulkan" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .gpu_annotation_name, .time_ns = 1005, .thread = 10, .gpu_context = 2, .gpu_annotation_id = 5, .name = "occupancy" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .gpu_zone_begin, .time_ns = 1010, .thread = 10, .gpu_context = 2, .gpu_query = 11, .name = "draw", .file = "draw.zig", .line = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .gpu_annotation, .time_ns = 1015, .thread = 10, .gpu_context = 2, .gpu_query = 11, .gpu_annotation_id = 5, .value_f64 = 0.75 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .gpu_zone_end, .time_ns = 1060, .thread = 10, .gpu_context = 2, .gpu_query = 12 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .gpu_time, .time_ns = 1070, .thread = 10, .gpu_context = 2, .gpu_query = 11, .gpu_time = 110 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 8, .kind = .gpu_time, .time_ns = 1080, .thread = 10, .gpu_context = 2, .gpu_query = 12, .gpu_time = 140 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 9, .kind = .stop, .time_ns = 1100, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.completed_zones);
    try std.testing.expectEqual(@as(u64, 60), analyzer.gpuNs());
    try std.testing.expectEqual(@as(u64, 50), analyzer.cpuNs());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.annotations);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .group = .name, .sort = .gpu, .top = 4, .occurrences = 8 });
    const text = out.written();
    try expectGpuContains(
        text,
        "tracy gpu groups=1 contexts=1 zones=1 completed_zones=1 " ++
            "gpu_duration_samples=1 cpu_duration_samples=1",
    );
    try expectGpuContains(
        text,
        "gpu_times=2 annotations=1 calibrations=0 syncs=0 gpu_ns=60 cpu_ns=50",
    );
    try expectGpuContains(
        text,
        "gpu group=name label=\"draw\" count=1 context=2 thread=10 zones=1 " ++
            "completed_zones=1 gpu_ns=60 cpu_ns=50 gpu_duration_samples=1 " ++
            "gpu_mean_ns=60 gpu_min_ns=60 gpu_p50_ns=60 gpu_p90_ns=60 " ++
            "gpu_p99_ns=60 gpu_max_ns=60",
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "gpu-occurrence kind=gpu-time time_ns=1070 context=2 query=11 thread=10 gpu_time=110 gpu_ns=1020") != null);
}

test "gpu jsonl filters annotations by context and match" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .gpu_context, .time_ns = 100, .thread = 1, .gpu_context = 1, .name = "render" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .gpu_annotation_name, .time_ns = 110, .thread = 1, .gpu_context = 1, .gpu_annotation_id = 3, .name = "wave occupancy" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .gpu_annotation, .time_ns = 120, .thread = 1, .gpu_context = 1, .gpu_annotation_id = 3, .value_f64 = 0.5 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .gpu_annotation, .time_ns = 130, .thread = 1, .gpu_context = 1, .gpu_annotation_id = 3, .value_f64 = 0.75 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{ .group = .annotation, .context = 1, .match = "OCCUPANCY", .ignore_case = true });
    const text = out.written();
    try expectGpuContains(text, "\"schema\":\"tracy.gpu/v1\"");
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"summary\",\"groups\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"label\":\"wave occupancy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"annotation_min\":0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"annotation_max\":0.75") != null);
}

test "gpu duration distributions retain tails and worst zones" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var seq: u64 = 1;
    try appendGpuTestEvent(&trace.writer, &seq, .start, 1);
    for (1..11) |index| {
        try appendGpuTestZone(
            &trace.writer,
            &seq,
            "draw",
            1_000 + index * 100,
            index,
            @intCast(index * 10),
        );
    }
    try appendGpuTestEvent(&trace.writer, &seq, .stop, 3_000);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    var rows = try analyzer.collectSummaries(
        std.testing.allocator,
        .{ .group = .name, .sort = .gpu_tail },
    );
    defer deinitSummaries(std.testing.allocator, &rows);
    const draw = rows.items[0];
    try std.testing.expectEqual(@as(u64, 10), draw.gpu_duration_samples);
    try std.testing.expectEqual(@as(u64, 550), draw.gpu_ns);
    try std.testing.expectEqual(@as(u64, 55), draw.meanGpuNs());
    try std.testing.expectEqual(@as(u64, 10), draw.gpu_min_ns);
    try std.testing.expectEqual(@as(u64, 50), draw.gpu_p50_ns);
    try std.testing.expectEqual(@as(u64, 90), draw.gpu_p90_ns);
    try std.testing.expectEqual(@as(u64, 100), draw.gpu_p99_ns);
    try std.testing.expectEqual(@as(u64, 100), draw.gpu_max_ns);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{
        .group = .name,
        .sort = .gpu_tail,
        .occurrences = 2,
    });
    try expectGpuContains(out.written(), "duration_evidence=complete");
    const worst = std.mem.indexOf(u8, out.written(), "gpu_duration_ns=100").?;
    const next = std.mem.indexOfPos(u8, out.written(), worst + 1, "gpu_duration_ns=90").?;
    try std.testing.expect(worst < next);
}

test "gpu duration spans the signed timestamp domain" {
    const duration_ns = gpuTimestampDuration(std.math.minInt(i64), std.math.maxInt(i64));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), duration_ns);
}

test "gpu excludes malformed duration pairs and preserves first timestamps" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var seq: u64 = 1;
    try appendGpuTestEvent(&trace.writer, &seq, .start, 1);
    try appendGpuTestZone(&trace.writer, &seq, "valid", 100, 5, 10);
    try writeGpuTime(&trace.writer, &seq, 2, 999, 120);
    try writeGpuBegin(&trace.writer, &seq, "reused", 200, 2);
    try writeGpuEnd(&trace.writer, &seq, 210, 100);
    try appendGpuTestZoneRaw(&trace.writer, &seq, "gpu-reversed", 300, 305, 200, 201, 50, 40);
    try appendGpuTestZoneRaw(&trace.writer, &seq, "cpu-reversed", 400, 390, 300, 301, 60, 70);
    try appendGpuTestEvent(&trace.writer, &seq, .stop, 500);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 3), analyzer.counters.completed_zones);
    try std.testing.expectEqual(@as(u64, 2), analyzer.counters.gpu_duration_samples);
    try std.testing.expectEqual(@as(u64, 2), analyzer.counters.cpu_duration_samples);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.duplicate_queries);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.duplicate_times);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.gpu_timestamp_regressions);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.cpu_timestamp_regressions);
    try std.testing.expectEqual(@as(?i64, 1_000), analyzer.zones.items[0].gpu_start_ns);
    try std.testing.expectEqualStrings("partial", analyzer.durationEvidence());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{
        .group = .name,
        .sort = .gpu_tail,
        .occurrences = 8,
    });
    try expectGpuContains(out.written(), "\"duration_evidence\":\"partial\"");
    try expectGpuContains(out.written(), "\"gpu_duration_valid\":false");
    try expectGpuContains(out.written(), "\"cpu_duration_valid\":false");
}

test "gpu retains flight reports and sequence gaps" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 1 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .gpu_context, .time_ns = 2 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .stop, .time_ns = 3 })
        .writeJsonLine(&trace.writer);
    const flight_report = gpuTestFlightReport();
    try flight_report.writeJsonl(&trace.writer);
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqualStrings("sequence_gaps", analyzer.captureIntegrity().status);
    try std.testing.expectEqualDeep(flight_report, analyzer.captureIntegrity().flight_report.?);
    try std.testing.expectEqualStrings("partial", analyzer.durationEvidence());
}

test "gpu releases duration evidence on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        analyzeGpuDurationDistributions,
        .{},
    );
}

fn analyzeGpuDurationDistributions(allocator: std.mem.Allocator) !void {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var seq: u64 = 1;
    try appendGpuTestEvent(&trace.writer, &seq, .start, 1);
    try appendGpuTestZone(&trace.writer, &seq, "draw", 100, 5, 10);
    try appendGpuTestZone(&trace.writer, &seq, "draw", 200, 8, 40);
    try appendGpuTestEvent(&trace.writer, &seq, .stop, 300);
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(allocator, &analyzer, &out.writer, .{ .sort = .gpu_tail });
}

fn appendGpuTestEvent(
    writer: *std.Io.Writer,
    seq: *u64,
    kind: event.Kind,
    time_ns: u64,
) !void {
    try (event.TraceEvent{ .seq = seq.*, .kind = kind, .time_ns = time_ns })
        .writeJsonLine(writer);
    seq.* += 1;
}

fn appendGpuTestZone(
    writer: *std.Io.Writer,
    seq: *u64,
    name: []const u8,
    cpu_start_ns: u64,
    cpu_duration_ns: u64,
    gpu_duration_ns: i64,
) !void {
    const start_query: u32 = @intCast(seq.*);
    const end_query = start_query + 1;
    const gpu_start: i64 = @intCast(cpu_start_ns * 10);
    try appendGpuTestZoneRaw(
        writer,
        seq,
        name,
        cpu_start_ns,
        cpu_start_ns + cpu_duration_ns,
        start_query,
        end_query,
        gpu_start,
        gpu_start + gpu_duration_ns,
    );
}

fn appendGpuTestZoneRaw(
    writer: *std.Io.Writer,
    seq: *u64,
    name: []const u8,
    cpu_start_ns: u64,
    cpu_end_ns: u64,
    start_query: u32,
    end_query: u32,
    gpu_start: i64,
    gpu_end: i64,
) !void {
    try writeGpuBegin(writer, seq, name, cpu_start_ns, start_query);
    try writeGpuEnd(writer, seq, cpu_end_ns, end_query);
    try writeGpuTime(writer, seq, start_query, gpu_start, cpu_end_ns +| 1);
    try writeGpuTime(writer, seq, end_query, gpu_end, cpu_end_ns +| 2);
}

fn writeGpuBegin(
    writer: *std.Io.Writer,
    seq: *u64,
    name: []const u8,
    time_ns: u64,
    query: u32,
) !void {
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = .gpu_zone_begin,
        .time_ns = time_ns,
        .thread = 7,
        .name = name,
        .gpu_context = 1,
        .gpu_query = query,
    }).writeJsonLine(writer);
    seq.* += 1;
}

fn writeGpuEnd(writer: *std.Io.Writer, seq: *u64, time_ns: u64, query: u32) !void {
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = .gpu_zone_end,
        .time_ns = time_ns,
        .thread = 7,
        .gpu_context = 1,
        .gpu_query = query,
    }).writeJsonLine(writer);
    seq.* += 1;
}

fn writeGpuTime(
    writer: *std.Io.Writer,
    seq: *u64,
    query: u32,
    gpu_time: i64,
    time_ns: u64,
) !void {
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = .gpu_time,
        .time_ns = time_ns,
        .thread = 7,
        .gpu_context = 1,
        .gpu_query = query,
        .gpu_time = gpu_time,
    }).writeJsonLine(writer);
    seq.* += 1;
}

fn gpuTestFlightReport() transport.Report {
    return .{
        .policy = .overwrite_oldest,
        .state = .accepting,
        .capacity_bytes = 64,
        .retained_bytes = 32,
        .event_capacity_bytes = 16,
        .writer_capacity_bytes = 8,
        .observed_events = 5,
        .stored_events = 5,
        .retained_events = 4,
        .overwritten_events = 1,
        .dropped_events = 0,
        .oversized_events = 0,
        .partial_event_bytes = 0,
        .discarding_oversized_event = false,
    };
}

fn expectGpuContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
