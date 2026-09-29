const std = @import("std");
const pretty_json = @import("pretty").json;
const report = @import("report.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");
const tree = @import("tree.zig");

pub const schema = "tracy.timeline/v0";

pub const Kind = enum {
    all,
    zone,
    message,
    app_info,
    frame,
    plot,
    alloc,
    free,
    thread,
    fiber,
    gpu,
    sample,
    context,
    lock,
    system,
    metadata,

    pub fn fromName(text: []const u8) ?Kind {
        if (std.mem.eql(u8, text, "all")) return .all;
        if (std.mem.eql(u8, text, "zone")) return .zone;
        if (std.mem.eql(u8, text, "message")) return .message;
        if (std.mem.eql(u8, text, "app-info")) return .app_info;
        if (std.mem.eql(u8, text, "frame")) return .frame;
        if (std.mem.eql(u8, text, "plot")) return .plot;
        if (std.mem.eql(u8, text, "alloc")) return .alloc;
        if (std.mem.eql(u8, text, "free")) return .free;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "fiber")) return .fiber;
        if (std.mem.eql(u8, text, "gpu")) return .gpu;
        if (std.mem.eql(u8, text, "sample")) return .sample;
        if (std.mem.eql(u8, text, "context")) return .context;
        if (std.mem.eql(u8, text, "lock")) return .lock;
        if (std.mem.eql(u8, text, "system")) return .system;
        if (std.mem.eql(u8, text, "metadata")) return .metadata;
        return null;
    }

    fn tag(self: Kind) []const u8 {
        return switch (self) {
            .all => "all",
            .zone => "zone",
            .message => "message",
            .app_info => "app-info",
            .frame => "frame",
            .plot => "plot",
            .alloc => "alloc",
            .free => "free",
            .thread => "thread",
            .fiber => "fiber",
            .gpu => "gpu",
            .sample => "sample",
            .context => "context",
            .lock => "lock",
            .system => "system",
            .metadata => "metadata",
        };
    }
};

pub const Sort = enum {
    time,
    duration,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "time")) return .time;
        if (std.mem.eql(u8, text, "duration")) return .duration;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .time => "time",
            .duration => "duration",
        };
    }
};

pub const Options = struct {
    top: usize = 100,
    kind: Kind = .all,
    sort: Sort = .time,
    thread: ?u64 = null,
    since_ns: ?u64 = null,
    until_ns: ?u64 = null,
    min_duration_ns: u64 = 0,
    match: ?[]const u8 = null,
};

pub const Counters = struct {
    events: u64 = 0,
    instants: u64 = 0,
    metadata: u64 = 0,
};

const Instant = struct {
    kind: Kind,
    event: []const u8,
    time_ns: u64,
    thread: u64,
    id: u64 = 0,
    name: ?[]u8 = null,
    text: ?[]u8 = null,
    file: ?[]u8 = null,
    function: ?[]u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    color: ?u32 = null,
    value_u64: ?u64 = null,
    value_i64: ?i64 = null,
    value_f64: ?f64 = null,
    address: u64 = 0,
    size: u64 = 0,
    depth: u32 = 0,
    cpu: ?u32 = null,
    prev_thread: u64 = 0,
    next_thread: u64 = 0,
    target_thread: u64 = 0,
    pid: u64 = 0,
    previous_cstate: ?u32 = null,
    prev_priority: ?i64 = null,
    next_priority: ?i64 = null,
    group_hint: ?i64 = null,
    gpu_context: ?u32 = null,
    gpu_query: ?u32 = null,
    gpu_time: ?i64 = null,
    gpu_period: ?f64 = null,
    gpu_cpu_delta_ns: ?i64 = null,
    gpu_context_type: ?[]u8 = null,
    gpu_has_calibration: bool = false,
    gpu_serial: bool = false,
    gpu_annotation_id: ?i64 = null,
    cpu_package: ?u32 = null,
    cpu_die: ?u32 = null,
    cpu_core: ?u32 = null,
    power_delta_uj: ?u64 = null,
    hw_sample_kind: ?[]u8 = null,
    plot_kind: ?[]u8 = null,
    plot_unit: ?[]u8 = null,
    plot_step: bool = false,
    plot_fill: bool = false,
    lock_kind: ?[]u8 = null,
    sample_kind: ?[]u8 = null,
    context_reason: ?[]u8 = null,
    context_state: ?[]u8 = null,

    fn deinit(self: *Instant, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.text) |text| allocator.free(text);
        if (self.file) |file| allocator.free(file);
        if (self.function) |function| allocator.free(function);
        if (self.plot_kind) |plot_kind| allocator.free(plot_kind);
        if (self.plot_unit) |plot_unit| allocator.free(plot_unit);
        if (self.lock_kind) |lock_kind| allocator.free(lock_kind);
        if (self.sample_kind) |sample_kind| allocator.free(sample_kind);
        if (self.gpu_context_type) |gpu_context_type| allocator.free(gpu_context_type);
        if (self.hw_sample_kind) |hw_sample_kind| allocator.free(hw_sample_kind);
        if (self.context_reason) |context_reason| allocator.free(context_reason);
        if (self.context_state) |context_state| allocator.free(context_state);
        self.* = undefined;
    }
};

