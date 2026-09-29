const std = @import("std");
const pretty_json = @import("pretty").json;

const assert = std.debug.assert;

pub const schema = "tracy.flight/v0";

pub const OverflowPolicy = enum {
    overwrite_oldest,
    stop_when_full,

    pub fn tag(self: OverflowPolicy) []const u8 {
        return switch (self) {
            .overwrite_oldest => "overwrite_oldest",
            .stop_when_full => "stop_when_full",
        };
    }
};

pub const State = enum {
    accepting,
    full,

    pub fn tag(self: State) []const u8 {
        return switch (self) {
            .accepting => "accepting",
            .full => "full",
        };
    }
};

pub const Report = struct {
    policy: OverflowPolicy,
    state: State,
    capacity_bytes: usize,
    retained_bytes: usize,
    event_capacity_bytes: usize,
    writer_capacity_bytes: usize,
    observed_events: u64,
    stored_events: u64,
    retained_events: usize,
    overwritten_events: u64,
    dropped_events: u64,
    oversized_events: u64,
    partial_event_bytes: usize,
    discarding_oversized_event: bool,

    pub fn valid(self: Report) bool {
        if (self.capacity_bytes == 0) return false;
        if (self.event_capacity_bytes == 0) return false;
        if (self.writer_capacity_bytes == 0) return false;
        if (self.retained_bytes > self.capacity_bytes) return false;
        if (self.partial_event_bytes > self.event_capacity_bytes) return false;
        if (self.discarding_oversized_event and self.partial_event_bytes != 0) return false;
        const retained_events = std.math.cast(u64, self.retained_events) orelse return false;
        const retained_and_overwritten = retained_events +| self.overwritten_events;
        if (retained_and_overwritten != self.stored_events) return false;
        const rejected_events = self.dropped_events +| self.oversized_events;
        const accounted_events = self.stored_events +| rejected_events;
        if (accounted_events != self.observed_events) return false;
        if (self.policy == .overwrite_oldest and self.dropped_events != 0) return false;
        if (self.policy == .stop_when_full and self.overwritten_events != 0) return false;
        if (self.state == .full and self.policy != .stop_when_full) return false;
        return true;
    }

    pub fn writeJson(self: Report, writer: *std.Io.Writer) !void {
        assert(self.valid());
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try self.writeFields(object);
        try object.end();
    }

    pub fn writeFields(self: Report, object: pretty_json.Object) !void {
        assert(self.valid());
        try object.field("schema", schema);
        try object.field("policy", self.policy.tag());
        try object.field("state", self.state.tag());
        try object.field("capacity_bytes", self.capacity_bytes);
        try object.field("retained_bytes", self.retained_bytes);
        try object.field("event_capacity_bytes", self.event_capacity_bytes);
        try object.field("writer_capacity_bytes", self.writer_capacity_bytes);
        try object.field("observed_events", self.observed_events);
        try object.field("stored_events", self.stored_events);
        try object.field("retained_events", self.retained_events);
        try object.field("overwritten_events", self.overwritten_events);
        try object.field("dropped_events", self.dropped_events);
        try object.field("oversized_events", self.oversized_events);
        try object.field("partial_event_bytes", self.partial_event_bytes);
        try object.field("discarding_oversized_event", self.discarding_oversized_event);
    }

    pub fn writeJsonl(self: Report, writer: *std.Io.Writer) !void {
        try self.writeJson(writer);
        try writer.writeByte('\n');
    }
};

/// One flight report line, field for field as `Report.writeJson` writes it.
pub const Record = struct {
    schema: []const u8,
    policy: OverflowPolicy,
    state: State,
    capacity_bytes: usize,
    retained_bytes: usize,
    event_capacity_bytes: usize,
    writer_capacity_bytes: usize,
    observed_events: u64,
    stored_events: u64,
    retained_events: usize,
    overwritten_events: u64,
    dropped_events: u64,
    oversized_events: u64,
    partial_event_bytes: usize,
    discarding_oversized_event: bool,
};

pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) !Report {
    const text = std.mem.trim(u8, line, " \t\r\n");
    if (text.len == 0) return error.InvalidFlightReport;
    const parsed = std.json.parseFromSlice(Record, allocator, text, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return schemaFault(allocator, text),
    };
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.schema, schema)) return error.UnsupportedTraceSchema;
    var result: Report = undefined;
    inline for (@typeInfo(Report).@"struct".field_names) |name| {
        @field(result, name) = @field(parsed.value, name);
    }
    if (!result.valid()) return error.InvalidFlightReport;
    return result;
}

/// Names the fault of a line that is not a flight report. A readable schema
/// other than this reader's outranks every other fault.
fn schemaFault(
    allocator: std.mem.Allocator,
    text: []const u8,
) error{ OutOfMemory, InvalidFlightReport, UnsupportedTraceSchema } {
    const header = std.json.parseFromSlice(struct { schema: []const u8 }, allocator, text, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFlightReport,
    };
    defer header.deinit();
    if (!std.mem.eql(u8, header.value.schema, schema)) return error.UnsupportedTraceSchema;
    return error.InvalidFlightReport;
}

test "transport report round trips" {
    const expected: Report = .{
        .policy = .stop_when_full,
        .state = .full,
        .capacity_bytes = 64,
        .retained_bytes = 32,
        .event_capacity_bytes = 16,
        .writer_capacity_bytes = 8,
        .observed_events = 7,
        .stored_events = 5,
        .retained_events = 5,
        .overwritten_events = 0,
        .dropped_events = 2,
        .oversized_events = 0,
        .partial_event_bytes = 0,
        .discarding_oversized_event = false,
    };
    var line = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer line.deinit();
    try expected.writeJsonl(&line.writer);
    const actual = try parseLine(std.testing.allocator, line.written());
    try std.testing.expectEqualDeep(expected, actual);
}

test "transport report rejects malformed rows" {
    try std.testing.expectError(
        error.UnsupportedTraceSchema,
        parseLine(std.testing.allocator, "{\"schema\":\"future/v0\"}"),
    );
    try std.testing.expectError(
        error.InvalidFlightReport,
        parseLine(std.testing.allocator, "{\"schema\":\"tracy.flight/v0\"}"),
    );
}

test "flight record names exactly the fields the report writes" {
    const report: Report = .{
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
    var line = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer line.deinit();
    try report.writeJsonl(&line.writer);
    const record = try std.json.parseFromSlice(Record, std.testing.allocator, line.written(), .{});
    defer record.deinit();
    const written = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line.written(), .{});
    defer written.deinit();
    inline for (@typeInfo(Record).@"struct".field_names) |name| {
        try std.testing.expect(written.value.object.contains(name));
    }
}

test "transport report keeps counts above the signed range" {
    const expected: Report = .{
        .policy = .overwrite_oldest,
        .state = .accepting,
        .capacity_bytes = 64,
        .retained_bytes = 32,
        .event_capacity_bytes = 16,
        .writer_capacity_bytes = 8,
        .observed_events = std.math.maxInt(u64),
        .stored_events = std.math.maxInt(u64),
        .retained_events = 3,
        .overwritten_events = std.math.maxInt(u64) - 3,
        .dropped_events = 0,
        .oversized_events = 0,
        .partial_event_bytes = 0,
        .discarding_oversized_event = false,
    };
    var line = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer line.deinit();
    try expected.writeJsonl(&line.writer);
    try std.testing.expectEqualDeep(expected, try parseLine(std.testing.allocator, line.written()));
}
