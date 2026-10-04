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

pub fn rangeCrossesLoopEntry(start: u32, end: u32, loops: []const Interval) bool {
    for (loops) |loop| {
        if (start <= loop.entry and end >= loop.entry) return true;
    }
    return false;
}

pub fn evictionUnsafeAt(victim_start: u32, at: u32, loops: []const Interval) bool {
    for (loops) |loop| {
        if (victim_start < loop.entry and loop.containsPosition(at)) return true;
    }
    return false;
}

pub fn innermostTrailing(use_position: u32, loops: []const Interval) ?u32 {
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
