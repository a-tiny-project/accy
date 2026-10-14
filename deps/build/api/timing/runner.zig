const std = @import("std");
const builtin = @import("builtin");
const pretty = @import("timing_runner_pretty");
const sys = @import("timing_runner_sys");
const command = @import("command.zig");
const progress = @import("progress.zig");
const receipt = @import("receipt.zig");
const execution = @import("execution.zig");
const deadline = @import("deadline.zig");
const selection_data = @import("selection.zig");
const shard_data = @import("shard.zig");
const supervisor = @import("supervisor.zig");
const tree = @import("tree.zig");
const balance = @import("balance.zig");
const rows_data = @import("rows.zig");
const Io = std.Io;

pub const std_options: std.Options = .{ .log_level = .warn };

const runner_io: Io = sys.thread.ThreadedIo.global_single_threaded.io();
const max_test_functions = 16 * 1024;
comptime {
    std.debug.assert(balance.max_tests == max_test_functions);
}
const max_test_filters = 32;
const report_width = 120;
const shard_warmup_tag = "[tiny-test-shard-warmup]";

pub fn main(init: sys.process.Init) void {
    var arguments = sys.process.Args.Iterator.init(init.minimal.args);
    switch (command.parse(&arguments)) {
        .run => {},
        .help => {
            writeHelp(init.minimal.environ);
            return;
        },
        .failure => |failure| {
            writeArgumentFailure(init.minimal.environ, failure);
            sys.process.exit(2);
        },
    }
    var timeout_arguments = sys.process.Args.Iterator.init(init.minimal.args);
    const timeout_ms = command.timeoutMilliseconds(&timeout_arguments) catch |err| {
        writeRunnerFailure(init.minimal.environ, "test deadline", err);
        sys.process.exit(2);
    };
    var deadline_arguments = sys.process.Args.Iterator.init(init.minimal.args);
    const deadline_overrides = testDeadlines(&deadline_arguments, timeout_ms) catch |err| {
        writeRunnerFailure(init.minimal.environ, "test deadline", err);
        sys.process.exit(2);
    };
    checkBinaryLimit(init.minimal);
    if (builtin.test_functions.len > max_test_functions) @panic("too many tests for timing runner");
    const selection = testSelection(init.minimal.args, init.minimal.environ);
    const selected_count = matchingTestCount(selection);
    const supervised = supervisor.load(
        init.minimal.args,
        init.minimal.environ,
    ) catch |err| {
        writeRunnerFailure(init.minimal.environ, "focused test supervisor", err);
        sys.process.exit(2);
    };
    const child = shard_data.childRequested(init.minimal.environ) or
        supervisor.childRequested(init.minimal.environ);
    requireSelection(init.minimal, selection, selected_count, supervised, child);
    if (supervised) |config| {
        validateFocusedSelection(selection) catch |err| {
            if (!child) {
                supervisor.initialize(config) catch {};
                const reason: supervisor.SelectionFailure = if (selected_count > supervisor.selected_cap) .limit else .invalid;
                supervisor.rejectSelection(
                    config,
                    selected_count,
                    reason,
                ) catch {};
            }
            writeRunnerFailure(init.minimal.environ, "focused test selection", err);
            sys.process.exit(2);
        };
        if (!child) runSupervised(init, selection, selected_count, config);
    }
    const balanced_run = loadBalance(init.minimal);
    if (shard_data.coordinatorRequested(init.minimal.environ)) {
        if (balanced_run != null) {
            writeRunnerFailure(init.minimal.environ, "balanced shards", error.ExternalShardRequired);
            sys.process.exit(2);
        }
        var order_storage: [max_test_functions]u32 = undefined;
        const order = matchingTestOrder(
            selection,
            testPriorityFilters(init.minimal.args),
            &order_storage,
        );
        const result = shard_data.runCoordinator(init, order) catch |err| {
            shard_data.writeCoordinatorError(err);
            sys.process.exit(1);
        };
        if (!result.success) sys.process.exit(1);
        shard_data.writeSuccess(selected_count, result.worker_count);
        return;
    }
    const workspace = prepareTree(init.minimal, supervised != null or child);
    runTests(init.minimal, supervised, balanced_run, timeout_ms, deadline_overrides.slice());
    if (workspace) |prepared| prepared.finish(runner_io) catch |err| {
        writeRunnerFailure(init.minimal.environ, "test tree cleanup", err);
        sys.process.exit(1);
    };
}

/// Refuses the run before any test when its own executable is larger than the argv's limit.
/// The first argument names the binary relative to the starting directory, which a private
/// test tree has not yet replaced.
fn checkBinaryLimit(init: sys.process.MinimalInit) void {
    var arguments = sys.process.Args.Iterator.init(init.args);
    const limit = command.binaryLimit(&arguments) catch |err| {
        writeRunnerFailure(init.environ, "test binary limit", err);
        sys.process.exit(2);
    } orelse return;
    var first = sys.process.Args.Iterator.init(init.args);
    const executable = first.next().?;
    const bytes = executableBytes(executable) catch |err| {
        writeRunnerFailure(init.environ, "test binary limit", err);
        sys.process.exit(2);
    };
    if (bytes <= limit) return;
    var detail: [128]u8 = undefined;
    const message = std.fmt.bufPrint(
        &detail,
        "backend={s}: {d} bytes exceed the {d}-byte limit",
        .{ @tagName(builtin.zig_backend), bytes, limit },
    ) catch unreachable;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = sys.stdio.stderr().writerStreaming(sys.stdio.debugIo(), &stderr_buffer);
    writeFailLine(&stderr_writer.interface, timingRenderOptions(init.environ), executable, message) catch {};
    stderr_writer.interface.flush() catch {};
    sys.process.exit(1);
}

fn executableBytes(path: []const u8) !u64 {
    const io = sys.fs.debugIo();
    return (try sys.fs.cwd().statFile(io, path, .{})).size;
}

/// A balanced shard's weights table, its position and the open rows file. Both files are
/// opened before a private tree changes the working directory.
const Balanced = struct {
    table: balance.Table,
    position: shard_data.Position,
    rows: std.Io.File,
};

