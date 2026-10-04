const std = @import("std");
const sys = @import("timing_runner_sys");
const pretty = @import("timing_runner_pretty");

var shard_warmup_ready = false;

test "renamed structural fixture [tiny-test-shard-warmup]" {
    if (std.testing.environ.getPosix("TINY_TIMING_DEADLINE_FIXTURE")) |mode| {
        if (std.mem.eql(u8, mode, "warmup")) while (true) std.atomic.spinLoopHint();
    }
    try std.testing.expect(!shard_warmup_ready);
    shard_warmup_ready = true;
}

test "timing runner shard warmup dependent alpha" {
    try std.testing.expect(shard_warmup_ready);
}

test "timing runner shard warmup dependent beta" {
    try std.testing.expect(shard_warmup_ready);
}

test "timing runner command exits before test execution" {
    return error.UnexpectedTestExecution;
}

test "timing runner executes only the selected test" {}

test "timing runner tree reads a declared input through its working directory" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "../declared/tree.zig",
        std.testing.allocator,
        .limited(1 << 20),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "const std = @import(\"std\");"));
}

test "timing runner tree hides an undeclared repository file" {
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().openFile(std.testing.io, "build.zig", .{}),
    );
}

test "timing runner tree gives testing tmpDir a writable scratch" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.writeFile(std.testing.io, .{ .sub_path = "scratch", .data = "written" });
    const bytes = try scratch.dir.readFileAlloc(
        std.testing.io,
        "scratch",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("written", bytes);
}

test "timing runner tree sees only its declared environment" {
    try std.testing.expectEqualStrings(
        "/usr/bin:/bin",
        std.process.Environ.getPosix(std.testing.environ, "PATH") orelse "",
    );
    try std.testing.expect(std.process.Environ.getPosix(std.testing.environ, "HOME") == null);
}

test "timing runner supervised order natural alpha" {}

test "timing runner supervised order priority beta" {}

test "timing runner supervised order natural gamma" {
    try spawnDescendant("success-descendant.pid");
}

test "timing runner supervised timeout owns descendant group" {
    try spawnDescendant("descendant.pid");
    sys.time.sleepSeconds(3);
    return error.SupervisorDeadlineMissed;
}

test "timing runner supervised completed failure keeps final receipt" {
    return error.ExpectedTimingFixtureFailure;
}

test "timing runner supervised incomplete child exit" {
    sys.process.exit(7);
}

test "timing runner supervised cancellation closes descendant group" {
    try spawnDescendant("cancel-descendant.pid");
    const parent = try sys.process.parentProcessId();
    try sys.process.signalChildId(parent, .terminate);
    sys.time.sleepSeconds(3);
    return error.SupervisorCancellationMissed;
}

fn spawnDescendant(file_name: []const u8) !void {
    const directory = std.process.Environ.getPosix(
        std.testing.environ,
        "TINY_TIMING_RUNNER_RECEIPT_DIR",
    ) orelse return error.MissingReceiptDirectory;
    const child = try sys.process.spawn(std.testing.io, .{
        .argv = &.{ "sh", "-c", "trap '' TERM; sleep 3" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const child_id = child.id orelse return error.MissingDescendantId;
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_storage,
        "{s}/{s}",
        .{ directory, file_name },
    );
    var pid_storage: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(&pid_storage, "{d}\n", .{child_id});
    try sys.fs.writeFile(path, pid);
}

test "timing runner selected cap admitted 00" {}
test "timing runner selected cap admitted 01" {}
test "timing runner selected cap admitted 02" {}
test "timing runner selected cap admitted 03" {}
test "timing runner selected cap admitted 04" {}
test "timing runner selected cap admitted 05" {}
test "timing runner selected cap admitted 06" {}
test "timing runner selected cap admitted 07" {}
test "timing runner selected cap admitted 08" {}
test "timing runner selected cap admitted 09" {}
test "timing runner selected cap admitted 10" {}
test "timing runner selected cap admitted 11" {}
test "timing runner selected cap admitted 12" {}
test "timing runner selected cap admitted 13" {}
test "timing runner selected cap admitted 14" {}
test "timing runner selected cap admitted 15" {}
test "timing runner selected cap admitted 16" {}
test "timing runner selected cap admitted 17" {}
test "timing runner selected cap admitted 18" {}
test "timing runner selected cap admitted 19" {}
test "timing runner selected cap admitted 20" {}
test "timing runner selected cap admitted 21" {}
test "timing runner selected cap admitted 22" {}
test "timing runner selected cap admitted 23" {}
test "timing runner selected cap admitted 24" {}
test "timing runner selected cap admitted 25" {}
test "timing runner selected cap admitted 26" {}
test "timing runner selected cap admitted 27" {}
test "timing runner selected cap admitted 28" {}
test "timing runner selected cap admitted 29" {}
test "timing runner selected cap admitted 30" {}
test "timing runner selected cap admitted 31" {}
test "timing runner selected cap sentinel 32" {
    return error.UnexpectedTestExecution;
}

var deadline_shared: usize = 0;
var deadline_thread: sys.thread.Id = undefined;
var deadline_teardown_started: std.atomic.Value(bool) = .init(false);
var deadline_teardown_future: ?std.Io.Future(void) = null;

test "timing runner deadline shared alpha" {
    try std.testing.expectEqual(@as(usize, 0), deadline_shared);
    deadline_thread = sys.thread.currentId();
    deadline_shared = 17;
}

test "timing runner deadline shared beta" {
    try std.testing.expectEqual(@as(usize, 17), deadline_shared);
    try std.testing.expectEqual(deadline_thread, sys.thread.currentId());
}

test "timing runner deadline cpu" {
    while (true) std.atomic.spinLoopHint();
}

test "timing runner deadline block" {
    sys.time.sleepSeconds(60);
    return error.TestDeadlineMissed;
}

test "timing runner deadline teardown" {
    deadline_teardown_future = try std.Io.concurrent(std.testing.io, stallTeardown, .{});
    while (!deadline_teardown_started.load(.acquire)) sys.thread.yield();
    try pretty.diagnostic.writeStderrDoc(.{ .text = "deadline body returned\n" }, .{});
}

fn stallTeardown() void {
    deadline_teardown_started.store(true, .release);
    while (true) std.atomic.spinLoopHint();
}

test "timing runner deadline sentinel" {
    try pretty.diagnostic.writeStderrDoc(.{ .text = "DEADLINE SENTINEL RAN\n" }, .{});
    return error.TestDeadlineMissed;
}

var deadline_repetitions: usize = 0;

test "timing runner deadline repeat" {
    deadline_repetitions += 1;
    if (deadline_repetitions == 2) while (true) std.atomic.spinLoopHint();
}
