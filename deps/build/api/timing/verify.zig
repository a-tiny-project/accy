const std = @import("std");
const pretty = @import("timing_runner_pretty");
const sys = @import("timing_runner_sys");

const progress = @import("progress.zig");
const receipt = @import("receipt.zig");

const maximum_receipt_bytes: usize = 4 * 1024 * 1024;

const Mode = enum {
    success,
    timeout,
    maximum,
    cap,
    empty,
    failure,
    child_exit,
    cancellation,
    deadline_cpu,
    deadline_block,
    deadline_teardown,
    deadline_warmup,
    deadline_repeat,
};

const FinalReceipt = struct {
    schema: []const u8,
    selected_test_count: usize,
    executed_test_count: usize,
    failed_test_count: usize,
    tests: []const FinalRow,
};

const FinalRow = struct {
    name: []const u8,
    status: []const u8,
};

pub fn main(init: sys.process.Init) u8 {
    run(init) catch |err| {
        pretty.diagnostic.writeStderrText(
            "timing supervisor verification: {s}\n",
            .{@errorName(err)},
        );
        return 1;
    };
    return 0;
}

fn run(init: sys.process.Init) !void {
    var iterator = sys.process.Args.Iterator.init(init.minimal.args);
    _ = iterator.next() orelse return error.MissingExecutableArgument;
    const mode_text = iterator.next() orelse return error.MissingVerificationMode;
    const directory = iterator.next() orelse return error.MissingReceiptDirectory;
    if (iterator.next() != null) return error.TooManyArguments;
    const mode = std.meta.stringToEnum(Mode, mode_text) orelse
        return error.InvalidVerificationMode;
    var arena = std.heap.ArenaAllocator.init(sys.allocator.processAllocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    if (std.mem.startsWith(u8, mode_text, "deadline_")) {
        return verifyDeadline(init, allocator, mode_text, directory);
    }
    const text = try readProgress(allocator, directory);
    switch (mode) {
        .success => try verifySuccess(allocator, directory, text),
        .timeout => try verifyTimeout(allocator, directory, text),
        .maximum => try verifyMaximum(allocator, directory, text),
        .cap => try verifyCap(allocator, directory, text),
        .empty => try verifyRejected(allocator, directory, text, .empty_selection, 0),
        .failure => try verifyFailure(allocator, directory, text),
        .child_exit => try verifyChildExit(allocator, directory, text),
        .cancellation => try verifyCancellation(allocator, directory, text),
        .deadline_cpu, .deadline_block, .deadline_teardown, .deadline_warmup, .deadline_repeat => unreachable,
    }
}

fn verifySuccess(
    allocator: std.mem.Allocator,
    directory: []const u8,
    text: []const u8,
) !void {
    const expected_names = [_][]const u8{
        "test.test.timing runner supervised order priority beta",
        "test.test.timing runner supervised order natural alpha",
        "test.test.timing runner supervised order natural gamma",
    };
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index >= expected_names.len * 2) return error.ExtraProgressEvent;
        var parsed = try std.json.parseFromSlice(progress.Event, allocator, line, .{});
        defer parsed.deinit();
        const event = parsed.value;
        if (event.sequence != index or event.selected_test_count != 3) {
            return error.InvalidProgressSequence;
        }
        const expected_state: progress.State = if (index % 2 == 0)
            .in_flight
        else
            .completed;
        if (event.state != expected_state) return error.InvalidProgressState;
        if (!std.mem.eql(u8, event.current_test.?, expected_names[index / 2])) {
            return error.InvalidProgressOrder;
        }
    }
    if (index != expected_names.len * 2) return error.MissingProgressEvent;
    try verifyFinal(allocator, directory, &expected_names);
    try requireDescendantStopped(allocator, directory, "success-descendant.pid");
}