fn loadBalance(init: sys.process.MinimalInit) ?Balanced {
    const weights_path = pathFlag(init.args, command.weights_flag) catch |err| {
        writeRunnerFailure(init.environ, "test weights", err);
        sys.process.exit(2);
    };
    const rows_path = pathFlag(init.args, command.rows_flag) catch |err| {
        writeRunnerFailure(init.environ, "test rows", err);
        sys.process.exit(2);
    };
    const weights = weights_path orelse {
        if (rows_path != null) {
            writeRunnerFailure(init.environ, "test rows", error.RowsRequireWeights);
            sys.process.exit(2);
        }
        return null;
    };
    const rows_output = rows_path orelse {
        writeRunnerFailure(init.environ, "test weights", error.WeightsRequireRows);
        sys.process.exit(2);
    };
    return openBalance(init, weights, rows_output) catch |err| {
        writeRunnerFailure(init.environ, "balanced shards", err);
        sys.process.exit(2);
    };
}

fn openBalance(init: sys.process.MinimalInit, weights: []const u8, rows_output: []const u8) !Balanced {
    const allocator = sys.allocator.processAllocator();
    const text = try sys.fs.readFileAlloc(allocator, weights, balance.max_table_bytes);
    const table = try balance.parse(
        text,
        try allocator.alloc([]const u8, balance.max_tests),
        try allocator.alloc(u64, balance.max_tests),
    );
    return .{
        .table = table,
        .position = try shard_data.externalPosition(init.environ),
        .rows = try sys.fs.createFile(rows_output, .{ .truncate = true }),
    };
}

fn pathFlag(args: anytype, flag: []const u8) !?[]const u8 {
    var selected: ?[]const u8 = null;
    var iterator = sys.process.Args.Iterator.init(args);
    while (iterator.next()) |arg| {
        const value = if (std.mem.eql(u8, arg, flag))
            iterator.next() orelse return error.MissingPath
        else if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len and arg[flag.len] == '=')
            arg[flag.len + 1 ..]
        else
            continue;
        if (selected != null) return error.DuplicatePath;
        if (value.len == 0 or value.len >= std.fs.max_path_bytes) return error.InvalidPath;
        selected = value;
    }
    return selected;
}

/// This shard's share of the selected tests, as selection ordinals, heaviest first.
fn balancedOrder(
    balanced: *const Balanced,
    selected: []const usize,
    storage: *[max_test_functions]u32,
) []const u32 {
    std.debug.assert(selected.len <= max_test_functions);
    for (selected, BalanceScratch.names[0..selected.len]) |index, *name| {
        name.* = builtin.test_functions[index].name;
    }
    return balance.assign(
        &balanced.table,
        BalanceScratch.names[0..selected.len],
        balanced.position.count,
        balanced.position.index,
        .{ .order = &BalanceScratch.order, .weights = &BalanceScratch.weights },
        storage,
    );
}

/// Static working memory for the one balanced assignment a shard computes.
const BalanceScratch = struct {
    var names: [max_test_functions][]const u8 = undefined;
    var order: [max_test_functions]u32 = undefined;
    var weights: [max_test_functions]u64 = undefined;
};

/// A cached run executes inside a private tree of declared inputs. Supervised and sharded
/// runs spawn children against the caller's working directory, so they refuse a tree.
fn prepareTree(init: sys.process.MinimalInit, spawning: bool) ?tree.Workspace {
    var arguments = sys.process.Args.Iterator.init(init.args);
    const selected = (tree.plan(&arguments) catch |err| {
        writeRunnerFailure(init.environ, "test tree", err);
        sys.process.exit(2);
    }) orelse {
        writeTreeLine(init.environ, null, null);
        return null;
    };
    if (spawning) {
        writeRunnerFailure(init.environ, "test tree", error.TreeRequiresInProcessRun);
        sys.process.exit(2);
    }
    const placement = placeTree(init.environ, selected.store);
    const memory: ?tree.Memory = switch (placement) {
        .memory => |chosen| chosen,
        .disk => null,
    };
    const workspace = tree.prepare(runner_io, &selected, memory) catch |err| {
        writeRunnerFailure(init.environ, "test tree", err);
        sys.process.exit(2);
    };
    writeTreeLine(init.environ, selected.store, placement);
    return workspace;
}

/// The mount point a run's tree can move to. Each user's trees share one directory there,
/// `tiny-test-trees-<uid>`.
const memory_tree_mount = "/dev/shm";
const memory_tree_environment = @import("carried.zig").tree;
var memory_tree_path: [64]u8 = undefined;

const TreePlacement = union(enum) {
    memory: tree.Memory,
    disk: tree.DiskReason,
};

/// Chooses where the run's tree lives. The build asks for memory per run, and
/// `TINY_TIMING_RUNNER_TREE` overrides it: `disk` forces the cached output directory and
/// `memory` asks for memory. A memory request stays on disk, with its reason, unless the
/// mount point is tmpfs with `tree.memory_free_bytes_min` free and the user's directory
/// there passes `tree.directoryRefusal`. Nothing is created or removed before the mount
/// passes. A run that fails or is killed leaves its tree for inspection, and the next memory
/// run removes this user's trees whose processes no longer exist.
fn placeTree(environ: sys.process.Environ, requested: tree.Store) TreePlacement {
    const override = sys.process.Environ.getPosix(environ, memory_tree_environment);
    switch (tree.request(requested, override)) {
        .memory => {},
        .disk => |reason| return .{ .disk = reason },
    }
    if (comptime builtin.os.tag != .linux) return .{ .disk = .unsupported_system };
    var mount = Io.Dir.cwd().openDir(runner_io, memory_tree_mount, .{}) catch
        return .{ .disk = tree.mountRefusal(null).? };
    defer mount.close(runner_io);
    const space: ?sys.fd.FilesystemSpace = sys.fd.filesystemSpace(mount.handle) catch null;
    if (tree.mountRefusal(.{
        .filesystem_type = filesystemType(mount),
        .available_bytes = if (space) |observed| observed.available_bytes else null,
    })) |reason| return .{ .disk = reason };
    const user = sys.process.currentUserId() catch return .{ .disk = .directory_unavailable };
    const process = sys.process.currentProcessId() catch return .{ .disk = .directory_unavailable };
    const path = std.fmt.bufPrint(
        &memory_tree_path,
        "tiny-test-trees-{d}/{d}",
        .{ user, process },
    ) catch unreachable;
    const separator = std.mem.indexOfScalar(u8, path, '/').?;
    var found = false;
    mount.createDir(
        runner_io,
        path[0..separator],
        .fromMode(tree.memory_directory_mode),
    ) catch |err| switch (err) {
        error.PathAlreadyExists => found = true,
        else => return .{ .disk = .directory_unavailable },
    };
    // The open refuses a link, and the permissions are read from the opened directory itself.
    var shared = mount.openDir(
        runner_io,
        path[0..separator],
        .{ .iterate = true, .follow_symlinks = false },
    ) catch return .{ .disk = if (found) .directory_untrusted else .directory_unavailable };
    const permissions: ?sys.fd.DirectoryPermissions = sys.fd.directoryPermissions(shared.handle) catch null;
    if (tree.directoryRefusal(
        if (permissions) |observed| .{ .owner = observed.owner_user_id, .mode = observed.mode } else null,
        user,
    )) |reason| {
        shared.close(runner_io);
        return .{ .disk = reason };
    }
    tree.removeDeadTrees(runner_io, shared, {}, processAlive);
    const name = path[separator + 1 ..];
    shared.deleteTree(runner_io, name) catch {};
    shared.createDir(runner_io, name, .fromMode(tree.memory_directory_mode)) catch {
        shared.close(runner_io);
        return .{ .disk = .directory_unavailable };
    };
    return .{ .memory = .{ .shared = shared, .name = name } };
}

