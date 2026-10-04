const std = @import("std");

pub const Schedule = struct {
    order: []const u32,
    next_ordinal: std.atomic.Value(usize) = .init(0),

    pub fn take(self: *Schedule) ?u32 {
        const ordinal = self.next_ordinal.fetchAdd(1, .monotonic);
        if (ordinal >= self.order.len) return null;
        return self.order[ordinal];
    }
};

pub fn activeCount(requested: usize, test_count: usize) usize {
    return @min(requested, test_count);
}

pub fn indexedPosition(
    total: usize,
    worker_count: usize,
    worker_index: usize,
    worker_ordinal: usize,
) ?usize {
    std.debug.assert(worker_count > 0);
    std.debug.assert(worker_index < worker_count);
    const offset = std.math.mul(usize, worker_ordinal, worker_count) catch
        return null;
    const position = std.math.add(usize, worker_index, offset) catch
        return null;
    if (position >= total) return null;
    return position;
}

test "schedule assigns every ordinal once" {
    var schedule = Schedule{ .order = &.{ 2, 0, 1 } };
    try std.testing.expectEqual(@as(?u32, 2), schedule.take());
    try std.testing.expectEqual(@as(?u32, 0), schedule.take());
    try std.testing.expectEqual(@as(?u32, 1), schedule.take());
    try std.testing.expectEqual(@as(?u32, null), schedule.take());
}

test "active worker count never exceeds selected tests" {
    try std.testing.expectEqual(@as(usize, 1), activeCount(8, 1));
    try std.testing.expectEqual(@as(usize, 8), activeCount(8, 64));
}

test "indexed workers partition an ordered schedule exactly once" {
    const order = [_]u32{ 7, 3, 9, 1, 5 };
    const expected = [_][2]?u32{
        .{ 7, 1 },
        .{ 3, 5 },
        .{ 9, null },
    };
    var visited: [order.len]bool = @splat(false);
    for (expected, 0..) |worker, worker_index| {
        for (worker, 0..) |expected_ordinal, worker_ordinal| {
            const position = indexedPosition(
                order.len,
                expected.len,
                worker_index,
                worker_ordinal,
            );
            const actual = if (position) |index| order[index] else null;
            try std.testing.expectEqual(expected_ordinal, actual);
            if (position) |index| {
                try std.testing.expect(!visited[index]);
                visited[index] = true;
            }
        }
    }
    for (visited) |assigned| try std.testing.expect(assigned);
}

test "indexed positions reject overflow and exhaustion" {
    try std.testing.expectEqual(
        @as(?usize, null),
        indexedPosition(
            std.math.maxInt(usize),
            2,
            1,
            std.math.maxInt(usize),
        ),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        indexedPosition(5, 3, 2, 1),
    );
}
