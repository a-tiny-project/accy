const std = @import("std");

pub const Error = std.mem.Allocator.Error;

pub fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) Error!?[]const u8 {
    return if (value) |actual| try dupe(allocator, actual) else null;
}

pub fn freeOptional(allocator: std.mem.Allocator, value: ?[]const u8) void {
    if (value) |actual| free(allocator, actual);
}

pub fn dupe(allocator: std.mem.Allocator, value: []const u8) Error![]const u8 {
    return try allocator.dupe(u8, value);
}

pub fn free(allocator: std.mem.Allocator, value: []const u8) void {
    allocator.free(@constCast(value));
}

pub fn dupeList(allocator: std.mem.Allocator, values: []const []const u8) Error![]const []const u8 {
    if (values.len == 0) return &.{};

    const out = try allocator.alloc([]const u8, values.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |item| free(allocator, item);
        allocator.free(out);
    }

    for (values, 0..) |value, index| {
        out[index] = try dupe(allocator, value);
        filled += 1;
    }
    return out;
}

pub fn freeList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| free(allocator, value);
    if (values.len > 0) allocator.free(@constCast(values));
}

pub fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}
