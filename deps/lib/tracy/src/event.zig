const std = @import("std");
const pretty_json = @import("pretty").json;

pub const schema = "tracy.event/v0";
pub const format_version: u32 = 0;

pub const Kind = enum {
    start,
    stop,
    zone_begin,
    zone_end,
    zone_text,
    zone_name,
    zone_color,
    zone_value,
    frame,
    message,
    app_info,
    plot_config,
    plot,
    alloc,
    free,
    thread_name,
    fiber_enter,
    fiber_leave,
    fiber_name,
    gpu_context,
    gpu_context_name,
    gpu_zone_begin,
    gpu_zone_end,
    gpu_time,
    gpu_calibration,
    gpu_time_sync,
    gpu_annotation,
    gpu_annotation_name,
    thread_context,
    thread_pid,
    cpu_topology,
    sys_time,
    sys_power,
    hw_sample,
    sample,
    sample_frame,
    context_switch,
    thread_wakeup,
    lock_announce,
    lock_terminate,
    lock_wait,
    lock_obtain,
    lock_release,
    lock_shared_wait,
    lock_shared_obtain,
    lock_shared_release,
    lock_mark,
    lock_name,

    pub fn tag(self: Kind) []const u8 {
        return switch (self) {
            .start => "start",
            .stop => "stop",
            .zone_begin => "zone.begin",
            .zone_end => "zone.end",
            .zone_text => "zone.text",
            .zone_name => "zone.name",
            .zone_color => "zone.color",
            .zone_value => "zone.value",
            .frame => "frame",
            .message => "message",
            .app_info => "app.info",
            .plot_config => "plot.config",
            .plot => "plot",
            .alloc => "alloc",
            .free => "free",
            .thread_name => "thread.name",
            .fiber_enter => "fiber.enter",
            .fiber_leave => "fiber.leave",
            .fiber_name => "fiber.name",
            .gpu_context => "gpu.context",
            .gpu_context_name => "gpu.context.name",
            .gpu_zone_begin => "gpu.zone.begin",
            .gpu_zone_end => "gpu.zone.end",
            .gpu_time => "gpu.time",
            .gpu_calibration => "gpu.calibration",
            .gpu_time_sync => "gpu.time_sync",
            .gpu_annotation => "gpu.annotation",
            .gpu_annotation_name => "gpu.annotation.name",
            .thread_context => "thread.context",
            .thread_pid => "thread.pid",
            .cpu_topology => "cpu.topology",
            .sys_time => "sys.time",
            .sys_power => "sys.power",
            .hw_sample => "hw.sample",
            .sample => "sample",
            .sample_frame => "sample.frame",
            .context_switch => "context.switch",
            .thread_wakeup => "thread.wakeup",
            .lock_announce => "lock.announce",
            .lock_terminate => "lock.terminate",
            .lock_wait => "lock.wait",
            .lock_obtain => "lock.obtain",
            .lock_release => "lock.release",
            .lock_shared_wait => "lock.shared.wait",
            .lock_shared_obtain => "lock.shared.obtain",
            .lock_shared_release => "lock.shared.release",
            .lock_mark => "lock.mark",
            .lock_name => "lock.name",
        };
    }

    pub fn fromTag(text: []const u8) ?Kind {
        if (std.mem.eql(u8, text, "start")) return .start;
        if (std.mem.eql(u8, text, "stop")) return .stop;
        if (std.mem.eql(u8, text, "zone.begin")) return .zone_begin;
        if (std.mem.eql(u8, text, "zone.end")) return .zone_end;
        if (std.mem.eql(u8, text, "zone.text")) return .zone_text;
        if (std.mem.eql(u8, text, "zone.name")) return .zone_name;
        if (std.mem.eql(u8, text, "zone.color")) return .zone_color;
        if (std.mem.eql(u8, text, "zone.value")) return .zone_value;
        if (std.mem.eql(u8, text, "frame")) return .frame;
        if (std.mem.eql(u8, text, "message")) return .message;
        if (std.mem.eql(u8, text, "app.info")) return .app_info;
        if (std.mem.eql(u8, text, "plot.config")) return .plot_config;
        if (std.mem.eql(u8, text, "plot")) return .plot;
        if (std.mem.eql(u8, text, "alloc")) return .alloc;
        if (std.mem.eql(u8, text, "free")) return .free;
        if (std.mem.eql(u8, text, "thread.name")) return .thread_name;
        if (std.mem.eql(u8, text, "fiber.enter")) return .fiber_enter;
        if (std.mem.eql(u8, text, "fiber.leave")) return .fiber_leave;
        if (std.mem.eql(u8, text, "fiber.name")) return .fiber_name;
        if (std.mem.eql(u8, text, "gpu.context")) return .gpu_context;
        if (std.mem.eql(u8, text, "gpu.context.name")) return .gpu_context_name;
        if (std.mem.eql(u8, text, "gpu.zone.begin")) return .gpu_zone_begin;
        if (std.mem.eql(u8, text, "gpu.zone.end")) return .gpu_zone_end;
        if (std.mem.eql(u8, text, "gpu.time")) return .gpu_time;
        if (std.mem.eql(u8, text, "gpu.calibration")) return .gpu_calibration;
        if (std.mem.eql(u8, text, "gpu.time_sync")) return .gpu_time_sync;
        if (std.mem.eql(u8, text, "gpu.annotation")) return .gpu_annotation;
        if (std.mem.eql(u8, text, "gpu.annotation.name")) return .gpu_annotation_name;
        if (std.mem.eql(u8, text, "thread.context")) return .thread_context;
        if (std.mem.eql(u8, text, "thread.pid")) return .thread_pid;
        if (std.mem.eql(u8, text, "cpu.topology")) return .cpu_topology;
        if (std.mem.eql(u8, text, "sys.time")) return .sys_time;
        if (std.mem.eql(u8, text, "sys.power")) return .sys_power;
        if (std.mem.eql(u8, text, "hw.sample")) return .hw_sample;
        if (std.mem.eql(u8, text, "sample")) return .sample;
        if (std.mem.eql(u8, text, "sample.frame")) return .sample_frame;
        if (std.mem.eql(u8, text, "context.switch")) return .context_switch;
        if (std.mem.eql(u8, text, "thread.wakeup")) return .thread_wakeup;
        if (std.mem.eql(u8, text, "lock.announce")) return .lock_announce;
        if (std.mem.eql(u8, text, "lock.terminate")) return .lock_terminate;
        if (std.mem.eql(u8, text, "lock.wait")) return .lock_wait;
        if (std.mem.eql(u8, text, "lock.obtain")) return .lock_obtain;
        if (std.mem.eql(u8, text, "lock.release")) return .lock_release;
        if (std.mem.eql(u8, text, "lock.shared.wait")) return .lock_shared_wait;
        if (std.mem.eql(u8, text, "lock.shared.obtain")) return .lock_shared_obtain;
        if (std.mem.eql(u8, text, "lock.shared.release")) return .lock_shared_release;
        if (std.mem.eql(u8, text, "lock.mark")) return .lock_mark;
        if (std.mem.eql(u8, text, "lock.name")) return .lock_name;
        return null;
    }

    /// Reads the wire tag, so that `zone_begin` parses from `"zone.begin"`.
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Kind {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const text = switch (token) {
            .string, .allocated_string => |text| text,
            else => return error.UnexpectedToken,
        };
        return fromTag(text) orelse error.InvalidEnumTag;
    }
};