/// Reports whether a process exists. An answer other than absence counts as alive.
fn processAlive(_: void, process: u32) bool {
    var path_storage: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_storage, "/proc/{d}", .{process}) catch unreachable;
    Io.Dir.cwd().access(runner_io, path, .{}) catch |err| return err != error.FileNotFound;
    return true;
}

/// Reads the Linux filesystem type of an opened directory. A refusal reads as unknown.
fn filesystemType(directory: Io.Dir) ?u64 {
    const observed = sys.fd.filesystemType(directory.handle) catch return null;
    return switch (observed) {
        .linux => |number| number,
        .darwin => null,
    };
}

/// Writes the tree the tests run in to standard error once the working directory is set:
/// the store asked for, the one used, its filesystem and its path, so a reader can tell a
/// memory run from a disk run and a fallback from a choice. A run without a tree, such as
/// the receipt mode, reports the working directory it was given. Only a run whose build
/// asked for memory or whose environment sets `TINY_TIMING_RUNNER_TREE` writes the line,
/// so every other run's output is unchanged.
fn writeTreeLine(environ: sys.process.Environ, asked: ?tree.Store, placement: ?TreePlacement) void {
    if (!tree.reports(asked, sys.process.Environ.getPosix(environ, memory_tree_environment))) return;
    var stderr_buffer: [std.fs.max_path_bytes + 256]u8 = undefined;
    var stderr_writer = sys.stdio.stderr().writerStreaming(sys.stdio.debugIo(), &stderr_buffer);
    const out = &stderr_writer.interface;
    var filesystem_storage: [24]u8 = undefined;
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path: []const u8 = path: {
        const process = sys.process.currentProcessId() catch break :path "unknown";
        break :path sys.process.inspect.cwd(process, &path_storage) catch "unknown";
    };
    const working_type: ?u64 = working: {
        var working = Io.Dir.cwd().openDir(runner_io, ".", .{}) catch break :working null;
        defer working.close(runner_io);
        break :working filesystemType(working);
    };
    const used: []const u8, const reason: ?tree.DiskReason = if (placement) |chosen| switch (chosen) {
        .memory => .{ "memory", null },
        .disk => |why| .{ "disk", why },
    } else .{ "working-directory", null };
    out.print("test tree: asked={s} used={s} filesystem={s} path={s}", .{
        if (asked) |store| @tagName(store) else "none",
        used,
        tree.filesystemName(working_type, &filesystem_storage),
        path,
    }) catch {};
    if (reason) |why| out.print(" reason={s}", .{@tagName(why)}) catch {};
    out.writeAll("\n") catch {};
    out.flush() catch {};
}

fn requireSelection(
    init: sys.process.MinimalInit,
    selection: TestSelection,
    selected_count: usize,
    supervised: ?supervisor.Config,
    child: bool,
) void {
    const selection_receipt = selectionReceiptPath(init.args) catch |err| {
        writeRunnerFailure(init.environ, "test selection receipt", err);
        sys.process.exit(1);
    };
    if (!child) {
        if (selection_receipt) |path| {
            writeSelectionReceipt(path, selected_count) catch |err| {
                writeRunnerFailure(init.environ, "test selection receipt", err);
                sys.process.exit(1);
            };
        }
    }
    if (selected_count == 0 and !emptyFilterAllowed(init.environ)) {
        if (supervised) |config| if (!child) {
            supervisor.initialize(config) catch {};
            supervisor.rejectSelection(config, selected_count, .empty) catch {};
        };
        writeNoTests(init.environ, selection.includes.len != 0);
        sys.process.exit(1);
    }
}

fn runSupervised(
    init: sys.process.Init,
    selection: TestSelection,
    selected_count: usize,
    config: supervisor.Config,
) noreturn {
    supervisor.initialize(config) catch |err| {
        writeRunnerFailure(init.minimal.environ, "focused test receipts", err);
        sys.process.exit(1);
    };
    var order_storage: [max_test_functions]u32 = undefined;
    const order = matchingTestOrder(
        selection,
        testPriorityFilters(init.minimal.args),
        &order_storage,
    );
    const outcome = supervisor.run(init, order, config) catch |err| {
        writeRunnerFailure(init.minimal.environ, "focused test supervisor", err);
        sys.process.exit(1);
    };
    switch (outcome) {
        .timeout => sys.process.exit(124),
        .cancelled => |signal| sys.process.exit(
            if (signal <= 127) @intCast(128 + signal) else 1,
        ),
        .terminated => |result| {
            const code: u8 = if (result.final_failed) |failed|
                if (failed == 0) 0 else 1
            else
                supervisedExitCode(result.term, false);
            if (code == 0 and result.final_failed != null) {
                shard_data.writeSuccess(selected_count, 1);
                sys.process.exit(0);
            }
            supervisor.writeChildFailure(
                config,
                selected_count,
                result.final_failed != null,
            );
            sys.process.exit(code);
        },
    }
}

