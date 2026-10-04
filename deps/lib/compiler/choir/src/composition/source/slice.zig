const std = @import("std");

pub fn dupeOrEmpty(comptime T: type, allocator: std.mem.Allocator, values: []const T) std.mem.Allocator.Error![]const T {
    if (values.len == 0) return &.{};
    return try allocator.dupe(T, values);
}

pub fn freeOrEmpty(comptime T: type, allocator: std.mem.Allocator, values: []const T) void {
    if (values.len != 0) allocator.free(@constCast(values));
}
