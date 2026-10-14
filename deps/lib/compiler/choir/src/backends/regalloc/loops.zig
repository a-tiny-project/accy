const std = @import("std");
const ir = @import("../../core/root.zig");
const interval = @import("interval.zig");
const position = @import("position.zig");

pub const Interval = struct {
    entry: u32,
    trailing: u32,

    pub fn containsPosition(self: Interval, pos: u32) bool {
        return pos >= self.entry and pos <= self.trailing;
    }
};

pub fn extendAcrossLoops(
    comptime Register: type,
    comptime Mask: type,
    candidates: []interval.Candidate(Register, Mask),
    loops: []const Interval,
) void {
    for (candidates) |*candidate| {
        for (candidate.use_positions.items) |use| {
            for (loops) |loop| {
                if (!loop.containsPosition(use.point.position)) continue;
                if (candidate.start() >= loop.entry) continue;
                const end_point = position.Point.source(loop.trailing);
                if (end_point.greaterThan(candidate.endPoint())) {
                    candidate.range.end = end_point.position;
                    candidate.range.end_phase = end_point.phase;
                }
            }
        }
    }
}

/// The loops of one function sorted by entry position. A query reaches the loops whose entries
/// fall in the span it asks about through one binary search, where testing every loop would cost
/// a pass over the function's loops for each candidate, register and range that asks.
pub const Index = struct {
    by_entry: []const Interval,

    pub const none: Index = .{ .by_entry = &.{} };

    /// Sorts `intervals` by entry in place and borrows them. The sort is stable, so loops that
    /// share an entry keep the order they were collected in.
    pub fn sort(intervals: []Interval) Index {
        std.mem.sort(Interval, intervals, {}, entryLessThan);
        return .{ .by_entry = intervals };
    }

    fn entryLessThan(_: void, lhs: Interval, rhs: Interval) bool {
        return lhs.entry < rhs.entry;
    }

    /// The index of the first loop whose entry is after `pos`.
    fn firstEntryAfter(self: Index, pos: u32) usize {
        var low: usize = 0;
        var high = self.by_entry.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.by_entry[middle].entry <= pos) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low;
    }

    /// The loops whose entries are after `after` and at or before `through`, in entry order.
    fn enteredBetween(self: Index, after: u32, through: u32) []const Interval {
        const first = self.firstEntryAfter(after);
        const last = @max(first, self.firstEntryAfter(through));
        return self.by_entry[first..last];
    }

    /// Whether some loop's entry lies in `start..end`, both ends included.
    pub fn rangeCrossesEntry(self: Index, start: u32, end: u32) bool {
        if (end < start) return false;
        const first = if (start == 0) 0 else self.firstEntryAfter(start - 1);
        return first < self.by_entry.len and self.by_entry[first].entry <= end;
    }

    /// Whether a loop holding `at` begins after `victim_start`.
    pub fn evictionUnsafeAt(self: Index, victim_start: u32, at: u32) bool {
        for (self.enteredBetween(victim_start, at)) |loop| {
            if (loop.containsPosition(at)) return true;
        }
        return false;
    }

    /// The first loop that a location range from `start` to `end` enters partway: one it begins
    /// before and reaches into, but leaves before the loop's trailing position. The back edge
    /// returns to the header with the value expected where the range keeps it, so such a range
    /// holds the value for the first iteration only. Ending the range just before this loop's
    /// entry leaves it entering no loop partway: a loop the shorter range would still leave early
    /// contains this one, so the longer range entered that loop partway too, and earlier.
    pub fn enteredPartway(self: Index, start: u32, end: position.Point) ?Interval {
        for (self.enteredBetween(start, end.position)) |loop| {
            if (end.lessThan(position.Point.source(loop.trailing))) return loop;
        }
        return null;
    }

    /// The trailing position of the innermost loop holding `use_position`.
    pub fn innermostTrailing(self: Index, use_position: u32) ?u32 {
        var clamp: ?u32 = null;
        for (self.by_entry[0..self.firstEntryAfter(use_position)]) |loop| {
            if (!loop.containsPosition(use_position)) continue;
            if (clamp) |current| {
                if (loop.trailing < current) clamp = loop.trailing;
            } else {
                clamp = loop.trailing;
            }
        }
        return clamp;
    }
};

/// The scans the index replaced, kept as the oracle its queries must agree with.
const Scan = struct {
    fn rangeCrossesEntry(start: u32, end: u32, loops: []const Interval) bool {
        for (loops) |loop| {
            if (start <= loop.entry and end >= loop.entry) return true;
        }
        return false;
    }

    fn evictionUnsafeAt(victim_start: u32, at: u32, loops: []const Interval) bool {
        for (loops) |loop| {
            if (victim_start < loop.entry and loop.containsPosition(at)) return true;
        }
        return false;
    }

    fn enteredPartway(start: u32, end: position.Point, loops: []const Interval) ?Interval {
        var first: ?Interval = null;
        for (loops) |loop| {
            if (start >= loop.entry or end.position < loop.entry) continue;
            if (!end.lessThan(position.Point.source(loop.trailing))) continue;
            if (first) |current| {
                if (current.entry <= loop.entry) continue;
            }
            first = loop;
        }
        return first;
    }

    fn innermostTrailing(use_position: u32, loops: []const Interval) ?u32 {
        var clamp: ?u32 = null;
        for (loops) |loop| {
            if (!loop.containsPosition(use_position)) continue;
            if (clamp) |current| {
                if (loop.trailing < current) clamp = loop.trailing;
            } else {
                clamp = loop.trailing;
            }
        }
        return clamp;
    }
};
