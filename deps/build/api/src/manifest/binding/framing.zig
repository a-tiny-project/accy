const std = @import("std");
const model = @import("root.zig").model;
const transport = @import("transport.zig");

/// Fixture-only compile mode. The parent captures one pipe; these three
/// independent processes inherit its write end, including an unrelated writer.
pub fn run(init: std.process.Init, output: std.Io.File) !void {
    const allocator = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    const executable = args.next() orelse return error.MissingFixtureExecutable;
    const mode = args.next() orelse return error.MissingFixtureMode;
    if (std.mem.eql(u8, mode, "framed")) {
        const path = args.next() orelse return error.MissingFixtureInput;
        if (args.next() != null) return error.UnexpectedFixtureArgument;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(model.locatorBytesMax() + 1));
        try transport.write(init.io, output, bytes);
    } else if (std.mem.eql(u8, mode, "noise")) {
        if (args.next() != null) return error.UnexpectedFixtureArgument;
        var noise: [32 * 1024]u8 = @splat('n');
        noise[noise.len - 1] = '\n';
        try output.writeStreamingAll(init.io, &noise);
    } else if (std.mem.eql(u8, mode, "blocked")) {
        const path = args.next() orelse return error.MissingFixtureInput;
        if (args.next() != null) return error.UnexpectedFixtureArgument;
        const gate = try std.Io.Dir.cwd().openFile(init.io, path, .{});
        defer gate.close(init.io);
        try gate.lock(init.io, .exclusive);
        gate.unlock(init.io);
    } else if (std.mem.eql(u8, mode, "coordinator") or std.mem.eql(u8, mode, "timeout")) {
        const first = args.next() orelse return error.MissingFixtureInput;
        const second = args.next() orelse return error.MissingFixtureInput;
        const receipt = args.next() orelse return error.MissingFixtureReceipt;
        if (args.next() != null) return error.UnexpectedFixtureArgument;
        try supervise(init, output, executable, first, second, receipt, std.mem.eql(u8, mode, "timeout"));
    } else return error.InvalidFixtureMode;
}

pub const Drain = struct { started: usize, reaped: usize, timed_out: bool };

/// This process owns both the absolute deadline and all three Child handles.
/// Waiting for each private stderr EOF is cancellable without losing the PID;
/// Child.wait is used only after EOF. Every failure/timeout kills and waits the
/// still-owned children before returning, with25 seconds before the outer guard.
fn supervise(init: std.process.Init, output: std.Io.File, executable: []const u8, first: []const u8, second: []const u8, receipt: []const u8, timeout_case: bool) !void {
    const io = init.io;
    const gate = try std.Io.Dir.cwd().openFile(io, first, .{});
    defer gate.close(io);
    if (timeout_case) try gate.lock(io, .exclusive);
    defer if (timeout_case) gate.unlock(io);
    const deadline = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(if (timeout_case) 0 else 5), .clock = .awake } }).toDeadline(io);
    var children: [3]std.process.Child = undefined;
    var started: usize = 0;
    defer drain(io, children[0..started]);
    const commands = if (timeout_case) [_][]const []const u8{
        &.{ executable, "blocked", first }, &.{ executable, "blocked", first }, &.{ executable, "blocked", first },
    } else [_][]const []const u8{
        &.{ executable, "framed", first }, &.{ executable, "framed", second }, &.{ executable, "noise" },
    };
    var streams: [3]std.Io.File = undefined;
    for (commands) |argv| {
        children[started] = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .{ .file = output }, .stderr = .pipe });
        streams[started] = children[started].stderr.?;
        started += 1;
    }
    var buffer: std.Io.File.MultiReader.Buffer(3) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(init.arena.allocator(), io, buffer.toStreams(), &streams);
    var timed_out = false;
    var pending_error: ?anyerror = null;
    while (reader.fill(256, deadline)) |_| {
        for (0..3) |index| if (reader.reader(index).buffered().len > 4096) {
            pending_error = error.FramingFixtureStderrTooLarge;
            break;
        };
        if (pending_error != null) break;
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => timed_out = true,
        else => pending_error = err,
    }
    reader.checkAnyError() catch |err| {
        if (pending_error == null and !timed_out) pending_error = err;
    };
    if (!timed_out and pending_error == null) {
        for (0..3) |index| if (reader.reader(index).buffered().len != 0) {
            pending_error = error.FramingFixtureStderr;
        };
    }
    reader.deinit();
    if (timed_out or pending_error != null) {
        drain(io, children[0..started]);
    } else {
        for (children[0..started]) |*child| {
            if (!(try child.wait(io)).success()) return error.FramingFixtureChildFailed;
        }
    }
    var reaped: usize = 0;
    for (children[0..started]) |child| if (child.id == null) {
        reaped += 1;
    };
    std.debug.assert(reaped == started);
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try std.json.Stringify.value(Drain{ .started = started, .reaped = reaped, .timed_out = timed_out }, .{}, &writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = receipt, .data = writer.buffered() });
    if (pending_error) |err| return err;
    if (timed_out != timeout_case) return error.FramingFixtureDeadline;
}

fn drain(io: std.Io, children: []std.process.Child) void {
    for (children) |*child| child.kill(io);
}