pub const TraceEvent = struct {
    seq: u64 = 0,
    kind: Kind,
    time_ns: u64 = 0,
    thread: u64 = 0,
    id: u64 = 0,
    name: ?[]const u8 = null,
    text: ?[]const u8 = null,
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
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

    pub fn writeJsonLine(self: TraceEvent, writer: *std.Io.Writer) !void {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("v", format_version);
        try object.field("seq", self.seq);
        try object.field("kind", self.kind.tag());
        try object.field("time_ns", self.time_ns);
        try object.field("thread", self.thread);
        if (self.id != 0) try object.field("id", self.id);
        if (self.name) |name| try object.field("name", name);
        if (self.text) |text| try object.field("text", text);
        if (self.function) |function| try object.field("function", function);
        if (self.file) |file| try object.field("file", file);
        if (self.line != 0) try object.field("line", self.line);
        if (self.column != 0) try object.field("column", self.column);
        if (self.color) |color| try object.field("color", color);
        if (self.value_u64) |value| try object.field("value_u64", value);
        if (self.value_i64) |value| try object.field("value_i64", value);
        if (self.value_f64) |value| {
            if (std.math.isFinite(value)) try object.field("value_f64", value);
        }
        if (self.address != 0) try object.field("address", self.address);
        if (self.size != 0) try object.field("size", self.size);
        if (self.depth != 0) try object.field("depth", self.depth);
        if (self.cpu) |cpu| try object.field("cpu", cpu);
        if (self.prev_thread != 0) try object.field("prev_thread", self.prev_thread);
        if (self.next_thread != 0) try object.field("next_thread", self.next_thread);
        if (self.target_thread != 0) try object.field("target_thread", self.target_thread);
        if (self.pid != 0) try object.field("pid", self.pid);
        if (self.previous_cstate) |previous_cstate| try object.field("previous_cstate", previous_cstate);
        if (self.prev_priority) |prev_priority| try object.field("prev_priority", prev_priority);
        if (self.next_priority) |next_priority| try object.field("next_priority", next_priority);
        if (self.group_hint) |group_hint| try object.field("group_hint", group_hint);
        if (self.gpu_context) |gpu_context| try object.field("gpu_context", gpu_context);
        if (self.gpu_query) |gpu_query| try object.field("gpu_query", gpu_query);
        if (self.gpu_time) |gpu_time| try object.field("gpu_time", gpu_time);
        if (self.gpu_period) |gpu_period| {
            if (std.math.isFinite(gpu_period)) try object.field("gpu_period", gpu_period);
        }
        if (self.gpu_cpu_delta_ns) |value| try object.field("gpu_cpu_delta_ns", value);
        if (self.gpu_context_type) |value| try object.field("gpu_context_type", value);
        if (self.gpu_has_calibration) try object.field("gpu_has_calibration", true);
        if (self.gpu_serial) try object.field("gpu_serial", true);
        if (self.gpu_annotation_id) |value| try object.field("gpu_annotation_id", value);
        if (self.cpu_package) |value| try object.field("cpu_package", value);
        if (self.cpu_die) |value| try object.field("cpu_die", value);
        if (self.cpu_core) |value| try object.field("cpu_core", value);
        if (self.power_delta_uj) |value| try object.field("power_delta_uj", value);
        if (self.hw_sample_kind) |value| try object.field("hw_sample_kind", value);
        if (self.plot_kind) |value| try object.field("plot_kind", value);
        if (self.plot_unit) |value| try object.field("plot_unit", value);
        if (self.plot_step) try object.field("plot_step", true);
        if (self.plot_fill) try object.field("plot_fill", true);
        if (self.lock_kind) |value| try object.field("lock_kind", value);
        if (self.sample_kind) |value| try object.field("sample_kind", value);
        if (self.context_reason) |value| try object.field("context_reason", value);
        if (self.context_state) |value| try object.field("context_state", value);
        try object.endLine();
    }
};