const Row = struct {
    kind: Kind,
    event: []const u8,
    time_ns: u64,
    end_ns: u64 = 0,
    duration_ns: u64 = 0,
    thread: u64 = 0,
    depth: usize = 0,
    id: u64 = 0,
    state: tree.SpanState = .complete,
    duration_valid: bool = false,
    name: ?[]const u8 = null,
    text: ?[]const u8 = null,
    file: ?[]const u8 = null,
    function: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    color: ?u32 = null,
    value_u64: ?u64 = null,
    value_i64: ?i64 = null,
    value_f64: ?f64 = null,
    address: u64 = 0,
    size: u64 = 0,
    sample_depth: u32 = 0,
    cpu: ?u32 = null,
    prev_thread: u64 = 0,
    next_thread: u64 = 0,
    target_thread: u64 = 0,
    pid: u64 = 0,
    previous_cstate: ?u32 = null,
    prev_priority: ?i64 = null,
    next_priority: ?i64 = null,
    group_hint: ?i64 = null,
    gpu_context: ?u32 = null,
    gpu_query: ?u32 = null,
    gpu_time: ?i64 = null,
    gpu_period: ?f64 = null,
    gpu_cpu_delta_ns: ?i64 = null,
    gpu_context_type: ?[]const u8 = null,
    gpu_has_calibration: bool = false,
    gpu_serial: bool = false,
    gpu_annotation_id: ?i64 = null,
    cpu_package: ?u32 = null,
    cpu_die: ?u32 = null,
    cpu_core: ?u32 = null,
    power_delta_uj: ?u64 = null,
    hw_sample_kind: ?[]const u8 = null,
    plot_kind: ?[]const u8 = null,
    plot_unit: ?[]const u8 = null,
    plot_step: bool = false,
    plot_fill: bool = false,
    lock_kind: ?[]const u8 = null,
    sample_kind: ?[]const u8 = null,
    context_reason: ?[]const u8 = null,
    context_state: ?[]const u8 = null,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    zones: tree.Analyzer,
    instants: std.ArrayListUnmanaged(Instant) = .empty,
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{
            .allocator = allocator,
            .zones = tree.Analyzer.init(allocator),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        for (self.instants.items) |*instant| instant.deinit(self.allocator);
        self.instants.deinit(self.allocator);
        self.zones.deinit();
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
            .flight => |report_value| self.zones.recordFlightReport(report_value),
        }
    }

    pub fn ingest(self: *Analyzer, parsed: event.Parsed) !void {
        self.counters.events += 1;
        if (self.start_ns == null and parsed.time_ns != 0) self.start_ns = parsed.time_ns;
        if (parsed.time_ns != 0) self.end_ns = parsed.time_ns;
        try self.zones.ingest(parsed);
        switch (parsed.kind) {
            .message => try self.recordInstant(.message, parsed),
            .app_info => try self.recordInstant(.app_info, parsed),
            .frame => try self.recordInstant(.frame, parsed),
            .plot_config, .plot => try self.recordInstant(.plot, parsed),
            .alloc => try self.recordInstant(.alloc, parsed),
            .free => try self.recordInstant(.free, parsed),
            .thread_name => try self.recordInstant(.thread, parsed),
            .fiber_name, .fiber_enter, .fiber_leave => try self.recordInstant(.fiber, parsed),
            .gpu_context,
            .gpu_context_name,
            .gpu_zone_begin,
            .gpu_zone_end,
            .gpu_time,
            .gpu_calibration,
            .gpu_time_sync,
            .gpu_annotation,
            .gpu_annotation_name,
            => try self.recordInstant(.gpu, parsed),
            .sample, .sample_frame => try self.recordInstant(.sample, parsed),
            .context_switch, .thread_wakeup => try self.recordInstant(.context, parsed),
            .lock_announce,
            .lock_terminate,
            .lock_wait,
            .lock_obtain,
            .lock_release,
            .lock_shared_wait,
            .lock_shared_obtain,
            .lock_shared_release,
            .lock_mark,
            .lock_name,
            => try self.recordInstant(.lock, parsed),
            .thread_context,
            .thread_pid,
            .cpu_topology,
            .sys_time,
            .sys_power,
            .hw_sample,
            => try self.recordInstant(.system, parsed),
            .zone_text, .zone_name, .zone_color, .zone_value => try self.recordInstant(.metadata, parsed),
            else => {},
        }
    }

    pub fn collectRows(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Row) {
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        var spans = try self.zones.collectSpans(allocator);
        defer spans.deinit(allocator);
        for (spans.items) |span| {
            const end_ns = if (span.state == .open)
                self.end_ns orelse span.start_ns
            else
                span.end_ns;
            const row = Row{
                .kind = .zone,
                .event = "zone",
                .time_ns = span.start_ns,
                .end_ns = end_ns,
                .duration_ns = if (span.state == .open and end_ns >= span.start_ns)
                    end_ns - span.start_ns
                else
                    span.total_ns,
                .thread = span.thread,
                .depth = span.depth,
                .id = span.id,
                .state = span.state,
                .duration_valid = span.duration_valid,
                .name = span.name,
                .text = span.text,
                .file = span.file,
                .function = span.function,
                .line = span.line,
                .column = span.column,
                .color = span.color,
                .value_u64 = span.value,
            };
            if (!rowMatches(row, options)) continue;
            try rows.append(allocator, row);
        }
        for (self.instants.items) |instant| {
            const row = instantRow(instant);
            if (!rowMatches(row, options)) continue;
            try rows.append(allocator, row);
        }
        sortRows(rows.items, options.sort);
        return rows;
    }

    pub fn durationNs(self: Analyzer) u64 {
        const start_ns = self.start_ns orelse return 0;
        const end_ns = self.end_ns orelse return 0;
        if (end_ns <= start_ns) return 0;
        return end_ns - start_ns;
    }

    fn recordInstant(self: *Analyzer, kind: Kind, parsed: event.Parsed) !void {
        try self.instants.append(self.allocator, .{
            .kind = kind,
            .event = parsed.kind.tag(),
            .time_ns = parsed.time_ns,
            .thread = parsed.thread,
            .id = parsed.id,
            .name = try dupeOptional(self.allocator, parsed.name),
            .text = try dupeOptional(self.allocator, parsed.text),
            .file = try dupeOptional(self.allocator, parsed.file),
            .function = try dupeOptional(self.allocator, parsed.function),
            .line = parsed.line,
            .column = parsed.column,
            .color = parsed.color,
            .value_u64 = parsed.value_u64,
            .value_i64 = parsed.value_i64,
            .value_f64 = parsed.value_f64,
            .address = parsed.address,
            .size = parsed.size,
            .depth = parsed.depth,
            .cpu = parsed.cpu,
            .prev_thread = parsed.prev_thread,
            .next_thread = parsed.next_thread,
            .target_thread = parsed.target_thread,
            .pid = parsed.pid,
            .previous_cstate = parsed.previous_cstate,
            .prev_priority = parsed.prev_priority,
            .next_priority = parsed.next_priority,
            .group_hint = parsed.group_hint,
            .gpu_context = parsed.gpu_context,
            .gpu_query = parsed.gpu_query,
            .gpu_time = parsed.gpu_time,
            .gpu_period = parsed.gpu_period,
            .gpu_cpu_delta_ns = parsed.gpu_cpu_delta_ns,
            .gpu_context_type = try dupeOptional(self.allocator, parsed.gpu_context_type),
            .gpu_has_calibration = parsed.gpu_has_calibration,
            .gpu_serial = parsed.gpu_serial,
            .gpu_annotation_id = parsed.gpu_annotation_id,
            .cpu_package = parsed.cpu_package,
            .cpu_die = parsed.cpu_die,
            .cpu_core = parsed.cpu_core,
            .power_delta_uj = parsed.power_delta_uj,
            .hw_sample_kind = try dupeOptional(self.allocator, parsed.hw_sample_kind),
            .plot_kind = try dupeOptional(self.allocator, parsed.plot_kind),
            .plot_unit = try dupeOptional(self.allocator, parsed.plot_unit),
            .plot_step = parsed.plot_step,
            .plot_fill = parsed.plot_fill,
            .lock_kind = try dupeOptional(self.allocator, parsed.lock_kind),
            .sample_kind = try dupeOptional(self.allocator, parsed.sample_kind),
            .context_reason = try dupeOptional(self.allocator, parsed.context_reason),
            .context_state = try dupeOptional(self.allocator, parsed.context_state),
        });
        self.counters.instants += 1;
        if (kind == .metadata) self.counters.metadata += 1;
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
    var rows = try analyzer.collectRows(allocator, options);
    defer rows.deinit(allocator);
    try writeTextSummary(analyzer, writer, options, rows.items.len);
    try analyzer.zones.evidence().writeText(writer);
    const limit = @min(options.top, rows.items.len);
    for (rows.items[0..limit]) |row| try writeTextRow(writer, row);
}

