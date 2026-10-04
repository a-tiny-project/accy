const std = @import("std");
const pretty = @import("timing_runner_pretty");
const sys = @import("timing_runner_sys");

const command = @import("command.zig");
const options = @import("options.zig");
const progress = @import("progress.zig");
const receipt = @import("receipt.zig");

pub const selected_cap: usize = progress.maximum_selected;
pub const deadline_ms: u64 = options.supervised_deadline_ms;
pub const heartbeat_ms: u64 = options.supervised_heartbeat_ms;
const poll_ms: u64 = 10;
const order_bytes: usize = selected_cap * 6;
const receipt_token = "focused";
var cancellation_signal: std.atomic.Value(u32) = .init(0);

pub const Config = struct {
    directory: []const u8,
    deadline: u64,
    heartbeat: u64,
};

pub const Outcome = union(enum) {
    terminated: Terminated,
    timeout: bool,
    cancelled: u32,
};

pub const Terminated = struct {
    term: sys.process.Termination,
    final_failed: ?usize,
};

pub const SelectionFailure = enum {
    limit,
    empty,
    invalid,
};

const Failure = struct {
    reason: progress.Reason,
    child_started: bool,
    term: ?sys.process.Termination = null,
    group_cleanup_succeeded: ?bool = null,
    cancellation: ?u32 = null,
};

const GroupClose = struct {
    term: sys.process.Termination,
    group_closed: bool,
};

const TerminationFields = struct {
    kind: progress.ChildTermination,
    status: u32,
};

pub fn load(
    args: anytype,
    environ: sys.process.Environ,
) !?Config {
    if (!enabled(environ)) return null;
    const directory = try receiptDirectory(args) orelse
        return error.MissingSupervisedReceiptDirectory;
    const requested_deadline = try boundedMilliseconds(
        environ,
        options.supervisor_deadline_environment,
        deadline_ms,
        deadline_ms,
    );
    const requested_heartbeat = try boundedMilliseconds(
        environ,
        options.supervisor_heartbeat_environment,
        heartbeat_ms,
        requested_deadline,
    );
    if (requested_heartbeat >= requested_deadline) {
        return error.InvalidSupervisorHeartbeat;
    }
    return .{
        .directory = directory,
        .deadline = requested_deadline,
        .heartbeat = requested_heartbeat,
    };
}

pub fn childRequested(environ: sys.process.Environ) bool {
    return sys.process.Environ.getPosix(
        environ,
        options.supervisor_child_environment,
    ) != null;
}

pub fn childOrder(
    environ: sys.process.Environ,
    selected_count: usize,
    storage: *[selected_cap]u32,
) ![]const u32 {
    const encoded = sys.process.Environ.getPosix(
        environ,
        options.supervisor_order_environment,
    ) orelse return error.MissingSupervisorOrder;
    return try parseOrder(encoded, selected_count, storage);
}

fn parseOrder(
    encoded: []const u8,
    selected_count: usize,
    storage: *[selected_cap]u32,
) ![]const u32 {
    var seen: [selected_cap]bool = @splat(false);
    var iterator = std.mem.splitScalar(u8, encoded, ',');
    var count: usize = 0;
    while (iterator.next()) |value| {
        if (count >= selected_count or value.len == 0) {
            return error.InvalidSupervisorOrder;
        }
        const ordinal = std.fmt.parseUnsigned(u32, value, 10) catch
            return error.InvalidSupervisorOrder;
        if (ordinal >= selected_count or seen[ordinal]) {
            return error.InvalidSupervisorOrder;
        }
        storage[count] = ordinal;
        seen[ordinal] = true;
        count += 1;
    }
    if (count != selected_count) return error.InvalidSupervisorOrder;
    return storage[0..count];
}