fn supervisedExitCode(term: sys.process.Termination, complete: bool) u8 {
    if (!complete and term == .exited and term.exited == 0) return 1;
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| if (@backingInt(signal) <= 127)
            @intCast(128 + @backingInt(signal))
        else
            1,
        .stopped, .unknown => 1,
    };
}

fn matchingTestOrder(
    selection: TestSelection,
    priorities: TestFilters,
    storage: *[max_test_functions]u32,
) []const u32 {
    var scheduled: [max_test_functions]bool = @splat(false);
    var count: usize = 0;
    for (priorities.values[0..priorities.len]) |priority| {
        var selected_ordinal: u32 = 0;
        for (builtin.test_functions) |test_fn| {
            if (!selectedTest(selection, test_fn.name)) continue;
            if (!scheduled[selected_ordinal] and std.mem.indexOf(u8, test_fn.name, priority) != null) {
                storage[count] = selected_ordinal;
                scheduled[selected_ordinal] = true;
                count += 1;
            }
            selected_ordinal += 1;
        }
    }
    for (scheduled[0..matchingTestCount(selection)], 0..) |is_scheduled, selected_ordinal| {
        if (is_scheduled) continue;
        storage[count] = @intCast(selected_ordinal);
        count += 1;
    }
    return storage[0..count];
}

fn matchingTestCount(selection: TestSelection) usize {
    var count: usize = 0;
    for (builtin.test_functions) |test_fn| if (selectedTest(selection, test_fn.name)) {
        count += 1;
    };
    return count;
}

fn selectedTest(selection: TestSelection, name: []const u8) bool {
    return !shardWarmup(name) and selection.match(name);
}

fn shardWarmup(name: []const u8) bool {
    return std.mem.indexOf(u8, name, shard_warmup_tag) != null;
}

fn validateFocusedSelection(selection: TestSelection) !void {
    var selected: usize = 0;
    for (builtin.test_functions) |test_fn| {
        if (!selectedTest(selection, test_fn.name)) continue;
        if (selected == supervisor.selected_cap) {
            return error.FocusedTestSelectionLimitExceeded;
        }
        try progress.validateName(test_fn.name);
        selected += 1;
    }
    std.debug.assert(selected > 0);
}

fn elapsedMilliseconds(started: i64) u64 {
    const now = sys.time.milliTimestamp();
    if (now <= started) return 0;
    return @intCast(now - started);
}

fn writeHelp(environ: sys.process.Environ) void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = sys.stdio.stdout().writerStreaming(
        sys.stdio.debugIo(),
        &stdout_buffer,
    );
    writeHelpDoc(
        &stdout_writer.interface,
        timingRenderOptions(environ),
    ) catch {};
    stdout_writer.interface.flush() catch {};
}

fn writeHelpDoc(
    out: *std.Io.Writer,
    options: pretty.LayoutOptions,
) !void {
    var scratch: [8192]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const doc = try builder.concat(&.{
        try builder.styledText(.title, "Tiny timing test runner"),
        pretty.hardline,
        builder.text("Usage: test-binary [options]"),
        pretty.hardline,
        pretty.hardline,
        try builder.styledText(.attribute, "Options"),
        pretty.hardline,
        builder.text("  -h, --help                       Show this help and exit."),
        pretty.hardline,
        builder.text("  --test-timeout-ms N              Awake deadline including teardown (0 disables)."),
        pretty.hardline,
        builder.text("  --test-deadline-ms N=NAME        Test NAME's own deadline (at most 600000)."),
        pretty.hardline,
        builder.text("  --test-filter VALUE              Include matching test names."),
        pretty.hardline,
        builder.text("  --test-exclude VALUE             Exclude matching test names."),
        pretty.hardline,
        builder.text("  --test-priority VALUE            Schedule matching tests first."),
        pretty.hardline,
        builder.text("  --test-selection-receipt PATH    Write the selected-test count."),
        pretty.hardline,
        builder.text("  --test-supervised-receipts DIR   Supervise a focused ordered run."),
        pretty.hardline,
        builder.text("  --test-tree DIR                  The run's cached directory; a disk tree is DIR/root."),
        pretty.hardline,
        builder.text("  --test-tree-store disk|memory    Where the tree lives (disk); a pass removes it."),
        pretty.hardline,
        builder.text("  --test-cwd PATH                  Working directory below the tree root."),
        pretty.hardline,
        builder.text("  --test-input PATH=FILE           Copy FILE to PATH below the tree root."),
        pretty.hardline,
        builder.text("  --seed=VALUE                     Preserve the Zig test seed argument."),
        pretty.hardline,
        pretty.hardline,
        builder.text(
            "VALUE flags also accept --flag=VALUE. " ++
                "Other arguments fail before tests run.",
        ),
        pretty.hardline,
    });
    try pretty.write(out, doc, options);
}

fn writeArgumentFailure(
    environ: sys.process.Environ,
    failure: command.Failure,
) void {
    var message_storage: [512]u8 = undefined;
    const message: []const u8 = switch (failure) {
        .missing_executable => "missing test executable argument",
        .missing_value => |flag| std.fmt.bufPrint(
            &message_storage,
            "{s} requires a value",
            .{flag},
        ) catch "timing runner argument requires a value",
        .unsupported => |argument| std.fmt.bufPrint(
            &message_storage,
            "unsupported argument '{s}'; use --help for supported arguments",
            .{argument},
        ) catch "unsupported timing runner argument; use --help",
        .too_many_arguments => "too many timing runner arguments",
    };
    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = sys.stdio.stderr().writerStreaming(
        sys.stdio.debugIo(),
        &stderr_buffer,
    );
    writeFailLine(
        &stderr_writer.interface,
        timingRenderOptions(environ),
        "timing runner argument",
        message,
    ) catch {};
    stderr_writer.interface.flush() catch {};
}

fn writeNoTests(environ: sys.process.Environ, filtered: bool) void {
    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = sys.stdio.stderr().writerStreaming(sys.stdio.debugIo(), &stderr_buffer);
    writeNoTestsLine(
        &stderr_writer.interface,
        timingRenderOptions(environ),
        filtered,
    ) catch {};
    stderr_writer.interface.flush() catch {};
}

