const std = @import("std");
const event = @import("event.zig");
const transport = @import("transport.zig");

pub const Parsed = union(enum) {
    event: event.Parsed,
    flight: transport.Report,

    pub fn deinit(self: *Parsed) void {
        switch (self.*) {
            .event => |*parsed| parsed.deinit(),
            .flight => {},
        }
        self.* = undefined;
    }
};

/// Reads the schema first, then parses the line as the record it names. A
/// line without a readable schema is left to the event reader, which names
/// its fault.
pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) !Parsed {
    if (try isFlightReport(allocator, line)) {
        return .{ .flight = try transport.parseLine(allocator, line) };
    }
    return .{ .event = try event.parseLine(allocator, line) };
}

fn isFlightReport(allocator: std.mem.Allocator, line: []const u8) !bool {
    const header = std.json.parseFromSlice(struct {
        schema: ?[]const u8 = null,
    }, allocator, std.mem.trim(u8, line, " \t\r\n"), .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer header.deinit();
    const actual = header.value.schema orelse return false;
    return std.mem.eql(u8, actual, transport.schema);
}

pub fn parseEventLine(allocator: std.mem.Allocator, line: []const u8) !?event.Parsed {
    return switch (try parseLine(allocator, line)) {
        .event => |parsed| parsed,
        .flight => null,
    };
}

test "record parser dispatches events and flight reports" {
    var event_line = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer event_line.deinit();
    try (event.TraceEvent{ .seq = 7, .kind = .message }).writeJsonLine(&event_line.writer);
    var parsed_event = try parseLine(std.testing.allocator, event_line.written());
    defer parsed_event.deinit();
    try std.testing.expectEqual(@as(u64, 7), parsed_event.event.seq);

    var report_line = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer report_line.deinit();
    const report: transport.Report = .{
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
    try report.writeJsonl(&report_line.writer);
    var parsed_report = try parseLine(std.testing.allocator, report_line.written());
    defer parsed_report.deinit();
    try std.testing.expectEqual(@as(u64, 2), parsed_report.flight.overwritten_events);
}

test "record parser rejects unknown schemas" {
    try std.testing.expectError(
        error.UnsupportedTraceSchema,
        parseLine(std.testing.allocator, "{\"schema\":\"future/v0\"}"),
    );
}