pub fn run(
    init: sys.process.Init,
    order: []const u32,
    config: Config,
) !Outcome {
    std.debug.assert(order.len > 0);
    std.debug.assert(order.len <= selected_cap);
    const started = sys.time.milliTimestamp();
    if (sys.process.childSignalPolicy() == .unsupported or
        sys.process.childPeekPolicy() == .unsupported)
    {
        return setupError(
            config,
            order.len,
            started,
            error.UnsupportedSupervisorProcessGroup,
        );
    }
    cancellation_signal.store(0, .release);
    sys.signal.installInterruptHandler(handleCancellation);
    defer sys.signal.restoreInterruptDefault();
    sys.signal.installTerminationHandlers(handleCancellation);
    defer sys.signal.restoreTerminationDefaults();
    var arena = std.heap.ArenaAllocator.init(sys.allocator.processAllocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    const argv = argvAlloc(allocator, init.minimal.args) catch |err|
        return setupError(config, order.len, started, err);
    var environment = init.environ_map.clone(allocator) catch |err|
        return setupError(config, order.len, started, err);
    defer environment.deinit();
    var encoded_order: [order_bytes]u8 = undefined;
    const order_text = encodeOrder(order, &encoded_order) catch |err|
        return setupError(config, order.len, started, err);
    configureChild(&environment, config, order_text) catch |err|
        return setupError(config, order.len, started, err);
    var child = sys.process.spawn(init.io, .{
        .argv = argv,
        .environ_map = &environment,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = 0,
    }) catch |err| return setupError(config, order.len, started, err);
    var group_owned = false;
    defer cleanupOwned(&child, init.io, group_owned);
    try ownProcessGroup(&child, init.io, config, order.len, started);
    group_owned = true;
    return try monitor(
        &child,
        init.io,
        allocator,
        order.len,
        config,
        started,
    );
}

fn ownProcessGroup(
    child: *sys.process.Child,
    io: anytype,
    config: Config,
    selected: usize,
    started: i64,
) !void {
    const child_id = child.id orelse {
        recordSetupFailure(config, selected, started, true);
        return error.MissingSupervisorChildId;
    };
    const child_group = sys.process.processGroupId(child_id) catch |err| {
        recordGroupSetupFailure(
            child,
            io,
            config,
            selected,
            started,
        );
        return err;
    };
    if (child_group != child_id) {
        recordGroupSetupFailure(
            child,
            io,
            config,
            selected,
            started,
        );
        return error.SupervisorProcessGroupMismatch;
    }
}

fn monitor(
    child: *sys.process.Child,
    io: anytype,
    allocator: std.mem.Allocator,
    selected: usize,
    config: Config,
    started: i64,
) !Outcome {
    const child_id = child.id.?;
    writeStart(config, selected);
    var next_heartbeat = config.heartbeat;
    while (true) {
        const elapsed = elapsedMilliseconds(started);
        if (try sys.process.peekNoHang(child_id)) |term| {
            return try finishObserved(
                child,
                io,
                allocator,
                selected,
                config,
                term,
                elapsed,
            );
        }
        const signal = cancellation_signal.load(.acquire);
        if (signal != 0) {
            return try finishCancellation(
                child,
                io,
                allocator,
                selected,
                config,
                signal,
                elapsed,
            );
        }
        if (elapsed >= config.deadline) break;
        if (elapsed >= next_heartbeat) {
            writeHeartbeat(config, selected, elapsed);
            next_heartbeat = std.math.add(u64, next_heartbeat, config.heartbeat) catch
                config.deadline;
        }
        const remaining = config.deadline - elapsed;
        sys.time.sleepMilliseconds(@min(poll_ms, remaining));
    }
    return try finishDeadline(child, io, allocator, selected, config, started);
}

fn finishObserved(
    child: *sys.process.Child,
    io: anytype,
    allocator: std.mem.Allocator,
    selected: usize,
    config: Config,
    term: sys.process.Termination,
    elapsed: u64,
) !Outcome {
    const closed = try closeGroupAndReap(child, io);
    std.debug.assert(std.meta.eql(term, closed.term));
    const completion = runCompletion(allocator, config, selected);
    if (!closed.group_closed) {
        try appendFailure(config, selected, elapsed, .{
            .reason = .process_group_failure,
            .child_started = true,
            .term = term,
            .group_cleanup_succeeded = false,
        });
        return error.SupervisorProcessGroupCleanupFailed;
    }
    if (completion == null) try appendFailure(config, selected, elapsed, .{
        .reason = .child_termination,
        .child_started = true,
        .term = term,
        .group_cleanup_succeeded = true,
    });
    return .{ .terminated = .{
        .term = term,
        .final_failed = if (completion) |value| value.failed else null,
    } };
}

fn finishCancellation(
    child: *sys.process.Child,
    io: anytype,
    allocator: std.mem.Allocator,
    selected: usize,
    config: Config,
    signal: u32,
    elapsed: u64,
) !Outcome {
    const closed = try closeGroupAndReap(child, io);
    const completion = runCompletion(allocator, config, selected);
    if (completion != null or !deadlineKill(closed.term)) {
        return try finishRaced(config, selected, elapsed, closed, completion);
    }
    try appendFailure(config, selected, elapsed, .{
        .reason = .cancelled,
        .child_started = true,
        .term = closed.term,
        .group_cleanup_succeeded = closed.group_closed,
        .cancellation = signal,
    });
    writeCancellation(config, selected, signal, closed.group_closed);
    return .{ .cancelled = signal };
}

fn finishDeadline(
    child: *sys.process.Child,
    io: anytype,
    allocator: std.mem.Allocator,
    selected: usize,
    config: Config,
    started: i64,
) !Outcome {
    const closed = try closeGroupAndReap(child, io);
    const completion = runCompletion(allocator, config, selected);
    if (completion != null or !deadlineKill(closed.term)) {
        return try finishRaced(
            config,
            selected,
            elapsedMilliseconds(started),
            closed,
            completion,
        );
    }
    if (!closed.group_closed) {
        try appendFailure(
            config,
            selected,
            elapsedMilliseconds(started),
            .{
                .reason = .timeout,
                .child_started = true,
                .term = closed.term,
                .group_cleanup_succeeded = false,
            },
        );
        writeTimeout(config, selected, false);
        return .{ .timeout = false };
    }
    try appendFailure(
        config,
        selected,
        elapsedMilliseconds(started),
        .{
            .reason = .timeout,
            .child_started = true,
            .term = closed.term,
            .group_cleanup_succeeded = closed.group_closed,
        },
    );
    writeTimeout(config, selected, closed.group_closed);
    return .{ .timeout = closed.group_closed };
}

fn finishRaced(
    config: Config,
    selected: usize,
    elapsed: u64,
    closed: GroupClose,
    completion: ?receipt.RunCompletion,
) !Outcome {
    if (!closed.group_closed) {
        try appendFailure(config, selected, elapsed, .{
            .reason = .process_group_failure,
            .child_started = true,
            .term = closed.term,
            .group_cleanup_succeeded = false,
        });
        return error.SupervisorProcessGroupCleanupFailed;
    }
    if (completion == null) try appendFailure(config, selected, elapsed, .{
        .reason = .child_termination,
        .child_started = true,
        .term = closed.term,
        .group_cleanup_succeeded = true,
    });
    return .{ .terminated = .{
        .term = closed.term,
        .final_failed = if (completion) |value| value.failed else null,
    } };
}

fn runCompletion(
    allocator: std.mem.Allocator,
    config: Config,
    selected: usize,
) ?receipt.RunCompletion {
    return receipt.completion(
        allocator,
        config.directory,
        receipt_token,
        selected,
    ) catch null;
}

fn deadlineKill(term: sys.process.Termination) bool {
    return switch (term) {
        .signal => |signal| signal == .KILL,
        else => false,
    };
}

pub fn initialize(config: Config) !void {
    try receipt.reset(
        sys.allocator.processAllocator(),
        config.directory,
        receipt_token,
    );
    try progress.initialize(config.directory);
}

pub fn rejectSelection(
    config: Config,
    selected: usize,
    failure: SelectionFailure,
) !void {
    const reason: progress.Reason = switch (failure) {
        .limit => .selection_limit,
        .empty => .empty_selection,
        .invalid => .invalid_selection,
    };
    try progress.appendTerminal(config.directory, .{
        .sequence = 0,
        .selected = @intCast(selected),
        .completed = 0,
        .elapsed_ms = 0,
        .reason = reason,
        .child_process_started = false,
    });
}

fn configureChild(
    environment: *sys.process.Environ.Map,
    config: Config,
    order: []const u8,
) !void {
    try environment.put(options.supervisor_child_environment, "1");
    try environment.put(options.supervisor_order_environment, order);
    try environment.put(options.directory_environment, config.directory);
    try environment.put(options.token_environment, receipt_token);
    try environment.put(options.shard_count_environment, "1");
    try environment.put(options.shard_index_environment, "0");
}

fn argvAlloc(
    allocator: std.mem.Allocator,
    args: sys.process.Args,
) ![]const []const u8 {
    const args_z = try args.toSlice(allocator);
    const argv = try allocator.alloc([]const u8, args_z.len);
    for (args_z, argv) |arg, *value| value.* = arg[0..arg.len];
    return argv;
}

fn encodeOrder(order: []const u32, storage: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(storage);
    for (order, 0..) |ordinal, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{ordinal});
    }
    return writer.buffered();
}

