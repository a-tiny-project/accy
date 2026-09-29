const std = @import("std");
const pretty_json = @import("pretty").json;

pub const schema = "coz.profile/v1";

pub const Location = struct {
    file: []const u8,
    line: u64,
};

pub const Startup = struct {
    timestamp_ns: u64,
};

pub const Experiment = struct {
    selected: Location,
    virtual_speedup: f64,
    duration_ns: u64,
    selected_samples: u64,
};

pub const Throughput = struct {
    name: []const u8,
    delta: u64,
};

pub const Latency = struct {
    name: []const u8,
    arrivals: u64,
    departures: u64,
    outstanding: u64,
};

pub const Runtime = struct {
    duration_ns: u64,
};

pub const Sample = struct {
    location: Location,
    count: u64,
};

pub const LossCounter = union(enum) {
    available: u64,
    unsupported,
    read_failed,
};

pub const TerminalStatus = enum {
    complete,
    not_started,
    stop_failed,
    drain_failed,
};

pub const Sampling = struct {
    record_count: u64 = 0,
    sample_record_count: u64 = 0,
    lost_record_count: u64 = 0,
    lost_event_count: u64 = 0,
    lost_samples_record_count: u64 = 0,
    lost_samples_count: u64 = 0,
    throttle_record_count: u64 = 0,
    unthrottle_record_count: u64 = 0,
    loss_counter: LossCounter = .unsupported,
    terminal_status: TerminalStatus = .not_started,
};

pub const Event = union(enum) {
    startup: Startup,
    experiment: Experiment,
    throughput: Throughput,
    latency: Latency,
    runtime: Runtime,
    sample: Sample,
    sampling: Sampling,

    pub fn writeJsonLine(self: Event, writer: *std.Io.Writer) !void {
        var stringify = pretty_json.Writer.init(writer, .minified);
        try stringify.beginObject();
        try stringify.objectField("schema");
        try stringify.write(schema);

        switch (self) {
            .startup => |event| {
                try stringify.objectField("event");
                try stringify.write("startup");
                try stringify.objectField("timestamp_ns");
                try stringify.write(event.timestamp_ns);
            },
            .experiment => |event| {
                try stringify.objectField("event");
                try stringify.write("experiment");
                try stringify.objectField("selected");
                try writeLocation(&stringify, event.selected);
                try stringify.objectField("virtual_speedup");
                try stringify.write(event.virtual_speedup);
                try stringify.objectField("duration_ns");
                try stringify.write(event.duration_ns);
                try stringify.objectField("selected_samples");
                try stringify.write(event.selected_samples);
            },
            .throughput => |event| {
                try stringify.objectField("event");
                try stringify.write("throughput");
                try stringify.objectField("name");
                try stringify.write(event.name);
                try stringify.objectField("delta");
                try stringify.write(event.delta);
            },
            .latency => |event| {
                try stringify.objectField("event");
                try stringify.write("latency");
                try stringify.objectField("name");
                try stringify.write(event.name);
                try stringify.objectField("arrivals");
                try stringify.write(event.arrivals);
                try stringify.objectField("departures");
                try stringify.write(event.departures);
                try stringify.objectField("outstanding");
                try stringify.write(event.outstanding);
            },
            .runtime => |event| {
                try stringify.objectField("event");
                try stringify.write("runtime");
                try stringify.objectField("duration_ns");
                try stringify.write(event.duration_ns);
            },
            .sample => |event| {
                try stringify.objectField("event");
                try stringify.write("sample");
                try stringify.objectField("location");
                try writeLocation(&stringify, event.location);
                try stringify.objectField("count");
                try stringify.write(event.count);
            },
            .sampling => |event| {
                try stringify.objectField("event");
                try stringify.write("sampling");
                try writeSampling(&stringify, event);
            },
        }

        try stringify.endObject();
        try writer.writeByte('\n');
    }
};

pub const ParsedEvent = struct {
    event: Event,

    pub fn deinit(self: *ParsedEvent, allocator: std.mem.Allocator) void {
        switch (self.event) {
            .startup, .runtime, .sampling => {},
            .experiment => |event| allocator.free(event.selected.file),
            .throughput => |event| allocator.free(event.name),
            .latency => |event| allocator.free(event.name),
            .sample => |event| allocator.free(event.location.file),
        }
        self.* = undefined;
    }
};