fn testName(test_index: usize) []const u8 {
    return builtin.test_functions[test_index].name;
}

const DeadlineOverrides = struct {
    entries: [deadline.max_overrides]deadline.Override = undefined,
    count: usize = 0,

    fn slice(self: *const DeadlineOverrides) []const deadline.Override {
        return self.entries[0..self.count];
    }
};

/// The argv's per-test deadlines as positions in this binary. A listed test this binary
/// lacks is refused, so an entry for a renamed or removed test fails the run instead of
/// lingering. An entry without a default deadline is refused too: it would bound one test
/// and leave the rest unbounded.
fn testDeadlines(iterator: anytype, timeout_ms: u64) !DeadlineOverrides {
    const listed = try command.deadlines(iterator);
    if (listed.count != 0 and timeout_ms == 0) return error.TestDeadlineWithoutDefault;
    return resolveDeadlines(listed.slice(), builtin.test_functions);
}

fn resolveDeadlines(listed: []const command.Deadline, test_fns: anytype) !DeadlineOverrides {
    comptime std.debug.assert(command.max_deadlines == deadline.max_overrides);
    var resolved: DeadlineOverrides = .{};
    for (listed) |entry| {
        const index = command.testIndex(test_fns, entry.name) orelse return error.UnknownDeadlineTest;
        resolved.entries[resolved.count] = .{ .test_index = index, .milliseconds = entry.milliseconds };
        resolved.count += 1;
    }
    return resolved;
}

fn runTests(
    init: sys.process.MinimalInit,
    supervised: ?supervisor.Config,
    balanced: ?Balanced,
    timeout_ms: u64,
    deadline_overrides: []const deadline.Override,
) void {
    @disableInstrumentation();
    var guard: deadline.Guard = .{ .names = testName };
    const active: ?*deadline.Guard = if (timeout_ms == 0) null else &guard;
    if (active) |value| value.start(timeout_ms, deadline_overrides) catch |err| {
        writeRunnerFailure(init.environ, "test deadline", err);
        sys.process.exit(2);
    };
    defer if (active) |value| value.stop();
    const started_unix_ns = sys.time.realNanoTimestamp();
    const started_ms = sys.time.milliTimestamp();

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = sys.stdio.stderr().writerStreaming(sys.stdio.debugIo(), &stderr_buffer);
    const err_out = &stderr_writer.interface;
    defer err_out.flush() catch {};

    const test_fns = builtin.test_functions;
    if (test_fns.len > max_test_functions) @panic("too many tests for timing runner");
    var row_storage: [max_test_functions]Row = undefined;
    const rows = row_storage[0..test_fns.len];

    var ok: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var total_ns: i128 = 0;
    const progress_enabled = progressEnabled(init.environ);
    const selection = testSelection(init.args, init.environ);
    const repeat = testRepeat(init.environ);
    const report = reportEnabled(init.environ);
    const render_options = timingRenderOptions(init.environ);
    var row_count: usize = 0;
    var selected_storage: [max_test_functions]usize = undefined;
    var selected_count: usize = 0;
    for (test_fns, 0..) |t, index| if (selectedTest(selection, t.name)) {
        selected_storage[selected_count] = index;
        selected_count += 1;
    };
    var parent_order_storage: [supervisor.selected_cap]u32 = undefined;
    var local_order_storage: [max_test_functions]u32 = undefined;
    const scheduled_order = if (balanced) |*value|
        balancedOrder(value, selected_storage[0..selected_count], &local_order_storage)
    else if (supervisor.childRequested(init.environ))
        supervisor.childOrder(
            init.environ,
            selected_count,
            &parent_order_storage,
        ) catch |err| {
            writeRunnerFailure(init.environ, "focused test order", err);
            sys.process.exit(1);
        }
    else if (!shard_data.childRequested(init.environ))
        matchingTestOrder(
            selection,
            testPriorityFilters(init.args),
            &local_order_storage,
        )
    else
        &.{};
    var worker = if (balanced != null)
        shard_data.Worker.single(scheduled_order.len)
    else
        shard_data.Worker.init(init.environ, selected_count) catch |err| {
            shard_data.writeCoordinatorError(err);
            sys.process.exit(1);
        };
    defer worker.deinit();
    var rows_file: RowsFile = .{};
    const rows_out = if (balanced) |*value| rows_file.start(init.environ, value, selected_count) else null;
    if (!runShardWarmups(init, err_out, render_options, rows_out, active)) {
        sys.process.exit(1);
    }

    for (0..selected_count + 1) |_| {
        const selected_ordinal = worker.next() catch |err| {
            shard_data.writeCoordinatorError(err);
            sys.process.exit(1);
        } orelse break;
        const scheduled_ordinal = if (scheduled_order.len == 0)
            selected_ordinal
        else
            scheduled_order[selected_ordinal];
        const i = selected_storage[scheduled_ordinal];
        const t = test_fns[i];
        if (supervised) |config| progress.appendInFlight(
            config.directory,
            @intCast(row_count * 2),
            @intCast(selected_count),
            @intCast(row_count),
            elapsedMilliseconds(started_ms),
            t.name,
        ) catch |err| {
            writeRunnerFailure(init.environ, "focused test progress", err);
            sys.process.exit(1);
        };
        if (progress_enabled) writeProgressLine(
            err_out,
            render_options,
            i + 1,
            test_fns.len,
            t.name,
        ) catch sys.process.exit(1);

        var row: Row = .{
            .name = t.name,
            .test_ns = 0,
            .teardown_ns = 0,
            .status = .ok,
            .leaked = false,
        };

        var report_error_name: []const u8 = "";
        var report_leak_message: []const u8 = "";
        for (0..repeat) |repeat_index| {
            const run = execution.run(sys.allocator.processAllocator(), init, runner_io, t, active, i, repeat_index);
            row.test_ns += run.test_ns;
            row.teardown_ns += run.teardown_ns;
            row.leaked = row.leaked or run.leaked;
            total_ns += run.test_ns + run.teardown_ns;
            if (run.status != .ok) {
                row.status = run.status;
                report_error_name = run.error_name;
                report_leak_message = run.leak_message;
                break;
            }
        }

        rows[row_count] = row;
        switch (row.status) {
            .ok => ok += 1,
            .skip => skipped += 1,
            .leak => {
                failed += 1;
                writeLeakLine(err_out, render_options, t.name, report_leak_message) catch sys.process.exit(1);
            },
            .fail, .fail_leak => {
                failed += 1;
                writeFailLine(err_out, render_options, t.name, report_error_name) catch sys.process.exit(1);
                if (row.status == .fail_leak)
                    writeLeakLine(err_out, render_options, t.name, report_leak_message) catch sys.process.exit(1);
            },
        }
        row_count += 1;
        if (supervised) |config| progress.appendCompleted(
            config.directory,
            @intCast(row_count * 2 - 1),
            @intCast(selected_count),
            @intCast(row_count),
            elapsedMilliseconds(started_ms),
            t.name,
            @tagName(row.status),
        ) catch |err| {
            writeRunnerFailure(init.environ, "focused test progress", err);
            sys.process.exit(1);
        };
    }

    if (active) |value| value.stop();
    const active_rows = rows[0..row_count];
    if (balanced) |*value| rows_file.finish(init.environ, value, active_rows);
    receipt.write(
        init.environ,
        started_unix_ns,
        sys.time.realNanoTimestamp(),
        .{
            .selected = selected_count,
            .ok = ok,
            .skipped = skipped,
            .failed = failed,
        },
        active_rows,
    ) catch |err| {
        writeFailLine(
            err_out,
            render_options,
            "timing runner receipt",
            @errorName(err),
        ) catch {};
        sys.process.exit(1);
    };
    std.mem.sort(Row, active_rows, {}, byTotalDesc);

    if (report) {
        writeReportHeader(err_out, render_options, active_rows.len) catch sys.process.exit(1);
        for (active_rows, 0..) |row, idx| {
            writeTimingRow(err_out, render_options, row, idx + 1) catch sys.process.exit(1);
        }
    }
    if (report) {
        writeSummaryLine(
            err_out,
            render_options,
            total_ns,
            ok,
            skipped,
            failed,
            row_count,
        ) catch sys.process.exit(1);
    } else if (selection.includes.len != 0 and
        !shard_data.childRequested(init.environ) and
        !supervisor.childRequested(init.environ))
    {
        writeSelectionLine(
            err_out,
            render_options,
            selected_count,
            row_count,
        ) catch sys.process.exit(1);
    }
    if (failed != 0) sys.process.exit(1);
}