fn cleanupOwned(
    child: *sys.process.Child,
    io: anytype,
    group_owned: bool,
) void {
    if (child.id == null) return;
    if (!group_owned) {
        sys.process.killAndReap(child, io);
        return;
    }
    _ = closeGroupAndReap(child, io) catch {
        sys.process.killAndReap(child, io);
    };
}

fn closeGroupAndReap(
    child: *sys.process.Child,
    io: anytype,
) !GroupClose {
    const child_id = child.id orelse return error.MissingSupervisorChildId;
    var group_closed = true;
    sys.process.signalChildGroup(child_id, .kill) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => {
            group_closed = false;
            sys.process.forceKillChildId(child_id);
        },
    };
    return .{
        .term = try sys.process.wait(child, io),
        .group_closed = group_closed,
    };
}

fn setupError(
    config: Config,
    selected: usize,
    started: i64,
    err: anyerror,
) anyerror {
    recordSetupFailure(config, selected, started, false);
    return err;
}

fn recordSetupFailure(
    config: Config,
    selected: usize,
    started: i64,
    child_started: bool,
) void {
    appendFailure(config, selected, elapsedMilliseconds(started), .{
        .reason = .spawn_failure,
        .child_started = child_started,
    }) catch {};
}

fn recordGroupSetupFailure(
    child: *sys.process.Child,
    io: anytype,
    config: Config,
    selected: usize,
    started: i64,
) void {
    const child_id = child.id orelse return;
    sys.process.forceKillChildId(child_id);
    const term = sys.process.wait(child, io) catch null;
    appendFailure(config, selected, elapsedMilliseconds(started), .{
        .reason = .process_group_failure,
        .child_started = true,
        .term = term,
        .group_cleanup_succeeded = false,
    }) catch {};
}

