const std = @import("std");
const invocation = @import("root.zig");

/// Absence must also invalidate configuration reuse: a later raw build cannot
/// inherit a previous launch's qualified generated module from the cache.
pub fn observe(b: *std.Build) !?invocation.Record {
    std.debug.assert(b.isRoot());
    switch (b.graph.cache_poison) {
        .ignored, .disallowed => return null,
        .pure, .poisoned => b.graph.poisonCache(),
    }
    const allocator = b.graph.arena;
    const directory = try std.process.currentPathAlloc(b.graph.io, allocator);
    const root = try b.root.joinString(allocator, "");
    const absolute_root = try std.fs.path.resolve(allocator, &.{ directory, root });
    const build_file = try std.fs.path.join(allocator, &.{ absolute_root, "build.zig" });
    return invocation.receive(allocator, &b.graph.environ_map, .{
        .compiler = b.graph.zig_exe,
        .directory = directory,
        .build_file = build_file,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
}
