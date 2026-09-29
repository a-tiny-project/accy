const std = @import("std");
const sys = @import("sys");

const tracy = @import("../../root.zig");
const cli_args = @import("../args/root.zig");

const compare_mod = tracy.compare;
const csv_mod = tracy.csv;
const flame_mod = tracy.flame;

pub fn exportCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const parsed = try cli_args.csv.parse(args);
    if (parsed.output) |path| {
        try ensureParentDir(path);
        var file = try sys.fs.cwd().createFile(sys.fs.debugIo(), path, .{ .truncate = true });
        defer file.close(sys.fs.debugIo());
        var buffer: [8192]u8 = undefined;
        var writer = file.writer(sys.fs.debugIo(), &buffer);
        try csv_mod.writeFromJsonlPath(allocator, parsed.path, &writer.interface, parsed.mode);
        try writer.interface.flush();
    } else {
        var stdout_buffer: [8192]u8 = undefined;
        var stdout = sys.stdio.stdout().writer(sys.stdio.debugIo(), &stdout_buffer);
        try csv_mod.writeFromJsonlPath(allocator, parsed.path, &stdout.interface, parsed.mode);
        try stdout.interface.flush();
    }
    return 0;
}

pub fn flame(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const parsed = try cli_args.flame.parse(args);
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = sys.stdio.stdout().writer(sys.stdio.debugIo(), &stdout_buffer);
    switch (parsed.format) {
        .text => try flame_mod.writeTextFromJsonlPath(allocator, parsed.path, &stdout.interface, parsed.options),
        .jsonl => try flame_mod.writeJsonlFromJsonlPath(allocator, parsed.path, &stdout.interface, parsed.options),
        .folded => try flame_mod.writeFoldedFromJsonlPath(allocator, parsed.path, &stdout.interface, parsed.options),
    }
    try stdout.interface.flush();
    return 0;
}

pub fn compare(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const parsed = try cli_args.compare.parse(args);
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = sys.stdio.stdout().writer(sys.stdio.debugIo(), &stdout_buffer);
    switch (parsed.format) {
        .text => try compare_mod.writeTextFromJsonlPaths(allocator, parsed.baseline_path, parsed.run_path, &stdout.interface, parsed.options),
        .jsonl => try compare_mod.writeJsonlFromJsonlPaths(allocator, parsed.baseline_path, parsed.run_path, &stdout.interface, parsed.options),
    }
    try stdout.interface.flush();
    return 0;
}

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) try sys.fs.cwd().createDirPath(sys.fs.debugIo(), dir);
    }
}
