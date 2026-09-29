const std = @import("std");

/// Refuses a gpu module graph that reaches compiler code. Every module the
/// runtime imports, directly or through another module, must come from
/// outside `lib/accy` and `lib/choir`.
pub fn requireRuntimeBoundary(b: *std.Build, runtime: *std.Build.Module) void {
    var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    visit(b, &visited, runtime, "gpu");
}

fn visit(
    b: *std.Build,
    visited: *std.AutoHashMapUnmanaged(*std.Build.Module, void),
    module: *std.Build.Module,
    path: []const u8,
) void {
    const entry = visited.getOrPut(b.graph.arena, module) catch @panic("OOM");
    if (entry.found_existing) return;
    const package = packageDirectory(b, module);
    if (std.mem.endsWith(u8, package, "lib/accy") or
        std.mem.endsWith(u8, package, "lib/choir"))
    {
        std.debug.panic("gpu reaches compiler module {s} from {s}", .{ path, package });
    }
    for (module.import_table.keys(), module.import_table.values()) |name, imported| {
        visit(b, visited, imported, b.fmt("{s}.{s}", .{ path, name }));
    }
}

fn packageDirectory(b: *std.Build, module: *std.Build.Module) []const u8 {
    const directory = module.owner.root.toString(b.graph.arena) catch @panic("OOM");
    return std.fs.path.resolve(b.graph.arena, &.{directory}) catch @panic("OOM");
}
