const std = @import("std");
const sys = @import("sys");
const cli = @import("../root.zig");

const activity = @import("activity.zig");
const inspect = @import("inspect.zig");
const report = @import("report.zig");
const special = @import("special.zig");
const usage = cli.usage;

const Runner = *const fn (std.mem.Allocator, []const []const u8) anyerror!u8;

const Command = struct {
    name: []const u8,
    run: Runner,
};

const commands = [_]Command{
    .{ .name = "summary", .run = report.summary },
    .{ .name = "context", .run = activity.context },
    .{ .name = "tree", .run = report.tree },
    .{ .name = "stats", .run = report.stats },
    .{ .name = "frames", .run = report.frames },
    .{ .name = "memory", .run = activity.memory },
    .{ .name = "locks", .run = activity.locks },
    .{ .name = "messages", .run = activity.messages },
    .{ .name = "samples", .run = activity.samples },
    .{ .name = "fibers", .run = activity.fibers },
    .{ .name = "gpu", .run = activity.gpu },
    .{ .name = "system", .run = activity.system },
    .{ .name = "plots", .run = activity.plots },
    .{ .name = "source", .run = inspect.source },
    .{ .name = "find", .run = inspect.find },
    .{ .name = "flame", .run = special.flame },
    .{ .name = "timeline", .run = inspect.timeline },
    .{ .name = "compare", .run = special.compare },
    .{ .name = "export", .run = special.exportCommand },
};

pub fn dispatch(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try usage.write(allocator, sys.stdio.stderr());
        return 1;
    }

    const command = args[1];
    if (isHelpCommand(command)) {
        try usage.write(allocator, sys.stdio.stdout());
        return 0;
    }
    for (commands) |entry| {
        if (std.mem.eql(u8, command, entry.name)) return try entry.run(allocator, args[2..]);
    }
    return error.UnknownCommand;
}

fn isHelpCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h");
}
