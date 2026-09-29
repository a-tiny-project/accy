const std = @import("std");

const hash_multiplier: u64 = 0x9e3779b97f4a7c15;

pub fn Map(comptime Value: type) type {
    return std.HashMapUnmanaged(u64, Value, Context, std.hash_map.default_max_load_percentage);
}

const Context = struct {
    pub fn hash(_: Context, key: u64) u64 {
        return std.math.rotl(u64, key *% hash_multiplier, 32);
    }

    pub fn eql(_: Context, left: u64, right: u64) bool {
        return left == right;
    }
};

fn exercise(stride: u64) !void {
    var map: Map(usize) = .{};
    defer map.deinit(std.testing.allocator);

    for (0..256) |index| {
        const key = @as(u64, @intCast(index + 1)) * stride;
        try map.putNoClobber(std.testing.allocator, key, index);
    }
    for (0..256) |index| {
        const key = @as(u64, @intCast(index + 1)) * stride;
        try std.testing.expectEqual(index, map.get(key));
    }
    var index: usize = 256;
    while (index > 0) {
        index -= 1;
        const key = @as(u64, @intCast(index + 1)) * stride;
        try std.testing.expectEqual(index, map.fetchRemove(key).?.value);
    }
    try std.testing.expectEqual(0, map.count());
    map.clearRetainingCapacity();
}

test "allocation map handles sequential ids and aligned addresses" {
    try exercise(1);
    try exercise(128);
}

test "allocation hash bounds working-set bucket load" {
    var sequential = @as([512]u8, @splat(0));
    var aligned = @as([512]u8, @splat(0));
    for (0..256) |index| {
        sequential[@intCast(Context.hash(.{}, @intCast(index + 1)) & 511)] += 1;
        aligned[@intCast(Context.hash(.{}, 0x1000 + @as(u64, @intCast(index)) * 128) & 511)] += 1;
    }
    for (sequential) |load| try std.testing.expect(load <= 1);
    for (aligned) |load| try std.testing.expect(load <= 2);
}