/// A balanced shard's rows file: the header and warmups as the shard starts, then every
/// executed test once the shard finishes.
const RowsFile = struct {
    buffer: [64 * 1024]u8 = undefined,
    writer: std.Io.File.Writer = undefined,

    fn start(
        self: *RowsFile,
        environ: sys.process.Environ,
        balanced: *const Balanced,
        selected: usize,
    ) *std.Io.Writer {
        std.debug.assert(balanced.position.index < balanced.position.count);
        self.writer = balanced.rows.writer(sys.fs.debugIo(), &self.buffer);
        rows_data.writeHeader(&self.writer.interface, .{
            .index = balanced.position.index,
            .count = balanced.position.count,
            .selected = selected,
        }) catch |err| failRows(environ, err);
        return &self.writer.interface;
    }

    fn finish(
        self: *RowsFile,
        environ: sys.process.Environ,
        balanced: *const Balanced,
        executed: []const Row,
    ) void {
        std.debug.assert(executed.len <= max_test_functions);
        const out = &self.writer.interface;
        for (executed) |row| rows_data.writeRecord(out, .{
            .status = @tagName(row.status),
            .test_ns = @intCast(row.test_ns),
            .teardown_ns = @intCast(row.teardown_ns),
            .name = row.name,
        }) catch |err| failRows(environ, err);
        out.flush() catch |err| failRows(environ, err);
        balanced.rows.close(sys.fs.debugIo());
    }
};

fn failRows(environ: sys.process.Environ, err: anyerror) noreturn {
    writeRunnerFailure(environ, "test rows", err);
    sys.process.exit(1);
}

fn runShardWarmups(
    init: sys.process.MinimalInit,
    err_out: *std.Io.Writer,
    render_options: pretty.LayoutOptions,
    rows_out: ?*std.Io.Writer,
    guard: ?*deadline.Guard,
) bool {
    for (builtin.test_functions, 0..) |test_fn, index| {
        if (!shardWarmup(test_fn.name)) continue;
        const run = execution.run(sys.allocator.processAllocator(), init, runner_io, test_fn, guard, index, 0);
        switch (run.status) {
            .ok => if (rows_out) |out| rows_data.writeWarmup(out, .{
                .name = test_fn.name,
                .ns = @intCast(run.test_ns + run.teardown_ns),
            }) catch |err| failRows(init.environ, err),
            .skip => {
                writeFailLine(
                    err_out,
                    render_options,
                    test_fn.name,
                    "ShardWarmupSkipped",
                ) catch return false;
                return false;
            },
            .leak => {
                writeLeakLine(
                    err_out,
                    render_options,
                    test_fn.name,
                    run.leak_message,
                ) catch return false;
                return false;
            },
            .fail, .fail_leak => {
                writeFailLine(
                    err_out,
                    render_options,
                    test_fn.name,
                    run.error_name,
                ) catch return false;
                if (run.status == .fail_leak) writeLeakLine(
                    err_out,
                    render_options,
                    test_fn.name,
                    run.leak_message,
                ) catch return false;
                return false;
            },
        }
    }
    return true;
}

fn timingRenderOptions(environ: sys.process.Environ) pretty.LayoutOptions {
    return .{
        .width = report_width,
        .color = if (colorEnabled(environ)) .ansi else .none,
    };
}

fn colorEnabled(environ: sys.process.Environ) bool {
    if (sys.process.Environ.getPosix(environ, "NO_COLOR") != null) return false;
    const value = sys.process.Environ.getPosix(environ, "TINY_TIMING_RUNNER_COLOR") orelse return true;
    return value.len == 0 or !(std.mem.eql(u8, value, "0") or
        std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "never") or
        std.mem.eql(u8, value, "none"));
}

fn progressEnabled(environ: sys.process.Environ) bool {
    const value = sys.process.Environ.getPosix(environ, "TINY_TIMING_RUNNER_PROGRESS") orelse return false;
    return value.len == 0 or !std.mem.eql(u8, value, "0");
}

