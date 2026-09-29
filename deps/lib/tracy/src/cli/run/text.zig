const std = @import("std");
const sys = @import("sys");

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    comptime parse: anytype,
    comptime writeText: anytype,
    comptime writeJsonl: anytype,
) !u8 {
    const parsed = try parse(args);
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = sys.stdio.stdout().writer(sys.stdio.debugIo(), &stdout_buffer);
    switch (parsed.format) {
        .text => try writeText(allocator, parsed.path, &stdout.interface, parsed.options),
        .jsonl => try writeJsonl(allocator, parsed.path, &stdout.interface, parsed.options),
    }
    try stdout.interface.flush();
    return 0;
}