/// One trace event line, field for field as `TraceEvent.writeJsonLine`
/// writes it. A field the writer omits takes the value the writer omitted.
/// `schema` is optional because earlier writers wrote only `v`.
pub const Record = struct {
    schema: ?[]const u8 = null,
    v: u64,
    seq: u64 = 0,
    kind: Kind,
    time_ns: u64 = 0,
    thread: u64 = 0,
    id: u64 = 0,
    name: ?[]const u8 = null,
    text: ?[]const u8 = null,
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
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

pub const Parsed = struct {
    tree: std.json.Parsed(Record),
    kind: Kind,
    seq: u64 = 0,
    time_ns: u64 = 0,
    thread: u64 = 0,
    id: u64 = 0,
    name: ?[]const u8 = null,
    text: ?[]const u8 = null,
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
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

    pub fn deinit(self: *Parsed) void {
        self.tree.deinit();
        self.* = undefined;
    }
};

/// Parses one event line. Strings are copied into the result, so it
/// outlives `line` until `deinit`.
pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) !Parsed {
    const text = std.mem.trim(u8, line, " \t\r\n");
    if (text.len == 0) return error.EmptyEventLine;
    var tree = std.json.parseFromSlice(Record, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return headerFault(allocator, text),
    };
    errdefer tree.deinit();
    const record = tree.value;
    if (record.schema) |actual| {
        if (!std.mem.eql(u8, actual, schema)) return error.UnsupportedTraceSchema;
    }
    if (record.v != format_version) return error.UnsupportedTraceVersion;
    var result: Parsed = .{ .tree = tree, .kind = record.kind };
    inline for (@typeInfo(TraceEvent).@"struct".field_names) |name| {
        @field(result, name) = @field(record, name);
    }
    return result;
}

