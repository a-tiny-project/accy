const std = @import("std");
const bench = @import("bench");
const hypothesis = @import("hypothesis");

const Allocator = std.mem.Allocator;
const max_samples = 32;
const bootstrap_iterations: u32 = 31;

const edge_values = [_]u64{
    0,
    1,
    2,
    7,
    31,
    1_000,
    1_000_000,
    @as(u64, @intCast(std.math.maxInt(i64))),
    @as(u64, @intCast(std.math.maxInt(i64))) + 1,
    std.math.maxInt(u64),
};

pub fn settings() hypothesis.Settings {
    return hypothesis.Settings.ci()
        .withSeed(0x4245_4e43_4850_4254)
        .withDatabase("zig-out/hypothesis-failures/bench");
}

fn drawUsize(data: *hypothesis.ConjectureData, min: usize, max: usize, shrink_towards: usize) !usize {
    return @intCast(try data.drawInteger(
        @intCast(min),
        @intCast(max),
        @intCast(shrink_towards),
    ));
}

fn drawSample(data: *hypothesis.ConjectureData) !u64 {
    if (try data.drawBoolean()) {
        return edge_values[try drawUsize(data, 0, edge_values.len - 1, 0)];
    }
    return try data.drawInteger(0, 1_000_000_000, 0);
}

fn lessThanU64(_: void, left: u64, right: u64) bool {
    return left < right;
}

fn modelPercentile(sorted: []const u64, pct: u8) u64 {
    const index = ((sorted.len - 1) * @as(usize, pct) + 99) / 100;
    return sorted[index];
}

fn expectStats(samples: []const u64, stats: bench.SampleStats, allocator: Allocator) !void {
    const sorted = try allocator.dupe(u64, samples);
    defer allocator.free(sorted);
    std.mem.sort(u64, sorted, {}, lessThanU64);

    var total: u128 = 0;
    for (samples) |sample| total += sample;
    const expected_total: u64 = if (total > std.math.maxInt(u64))
        std.math.maxInt(u64)
    else
        @intCast(total);

    try std.testing.expectEqual(sorted[0], stats.min_ns);
    try std.testing.expectEqual(sorted[sorted.len - 1], stats.max_ns);
    try std.testing.expectEqual(expected_total, stats.total_ns);
    try std.testing.expectEqual(modelPercentile(sorted, 50), stats.median_ns);
    try std.testing.expectEqual(modelPercentile(sorted, 75), stats.p75_ns);
    try std.testing.expectEqual(modelPercentile(sorted, 95), stats.p95_ns);
    try std.testing.expectEqual(modelPercentile(sorted, 99), stats.p99_ns);
    try std.testing.expect(stats.mean_ns >= @as(f64, @floatFromInt(stats.min_ns)));
    try std.testing.expect(stats.mean_ns <= @as(f64, @floatFromInt(stats.max_ns)));
    try std.testing.expect(stats.confidence_intervals != null);
    const intervals = stats.confidence_intervals.?;
    try std.testing.expectEqual(bootstrap_iterations, intervals.iterations);
    try expectInterval(intervals.mean_ns, stats.min_ns, stats.max_ns);
    try expectInterval(intervals.median_ns, stats.min_ns, stats.max_ns);
    try expectInterval(intervals.p75_ns, stats.min_ns, stats.max_ns);
    try expectInterval(intervals.p95_ns, stats.min_ns, stats.max_ns);
    try expectInterval(intervals.p99_ns, stats.min_ns, stats.max_ns);
}

fn expectInterval(interval: bench.ConfidenceInterval, min: u64, max: u64) !void {
    try std.testing.expect(interval.low_ns <= interval.high_ns);
    try std.testing.expect(interval.low_ns >= @as(f64, @floatFromInt(min)));
    try std.testing.expect(interval.high_ns <= @as(f64, @floatFromInt(max)));
}

pub const Property = struct {
    pub fn property(data: *hypothesis.ConjectureData, property_allocator: Allocator) !void {
        const len = try drawUsize(data, 1, max_samples, 4);
        var samples: [max_samples]u64 = undefined;
        for (samples[0..len]) |*sample| sample.* = try drawSample(data);
        var storage = try bench.StatisticsStorage.init(property_allocator, .{
            .samples = max_samples,
            .bootstrap_iterations = bootstrap_iterations,
        });
        defer storage.deinit(property_allocator);
        storage.activate();

        const bootstrap = bench.BootstrapConfig{ .iterations = bootstrap_iterations };
        const stats = try bench.computeSampleStatsWithBootstrap(
            &storage,
            samples[0..len],
            bootstrap,
        );
        try expectStats(samples[0..len], stats, property_allocator);

        std.mem.reverse(u64, samples[0..len]);
        const reversed = try bench.computeSampleStatsWithBootstrap(
            &storage,
            samples[0..len],
            bootstrap,
        );
        try expectStats(samples[0..len], reversed, property_allocator);
        try std.testing.expectEqual(stats.min_ns, reversed.min_ns);
        try std.testing.expectEqual(stats.max_ns, reversed.max_ns);
        try std.testing.expectEqual(stats.median_ns, reversed.median_ns);
        try std.testing.expectEqual(stats.p75_ns, reversed.p75_ns);
        try std.testing.expectEqual(stats.p95_ns, reversed.p95_ns);
        try std.testing.expectEqual(stats.p99_ns, reversed.p99_ns);
        try std.testing.expectEqual(stats.total_ns, reversed.total_ns);
        try std.testing.expectEqual(stats.mean_ns, reversed.mean_ns);
        try std.testing.expectEqual(
            stats.confidence_intervals.?,
            reversed.confidence_intervals.?,
        );
    }
};

test "property: sample statistics follow generated order-insensitive model" {
    try hypothesis.checkNamed(Property, "bench-sample-statistics", settings());
}
