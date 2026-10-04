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