fn writeTextSummary(
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
    rows: usize,
) !void {
    try writer.print(
        "tracy timeline rows={d} events={d} zones={d} completed_zones={d} " ++
            "open_zones={d} instants={d} metadata={d} duration_ns={d} " ++
            "kind={s} sort={s}\n",
        .{
            rows,
            analyzer.counters.events,
            analyzer.zones.counters.started_zones,
            analyzer.zones.counters.completed_zones,
            analyzer.zones.active.count(),
            analyzer.counters.instants,
            analyzer.counters.metadata,
            analyzer.durationNs(),
            options.kind.tag(),
            options.sort.tag(),
        },
    );
}

fn writeTextRow(writer: *std.Io.Writer, row: Row) !void {
    try writer.print(
        "timeline kind={s} event={s} time_ns={d}",
        .{ row.kind.tag(), row.event, row.time_ns },
    );
    if (row.kind == .zone) {
        try writer.print(
            " end_ns={d} duration_ns={d} state={s} depth={d}",
            .{ row.end_ns, row.duration_ns, row.state.tag(), row.depth },
        );
    }
    try writer.print(" thread={d}", .{row.thread});
    if (row.id != 0) try writer.print(" id={d}", .{row.id});
    if (row.name) |name| {
        try writer.writeAll(" name=");
        try pretty_json.writeString(writer, name);
    }
    if (row.text) |text| {
        try writer.writeAll(" text=");
        try pretty_json.writeString(writer, text);
    }
    if (row.file) |file| try writer.print(" file={s}:{d}", .{ file, row.line });
    if (row.function) |function| {
        try writer.writeAll(" function=");
        try pretty_json.writeString(writer, function);
    }
    try writeValueText(writer, row);
    try writeTextDetails(writer, row);
    try writer.writeByte('\n');
}