/// Names the fault of a line that is not a version 0 event. A readable
/// schema or version other than this reader's outranks every other fault,
/// because a newer writer's fields are not this reader's to judge.
fn headerFault(
    allocator: std.mem.Allocator,
    text: []const u8,
) error{ OutOfMemory, InvalidEventJson, UnsupportedTraceSchema, UnsupportedTraceVersion } {
    const header = std.json.parseFromSlice(struct {
        schema: ?[]const u8 = null,
        v: ?u64 = null,
    }, allocator, text, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEventJson,
    };
    defer header.deinit();
    if (header.value.schema) |actual| {
        if (!std.mem.eql(u8, actual, schema)) return error.UnsupportedTraceSchema;
    }
    const version = header.value.v orelse return error.InvalidEventJson;
    if (version != format_version) return error.UnsupportedTraceVersion;
    return error.InvalidEventJson;
}

test "event json parses written zone begin" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try (TraceEvent{
        .seq = 7,
        .kind = .zone_begin,
        .time_ns = 100,
        .thread = 2,
        .id = 9,
        .name = "phase",
        .function = "run",
        .file = "run.zig",
        .line = 12,
        .color = 0x44aa88,
    }).writeJsonLine(&out.writer);

    var parsed = try parseLine(std.testing.allocator, out.written());
    defer parsed.deinit();
    try std.testing.expectEqual(Kind.zone_begin, parsed.kind);
    try std.testing.expectEqual(@as(u64, 9), parsed.id);
    try std.testing.expectEqualStrings("phase", parsed.name.?);
    try std.testing.expectEqualStrings("run.zig", parsed.file.?);
    try std.testing.expectEqual(@as(?u32, 0x44aa88), parsed.color);
}

test "event json parses sample frame metadata" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try (TraceEvent{
        .seq = 8,
        .kind = .sample_frame,
        .time_ns = 120,
        .thread = 3,
        .id = 4,
        .depth = 2,
        .name = "leaf",
        .function = "run",
        .file = "run.zig",
        .line = 14,
        .sample_kind = "cpu",
    }).writeJsonLine(&out.writer);

    var parsed = try parseLine(std.testing.allocator, out.written());
    defer parsed.deinit();
    try std.testing.expectEqual(Kind.sample_frame, parsed.kind);
    try std.testing.expectEqual(@as(u32, 2), parsed.depth);
    try std.testing.expectEqualStrings("cpu", parsed.sample_kind.?);
}

test "event json parses context switch metadata" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try (TraceEvent{
        .seq = 9,
        .kind = .context_switch,
        .time_ns = 150,
        .thread = 3,
        .cpu = 0,
        .prev_thread = 10,
        .next_thread = 11,
        .previous_cstate = 1,
        .prev_priority = 8,
        .next_priority = 9,
        .context_reason = "WrPreempted",
        .context_state = "Ready",
    }).writeJsonLine(&out.writer);

    var parsed = try parseLine(std.testing.allocator, out.written());
    defer parsed.deinit();
    try std.testing.expectEqual(Kind.context_switch, parsed.kind);
    try std.testing.expectEqual(@as(?u32, 0), parsed.cpu);
    try std.testing.expectEqual(@as(u64, 10), parsed.prev_thread);
    try std.testing.expectEqual(@as(u64, 11), parsed.next_thread);
    try std.testing.expectEqual(@as(?u32, 1), parsed.previous_cstate);
    try std.testing.expectEqual(@as(?i64, 8), parsed.prev_priority);
    try std.testing.expectEqual(@as(?i64, 9), parsed.next_priority);
    try std.testing.expectEqualStrings("WrPreempted", parsed.context_reason.?);
    try std.testing.expectEqualStrings("Ready", parsed.context_state.?);
}

test "event json parses fiber metadata" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try (TraceEvent{
        .seq = 10,
        .kind = .fiber_enter,
        .time_ns = 200,
        .thread = 42,
        .id = 9,
        .name = "job.apply",
        .group_hint = 3,
    }).writeJsonLine(&out.writer);

    var parsed = try parseLine(std.testing.allocator, out.written());
    defer parsed.deinit();
    try std.testing.expectEqual(Kind.fiber_enter, parsed.kind);
    try std.testing.expectEqual(@as(u64, 9), parsed.id);
    try std.testing.expectEqual(@as(u64, 42), parsed.thread);
    try std.testing.expectEqualStrings("job.apply", parsed.name.?);
    try std.testing.expectEqual(@as(?i64, 3), parsed.group_hint);
}

