const std = @import("std");
const pretty = @import("timing_runner_pretty");
const sys = @import("timing_runner_sys");

const pretty_json = pretty.json;
const options = @import("options.zig");

pub const schema = "tiny.build.test-run-progress/v1";
pub const file_name = "progress.jsonl";
pub const maximum_selected: usize = options.supervised_selected_cap;
pub const maximum_name_bytes: usize = 4096;
const maximum_event_bytes: usize = 32 * 1024;
const maximum_event_count: usize = maximum_selected * 2 + 2;
pub const maximum_file_bytes: usize = maximum_event_bytes * maximum_event_count;

pub const State = enum {
    in_flight,
    completed,
    terminal,
};

pub const Reason = enum {
    timeout,
    selection_limit,
    empty_selection,
    invalid_selection,
    spawn_failure,
    child_termination,
    process_group_failure,
    cancelled,
};

pub const ChildTermination = enum {
    exited,
    signal,
    stopped,
    unknown,
};

pub const Event = struct {
    schema: []const u8,
    sequence: u8,
    state: State,
    selected_test_count: u32,
    completed_test_count: u32,
    elapsed_ms: u64,
    current_test: ?[]const u8 = null,
    status: ?[]const u8 = null,
    complete: ?bool = null,
    reason: ?Reason = null,
    child_process_started: ?bool = null,
    child_termination: ?ChildTermination = null,
    child_status: ?u32 = null,
    process_group_cleanup_succeeded: ?bool = null,
    cancellation_signal: ?u32 = null,
};

pub const Snapshot = struct {
    sequence: u8,
    state: State,
    selected: u32,
    completed: u32,
    elapsed_ms: u64,
    current_test: ?[]const u8,
    complete: ?bool,
    reason: ?Reason,
    child_process_started: ?bool,
    child_termination: ?ChildTermination,
    child_status: ?u32,
    process_group_cleanup_succeeded: ?bool,
    cancellation_signal: ?u32,
};

pub const Terminal = struct {
    sequence: u8,
    selected: u32,
    completed: u32,
    elapsed_ms: u64,
    reason: Reason,
    current_test: ?[]const u8 = null,
    child_process_started: ?bool = null,
    child_termination: ?ChildTermination = null,
    child_status: ?u32 = null,
    process_group_cleanup_succeeded: ?bool = null,
    cancellation_signal: ?u32 = null,
};

pub fn initialize(directory: []const u8) !void {
    try sys.fs.createDirPath(directory);
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try progressPath(directory, &path_storage);
    try sys.fs.writeFile(path, "");
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > maximum_name_bytes) {
        return error.InvalidFocusedTestName;
    }
}

pub fn appendInFlight(
    directory: []const u8,
    sequence: u8,
    selected: u32,
    completed: u32,
    elapsed_ms: u64,
    name: []const u8,
) !void {
    try validateName(name);
    try append(directory, .{
        .schema = schema,
        .sequence = sequence,
        .state = .in_flight,
        .selected_test_count = selected,
        .completed_test_count = completed,
        .elapsed_ms = elapsed_ms,
        .current_test = name,
    });
}

pub fn appendCompleted(
    directory: []const u8,
    sequence: u8,
    selected: u32,
    completed: u32,
    elapsed_ms: u64,
    name: []const u8,
    status: []const u8,
) !void {
    try validateName(name);
    try append(directory, .{
        .schema = schema,
        .sequence = sequence,
        .state = .completed,
        .selected_test_count = selected,
        .completed_test_count = completed,
        .elapsed_ms = elapsed_ms,
        .current_test = name,
        .status = status,
    });
}

pub fn appendTerminal(
    directory: []const u8,
    terminal: Terminal,
) !void {
    if (terminal.current_test) |name| try validateName(name);
    try append(directory, .{
        .schema = schema,
        .sequence = terminal.sequence,
        .state = .terminal,
        .selected_test_count = terminal.selected,
        .completed_test_count = terminal.completed,
        .elapsed_ms = terminal.elapsed_ms,
        .current_test = terminal.current_test,
        .complete = false,
        .reason = terminal.reason,
        .child_process_started = terminal.child_process_started,
        .child_termination = terminal.child_termination,
        .child_status = terminal.child_status,
        .process_group_cleanup_succeeded = terminal.process_group_cleanup_succeeded,
        .cancellation_signal = terminal.cancellation_signal,
    });
}