fn writeTextDetails(writer: *std.Io.Writer, row: Row) !void {
    if (row.color) |color| try writer.print(" color={d}", .{color});
    if (row.address != 0) try writer.print(" address={d}", .{row.address});
    if (row.size != 0) try writer.print(" size={d}", .{row.size});
    if (std.mem.eql(u8, row.event, "sample.frame")) {
        try writer.print(" depth={d}", .{row.sample_depth});
    }
    if (row.cpu) |cpu| try writer.print(" cpu={d}", .{cpu});
    if (row.prev_thread != 0) try writer.print(" prev_thread={d}", .{row.prev_thread});
    if (row.next_thread != 0) try writer.print(" next_thread={d}", .{row.next_thread});
    if (row.target_thread != 0) try writer.print(" target_thread={d}", .{row.target_thread});
    if (row.pid != 0) try writer.print(" pid={d}", .{row.pid});
    if (row.previous_cstate) |value| try writer.print(" previous_cstate={d}", .{value});
    if (row.prev_priority) |value| try writer.print(" prev_priority={d}", .{value});
    if (row.next_priority) |value| try writer.print(" next_priority={d}", .{value});
    if (row.group_hint) |value| try writer.print(" group_hint={d}", .{value});
    try writeGpuFieldsText(writer, row);
    try writeSystemFieldsText(writer, row);
    if (row.plot_kind) |plot_kind| {
        try writer.writeAll(" plot_kind=");
        try pretty_json.writeString(writer, plot_kind);
    }
    try writePlotFieldsText(writer, row);
    try writeTextLabels(writer, row);
    if (row.kind == .zone) try writer.print(" duration_valid={}", .{row.duration_valid});
}

fn writeTextLabels(writer: *std.Io.Writer, row: Row) !void {
    if (row.lock_kind) |value| {
        try writer.writeAll(" lock_kind=");
        try pretty_json.writeString(writer, value);
    }
    if (row.sample_kind) |value| {
        try writer.writeAll(" sample_kind=");
        try pretty_json.writeString(writer, value);
    }
    if (row.context_reason) |value| {
        try writer.writeAll(" context_reason=");
        try pretty_json.writeString(writer, value);
    }
    if (row.context_state) |value| {
        try writer.writeAll(" context_state=");
        try pretty_json.writeString(writer, value);
    }
}

fn writeJsonl(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var rows = try analyzer.collectRows(allocator, options);
    defer rows.deinit(allocator);
    try writeJsonSummary(analyzer, writer, options, rows.items.len);
    const limit = @min(options.top, rows.items.len);
    for (rows.items[0..limit]) |row| try writeJsonRow(writer, row);
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
    try object.field("events", analyzer.counters.events);
    try object.field("zones", analyzer.zones.counters.started_zones);
    try object.field("completed_zones", analyzer.zones.counters.completed_zones);
    try object.field("open_zones", analyzer.zones.active.count());
    try object.field("instants", analyzer.counters.instants);
    try object.field("metadata", analyzer.counters.metadata);
    try object.field("duration_ns", analyzer.durationNs());
    try object.field("filter_kind", options.kind.tag());
    try object.field("sort", options.sort.tag());
    try analyzer.zones.evidence().writeFields(object);
    try object.endLine();
}

