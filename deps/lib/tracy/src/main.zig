const std = @import("std");
const sys = @import("sys");
const tracy = @import("tracy");

pub fn main(init: sys.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    const backing_allocator = gpa.allocator();

    var args_arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer args_arena.deinit();

    const args = init.minimal.args.toSlice(args_arena.allocator()) catch |err| {
        try tracy.cli.printError(backing_allocator, sys.stdio.stderr(), @errorName(err));
        sys.process.exit(1);
    };

    const code = tracy.cli.dispatch(backing_allocator, args) catch |err| blk: {
        try tracy.cli.printError(backing_allocator, sys.stdio.stderr(), @errorName(err));
        break :blk 1;
    };
    sys.process.exit(code);
}
