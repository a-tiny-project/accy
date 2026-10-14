const std = @import("std");

pub fn requireReachable(
    b: *std.Build,
    source: *std.Build.Step,
    target: *std.Build.Step,
    message: []const u8,
) void {
    if (!reaches(b, source, target)) @panic(message);
}

pub fn requireUnreachable(
    b: *std.Build,
    source: *std.Build.Step,
    target: *std.Build.Step,
    message: []const u8,
) void {
    if (reaches(b, source, target)) @panic(message);
}

fn reaches(
    b: *std.Build,
    source: *std.Build.Step,
    target: *std.Build.Step,
) bool {
    var visited: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    return reachesFrom(b, &visited, source, target);
}

fn reachesFrom(
    b: *std.Build,
    visited: *std.AutoHashMapUnmanaged(*std.Build.Step, void),
    source: *std.Build.Step,
    target: *std.Build.Step,
) bool {
    if (source == target) return true;
    const entry = visited.getOrPut(b.graph.arena, source) catch @panic("OOM");
    if (entry.found_existing) return false;
    for (source.dependencies.items) |dependency| {
        if (reachesFrom(b, visited, dependency, target)) return true;
    }
    return false;
}