pub fn parseJsonLine(allocator: std.mem.Allocator, line: []const u8) !ParsedEvent {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trim(u8, line, " \t\r\n"), .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidProfileJson,
    };

    const actual_schema = try jsonString(object.get("schema") orelse return error.InvalidProfileJson);
    if (!std.mem.eql(u8, actual_schema, schema)) return error.UnsupportedProfileSchema;

    const event_name = try jsonString(object.get("event") orelse return error.InvalidProfileJson);
    if (std.mem.eql(u8, event_name, "startup")) {
        return .{ .event = .{ .startup = .{
            .timestamp_ns = try jsonU64(object.get("timestamp_ns") orelse return error.InvalidProfileJson),
        } } };
    }
    if (std.mem.eql(u8, event_name, "experiment")) {
        const virtual_speedup = try jsonF64(object.get("virtual_speedup") orelse return error.InvalidProfileJson);
        const duration_ns = try jsonU64(object.get("duration_ns") orelse return error.InvalidProfileJson);
        const selected_samples = try jsonU64(object.get("selected_samples") orelse return error.InvalidProfileJson);
        return .{ .event = .{ .experiment = .{
            .selected = try parseOwnedLocation(allocator, object.get("selected") orelse return error.InvalidProfileJson),
            .virtual_speedup = virtual_speedup,
            .duration_ns = duration_ns,
            .selected_samples = selected_samples,
        } } };
    }
    if (std.mem.eql(u8, event_name, "throughput")) {
        const delta = try jsonU64(object.get("delta") orelse return error.InvalidProfileJson);
        return .{ .event = .{ .throughput = .{
            .name = try allocator.dupe(u8, try jsonString(object.get("name") orelse return error.InvalidProfileJson)),
            .delta = delta,
        } } };
    }
    if (std.mem.eql(u8, event_name, "latency")) {
        const arrivals = try jsonU64(object.get("arrivals") orelse return error.InvalidProfileJson);
        const departures = try jsonU64(object.get("departures") orelse return error.InvalidProfileJson);
        const outstanding = try jsonU64(object.get("outstanding") orelse return error.InvalidProfileJson);
        return .{ .event = .{ .latency = .{
            .name = try allocator.dupe(u8, try jsonString(object.get("name") orelse return error.InvalidProfileJson)),
            .arrivals = arrivals,
            .departures = departures,
            .outstanding = outstanding,
        } } };
    }
    if (std.mem.eql(u8, event_name, "runtime")) {
        return .{ .event = .{ .runtime = .{
            .duration_ns = try jsonU64(object.get("duration_ns") orelse return error.InvalidProfileJson),
        } } };
    }
    if (std.mem.eql(u8, event_name, "sample")) {
        const count = try jsonU64(object.get("count") orelse return error.InvalidProfileJson);
        return .{ .event = .{ .sample = .{
            .location = try parseOwnedLocation(allocator, object.get("location") orelse return error.InvalidProfileJson),
            .count = count,
        } } };
    }
    if (std.mem.eql(u8, event_name, "sampling")) {
        return .{ .event = .{ .sampling = try parseSampling(object) } };
    }

    return error.InvalidProfileJson;
}

fn writeSampling(stringify: *pretty_json.Writer, event: Sampling) !void {
    try writeU64Field(stringify, "record_count", event.record_count);
    try writeU64Field(stringify, "sample_record_count", event.sample_record_count);
    try writeU64Field(stringify, "lost_record_count", event.lost_record_count);
    try writeU64Field(stringify, "lost_event_count", event.lost_event_count);
    try writeU64Field(stringify, "lost_samples_record_count", event.lost_samples_record_count);
    try writeU64Field(stringify, "lost_samples_count", event.lost_samples_count);
    try writeU64Field(stringify, "throttle_record_count", event.throttle_record_count);
    try writeU64Field(stringify, "unthrottle_record_count", event.unthrottle_record_count);
    try stringify.objectField("loss_counter_status");
    try stringify.write(lossCounterStatus(event.loss_counter));
    try stringify.objectField("loss_counter_value");
    switch (event.loss_counter) {
        .available => |value| try stringify.write(value),
        .unsupported, .read_failed => try stringify.write(null),
    }
    try stringify.objectField("terminal_status");
    try stringify.write(@tagName(event.terminal_status));
}

fn writeU64Field(stringify: *pretty_json.Writer, name: []const u8, value: u64) !void {
    try stringify.objectField(name);
    try stringify.write(value);
}

fn lossCounterStatus(counter: LossCounter) []const u8 {
    return switch (counter) {
        .available => "available",
        .unsupported => "unsupported",
        .read_failed => "read_failed",
    };
}

fn parseSampling(object: std.json.ObjectMap) !Sampling {
    const status = try jsonString(
        object.get("loss_counter_status") orelse return error.InvalidProfileJson,
    );
    const value = object.get("loss_counter_value") orelse return error.InvalidProfileJson;
    return .{
        .record_count = try requiredU64(object, "record_count"),
        .sample_record_count = try requiredU64(object, "sample_record_count"),
        .lost_record_count = try requiredU64(object, "lost_record_count"),
        .lost_event_count = try requiredU64(object, "lost_event_count"),
        .lost_samples_record_count = try requiredU64(object, "lost_samples_record_count"),
        .lost_samples_count = try requiredU64(object, "lost_samples_count"),
        .throttle_record_count = try requiredU64(object, "throttle_record_count"),
        .unthrottle_record_count = try requiredU64(object, "unthrottle_record_count"),
        .loss_counter = try parseLossCounter(status, value),
        .terminal_status = try parseTerminalStatus(object),
    };
}

