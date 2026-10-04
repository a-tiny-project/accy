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

test "loop intervals extend crossing candidates to the trailing position" {
    var owner: u8 = 0;
    var outside = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 0 } },
        .type = undefined,
        .id = 0,
    };
    var inside = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 1 } },
        .type = undefined,
        .id = 1,
    };

    const CandidateType = interval.Candidate(u8, u8);
    var outside_uses: std.ArrayListUnmanaged(interval.UsePosition(u8, u8)) = .empty;
    defer outside_uses.deinit(std.testing.allocator);
    try outside_uses.append(std.testing.allocator, .{
        .point = position.Point.source(4),
        .requirement = .any,
        .source_blockers = 0,
    });
    var inside_uses: std.ArrayListUnmanaged(interval.UsePosition(u8, u8)) = .empty;
    defer inside_uses.deinit(std.testing.allocator);
    try inside_uses.append(std.testing.allocator, .{
        .point = position.Point.source(6),
        .requirement = .any,
        .source_blockers = 0,
    });

    var candidates = [_]CandidateType{
        .{
            .value = &outside,
            .range = .{ .start = 0, .end = 4, .end_phase = .source },
            .use_positions = outside_uses,
            .definition = .{
                .point = position.Point.definition(0),
                .requirement = .any,
                .source = .any,
            },
            .order = 0,
            .is_constant = false,
        },
        .{
            .value = &inside,
            .range = .{ .start = 5, .end = 6, .end_phase = .source },
            .use_positions = inside_uses,
            .definition = .{
                .point = position.Point.definition(5),
                .requirement = .any,
                .source = .any,
            },
            .order = 1,
            .is_constant = false,
        },
    };

    const loops = [_]Interval{.{ .entry = 3, .trailing = 8 }};
    extendAcrossLoops(u8, u8, &candidates, &loops);

    try std.testing.expectEqual(@as(u32, 8), candidates[0].range.end);
    try std.testing.expectEqual(position.Phase.source, candidates[0].range.end_phase);
    try std.testing.expectEqual(@as(u32, 6), candidates[1].range.end);
}

test "loop crossing and eviction predicates track entry positions" {
    const loops = [_]Interval{
        .{ .entry = 3, .trailing = 8 },
        .{ .entry = 5, .trailing = 7 },
    };

    try std.testing.expect(rangeCrossesLoopEntry(0, 4, &loops));
    try std.testing.expect(rangeCrossesLoopEntry(3, 8, &loops));
    try std.testing.expect(rangeCrossesLoopEntry(5, 7, &loops));
    try std.testing.expect(!rangeCrossesLoopEntry(0, 2, &loops));

    try std.testing.expect(evictionUnsafeAt(0, 6, &loops));
    try std.testing.expect(!evictionUnsafeAt(0, 2, &loops));
    try std.testing.expect(!evictionUnsafeAt(3, 4, &loops));
    try std.testing.expect(evictionUnsafeAt(3, 6, &loops));

    try std.testing.expectEqual(@as(?u32, 7), innermostTrailing(6, &loops));
    try std.testing.expectEqual(@as(?u32, 8), innermostTrailing(4, &loops));
    try std.testing.expectEqual(@as(?u32, null), innermostTrailing(9, &loops));
}