pub fn latest(
    directory: []const u8,
    name_storage: []u8,
) !?Snapshot {
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try progressPath(directory, &path_storage);
    var file = sys.fs.cwd().openFile(sys.fs.debugIo(), path, .{}) catch
        return null;
    defer file.close(sys.fs.debugIo());
    const stat = try file.stat(sys.fs.debugIo());
    if (stat.size == 0 or stat.size > maximum_file_bytes) return null;
    var bytes: [maximum_event_bytes]u8 = undefined;
    const start = stat.size - @min(stat.size, bytes.len);
    const count = try file.readPositionalAll(sys.fs.debugIo(), &bytes, start);
    const line = latestLine(bytes[0..count]) orelse return null;
    var parse_storage: [maximum_event_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&parse_storage);
    var parsed = try std.json.parseFromSlice(Event, fixed.allocator(), line, .{});
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.schema, schema)) {
        return error.InvalidProgressReceiptSchema;
    }
    const current = if (parsed.value.current_test) |name|
        try copyName(name_storage, name)
    else
        null;
    return .{
        .sequence = parsed.value.sequence,
        .state = parsed.value.state,
        .selected = parsed.value.selected_test_count,
        .completed = parsed.value.completed_test_count,
        .elapsed_ms = parsed.value.elapsed_ms,
        .current_test = current,
        .complete = parsed.value.complete,
        .reason = parsed.value.reason,
        .child_process_started = parsed.value.child_process_started,
        .child_termination = parsed.value.child_termination,
        .child_status = parsed.value.child_status,
        .process_group_cleanup_succeeded = parsed.value.process_group_cleanup_succeeded,
        .cancellation_signal = parsed.value.cancellation_signal,
    };
}

fn append(directory: []const u8, event: Event) !void {
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try progressPath(directory, &path_storage);
    var line_storage: [maximum_event_bytes]u8 = undefined;
    var line = std.Io.Writer.fixed(&line_storage);
    var out = pretty_json.Writer.init(&line, .minified);
    try writeEvent(&out, event);
    try line.writeByte('\n');
    const encoded = line.buffered();
    const existing = sys.fs.statFile(path) catch null;
    const size: usize = if (existing) |stat| @intCast(stat.size) else 0;
    if (size > maximum_file_bytes - encoded.len) {
        return error.ProgressReceiptCapacityExceeded;
    }
    try sys.fs.appendFile(path, &.{encoded});
}

fn writeEvent(out: *pretty_json.Writer, event: Event) !void {
    try out.beginObject();
    try field(out, "schema", event.schema);
    try field(out, "sequence", event.sequence);
    try field(out, "state", @tagName(event.state));
    try field(out, "selected_test_count", event.selected_test_count);
    try field(out, "completed_test_count", event.completed_test_count);
    try field(out, "elapsed_ms", event.elapsed_ms);
    if (event.current_test) |value| try field(out, "current_test", value);
    if (event.status) |value| try field(out, "status", value);
    if (event.complete) |value| try field(out, "complete", value);
    if (event.reason) |value| try field(out, "reason", @tagName(value));
    if (event.child_process_started) |value| {
        try field(out, "child_process_started", value);
    }
    if (event.child_termination) |value| {
        try field(out, "child_termination", @tagName(value));
    }
    if (event.child_status) |value| try field(out, "child_status", value);
    if (event.process_group_cleanup_succeeded) |value| {
        try field(out, "process_group_cleanup_succeeded", value);
    }
    if (event.cancellation_signal) |value| {
        try field(out, "cancellation_signal", value);
    }
    try out.endObject();
}

fn progressPath(
    directory: []const u8,
    storage: *[std.fs.max_path_bytes]u8,
) ![]const u8 {
    if (directory.len == 0 or directory.len >= storage.len) {
        return error.InvalidProgressReceiptDirectory;
    }
    return try std.fmt.bufPrint(storage, "{s}/{s}", .{ directory, file_name });
}

fn latestLine(bytes: []const u8) ?[]const u8 {
    const end = std.mem.trimEnd(u8, bytes, "\n").len;
    if (end == 0) return null;
    const start = if (std.mem.lastIndexOfScalar(u8, bytes[0..end], '\n')) |index|
        index + 1
    else
        0;
    return bytes[start..end];
}

fn copyName(storage: []u8, name: []const u8) ![]const u8 {
    if (name.len > storage.len) return error.ProgressTestNameTooLong;
    @memcpy(storage[0..name.len], name);
    return storage[0..name.len];
}

fn field(
    out: *pretty_json.Writer,
    name: []const u8,
    value: anytype,
) !void {
    try out.objectField(name);
    try out.write(value);
}

test "progress receipt remains append only and reports its latest state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(sys.fs.debugIo(), &directory);
    const path = directory[0..length];
    try initialize(path);
    try appendInFlight(path, 0, 1, 0, 4, "test alpha");
    try appendCompleted(path, 1, 1, 1, 9, "test alpha", "ok");
    var name: [maximum_name_bytes]u8 = undefined;
    const snapshot = (try latest(path, &name)).?;
    try std.testing.expectEqual(State.completed, snapshot.state);
    try std.testing.expectEqual(@as(u32, 1), snapshot.completed);
    try std.testing.expectEqualStrings("test alpha", snapshot.current_test.?);
}
