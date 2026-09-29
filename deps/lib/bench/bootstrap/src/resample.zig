//! One bootstrap resample and the order statistics read from it.

const std = @import("std");

/// Draws one resample of `counts.len` items with replacement and records how
/// often each index was drawn. It draws one uniform index per item, in order, so
/// a caller that copies `samples[index]` per draw sees the same indices.
pub fn resampleCounts(random: std.Random, counts: []u32) void {
    std.debug.assert(counts.len > 0);
    std.debug.assert(counts.len <= std.math.maxInt(u32));
    @memset(counts, 0);
    for (0..counts.len) |_| {
        const index = random.intRangeLessThan(usize, 0, counts.len);
        counts[index] += 1;
    }
}

/// The mean of one resample of `samples`, summed in draw order. The order of
/// the sum is part of the result's bits, so callers that pin intervals keep it.
pub fn resampleMean(random: std.Random, samples: []const f64) f64 {
    std.debug.assert(samples.len > 0);
    var total: f64 = 0;
    for (0..samples.len) |_| {
        total += samples[random.intRangeLessThan(usize, 0, samples.len)];
    }
    return total / @as(f64, @floatFromInt(samples.len));
}

/// The value at 0-based `rank` of the resample that `counts` describes over
/// `sorted`. `sorted` must be ascending and `counts` must come from
/// `resampleCounts`, so the counts sum to `sorted.len`.
pub fn rankValue(comptime T: type, sorted: []const T, counts: []const u32, rank: usize) T {
    std.debug.assert(sorted.len > 0);
    std.debug.assert(sorted.len == counts.len);
    std.debug.assert(rank < sorted.len);
    var seen: usize = 0;
    for (sorted, counts) |value, count| {
        seen += count;
        if (seen > rank) return value;
    }
    unreachable;
}

/// The nearest-rank index ceil((len - 1) * numerator / denominator), the rank
/// of the `numerator / denominator` quantile among `len` sorted values.
pub fn nearestRank(len: usize, numerator: usize, denominator: usize) usize {
    std.debug.assert(len > 0);
    std.debug.assert(denominator > 0);
    std.debug.assert(numerator <= denominator);
    const product = @as(u128, len - 1) * numerator;
    return @intCast((product + denominator - 1) / denominator);
}

test "resampleCounts draws each item once and repeats under a fixed seed" {
    var first: [7]u32 = undefined;
    var second: [7]u32 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    resampleCounts(prng.random(), &first);
    prng = std.Random.DefaultPrng.init(11);
    resampleCounts(prng.random(), &second);
    var total: usize = 0;
    for (first) |count| total += count;
    try std.testing.expectEqual(@as(usize, 7), total);
    try std.testing.expectEqualSlices(u32, &first, &second);
}

test "resampleCounts and a copied resample draw the same indices" {
    const samples = [_]f64{ 1, 2, 3, 4, 5 };
    var copied: [5]f64 = undefined;
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    for (&copied) |*value| value.* = samples[random.intRangeLessThan(usize, 0, samples.len)];
    std.mem.sort(f64, &copied, {}, std.sort.asc(f64));
    var counts: [5]u32 = undefined;
    prng = std.Random.DefaultPrng.init(3);
    resampleCounts(prng.random(), &counts);
    for (copied, 0..) |value, rank| {
        try std.testing.expectEqual(value, rankValue(f64, &samples, &counts, rank));
    }
}

test "rankValue walks repeated values by their counts" {
    const sorted = [_]u64{ 10, 20, 30 };
    const counts = [_]u32{ 0, 2, 1 };
    try std.testing.expectEqual(@as(u64, 20), rankValue(u64, &sorted, &counts, 0));
    try std.testing.expectEqual(@as(u64, 20), rankValue(u64, &sorted, &counts, 1));
    try std.testing.expectEqual(@as(u64, 30), rankValue(u64, &sorted, &counts, 2));
}

test "nearestRank rounds up and stays within the values" {
    try std.testing.expectEqual(@as(usize, 0), nearestRank(1, 99, 100));
    try std.testing.expectEqual(@as(usize, 50), nearestRank(101, 50, 100));
    try std.testing.expectEqual(@as(usize, 3), nearestRank(4, 95, 100));
    try std.testing.expectEqual(@as(usize, 25), nearestRank(1000, 25, 1000));
    try std.testing.expectEqual(@as(usize, 975), nearestRank(1000, 975, 1000));
    try std.testing.expectEqual(@as(usize, 999), nearestRank(1000, 1000, 1000));
}