fn verifyMaximum(
    allocator: std.mem.Allocator,
    directory: []const u8,
    text: []const u8,
) !void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index >= progress.maximum_selected * 2) {
            return error.ExtraProgressEvent;
        }
        var parsed = try std.json.parseFromSlice(progress.Event, allocator, line, .{});
        defer parsed.deinit();
        const expected_state: progress.State = if (index % 2 == 0)
            .in_flight
        else
            .completed;
        if (parsed.value.sequence != index or
            parsed.value.state != expected_state or
            parsed.value.selected_test_count != progress.maximum_selected)
        {
            return error.InvalidMaximumSelectionProgress;
        }
    }
    if (index != progress.maximum_selected * 2) {
        return error.MissingProgressEvent;
    }
    try verifyFinalCount(allocator, directory, progress.maximum_selected, 0);
}

fn verifyTimeout(
    allocator: std.mem.Allocator,
    directory: []const u8,
    text: []const u8,
) !void {
    const expected =
        "test.test.timing runner supervised timeout owns descendant group";
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    const first = lines.next() orelse return error.MissingInFlightEvent;
    var started = try std.json.parseFromSlice(progress.Event, allocator, first, .{});
    defer started.deinit();
    if (started.value.state != .in_flight or
        started.value.current_test == null or
        !std.mem.eql(
            u8,
            started.value.current_test.?,
            expected,
        ))
    {
        return error.InvalidInFlightEvent;
    }
    const last = lines.next() orelse return error.MissingTimeoutEvent;
    if (lines.next() != null) return error.ExtraTimeoutEvent;
    var timed_out = try std.json.parseFromSlice(progress.Event, allocator, last, .{});
    defer timed_out.deinit();
    if (timed_out.value.state != .terminal or
        timed_out.value.complete != false or
        timed_out.value.reason != .timeout or
        timed_out.value.completed_test_count != 0 or
        timed_out.value.child_process_started != true or
        timed_out.value.child_termination != .signal or
        timed_out.value.process_group_cleanup_succeeded != true or
        timed_out.value.current_test == null or
        !std.mem.eql(u8, timed_out.value.current_test.?, expected))
    {
        return error.InvalidTimeoutEvent;
    }
    try requireNoFinal(allocator, directory);
    try requireDescendantStopped(allocator, directory, "descendant.pid");
}

fn verifyCap(
    allocator: std.mem.Allocator,
    directory: []const u8,
    text: []const u8,
) !void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    const line = lines.next() orelse return error.MissingSelectionLimitEvent;
    if (lines.next() != null) return error.ExtraSelectionLimitEvent;
    var parsed = try std.json.parseFromSlice(progress.Event, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value.state != .terminal or
        parsed.value.complete != false or
        parsed.value.reason != .selection_limit or
        parsed.value.selected_test_count != 33 or
        parsed.value.completed_test_count != 0 or
        parsed.value.child_process_started != false)
    {
        return error.InvalidSelectionLimitEvent;
    }
    try requireNoFinal(allocator, directory);
}

fn verifyRejected(
    allocator: std.mem.Allocator,
    directory: []const u8,
    text: []const u8,
    reason: progress.Reason,
    selected: u32,
) !void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    const line = lines.next() orelse return error.MissingRejectedEvent;
    if (lines.next() != null) return error.ExtraRejectedEvent;
    var parsed = try std.json.parseFromSlice(progress.Event, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value.state != .terminal or
        parsed.value.complete != false or
        parsed.value.reason != reason or
        parsed.value.selected_test_count != selected or
        parsed.value.completed_test_count != 0 or
        parsed.value.child_process_started != false)
    {
        return error.InvalidRejectedEvent;
    }
    try requireNoFinal(allocator, directory);
}

fn verifyFailure(
    allocator: std.mem.Allocator,
    directory: []const u8,
    text: []const u8,
) !void {
    try verifyTwoRowProgress(allocator, text, "fail");
    try verifyFinalCount(allocator, directory, 1, 1);
}