fn writeJsonRow(writer: *std.Io.Writer, row: Row) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", row.kind.tag());
    try object.field("event", row.event);
    try object.field("time_ns", row.time_ns);
    try object.field("thread", row.thread);
    if (row.kind == .zone) {
        try object.field("end_ns", row.end_ns);
        try object.field("duration_ns", row.duration_ns);
        try object.field("state", row.state.tag());
        try object.field("duration_valid", row.duration_valid);
        try object.field("depth", row.depth);
    }
    if (row.id != 0) try object.field("id", row.id);
    if (row.name) |name| try object.field("name", name);
    if (row.text) |value| try object.field("text", value);
    if (row.file) |value| {
        try object.field("file", value);
        try object.field("line", row.line);
    }
    if (row.function) |value| try object.field("function", value);
    try writeValueField(object, row);
    try writeFields(object, row);
    try object.endLine();
}

fn writeFields(object: pretty_json.Object, row: Row) !void {
    if (row.color) |value| try object.field("color", value);
    if (row.address != 0) try object.field("address", row.address);
    if (row.size != 0) try object.field("size", row.size);
    if (std.mem.eql(u8, row.event, "sample.frame")) try object.field("depth", row.sample_depth);
    if (row.cpu) |value| try object.field("cpu", value);
    if (row.prev_thread != 0) try object.field("prev_thread", row.prev_thread);
    if (row.next_thread != 0) try object.field("next_thread", row.next_thread);
    if (row.target_thread != 0) try object.field("target_thread", row.target_thread);
    if (row.pid != 0) try object.field("pid", row.pid);
    if (row.previous_cstate) |value| try object.field("previous_cstate", value);
    if (row.prev_priority) |value| try object.field("prev_priority", value);
    if (row.next_priority) |value| try object.field("next_priority", value);
    if (row.group_hint) |value| try object.field("group_hint", value);
    try writeGpuFields(object, row);
    try writeSystemFields(object, row);
    if (row.plot_kind) |value| try object.field("plot_kind", value);
    try writePlotFields(object, row);
    try writeLabels(object, row);
}

fn writeLabels(object: pretty_json.Object, row: Row) !void {
    if (row.lock_kind) |value| try object.field("lock_kind", value);
    if (row.sample_kind) |value| try object.field("sample_kind", value);
    if (row.context_reason) |value| try object.field("context_reason", value);
    if (row.context_state) |value| try object.field("context_state", value);
}

fn rowMatches(row: Row, options: Options) bool {
    if (options.kind != .all and row.kind != options.kind) return false;
    if (options.thread) |thread| {
        if (row.thread != thread) return false;
    }
    if (row.kind == .zone and row.duration_ns < options.min_duration_ns) return false;
    if (options.since_ns) |since_ns| {
        const row_end = if (row.kind == .zone) row.end_ns else row.time_ns;
        if (row_end < since_ns) return false;
    }
    if (options.until_ns) |until_ns| {
        if (row.time_ns > until_ns) return false;
    }
    if (options.match) |needle| {
        if (!rowContains(row, needle)) return false;
    }
    return true;
}