fn parseTerminalStatus(object: std.json.ObjectMap) !TerminalStatus {
    const value = object.get("terminal_status") orelse return error.InvalidProfileJson;
    const status = try jsonString(value);
    inline for (
        @typeInfo(TerminalStatus).@"enum".field_names,
        @typeInfo(TerminalStatus).@"enum".field_values,
    ) |field_name, field_name_value| {
        const field = .{ .name = field_name, .value = field_name_value };
        if (std.mem.eql(u8, status, field.name)) return @fromBackingInt(@intCast(field.value));
    }
    return error.InvalidProfileJson;
}

fn requiredU64(object: std.json.ObjectMap, name: []const u8) !u64 {
    return jsonU64(object.get(name) orelse return error.InvalidProfileJson);
}

fn parseLossCounter(status: []const u8, value: std.json.Value) !LossCounter {
    if (std.mem.eql(u8, status, "available")) return .{
        .available = try jsonU64(value),
    };
    if (value != .null) return error.InvalidProfileJson;
    if (std.mem.eql(u8, status, "unsupported")) return .unsupported;
    if (std.mem.eql(u8, status, "read_failed")) return .read_failed;
    return error.InvalidProfileJson;
}

fn writeLocation(stringify: *pretty_json.Writer, location: Location) !void {
    try stringify.beginObject();
    try stringify.objectField("file");
    try stringify.write(location.file);
    try stringify.objectField("line");
    try stringify.write(location.line);
    try stringify.endObject();
}

fn parseOwnedLocation(allocator: std.mem.Allocator, value: std.json.Value) !Location {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidProfileJson,
    };
    const line = try jsonU64(object.get("line") orelse return error.InvalidProfileJson);
    return .{
        .file = try allocator.dupe(u8, try jsonString(object.get("file") orelse return error.InvalidProfileJson)),
        .line = line,
    };
}

fn jsonString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidProfileJson,
    };
}

fn jsonU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |integer| if (integer < 0) error.InvalidProfileJson else @intCast(integer),
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch error.InvalidProfileJson,
        else => error.InvalidProfileJson,
    };
}

fn jsonF64(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => error.InvalidProfileJson,
    };
}

fn writeEventToBuffer(buffer: []u8, event: Event) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try event.writeJsonLine(&writer);
    return writer.buffered();
}

test "startup record writes versioned JSONL" {
    var buffer: [128]u8 = undefined;
    const line = try writeEventToBuffer(&buffer, .{ .startup = .{ .timestamp_ns = 123 } });

    try std.testing.expectEqualStrings(
        "{\"schema\":\"coz.profile/v1\",\"event\":\"startup\",\"timestamp_ns\":123}\n",
        line,
    );
}

test "experiment record round-trips selected line and virtual speedup" {
    var buffer: [512]u8 = undefined;
    const line = try writeEventToBuffer(&buffer, .{ .experiment = .{
        .selected = .{ .file = "src/main.zig", .line = 42 },
        .virtual_speedup = 0.25,
        .duration_ns = 500_000_000,
        .selected_samples = 17,
    } });

    var parsed = try parseJsonLine(std.testing.allocator, line);
    defer parsed.deinit(std.testing.allocator);

    const event = switch (parsed.event) {
        .experiment => |event| event,
        else => return error.WrongEvent,
    };

    try std.testing.expectEqualStrings("src/main.zig", event.selected.file);
    try std.testing.expectEqual(@as(u64, 42), event.selected.line);
    try std.testing.expectEqual(@as(f64, 0.25), event.virtual_speedup);
    try std.testing.expectEqual(@as(u64, 500_000_000), event.duration_ns);
    try std.testing.expectEqual(@as(u64, 17), event.selected_samples);
}

test "throughput record round-trips escaped names" {
    var buffer: [512]u8 = undefined;
    const line = try writeEventToBuffer(&buffer, .{ .throughput = .{
        .name = "items \"done\"\n",
        .delta = 91,
    } });

    var parsed = try parseJsonLine(std.testing.allocator, line);
    defer parsed.deinit(std.testing.allocator);

    const event = switch (parsed.event) {
        .throughput => |event| event,
        else => return error.WrongEvent,
    };

    try std.testing.expectEqualStrings("items \"done\"\n", event.name);
    try std.testing.expectEqual(@as(u64, 91), event.delta);
}