test "event json parses gpu metadata" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try (TraceEvent{
        .seq = 11,
        .kind = .gpu_context,
        .time_ns = 300,
        .thread = 4,
        .name = "render",
        .gpu_context = 2,
        .gpu_time = 1000,
        .gpu_period = 2.0,
        .gpu_context_type = "vulkan",
        .gpu_has_calibration = true,
        .gpu_serial = true,
    }).writeJsonLine(&out.writer);

    var parsed = try parseLine(std.testing.allocator, out.written());
    defer parsed.deinit();
    try std.testing.expectEqual(Kind.gpu_context, parsed.kind);
    try std.testing.expectEqual(@as(?u32, 2), parsed.gpu_context);
    try std.testing.expectEqual(@as(?i64, 1000), parsed.gpu_time);
    try std.testing.expectEqual(@as(?f64, 2.0), parsed.gpu_period);
    try std.testing.expectEqualStrings("vulkan", parsed.gpu_context_type.?);
    try std.testing.expect(parsed.gpu_has_calibration);
    try std.testing.expect(parsed.gpu_serial);
}

test "event json parses system metadata" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try (TraceEvent{
        .seq = 12,
        .kind = .hw_sample,
        .time_ns = 400,
        .thread = 9,
        .cpu = 3,
        .address = 0x1234,
        .pid = 77,
        .cpu_package = 1,
        .cpu_die = 2,
        .cpu_core = 4,
        .power_delta_uj = 500,
        .hw_sample_kind = "cache-miss",
    }).writeJsonLine(&out.writer);

    var parsed = try parseLine(std.testing.allocator, out.written());
    defer parsed.deinit();
    try std.testing.expectEqual(Kind.hw_sample, parsed.kind);
    try std.testing.expectEqual(@as(u64, 9), parsed.thread);
    try std.testing.expectEqual(@as(?u32, 3), parsed.cpu);
    try std.testing.expectEqual(@as(u64, 0x1234), parsed.address);
    try std.testing.expectEqual(@as(u64, 77), parsed.pid);
    try std.testing.expectEqual(@as(?u32, 1), parsed.cpu_package);
    try std.testing.expectEqual(@as(?u32, 2), parsed.cpu_die);
    try std.testing.expectEqual(@as(?u32, 4), parsed.cpu_core);
    try std.testing.expectEqual(@as(?u64, 500), parsed.power_delta_uj);
    try std.testing.expectEqualStrings("cache-miss", parsed.hw_sample_kind.?);
}

test "event record names exactly the fields the writer writes" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try (TraceEvent{
        .seq = 1,
        .kind = .zone_begin,
        .time_ns = 2,
        .thread = 3,
        .id = 4,
        .name = "name",
        .text = "text",
        .function = "function",
        .file = "file",
        .line = 5,
        .column = 6,
        .color = 7,
        .value_u64 = 8,
        .value_i64 = 9,
        .value_f64 = 1.5,
        .address = 10,
        .size = 11,
        .depth = 12,
        .cpu = 13,
        .prev_thread = 14,
        .next_thread = 15,
        .target_thread = 16,
        .pid = 17,
        .previous_cstate = 18,
        .prev_priority = 19,
        .next_priority = 20,
        .group_hint = 21,
        .gpu_context = 22,
        .gpu_query = 23,
        .gpu_time = 24,
        .gpu_period = 1.5,
        .gpu_cpu_delta_ns = 25,
        .gpu_context_type = "gpu_context_type",
        .gpu_has_calibration = true,
        .gpu_serial = true,
        .gpu_annotation_id = 26,
        .cpu_package = 27,
        .cpu_die = 28,
        .cpu_core = 29,
        .power_delta_uj = 30,
        .hw_sample_kind = "hw_sample_kind",
        .plot_kind = "plot_kind",
        .plot_unit = "plot_unit",
        .plot_step = true,
        .plot_fill = true,
        .lock_kind = "lock_kind",
        .sample_kind = "sample_kind",
        .context_reason = "context_reason",
        .context_state = "context_state",
    }).writeJsonLine(&out.writer);
    const record = try std.json.parseFromSlice(Record, std.testing.allocator, out.written(), .{});
    defer record.deinit();
    const written = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer written.deinit();
    inline for (@typeInfo(Record).@"struct".field_names) |name| {
        try std.testing.expect(written.value.object.contains(name));
    }
}

test "event line refuses a narrow field out of range" {
    try std.testing.expectError(error.InvalidEventJson, parseLine(
        std.testing.allocator,
        "{\"schema\":\"tracy.event/v0\",\"v\":0,\"kind\":\"zone.begin\",\"line\":4294967296}",
    ));
    try std.testing.expectError(error.UnsupportedTraceVersion, parseLine(
        std.testing.allocator,
        "{\"v\":1,\"kind\":\"later.kind\"}",
    ));
}