fn verifyChildExit(
    allocator: std.mem.Allocator,
    directory: []const u8,
    text: []const u8,
) !void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    const first = lines.next() orelse return error.MissingInFlightEvent;
    var started = try std.json.parseFromSlice(progress.Event, allocator, first, .{});
    defer started.deinit();
    if (started.value.state != .in_flight) return error.InvalidInFlightEvent;
    const last = lines.next() orelse return error.MissingChildTerminationEvent;
    if (lines.next() != null) return error.ExtraChildTerminationEvent;
    var ended = try std.json.parseFromSlice(progress.Event, allocator, last, .{});
    defer ended.deinit();
    if (ended.value.state != .terminal or
        ended.value.reason != .child_termination or
        ended.value.complete != false or
        ended.value.current_test == null or
        ended.value.child_termination != .exited or
        ended.value.child_status != 7 or
        ended.value.process_group_cleanup_succeeded != true)
    {
        return error.InvalidChildTerminationEvent;
    }
    try requireNoFinal(allocator, directory);
}

fn verifyCancellation(
    allocator: std.mem.Allocator,
    directory: []const u8,
    text: []const u8,
) !void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    _ = lines.next() orelse return error.MissingInFlightEvent;
    const last = lines.next() orelse return error.MissingCancellationEvent;
    if (lines.next() != null) return error.ExtraCancellationEvent;
    var ended = try std.json.parseFromSlice(progress.Event, allocator, last, .{});
    defer ended.deinit();
    if (ended.value.state != .terminal or
        ended.value.reason != .cancelled or
        ended.value.complete != false or
        ended.value.current_test == null or
        ended.value.cancellation_signal != 15 or
        ended.value.process_group_cleanup_succeeded != true)
    {
        return error.InvalidCancellationEvent;
    }
    try requireNoFinal(allocator, directory);
    try requireDescendantStopped(
        allocator,
        directory,
        "cancel-descendant.pid",
    );
}

fn verifyTwoRowProgress(
    allocator: std.mem.Allocator,
    text: []const u8,
    completed_status: []const u8,
) !void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    const first = lines.next() orelse return error.MissingInFlightEvent;
    var started = try std.json.parseFromSlice(progress.Event, allocator, first, .{});
    defer started.deinit();
    if (started.value.state != .in_flight) return error.InvalidInFlightEvent;
    const last = lines.next() orelse return error.MissingCompletedEvent;
    if (lines.next() != null) return error.ExtraProgressEvent;
    var completed = try std.json.parseFromSlice(progress.Event, allocator, last, .{});
    defer completed.deinit();
    if (completed.value.state != .completed or
        completed.value.status == null or
        !std.mem.eql(u8, completed.value.status.?, completed_status))
    {
        return error.InvalidCompletedEvent;
    }
}

fn verifyFinal(
    allocator: std.mem.Allocator,
    directory: []const u8,
    expected_names: []const []const u8,
) !void {
    const path = try finalPath(allocator, directory);
    const text = try sys.fs.readFileAlloc(allocator, path, maximum_receipt_bytes);
    var parsed = try std.json.parseFromSlice(FinalReceipt, allocator, text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const final = parsed.value;
    if (!std.mem.eql(u8, final.schema, receipt.schema) or
        final.selected_test_count != expected_names.len or
        final.executed_test_count != expected_names.len or
        final.failed_test_count != 0 or
        final.tests.len != expected_names.len)
    {
        return error.InvalidFinalReceipt;
    }
    for (final.tests, expected_names) |row, expected| {
        if (!std.mem.eql(u8, row.name, expected) or
            !std.mem.eql(u8, row.status, "ok"))
        {
            return error.InvalidFinalReceiptOrder;
        }
    }
}

fn verifyFinalCount(
    allocator: std.mem.Allocator,
    directory: []const u8,
    selected: usize,
    failed: usize,
) !void {
    const path = try finalPath(allocator, directory);
    const text = try sys.fs.readFileAlloc(allocator, path, maximum_receipt_bytes);
    var parsed = try std.json.parseFromSlice(FinalReceipt, allocator, text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const final = parsed.value;
    if (!std.mem.eql(u8, final.schema, receipt.schema) or
        final.selected_test_count != selected or
        final.executed_test_count != selected or
        final.failed_test_count != failed or
        final.tests.len != selected)
    {
        return error.InvalidFinalReceipt;
    }
}

fn requireNoFinal(
    allocator: std.mem.Allocator,
    directory: []const u8,
) !void {
    _ = finalPath(allocator, directory) catch |err| switch (err) {
        error.MissingFinalReceipt => return,
        else => return err,
    };
    return error.UnexpectedFinalReceipt;
}

fn finalPath(
    allocator: std.mem.Allocator,
    directory: []const u8,
) ![]const u8 {
    const entries = try sys.fs.listDirAlloc(allocator, directory);
    var selected: ?[]const u8 = null;
    for (entries) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.name, ".json"))
        {
            continue;
        }
        if (selected != null) return error.DuplicateFinalReceipt;
        selected = entry.path;
    }
    if (selected) |path| return path;
    return error.MissingFinalReceipt;
}