fn reportEnabled(environ: sys.process.Environ) bool {
    const value = sys.process.Environ.getPosix(environ, "TINY_TIMING_RUNNER_REPORT") orelse return true;
    return value.len == 0 or !(std.mem.eql(u8, value, "0") or
        std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "never") or
        std.mem.eql(u8, value, "none"));
}

fn emptyFilterAllowed(environ: sys.process.Environ) bool {
    const value = sys.process.Environ.getPosix(environ, "TINY_TIMING_RUNNER_ALLOW_EMPTY_FILTER") orelse return false;
    return value.len == 0 or !std.mem.eql(u8, value, "0");
}

fn testRepeat(environ: sys.process.Environ) usize {
    const value = sys.process.Environ.getPosix(environ, "TINY_TIMING_RUNNER_REPEAT") orelse return 1;
    return testRepeatFromText(value);
}

fn testRepeatFromText(value: []const u8) usize {
    const repeat = std.fmt.parseUnsigned(usize, value, 10) catch @panic("invalid test repeat count");
    if (repeat == 0) @panic("invalid test repeat count");
    return repeat;
}

const TestFilters = selection_data.Filters(max_test_filters);
const TestSelection = selection_data.Selection(TestFilters);

fn testSelection(args: anytype, environ: sys.process.Environ) TestSelection {
    return .{
        .includes = testFilters(args, environ),
        .excludes = testExcludeFilters(args),
    };
}

fn testFilters(args: anytype, environ: sys.process.Environ) TestFilters {
    var filters: TestFilters = .{};
    if (sys.process.Environ.getPosix(environ, "TINY_TIMING_RUNNER_FILTER")) |value| {
        filters.add(value);
    }
    var iterator = sys.process.Args.Iterator.init(args);
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, command.filter_flag)) {
            filters.add(iterator.next() orelse unreachable);
        } else if (std.mem.startsWith(u8, arg, command.filter_flag ++ "=")) {
            filters.add(arg[command.filter_flag.len + 1 ..]);
        }
    }
    return filters;
}

fn testExcludeFilters(args: anytype) TestFilters {
    var filters: TestFilters = .{};
    var iterator = sys.process.Args.Iterator.init(args);
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, command.exclude_flag)) {
            filters.add(iterator.next() orelse unreachable);
        } else if (std.mem.startsWith(u8, arg, command.exclude_flag ++ "=")) {
            filters.add(arg[command.exclude_flag.len + 1 ..]);
        }
    }
    return filters;
}

fn testPriorityFilters(args: anytype) TestFilters {
    var filters: TestFilters = .{};
    var iterator = sys.process.Args.Iterator.init(args);
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, command.priority_flag)) {
            filters.add(iterator.next() orelse unreachable);
        } else if (std.mem.startsWith(u8, arg, command.priority_flag ++ "=")) {
            filters.add(arg[command.priority_flag.len + 1 ..]);
        }
    }
    return filters;
}

fn selectionReceiptPath(args: anytype) !?[]const u8 {
    var selected: ?[]const u8 = null;
    var iterator = sys.process.Args.Iterator.init(args);
    while (iterator.next()) |arg| {
        const value = if (std.mem.eql(u8, arg, command.selection_receipt_flag))
            iterator.next() orelse return error.MissingSelectionReceiptPath
        else if (std.mem.startsWith(u8, arg, command.selection_receipt_flag ++ "="))
            arg[command.selection_receipt_flag.len + 1 ..]
        else
            continue;
        if (selected != null) return error.DuplicateSelectionReceiptPath;
        if (value.len == 0 or value.len >= std.fs.max_path_bytes) {
            return error.InvalidSelectionReceiptPath;
        }
        selected = value;
    }
    return selected;
}

fn writeSelectionReceipt(path: []const u8, selected_count: usize) !void {
    var storage: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&storage, "{d}\n", .{selected_count});
    try sys.fs.writeFile(path, text);
}

const Row = receipt.Row;
const Status = receipt.Status;

fn byTotalDesc(_: void, a: Row, b: Row) bool {
    return (a.test_ns + a.teardown_ns) > (b.test_ns + b.teardown_ns);
}

fn writeProgressLine(
    out: *std.Io.Writer,
    options: pretty.LayoutOptions,
    index: usize,
    total: usize,
    name: []const u8,
) !void {
    var scratch: [4096]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const doc = try builder.concat(&.{
        try tagDoc(builder, "run", .attribute),
        builder.text(" "),
        try builder.styledFmt(.number, "{d}", .{index}),
        try builder.punct("/"),
        try builder.styledFmt(.number, "{d}", .{total}),
        builder.text(" "),
        try builder.styledText(.name, name),
        pretty.hardline,
    });
    try pretty.write(out, doc, options);
    try out.flush();
}

fn writeFailLine(
    out: *std.Io.Writer,
    options: pretty.LayoutOptions,
    name: []const u8,
    error_name: []const u8,
) !void {
    var scratch: [4096]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const doc = try builder.concat(&.{
        try tagDoc(builder, "FAIL", .danger),
        builder.text(" "),
        try builder.styledText(.name, name),
        try builder.punct(":"),
        builder.text(" "),
        try builder.styledText(.danger, error_name),
        pretty.hardline,
    });
    try pretty.write(out, doc, options);
    try out.flush();
}

fn writeNoTestsLine(
    out: *std.Io.Writer,
    options: pretty.LayoutOptions,
    filtered: bool,
) !void {
    var scratch: [4096]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const doc = try builder.concat(&.{
        try tagDoc(builder, "FAIL", .danger),
        builder.text(" "),
        try builder.styledText(.danger, if (filtered)
            "no tests matched the requested filters"
        else
            "this test root collected no tests, so the gate cannot fail"),
        pretty.hardline,
    });
    try pretty.write(out, doc, options);
    try out.flush();
}

fn writeRunnerFailure(
    environ: sys.process.Environ,
    name: []const u8,
    err: anyerror,
) void {
    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = sys.stdio.stderr().writerStreaming(
        sys.stdio.debugIo(),
        &stderr_buffer,
    );
    writeFailLine(
        &stderr_writer.interface,
        timingRenderOptions(environ),
        name,
        @errorName(err),
    ) catch {};
    stderr_writer.interface.flush() catch {};
}

