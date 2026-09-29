//! Reading a confidence interval off a sorted bootstrap distribution.

const std = @import("std");
const resample = @import("resample.zig");

pub const Interval = struct {
    low: f64,
    high: f64,
};

/// How an interval's bounds are read off a sorted bootstrap distribution of
/// `n` values, with the tail `t = (1000 - confidence) / 2` per mille. The three
/// rules agree on most indices but not all. At the default `n = 1000` and 95%
/// confidence, `outward` reads its low bound at index 24 where the other two
/// read 25. Settling on one rule changes reported intervals, so each owner
/// names the rule it has always used.
pub const Rule = enum {
    /// low at ceil((n - 1) * t / 1000), high at ceil((n - 1) * (1000 - t) / 1000).
    /// Used by capture's four effect intervals and by bench's sample statistic
    /// intervals.
    nearest_rank,
    /// low at floor((n - 1) * t / 1000), high at ceil((n - 1) * (1000 - t) / 1000),
    /// so the interval is never narrower than `nearest_rank`. Used by bench's
    /// execution median percent change.
    outward,
    /// low at floor(n * t / 1000), high at floor(n * (1000 - t) / 1000), each
    /// clamped to the last index. Used by bench's u64 median ratio.
    truncated,
};

/// The interval at `confidence_per_mille` of the ascending distribution `sorted`.
pub fn interval(sorted: []const f64, confidence_per_mille: u16, rule: Rule) Interval {
    std.debug.assert(sorted.len > 0);
    std.debug.assert(confidence_per_mille <= 1000);
    const n = sorted.len;
    const tail = (1000 - @as(usize, confidence_per_mille)) / 2;
    const low: usize, const high: usize = switch (rule) {
        .nearest_rank => .{
            resample.nearestRank(n, tail, 1000),
            resample.nearestRank(n, 1000 - tail, 1000),
        },
        .outward => .{
            @intCast(@as(u128, n - 1) * tail / 1000),
            resample.nearestRank(n, 1000 - tail, 1000),
        },
        .truncated => .{
            @intCast(@as(u128, n) * tail / 1000),
            @intCast(@as(u128, n) * (1000 - tail) / 1000),
        },
    };
    return .{ .low = sorted[@min(low, n - 1)], .high = sorted[@min(high, n - 1)] };
}

test "the three rules read the indices their definitions name" {
    var values: [1000]f64 = undefined;
    for (&values, 0..) |*value, index| value.* = @floatFromInt(index);
    const nearest = interval(&values, 950, .nearest_rank);
    const outward = interval(&values, 950, .outward);
    const truncated = interval(&values, 950, .truncated);
    try std.testing.expectEqual(Interval{ .low = 25, .high = 975 }, nearest);
    try std.testing.expectEqual(Interval{ .low = 24, .high = 975 }, outward);
    try std.testing.expectEqual(Interval{ .low = 25, .high = 975 }, truncated);
}

test "each rule stays within a short distribution" {
    const one = [_]f64{3};
    const three = [_]f64{ 1, 2, 3 };
    inline for (.{ Rule.nearest_rank, Rule.outward, Rule.truncated }) |rule| {
        try std.testing.expectEqual(Interval{ .low = 3, .high = 3 }, interval(&one, 950, rule));
        const bounds = interval(&three, 950, rule);
        try std.testing.expect(bounds.low <= bounds.high);
    }
    try std.testing.expectEqual(Interval{ .low = 2, .high = 3 }, interval(&three, 950, .nearest_rank));
    try std.testing.expectEqual(Interval{ .low = 1, .high = 3 }, interval(&three, 950, .outward));
    try std.testing.expectEqual(Interval{ .low = 1, .high = 3 }, interval(&three, 950, .truncated));
}
