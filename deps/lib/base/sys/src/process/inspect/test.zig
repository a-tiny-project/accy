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

test "private memory counts anonymous pages and leaves out mapped file pages" {
    const length: usize = 16 << 20;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file = try temporary.dir.createFile(std.Options.debug_io, "mapped.bin", .{ .read = true });
    defer file.close(std.Options.debug_io);
    try file.setLength(std.Options.debug_io, length);
    const pid = try sys.process.currentProcessId();
    const before = (try inspect.info(pid)).private_bytes orelse return error.SkipZigTest;
    const mapped = sys.memory.mapSharedFile(file.handle, length, .{ .read = true }, 0) catch |err|
        switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
    defer sys.memory.unmap(mapped);
    var checksum: u8 = 0;
    var offset: usize = 0;
    while (offset < length) : (offset += sys.memory.pageSize()) checksum +%= mapped[offset];
    std.mem.doNotOptimizeAway(checksum);
    const after_file = (try inspect.info(pid)).private_bytes.?;
    try std.testing.expect(after_file -| before < length / 4);
    const anonymous = try sys.memory.mapAnonymous(length, .{ .read = true, .write = true });
    defer sys.memory.unmap(anonymous);
    @memset(anonymous, 0x5a);
    std.mem.doNotOptimizeAway(anonymous.ptr);
    const after_anonymous = (try inspect.info(pid)).private_bytes.?;
    try std.testing.expect(after_anonymous -| after_file >= length / 2);
}
