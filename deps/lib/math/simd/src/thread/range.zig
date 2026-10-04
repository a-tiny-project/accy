const std = @import("std");

pub const IndexRange = struct {
    begin: usize = 0,
    end: usize = 0,

    pub fn init(begin: usize, end: usize) error{InvalidRange}!IndexRange {
        if (begin >= end) return error.InvalidRange;
        return .{ .begin = begin, .end = end };
    }

    pub fn count(self: IndexRange) usize {
        std.debug.assert(self.begin <= self.end);
        return self.end - self.begin;
    }

    pub fn contains(self: IndexRange, index: usize) bool {
        return self.begin <= index and index < self.end;
    }

    pub fn containsRange(self: IndexRange, other: IndexRange) bool {
        return other.begin >= self.begin and other.end <= self.end;
    }
};

pub fn makeIndexRange(
    begin: usize,
    end: usize,
    max_size: usize,
) error{ InvalidRange, EmptyTask }!IndexRange {
    if (begin >= end) return error.InvalidRange;
    if (max_size == 0) return error.EmptyTask;
    return .{
        .begin = begin,
        .end = begin + @min(max_size, end - begin),
    };
}

pub const IndexRangePartition = struct {
    range: IndexRange,
    task_size: u32,
    task_count: u32,

    pub fn single(
        task_size: usize,
    ) error{ EmptyTask, TaskTooLarge }!IndexRangePartition {
        if (task_size == 0) return error.EmptyTask;
        if (task_size > std.math.maxInt(u32)) return error.TaskTooLarge;
        return .{
            .range = .{ .begin = 0, .end = task_size },
            .task_size = @intCast(task_size),
            .task_count = 1,
        };
    }

    pub fn init(
        range: IndexRange,
        task_size: usize,
    ) error{ InvalidRange, EmptyTask, RangeTooLarge, TaskTooLarge }!IndexRangePartition {
        if (range.begin >= range.end) return error.InvalidRange;
        if (task_size == 0) return error.EmptyTask;
        if (range.count() > std.math.maxInt(u32)) return error.RangeTooLarge;
        if (task_size > std.math.maxInt(u32)) return error.TaskTooLarge;
        const task_count = std.math.divCeil(
            u32,
            @intCast(range.count()),
            @intCast(task_size),
        ) catch unreachable;
        std.debug.assert(task_count != 0);
        return .{
            .range = range,
            .task_size = @intCast(task_size),
            .task_count = task_count,
        };
    }

    pub fn taskSize(self: IndexRangePartition) usize {
        return self.task_size;
    }

    pub fn taskCount(self: IndexRangePartition) usize {
        return self.task_count;
    }

    pub fn rangeAt(
        self: IndexRangePartition,
        task_index: usize,
    ) error{TaskOutOfBounds}!IndexRange {
        if (task_index >= self.task_count) return error.TaskOutOfBounds;
        const begin = self.range.begin + task_index * self.task_size;
        return .{
            .begin = begin,
            .end = begin + @min(self.task_size, self.range.end - begin),
        };
    }

    pub fn visitAll(
        self: IndexRangePartition,
        context: anytype,
        comptime visit: fn (@TypeOf(context), IndexRange) void,
    ) void {
        for (0..self.task_count) |task_index| {
            visit(context, self.rangeAt(task_index) catch unreachable);
        }
    }

    pub fn visitFirst(
        self: IndexRangePartition,
        context: anytype,
        comptime visit: fn (@TypeOf(context), IndexRange) void,
    ) void {
        visit(context, self.rangeAt(0) catch unreachable);
    }

    pub fn visitRemaining(
        self: IndexRangePartition,
        context: anytype,
        comptime visit: fn (@TypeOf(context), IndexRange) void,
    ) void {
        for (1..self.task_count) |task_index| {
            visit(context, self.rangeAt(task_index) catch unreachable);
        }
    }
};

const RangeVisits = struct {
    ranges: [8]IndexRange = @splat(.{}),
    count: usize = 0,

    fn append(self: *RangeVisits, range: IndexRange) void {
        self.ranges[self.count] = range;
        self.count += 1;
    }
};

test "Highway index ranges preserve half-open containment" {
    const range = try IndexRange.init(7, 19);
    try std.testing.expectEqual(@as(usize, 12), range.count());
    try std.testing.expect(range.contains(7));
    try std.testing.expect(range.contains(18));
    try std.testing.expect(!range.contains(19));
    try std.testing.expect(range.containsRange(try IndexRange.init(9, 13)));
    try std.testing.expect(!range.containsRange(try IndexRange.init(6, 13)));
    try std.testing.expectEqual(
        IndexRange{ .begin = 17, .end = 19 },
        try makeIndexRange(17, 19, std.math.maxInt(usize)),
    );
}

test "Highway index range partitions cover the remainder once" {
    const partition = try IndexRangePartition.init(
        try IndexRange.init(11, 40),
        6,
    );
    try std.testing.expectEqual(@as(usize, 6), partition.taskSize());
    try std.testing.expectEqual(@as(usize, 5), partition.taskCount());
    var cursor: usize = 11;
    for (0..partition.taskCount()) |task_index| {
        const range = try partition.rangeAt(task_index);
        try std.testing.expectEqual(cursor, range.begin);
        try std.testing.expect(range.count() >= 1);
        try std.testing.expect(range.count() <= partition.taskSize());
        cursor = range.end;
    }
    try std.testing.expectEqual(@as(usize, 40), cursor);
    try std.testing.expectError(
        error.TaskOutOfBounds,
        partition.rangeAt(partition.taskCount()),
    );
    var all = RangeVisits{};
    partition.visitAll(&all, RangeVisits.append);
    try std.testing.expectEqual(partition.taskCount(), all.count);
    for (all.ranges[0..all.count], 0..) |range, task| {
        try std.testing.expectEqual(try partition.rangeAt(task), range);
    }
    var first = RangeVisits{};
    partition.visitFirst(&first, RangeVisits.append);
    try std.testing.expectEqual(@as(usize, 1), first.count);
    try std.testing.expectEqual(try partition.rangeAt(0), first.ranges[0]);
    var remaining = RangeVisits{};
    partition.visitRemaining(&remaining, RangeVisits.append);
    try std.testing.expectEqual(partition.taskCount() - 1, remaining.count);
    for (remaining.ranges[0..remaining.count], 1..) |range, task| {
        try std.testing.expectEqual(try partition.rangeAt(task), range);
    }
}

test "Highway one-task partition covers the requested prefix" {
    const partition = try IndexRangePartition.single(17);
    try std.testing.expectEqual(@as(usize, 17), partition.taskSize());
    try std.testing.expectEqual(@as(usize, 1), partition.taskCount());
    try std.testing.expectEqual(
        IndexRange{ .begin = 0, .end = 17 },
        try partition.rangeAt(0),
    );
    try std.testing.expectError(
        error.EmptyTask,
        IndexRangePartition.single(0),
    );
}

test "Highway index range partition rejects unrepresentable limits" {
    try std.testing.expectError(
        error.EmptyTask,
        IndexRangePartition.init(try IndexRange.init(0, 1), 0),
    );
    if (@sizeOf(usize) > @sizeOf(u32)) {
        try std.testing.expectError(
            error.RangeTooLarge,
            IndexRangePartition.init(
                .{ .begin = 0, .end = @as(usize, std.math.maxInt(u32)) + 2 },
                1,
            ),
        );
        try std.testing.expectError(
            error.TaskTooLarge,
            IndexRangePartition.init(
                try IndexRange.init(0, 1),
                @as(usize, std.math.maxInt(u32)) + 1,
            ),
        );
    }
}
