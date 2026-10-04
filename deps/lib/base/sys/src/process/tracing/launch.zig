const std = @import("std");
const linux = std.os.linux;
const sys = @import("../../root.zig");

pub const Child = struct {
    pid: i32,
    gate: i32,

    pub fn release(self: Child) !void {
        if (linux.write(self.gate, "x", 1) != 1) return error.ChildReleaseFailed;
    }

    pub fn close(self: Child) void {
        _ = linux.close(self.gate);
    }
};

/// Forks a child that blocks reading the gate, so a tracer can attach before
/// the child execs, and returns the child's process id together with the
/// writing end of the gate. `Child.release` writes the byte that lets the child
/// exec, and `Child.close` drops the gate. The caller forks through this before
/// it starts any application thread, because the child runs syscalls alone
/// between the fork and the exec. The executable is searched along the
/// environment's `PATH`, falling back to `/bin:/usr/bin`, over at most 256
/// candidates, while an empty argument vector, and one longer than 4096, fail
/// with `InvalidArguments`.
pub fn start(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    environment: *const std.process.Environ.Map,
) !Child {
    if (argv.len == 0 or argv.len > 4096) return error.InvalidArguments;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const arguments = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| arguments[i] = (try arena.dupeSentinel(u8, arg, 0)).ptr;
    const env = try environment.createPosixBlock(arena, .{ .zig_progress_fd = -1 });
    const paths = try candidates(arena, argv[0], environment.get("PATH") orelse "/bin:/usr/bin");
    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS)
        return error.PipeFailed;
    errdefer {
        _ = linux.close(pipe[0]);
        _ = linux.close(pipe[1]);
    }
    const forked = try sys.process.fork();
    if (forked == .child) {
        _ = linux.close(pipe[1]);
        child(pipe[0], paths, arguments, env.slice);
    }
    _ = linux.close(pipe[0]);
    return .{ .pid = forked.parent, .gate = pipe[1] };
}

fn candidates(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
) ![]const [:0]const u8 {
    if (name.len == 0) return error.EmptyCommand;
    var result: std.ArrayList([:0]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        try result.append(allocator, try allocator.dupeSentinel(u8, name, 0));
    } else {
        var parts = std.mem.splitScalar(u8, path, ':');
        while (parts.next()) |part| {
            if (result.items.len == 256) return error.PathLimitExceeded;
            const directory = if (part.len == 0) "." else part;
            try result.append(allocator, try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{
                directory, name,
            }, 0));
        }
    }
    return result.toOwnedSlice(allocator);
}

fn child(
    gate: i32,
    paths: []const [:0]const u8,
    argv: [:null]const ?[*:0]const u8,
    env: [:null]const ?[*:0]const u8,
) noreturn {
    var byte: [1]u8 = undefined;
    const n = linux.read(gate, &byte, 1);
    _ = linux.close(gate);
    if (n != 1) linux.exit(125);
    var code: u8 = 127;
    for (paths) |path| {
        const failure = linux.errno(linux.execve(path, argv, env));
        if (failure == .ACCES) {
            code = 126;
            continue;
        }
        if (failure != .NOENT and failure != .NOTDIR) {
            code = 126;
            break;
        }
    }
    const message = "tempo: command could not be executed\n";
    _ = linux.write(2, message.ptr, message.len);
    linux.exit(code);
}

test "executable lookup preserves absolute paths and empty PATH entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = try candidates(arena.allocator(), "echo", ":/bin");
    try std.testing.expectEqualStrings("./echo", paths[0]);
    try std.testing.expectEqualStrings("/bin/echo", paths[1]);
    const absolute = try candidates(arena.allocator(), "/bin/echo", "/wrong");
    try std.testing.expectEqual(@as(usize, 1), absolute.len);
    try std.testing.expectEqualStrings("/bin/echo", absolute[0]);
}
