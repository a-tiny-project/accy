const std = @import("std");
const pretty = @import("pretty");

const fs_io = std.Options.debug_io;
const path_count_max: usize = 64;
const stderr_bytes_max: usize = 64 * 1024;
const writer_buffer_bytes: usize = 4096;

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        pretty.diagnostic.writeStderrText(
            "repository status: {s}\n",
            .{@errorName(err)},
        );
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4 or args.len - 3 > path_count_max) {
        return error.InvalidArguments;
    }
    const clean = repositoryClean(init, args[3..]);
    try writeModule(args[1], clean);
    try writeValue(args[2], clean);
    return 0;
}

fn repositoryClean(init: std.process.Init, paths: []const []const u8) bool {
    const prefix = [_][]const u8{
        "git",
        "status",
        "--porcelain",
        "--untracked-files=all",
        "--",
    };
    var argv: [prefix.len + path_count_max][]const u8 = undefined;
    @memcpy(argv[0..prefix.len], &prefix);
    @memcpy(argv[prefix.len..][0..paths.len], paths);
    const result = std.process.run(init.arena.allocator(), init.io, .{
        .argv = argv[0 .. prefix.len + paths.len],
        .stdout_limit = .limited(1),
        .stderr_limit = .limited(stderr_bytes_max),
    }) catch return false;
    const exited_zero = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return exited_zero and
        std.mem.trim(u8, result.stdout, " \t\r\n").len == 0;
}

fn writeModule(path: []const u8, clean: bool) !void {
    std.debug.assert(path.len > 0);
    const file = try std.Io.Dir.cwd().createFile(fs_io, path, .{ .truncate = true });
    defer file.close(fs_io);
    var buffer: [writer_buffer_bytes]u8 = undefined;
    var file_writer = file.writer(fs_io, &buffer);
    const writer = &file_writer.interface;
    try writer.print("pub const value: bool = {};\n", .{clean});
    try writer.flush();
}

fn writeValue(path: []const u8, clean: bool) !void {
    std.debug.assert(path.len > 0);
    const file = try std.Io.Dir.cwd().createFile(fs_io, path, .{ .truncate = true });
    defer file.close(fs_io);
    var buffer: [writer_buffer_bytes]u8 = undefined;
    var file_writer = file.writer(fs_io, &buffer);
    const writer = &file_writer.interface;
    try writer.print("{}\n", .{clean});
    try writer.flush();
}