fn appendFailure(
    config: Config,
    selected: usize,
    elapsed: u64,
    failure: Failure,
) !void {
    var name: [progress.maximum_name_bytes]u8 = undefined;
    const latest = try progress.latest(config.directory, &name);
    const sequence = if (latest) |snapshot| snapshot.sequence + 1 else 0;
    const completed = if (latest) |snapshot| snapshot.completed else 0;
    const current = if (latest) |snapshot| snapshot.current_test else null;
    const termination = if (failure.term) |term|
        terminationFields(term)
    else
        null;
    try progress.appendTerminal(config.directory, .{
        .sequence = sequence,
        .selected = @intCast(selected),
        .completed = completed,
        .elapsed_ms = elapsed,
        .reason = failure.reason,
        .current_test = current,
        .child_process_started = failure.child_started,
        .child_termination = if (termination) |value| value.kind else null,
        .child_status = if (termination) |value| value.status else null,
        .process_group_cleanup_succeeded = failure.group_cleanup_succeeded,
        .cancellation_signal = failure.cancellation,
    });
}

fn terminationFields(term: sys.process.Termination) TerminationFields {
    return switch (term) {
        .exited => |status| .{ .kind = .exited, .status = status },
        .signal => |status| .{
            .kind = .signal,
            .status = @intCast(@backingInt(status)),
        },
        .stopped => |status| .{
            .kind = .stopped,
            .status = @intCast(@backingInt(status)),
        },
        .unknown => |status| .{ .kind = .unknown, .status = status },
    };
}

fn writeStart(config: Config, selected: usize) void {
    pretty.diagnostic.writeStderrText(
        "[run] {d} focused tests in one process; deadline={d} ms; receipts={s}\n",
        .{ selected, config.deadline, config.directory },
    );
}

