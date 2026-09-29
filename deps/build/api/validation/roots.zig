const std = @import("std");

pub const count_max = 1024;

fn contains(parent: []const u8, child: []const u8) bool {
    std.debug.assert(parent.len != 0);
    std.debug.assert(child.len != 0);
    return std.mem.eql(u8, parent, child) or
        (child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/');
}

pub fn add(allocator: std.mem.Allocator, roots: *std.ArrayList([]const u8), path: []const u8) !void {
    std.debug.assert(path.len != 0);
    std.debug.assert(roots.items.len <= count_max);
    for (roots.items) |existing| if (contains(existing, path)) return;
    var index: usize = 0;
    while (index < roots.items.len) {
        if (contains(path, roots.items[index])) {
            _ = roots.swapRemove(index);
        } else index += 1;
    }
    if (roots.items.len == count_max) return error.ValidationPlanCapacityExceeded;
    try roots.append(allocator, path);
}

test "validation inventory coalesces overlapping roots without crossing path components" {
    const allocator = std.testing.allocator;
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(allocator);
    try add(allocator, &roots, "lib/a/build/validation.zon");
    try add(allocator, &roots, "lib/a/build.zig");
    try add(allocator, &roots, "lib/a/build");
    try add(allocator, &roots, "lib/a/build/steps.zig");
    try add(allocator, &roots, "lib/a/build");
    try std.testing.expectEqual(@as(usize, 2), roots.items.len);
    try std.testing.expectEqualStrings("lib/a/build.zig", roots.items[0]);
    try std.testing.expectEqualStrings("lib/a/build", roots.items[1]);
}