fn requireDescendantStopped(
    allocator: std.mem.Allocator,
    directory: []const u8,
    file_name: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, file_name });
    const text = try sys.fs.readFileAlloc(allocator, path, 32);
    const child_id = std.fmt.parseInt(
        sys.process.ProcessId,
        std.mem.trim(u8, text, &std.ascii.whitespace),
        10,
    ) catch return error.InvalidDescendantId;
    for (0..100) |_| {
        const observed = sys.process.inspect.info(child_id) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        if (!observed.alive) return;
        sys.time.sleepMilliseconds(10);
    }
    return error.DescendantProcessSurvived;
}

fn readProgress(
    allocator: std.mem.Allocator,
    directory: []const u8,
) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ directory, progress.file_name });
    return try sys.fs.readFileAlloc(allocator, path, progress.maximum_file_bytes);
}

/// Runs the existing fixture binary, not another runner or receipt protocol.
/// The enclosing ordinary admitted gate owns its finite outer deadline.
fn verifyDeadline(init: sys.process.Init, allocator: std.mem.Allocator, mode: []const u8, binary: []const u8) !void {
    const suffix = mode["deadline_".len..];
    const selected = try std.fmt.allocPrint(allocator, "timing runner deadline {s}", .{suffix});
    var environment = sys.process.Environ.Map.init(allocator);
    defer environment.deinit();
    if (std.mem.eql(u8, suffix, "warmup")) try environment.put("TINY_TIMING_DEADLINE_FIXTURE", "warmup");
    if (std.mem.eql(u8, suffix, "repeat")) try environment.put("TINY_TIMING_RUNNER_REPEAT", "2");
    const started = try sys.time.awakeNow();
    const result = try std.process.run(allocator, init.io, .{
        .environ_map = &environment,
        .argv = &.{ binary, "--test-timeout-ms=250", "--test-filter", selected, "--test-filter", "timing runner deadline sentinel", "--test-priority", selected },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    const elapsed = try (try sys.time.awakeNow()).elapsedSince(started);
    if (elapsed.asNanoseconds() > 10 * std.time.ns_per_s) return error.DeadlineFixtureTooSlow;
    switch (result.term) {
        .signal => |signal| if (signal != .KILL) return error.WrongDeadlineSignal,
        else => return error.DeadlineDidNotTerminate,
    }
    if (std.mem.indexOf(u8, result.stderr, "DEADLINE SENTINEL RAN") != null)
        return error.LaterTestExecuted;
    if (std.mem.indexOf(u8, result.stderr, "test timing:") != null)
        return error.PartialDeadlineReportAccepted;
    if (std.mem.eql(u8, suffix, "teardown") and
        std.mem.indexOf(u8, result.stderr, "deadline body returned") == null)
        return error.TeardownNotReached;
}