fn rowContains(row: Row, needle: []const u8) bool {
    if (contains(row.kind.tag(), needle)) return true;
    if (contains(row.event, needle)) return true;
    if (row.name) |name| if (contains(name, needle)) return true;
    if (row.text) |text| if (contains(text, needle)) return true;
    if (row.file) |file| if (contains(file, needle)) return true;
    if (row.function) |function| if (contains(function, needle)) return true;
    if (row.plot_kind) |plot_kind| if (contains(plot_kind, needle)) return true;
    if (row.plot_unit) |plot_unit| if (contains(plot_unit, needle)) return true;
    if (row.lock_kind) |lock_kind| if (contains(lock_kind, needle)) return true;
    if (row.sample_kind) |sample_kind| if (contains(sample_kind, needle)) return true;
    if (row.gpu_context_type) |context_type| if (contains(context_type, needle)) return true;
    if (row.hw_sample_kind) |sample_kind| if (contains(sample_kind, needle)) return true;
    if (row.context_reason) |context_reason| if (contains(context_reason, needle)) return true;
    if (row.context_state) |context_state| if (contains(context_state, needle)) return true;
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn instantRow(instant: Instant) Row {
    return .{
        .kind = instant.kind,
        .event = instant.event,
        .time_ns = instant.time_ns,
        .thread = instant.thread,
        .id = instant.id,
        .name = instant.name,
        .text = instant.text,
        .file = instant.file,
        .function = instant.function,
        .line = instant.line,
        .column = instant.column,
        .color = instant.color,
        .value_u64 = instant.value_u64,
        .value_i64 = instant.value_i64,
        .value_f64 = instant.value_f64,
        .address = instant.address,
        .size = instant.size,
        .sample_depth = instant.depth,
        .cpu = instant.cpu,
        .prev_thread = instant.prev_thread,
        .next_thread = instant.next_thread,
        .target_thread = instant.target_thread,
        .pid = instant.pid,
        .previous_cstate = instant.previous_cstate,
        .prev_priority = instant.prev_priority,
        .next_priority = instant.next_priority,
        .group_hint = instant.group_hint,
        .gpu_context = instant.gpu_context,
        .gpu_query = instant.gpu_query,
        .gpu_time = instant.gpu_time,
        .gpu_period = instant.gpu_period,
        .gpu_cpu_delta_ns = instant.gpu_cpu_delta_ns,
        .gpu_context_type = instant.gpu_context_type,
        .gpu_has_calibration = instant.gpu_has_calibration,
        .gpu_serial = instant.gpu_serial,
        .gpu_annotation_id = instant.gpu_annotation_id,
        .cpu_package = instant.cpu_package,
        .cpu_die = instant.cpu_die,
        .cpu_core = instant.cpu_core,
        .power_delta_uj = instant.power_delta_uj,
        .hw_sample_kind = instant.hw_sample_kind,
        .plot_kind = instant.plot_kind,
        .plot_unit = instant.plot_unit,
        .plot_step = instant.plot_step,
        .plot_fill = instant.plot_fill,
        .lock_kind = instant.lock_kind,
        .sample_kind = instant.sample_kind,
        .context_reason = instant.context_reason,
        .context_state = instant.context_state,
    };
}

fn sortRows(items: []Row, sort: Sort) void {
    std.mem.sort(Row, items, sort, rowLessThan);
}

fn rowLessThan(sort: Sort, left: Row, right: Row) bool {
    return switch (sort) {
        .time => rowTimeLessThan({}, left, right),
        .duration => rowDurationGreaterThan({}, left, right),
    };
}

fn rowTimeLessThan(_: void, left: Row, right: Row) bool {
    if (left.time_ns != right.time_ns) return left.time_ns < right.time_ns;
    if (left.duration_ns != right.duration_ns) return left.duration_ns > right.duration_ns;
    return std.mem.lessThan(u8, left.event, right.event);
}

fn rowDurationGreaterThan(_: void, left: Row, right: Row) bool {
    if (left.duration_ns != right.duration_ns) return left.duration_ns > right.duration_ns;
    return rowTimeLessThan({}, left, right);
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
}

fn writeValueText(writer: *std.Io.Writer, row: Row) !void {
    if (row.value_f64) |value| {
        try writer.print(" value={d}", .{value});
    } else if (row.value_i64) |value| {
        try writer.print(" value={d}", .{value});
    } else if (row.value_u64) |value| {
        try writer.print(" value={d}", .{value});
    }
}

fn writeValueField(object: pretty_json.Object, row: Row) !void {
    if (row.value_f64) |value| {
        try object.field("value", value);
    } else if (row.value_i64) |value| {
        try object.field("value", value);
    } else if (row.value_u64) |value| {
        try object.field("value", value);
    }
}

fn writePlotFieldsText(writer: *std.Io.Writer, row: Row) !void {
    if (row.plot_unit) |plot_unit| {
        try writer.writeAll(" plot_unit=");
        try pretty_json.writeString(writer, plot_unit);
    }
    if (std.mem.eql(u8, row.event, "plot.config")) {
        try writer.print(" plot_step={} plot_fill={}", .{ row.plot_step, row.plot_fill });
    }
}

fn writePlotFields(object: pretty_json.Object, row: Row) !void {
    if (row.plot_unit) |plot_unit| try object.field("plot_unit", plot_unit);
    if (std.mem.eql(u8, row.event, "plot.config")) {
        try object.field("plot_step", row.plot_step);
        try object.field("plot_fill", row.plot_fill);
    }
}

fn writeGpuFieldsText(writer: *std.Io.Writer, row: Row) !void {
    if (row.gpu_context) |context| try writer.print(" gpu_context={d}", .{context});
    if (row.gpu_query) |query| try writer.print(" gpu_query={d}", .{query});
    if (row.gpu_time) |gpu_time| try writer.print(" gpu_time={d}", .{gpu_time});
    if (row.gpu_period) |period| try writer.print(" gpu_period={d}", .{period});
    if (row.gpu_cpu_delta_ns) |delta| try writer.print(" gpu_cpu_delta_ns={d}", .{delta});
    if (row.gpu_context_type) |context_type| {
        try writer.writeAll(" gpu_context_type=");
        try pretty_json.writeString(writer, context_type);
    }
    if (row.gpu_has_calibration) try writer.writeAll(" gpu_has_calibration=true");
    if (row.gpu_serial) try writer.writeAll(" gpu_serial=true");
    if (row.gpu_annotation_id) |annotation_id| try writer.print(" gpu_annotation_id={d}", .{annotation_id});
}

fn writeGpuFields(object: pretty_json.Object, row: Row) !void {
    if (row.gpu_context) |context| try object.field("gpu_context", context);
    if (row.gpu_query) |query| try object.field("gpu_query", query);
    if (row.gpu_time) |gpu_time| try object.field("gpu_time", gpu_time);
    if (row.gpu_period) |period| try object.field("gpu_period", period);
    if (row.gpu_cpu_delta_ns) |delta| try object.field("gpu_cpu_delta_ns", delta);
    if (row.gpu_context_type) |context_type| try object.field("gpu_context_type", context_type);
    if (row.gpu_has_calibration) try object.field("gpu_has_calibration", true);
    if (row.gpu_serial) try object.field("gpu_serial", true);
    if (row.gpu_annotation_id) |annotation_id| try object.field("gpu_annotation_id", annotation_id);
}

fn writeSystemFieldsText(writer: *std.Io.Writer, row: Row) !void {
    if (row.cpu_package) |package| try writer.print(" cpu_package={d}", .{package});
    if (row.cpu_die) |die| try writer.print(" cpu_die={d}", .{die});
    if (row.cpu_core) |core| try writer.print(" cpu_core={d}", .{core});
    if (row.power_delta_uj) |delta| try writer.print(" power_delta_uj={d}", .{delta});
    if (row.hw_sample_kind) |kind| {
        try writer.writeAll(" hw_sample_kind=");
        try pretty_json.writeString(writer, kind);
    }
}

fn writeSystemFields(object: pretty_json.Object, row: Row) !void {
    if (row.cpu_package) |package| try object.field("cpu_package", package);
    if (row.cpu_die) |die| try object.field("cpu_die", die);
    if (row.cpu_core) |core| try object.field("cpu_core", core);
    if (row.power_delta_uj) |delta| try object.field("power_delta_uj", delta);
    if (row.hw_sample_kind) |kind| try object.field("hw_sample_kind", kind);
}

test "timeline combines spans and instant events by time" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 90, .thread = 1, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .thread_name, .time_ns = 95, .thread = 1, .name = "main" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_begin, .time_ns = 100, .thread = 1, .id = 1, .name = "root", .file = "root.zig", .line = 7 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .zone_begin, .time_ns = 120, .thread = 1, .id = 2, .name = "child" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .message, .time_ns = 125, .thread = 1, .text = "inside child" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .zone_text, .time_ns = 130, .thread = 1, .id = 2, .text = "child detail" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .zone_end, .time_ns = 150, .thread = 1, .id = 2 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 8, .kind = .plot, .time_ns = 155, .thread = 1, .name = "latency.ns", .value_i64 = 30, .plot_kind = "int" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 9, .kind = .alloc, .time_ns = 170, .thread = 1, .name = "arena", .address = 4096, .size = 64 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 10, .kind = .zone_end, .time_ns = 210, .thread = 1, .id = 1 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 11, .kind = .stop, .time_ns = 220, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .top = 8, .sort = .time });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy timeline rows=7 events=11 zones=2 completed_zones=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=zone event=zone time_ns=100 end_ns=210 duration_ns=110 state=complete depth=0 thread=1 id=1 name=\"root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=zone event=zone time_ns=120 end_ns=150 duration_ns=30 state=complete depth=1 thread=1 id=2 name=\"child\" text=\"child detail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=message event=message time_ns=125 thread=1 text=\"inside child\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=plot event=plot time_ns=155 thread=1 name=\"latency.ns\" value=30 plot_kind=\"int\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=alloc event=alloc time_ns=170 thread=1 name=\"arena\" address=4096 size=64") != null);
}