test "latency record round-trips arrivals departures and outstanding work" {
    var buffer: [512]u8 = undefined;
    const line = try writeEventToBuffer(&buffer, .{ .latency = .{
        .name = "request",
        .arrivals = 10,
        .departures = 7,
        .outstanding = 3,
    } });

    var parsed = try parseJsonLine(std.testing.allocator, line);
    defer parsed.deinit(std.testing.allocator);

    const event = switch (parsed.event) {
        .latency => |event| event,
        else => return error.WrongEvent,
    };

    try std.testing.expectEqualStrings("request", event.name);
    try std.testing.expectEqual(@as(u64, 10), event.arrivals);
    try std.testing.expectEqual(@as(u64, 7), event.departures);
    try std.testing.expectEqual(@as(u64, 3), event.outstanding);
}

test "runtime and sample records keep nanosecond and location fields explicit" {
    var runtime_buffer: [256]u8 = undefined;
    const runtime_line = try writeEventToBuffer(&runtime_buffer, .{ .runtime = .{ .duration_ns = 99 } });
    var parsed_runtime = try parseJsonLine(std.testing.allocator, runtime_line);
    defer parsed_runtime.deinit(std.testing.allocator);

    const runtime = switch (parsed_runtime.event) {
        .runtime => |event| event,
        else => return error.WrongEvent,
    };
    try std.testing.expectEqual(@as(u64, 99), runtime.duration_ns);

    var sample_buffer: [512]u8 = undefined;
    const sample_line = try writeEventToBuffer(&sample_buffer, .{ .sample = .{
        .location = .{ .file = "src/hot.zig", .line = 9 },
        .count = 1234,
    } });
    var parsed_sample = try parseJsonLine(std.testing.allocator, sample_line);
    defer parsed_sample.deinit(std.testing.allocator);

    const sample = switch (parsed_sample.event) {
        .sample => |event| event,
        else => return error.WrongEvent,
    };
    try std.testing.expectEqualStrings("src/hot.zig", sample.location.file);
    try std.testing.expectEqual(@as(u64, 9), sample.location.line);
    try std.testing.expectEqual(@as(u64, 1234), sample.count);
}

test "sampling record round-trips transport evidence" {
    var buffer: [1024]u8 = undefined;
    const line = try writeEventToBuffer(&buffer, .{ .sampling = .{
        .record_count = 100,
        .sample_record_count = 91,
        .lost_record_count = 1,
        .lost_event_count = 3,
        .lost_samples_record_count = 2,
        .lost_samples_count = 4,
        .throttle_record_count = 1,
        .unthrottle_record_count = 1,
        .loss_counter = .{ .available = 7 },
        .terminal_status = .complete,
    } });
    var parsed = try parseJsonLine(std.testing.allocator, line);
    defer parsed.deinit(std.testing.allocator);

    const sampling = switch (parsed.event) {
        .sampling => |event| event,
        else => return error.WrongEvent,
    };
    try std.testing.expectEqual(@as(u64, 100), sampling.record_count);
    try std.testing.expectEqual(@as(u64, 91), sampling.sample_record_count);
    try std.testing.expectEqual(@as(u64, 3), sampling.lost_event_count);
    try std.testing.expectEqual(@as(u64, 4), sampling.lost_samples_count);
    try std.testing.expectEqual(@as(u64, 7), sampling.loss_counter.available);
    try std.testing.expectEqual(TerminalStatus.complete, sampling.terminal_status);
}

test "sampling record validates loss counter state" {
    const prefix =
        "{\"schema\":\"coz.profile/v1\",\"event\":\"sampling\"," ++
        "\"record_count\":0,\"sample_record_count\":0,\"lost_record_count\":0," ++
        "\"lost_event_count\":0,\"lost_samples_record_count\":0," ++
        "\"lost_samples_count\":0,\"throttle_record_count\":0," ++
        "\"unthrottle_record_count\":0,";
    try std.testing.expectError(error.InvalidProfileJson, parseJsonLine(
        std.testing.allocator,
        prefix ++ "\"loss_counter_status\":\"available\",\"loss_counter_value\":null}\n",
    ));
    try std.testing.expectError(error.InvalidProfileJson, parseJsonLine(
        std.testing.allocator,
        prefix ++ "\"loss_counter_status\":\"unsupported\",\"loss_counter_value\":1}\n",
    ));
}

test "parser rejects incompatible schema and missing fields" {
    try std.testing.expectError(
        error.UnsupportedProfileSchema,
        parseJsonLine(std.testing.allocator, "{\"schema\":\"coz.profile/v2\",\"event\":\"runtime\",\"duration_ns\":1}\n"),
    );
    try std.testing.expectError(
        error.InvalidProfileJson,
        parseJsonLine(std.testing.allocator, "{\"schema\":\"coz.profile/v1\",\"event\":\"runtime\"}\n"),
    );
}