fn writeHeartbeat(config: Config, selected: usize, elapsed: u64) void {
    var name: [progress.maximum_name_bytes]u8 = undefined;
    const latest = progress.latest(config.directory, &name) catch null;
    const completed = if (latest) |snapshot| snapshot.completed else 0;
    const current = if (latest) |snapshot|
        snapshot.current_test orelse "starting"
    else
        "starting";
    pretty.diagnostic.writeStderrText(
        "[run] heartbeat completed={d}/{d} elapsed={d} ms current={s}\n",
        .{ completed, selected, elapsed, current },
    );
}

fn handleCancellation(signal: sys.signal.RawSignal) callconv(.c) void {
    cancellation_signal.store(@intCast(@backingInt(signal)), .release);
}

pub fn writeChildFailure(
    config: Config,
    selected: usize,
    complete: bool,
) void {
    var name: [progress.maximum_name_bytes]u8 = undefined;
    const latest = progress.latest(config.directory, &name) catch null;
    const completed = if (latest) |snapshot| snapshot.completed else 0;
    const current = if (latest) |snapshot|
        snapshot.current_test orelse "none"
    else
        "none";
    pretty.diagnostic.writeStderrText(
        "[FAIL] focused child exited completed={d}/{d} current={s} complete={any}; receipts={s}\n",
        .{ completed, selected, current, complete, config.directory },
    );
}

fn writeCancellation(
    config: Config,
    selected: usize,
    signal: u32,
    group_closed: bool,
) void {
    var name: [progress.maximum_name_bytes]u8 = undefined;
    const latest = progress.latest(config.directory, &name) catch null;
    const completed = if (latest) |snapshot| snapshot.completed else 0;
    const current = if (latest) |snapshot|
        snapshot.current_test orelse "unknown"
    else
        "unknown";
    pretty.diagnostic.writeStderrText(
        "[FAIL] focused tests cancelled signal={d} completed={d}/{d} " ++
            "current={s} process-group={s}\n",
        .{
            signal,
            completed,
            selected,
            current,
            if (group_closed) "closed" else "failed",
        },
    );
}

fn writeTimeout(config: Config, selected: usize, group_closed: bool) void {
    var name: [progress.maximum_name_bytes]u8 = undefined;
    const latest = progress.latest(config.directory, &name) catch null;
    const completed = if (latest) |snapshot| snapshot.completed else 0;
    const current = if (latest) |snapshot|
        snapshot.current_test orelse "unknown"
    else
        "unknown";
    const cleanup = if (group_closed) "closed" else "failed";
    pretty.diagnostic.writeStderrText(
        "[FAIL] focused tests timed out completed={d}/{d} current={s}; " ++
            "process-group={s}; receipt={s}/{s}\n",
        .{
            completed,
            selected,
            current,
            cleanup,
            config.directory,
            progress.file_name,
        },
    );
}

fn enabled(environ: sys.process.Environ) bool {
    const value = sys.process.Environ.getPosix(
        environ,
        options.supervised_environment,
    ) orelse return false;
    return value.len == 0 or !std.mem.eql(u8, value, "0");
}

fn receiptDirectory(args: anytype) !?[]const u8 {
    var selected: ?[]const u8 = null;
    var iterator = sys.process.Args.Iterator.init(args);
    while (iterator.next()) |arg| {
        const value = if (std.mem.eql(u8, arg, command.supervised_receipts_flag))
            iterator.next() orelse return error.MissingSupervisedReceiptDirectory
        else if (std.mem.startsWith(u8, arg, command.supervised_receipts_flag ++ "="))
            arg[command.supervised_receipts_flag.len + 1 ..]
        else
            continue;
        if (selected != null) return error.DuplicateSupervisedReceiptDirectory;
        if (value.len == 0 or value.len >= std.fs.max_path_bytes) {
            return error.InvalidSupervisedReceiptDirectory;
        }
        selected = value;
    }
    return selected;
}

fn boundedMilliseconds(
    environ: sys.process.Environ,
    name: []const u8,
    default: u64,
    maximum: u64,
) !u64 {
    const value = sys.process.Environ.getPosix(environ, name) orelse
        return default;
    const parsed = std.fmt.parseUnsigned(u64, value, 10) catch
        return error.InvalidSupervisorDuration;
    if (parsed == 0 or parsed > maximum) {
        return error.InvalidSupervisorDuration;
    }
    return parsed;
}

fn elapsedMilliseconds(started: i64) u64 {
    const now = sys.time.milliTimestamp();
    if (now <= started) return 0;
    return @intCast(now - started);
}
