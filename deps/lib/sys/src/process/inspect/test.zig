const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../../root.zig");

const inspect = sys.process.inspect;

test "group census counts a running leader" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var storage: [16 * 1024]inspect.ProcessId = undefined;
    const own = try inspect.group(std.os.linux.getpid());
    try std.testing.expect(try inspect.groupRunning(own, &storage));
}

test "group census treats an unreaped exited group as drained" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const leader = switch (try sys.process.fork()) {
        .child => {
            sys.process.createOwnProcessGroup() catch sys.process.exit(2);
            sys.process.exit(0);
        },
        .parent => |pid| pid,
    };
    var reaped = false;
    defer if (!reaped) {
        _ = sys.process.waitDirect(leader) catch {};
    };
    for (0..5_000) |_| {
        if (try sys.process.peekNoHang(leader) != null) break;
        sys.time.sleepMilliseconds(1);
    } else return error.TestLeaderDidNotExit;
    try std.testing.expectEqual(leader, try inspect.group(leader));
    try std.testing.expect(try sys.process.processGroupAlive(leader));
    var storage: [16 * 1024]inspect.ProcessId = undefined;
    try std.testing.expect(!try inspect.groupRunning(leader, &storage));
    const termination = try sys.process.waitDirect(leader);
    reaped = true;
    try std.testing.expectEqual(@as(i64, 0), sys.process.exitCode(termination));
    try std.testing.expect(!try inspect.groupRunning(leader, &storage));
    try std.testing.expectError(error.BufferTooSmall, inspect.groupRunning(
        try inspect.group(std.os.linux.getpid()),
        storage[0..1],
    ));
}

test "exit descriptor signals an unreaped exit and nothing before it" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const gate = try sys.fd.pipe(.{ .CLOEXEC = true });
    var gate_open = true;
    defer if (gate_open) sys.fd.close(gate[1]);
    const child = switch (try sys.process.fork()) {
        .child => {
            sys.fd.close(gate[1]);
            var byte: [1]u8 = undefined;
            _ = sys.fd.read(gate[0], &byte) catch sys.process.exit(2);
            sys.process.exit(0);
        },
        .parent => |pid| pid,
    };
    sys.fd.close(gate[0]);
    var reaped = false;
    defer if (!reaped) {
        if (gate_open) sys.fd.close(gate[1]);
        gate_open = false;
        _ = sys.process.waitDirect(child) catch {};
    };
    const exit = try inspect.exitDescriptor(child);
    defer sys.fd.close(exit);
    var descriptors = [_]sys.poll.Descriptor{.{
        .fd = exit,
        .events = sys.poll.Event.input,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try sys.poll.wait(&descriptors, 0));
    sys.fd.close(gate[1]);
    gate_open = false;
    try std.testing.expectEqual(@as(usize, 1), try sys.poll.wait(&descriptors, 5_000));
    try std.testing.expect((descriptors[0].revents & sys.poll.Event.input) != 0);
    try std.testing.expect(!(try inspect.info(child)).alive);
    _ = try sys.process.waitDirect(child);
    reaped = true;
    try std.testing.expectError(error.ProcessNotFound, inspect.exitDescriptor(child));
}
