const std = @import("std");

pub const Failure = enum {
    out_of_range,
    duplicate,
};

fn appearsInPriorGroup(
    groups: []const []const i64,
    group_index: usize,
    axis: i64,
) bool {
    for (groups[0..group_index]) |prior| {
        for (prior) |seen| {
            if (seen == axis) return true;
        }
    }
    return false;
}

pub fn check(
    rank: usize,
    groups: []const []const i64,
) ?Failure {
    for (groups, 0..) |group, group_index| {
        for (group, 0..) |axis, axis_index| {
            const index = std.math.cast(usize, axis) orelse
                return .out_of_range;
            if (index >= rank) return .out_of_range;
            if (appearsInPriorGroup(groups, group_index, axis)) {
                return .duplicate;
            }
            for (group[0..axis_index]) |seen| {
                if (seen == axis) return .duplicate;
            }
        }
    }
    return null;
}

pub fn groupsOverlap(groups: []const []const i64) bool {
    for (groups, 0..) |group, group_index| {
        for (group) |axis| {
            if (appearsInPriorGroup(groups, group_index, axis)) return true;
        }
    }
    return false;
}

test "axis role groups form a partial permutation" {
    try std.testing.expect(check(4, &.{ &.{ 2, 0 }, &.{3} }) == null);
    try std.testing.expectEqual(
        Failure.out_of_range,
        check(2, &.{&.{-1}}).?,
    );
    try std.testing.expectEqual(
        Failure.out_of_range,
        check(2, &.{&.{2}}).?,
    );
    try std.testing.expectEqual(
        Failure.duplicate,
        check(2, &.{&.{ 0, 0 }}).?,
    );
    try std.testing.expectEqual(
        Failure.duplicate,
        check(2, &.{ &.{0}, &.{0} }).?,
    );
    try std.testing.expect(!groupsOverlap(&.{ &.{ 2, 0 }, &.{3} }));
    try std.testing.expect(groupsOverlap(&.{ &.{0}, &.{0} }));
}