test "timeline jsonl filters by window kind and match text" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .zone_begin, .time_ns = 100, .thread = 1, .id = 1, .name = "root" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .message, .time_ns = 120, .thread = 1, .text = "queue ready" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .message, .time_ns = 180, .thread = 2, .text = "other thread" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .zone_text, .time_ns = 190, .thread = 1, .id = 1, .text = "root detail" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .zone_end, .time_ns = 240, .thread = 1, .id = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4, .kind = .message, .since_ns = 110, .until_ns = 140, .match = "queue" });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.timeline/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"summary\",\"rows\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"text\":\"queue ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"other thread\"") == null);
}

test "timeline includes sample instants and frames" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .sample, .time_ns = 100, .thread = 1, .id = 9, .name = "tick", .sample_kind = "cpu", .file = "hot.zig", .line = 4 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .sample_frame, .time_ns = 100, .thread = 1, .id = 9, .depth = 1, .name = "hot", .sample_kind = "cpu" }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4, .kind = .sample });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy timeline rows=2 events=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=sample event=sample time_ns=100 thread=1 id=9 name=\"tick\" file=hot.zig:4 sample_kind=\"cpu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=sample event=sample.frame time_ns=100 thread=1 id=9 name=\"hot\" depth=1 sample_kind=\"cpu\"") != null);
}