fn writeSelectionLine(
    out: *std.Io.Writer,
    options: pretty.LayoutOptions,
    selected: usize,
    executed: usize,
) !void {
    var scratch: [4096]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const doc = try builder.concat(&.{
        try tagDoc(
            builder,
            if (selected == 0) "SKIP" else "PASS",
            if (selected == 0) .muted else .value,
        ),
        builder.text(" "),
        try builder.styledFmt(.number, "{d}", .{selected}),
        builder.text(" selected"),
        try builder.punct(","),
        builder.text(" "),
        try builder.styledFmt(.number, "{d}", .{executed}),
        builder.text(" executed"),
        pretty.hardline,
    });
    try pretty.write(out, doc, options);
    try out.flush();
}

fn writeLeakLine(
    out: *std.Io.Writer,
    options: pretty.LayoutOptions,
    name: []const u8,
    message: []const u8,
) !void {
    var scratch: [4096]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const doc = try builder.concat(&.{
        try tagDoc(builder, "LEAK", .danger),
        builder.text(" "),
        try builder.styledText(.name, name),
        try builder.punct(":"),
        builder.text(" "),
        try builder.styledText(.danger, message),
        pretty.hardline,
    });
    try pretty.write(out, doc, options);
    try out.flush();
}

fn writeReportHeader(
    out: *std.Io.Writer,
    options: pretty.LayoutOptions,
    count: usize,
) !void {
    var scratch: [4096]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const doc = try builder.concat(&.{
        pretty.hardline,
        try builder.styledText(.title, "per-test timing"),
        try builder.punct(":"),
        builder.text(" "),
        try builder.styledFmt(.number, "{d}", .{count}),
        builder.text(" tests sorted by total duration"),
        pretty.hardline,
    });
    try pretty.write(out, doc, options);
}

fn writeTimingRow(
    out: *std.Io.Writer,
    options: pretty.LayoutOptions,
    row: Row,
    rank: usize,
) !void {
    var scratch: [8192]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const fields = [_]pretty.Doc{
        try durationFieldDoc(builder, "test", row.test_ns),
        try durationFieldDoc(builder, "teardown", row.teardown_ns),
        try durationFieldDoc(builder, "total", row.test_ns + row.teardown_ns),
        try statusFieldDoc(builder, row.status),
        try boolFieldDoc(builder, "leak", row.leaked),
    };
    const doc = try builder.group(try builder.concat(&.{
        builder.text("  "),
        try builder.styledFmt(.number, "{d}", .{rank}),
        try builder.punct("."),
        builder.text(" "),
        try builder.styledText(.name, row.name),
        try builder.punct(":"),
        try builder.nest(4, try builder.concat(&.{
            pretty.softline,
            try builder.join(fields[0..], try fieldSeparatorDoc(builder)),
        })),
        pretty.hardline,
    }));
    try pretty.write(out, doc, options);
}

fn writeSummaryLine(
    out: *std.Io.Writer,
    options: pretty.LayoutOptions,
    total_ns: i128,
    ok: usize,
    skipped: usize,
    failed: usize,
    count: usize,
) !void {
    var scratch: [4096]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const fields = [_]pretty.Doc{
        try durationMsFieldDoc(builder, "total", total_ns),
        try countFieldDoc(builder, "ok", ok, .value),
        try countFieldDoc(builder, "skip", skipped, .muted),
        try countFieldDoc(builder, "fail", failed, if (failed == 0) .number else .danger),
        try countFieldDoc(builder, "count", count, .number),
    };
    const doc = try builder.concat(&.{
        pretty.hardline,
        try builder.styledText(.title, "test timing"),
        try builder.punct(":"),
        builder.text(" "),
        try builder.group(try builder.join(fields[0..], try fieldSeparatorDoc(builder))),
        pretty.hardline,
    });
    try pretty.write(out, doc, options);
    try out.flush();
}

fn durationFieldDoc(builder: pretty.Builder, label: []const u8, ns: i128) !pretty.Doc {
    return try builder.concat(&.{
        try builder.styledText(.attribute, label),
        try builder.punct("="),
        try builder.styledFmt(.number, "{d}", .{@divFloor(ns, std.time.ns_per_us)}),
        builder.text(" us"),
    });
}

fn durationMsFieldDoc(builder: pretty.Builder, label: []const u8, ns: i128) !pretty.Doc {
    return try builder.concat(&.{
        try builder.styledText(.attribute, label),
        try builder.punct("="),
        try builder.styledFmt(.number, "{d}", .{@divFloor(ns, std.time.ns_per_ms)}),
        builder.text(" ms"),
    });
}

fn countFieldDoc(
    builder: pretty.Builder,
    label: []const u8,
    count: usize,
    style: pretty.Style,
) !pretty.Doc {
    return try builder.concat(&.{
        try builder.styledText(.attribute, label),
        try builder.punct("="),
        try builder.styledFmt(style, "{d}", .{count}),
    });
}

fn statusFieldDoc(builder: pretty.Builder, status: Status) !pretty.Doc {
    return try builder.concat(&.{
        try builder.styledText(.attribute, "status"),
        try builder.punct("="),
        try builder.styledText(statusStyle(status), statusName(status)),
    });
}

fn boolFieldDoc(builder: pretty.Builder, label: []const u8, value: bool) !pretty.Doc {
    return try builder.concat(&.{
        try builder.styledText(.attribute, label),
        try builder.punct("="),
        try builder.styledText(if (value) .danger else .number, if (value) "yes" else "no"),
    });
}

fn fieldSeparatorDoc(builder: pretty.Builder) !pretty.Doc {
    return try builder.concat(&.{
        try builder.punct(";"),
        pretty.softline,
    });
}

fn tagDoc(builder: pretty.Builder, text: []const u8, style: pretty.Style) !pretty.Doc {
    return try builder.concat(&.{
        try builder.punct("["),
        try builder.styledText(style, text),
        try builder.punct("]"),
    });
}

fn statusName(status: Status) []const u8 {
    return switch (status) {
        .ok => "ok",
        .skip => "skip",
        .fail => "fail",
        .leak => "leak",
        .fail_leak => "fail+leak",
    };
}

fn statusStyle(status: Status) pretty.Style {
    return switch (status) {
        .ok => .value,
        .skip => .muted,
        .fail, .leak, .fail_leak => .danger,
    };
}