test "timeline includes context switches and wakeups" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .context_switch, .time_ns = 100, .thread = 1, .cpu = 0, .prev_thread = 10, .next_thread = 11, .context_reason = "WrPreempted", .context_state = "Ready" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .thread_wakeup, .time_ns = 120, .thread = 1, .target_thread = 10, .cpu = 0, .context_reason = "Unwait" }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4, .kind = .context });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy timeline rows=2 events=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=context event=context.switch time_ns=100 thread=1 cpu=0 prev_thread=10 next_thread=11 context_reason=\"WrPreempted\" context_state=\"Ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=context event=thread.wakeup time_ns=120 thread=1 cpu=0 target_thread=10 context_reason=\"Unwait\"") != null);
}

test "timeline includes fiber instants" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .fiber_name, .time_ns = 90, .thread = 10, .id = 7, .name = "job.parse", .group_hint = 3 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .fiber_enter, .time_ns = 100, .thread = 10, .id = 7, .name = "job.parse", .group_hint = 3 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .fiber_leave, .time_ns = 140, .thread = 10, .id = 7 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4, .kind = .fiber });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy timeline rows=3 events=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=fiber event=fiber.name time_ns=90 thread=10 id=7 name=\"job.parse\" group_hint=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=fiber event=fiber.enter time_ns=100 thread=10 id=7 name=\"job.parse\" group_hint=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=fiber event=fiber.leave time_ns=140 thread=10 id=7") != null);
}

test "timeline includes gpu instants" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .gpu_context, .time_ns = 90, .thread = 10, .gpu_context = 2, .name = "render", .gpu_period = 1.0, .gpu_context_type = "vulkan" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .gpu_zone_begin, .time_ns = 100, .thread = 10, .gpu_context = 2, .gpu_query = 11, .name = "draw" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .gpu_time, .time_ns = 140, .thread = 10, .gpu_context = 2, .gpu_query = 11, .gpu_time = 55 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4, .kind = .gpu });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy timeline rows=3 events=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=gpu event=gpu.context time_ns=90 thread=10 name=\"render\" gpu_context=2 gpu_period=1 gpu_context_type=\"vulkan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=gpu event=gpu.zone.begin time_ns=100 thread=10 name=\"draw\" gpu_context=2 gpu_query=11") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=gpu event=gpu.time time_ns=140 thread=10 gpu_context=2 gpu_query=11 gpu_time=55") != null);
}

test "timeline includes system instants" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .thread_pid, .time_ns = 90, .thread = 42, .pid = 900 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .cpu_topology, .time_ns = 100, .thread = 1, .cpu = 7, .cpu_package = 1, .cpu_die = 0, .cpu_core = 3 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .hw_sample, .time_ns = 110, .thread = 42, .cpu = 7, .address = 0xabc, .hw_sample_kind = "cache-miss" }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .top = 4, .kind = .system });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy timeline rows=3 events=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=system event=thread.pid time_ns=90 thread=42 pid=900") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=system event=cpu.topology time_ns=100 thread=1 cpu=7 cpu_package=1 cpu_die=0 cpu_core=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timeline kind=system event=hw.sample time_ns=110 thread=42 address=2748 cpu=7 hw_sample_kind=\"cache-miss\"") != null);
}

test "timeline preserves plot configuration metadata" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{
        .seq = 1,
        .kind = .plot_config,
        .time_ns = 100,
        .thread = 1,
        .name = "heap.live",
        .color = 7,
        .plot_unit = "bytes",
        .plot_step = true,
        .plot_fill = true,
    }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var text_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text_out.deinit();
    try writeText(std.testing.allocator, &analyzer, &text_out.writer, .{ .kind = .plot });
    const text_metadata =
        "name=\"heap.live\" color=7 plot_unit=\"bytes\" plot_step=true plot_fill=true";
    try std.testing.expect(std.mem.indexOf(u8, text_out.written(), text_metadata) != null);

    var json_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json_out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &json_out.writer, .{ .kind = .plot });
    const json = json_out.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"plot.config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plot_unit\":\"bytes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plot_step\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plot_fill\":true") != null);
}
