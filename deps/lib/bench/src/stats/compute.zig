const std = @import("std");
const bench_bootstrap = @import("bench_bootstrap");
const model = @import("model.zig");
const storage_mod = @import("storage.zig");

pub fn sample(
    storage: *storage_mod.Storage,
    samples: []const u64,
) model.ComputeError!model.SampleStats {
    return sampleWithBootstrap(storage, samples, .{});
}

pub fn sampleWithBootstrap(
    storage: *storage_mod.Storage,
    samples: []const u64,
    bootstrap: model.BootstrapConfig,
) model.ComputeError!model.SampleStats {
    const regions = try storage.acquire(samples.len, bootstrap);
    defer storage.reset();
    @memcpy(regions.sorted, samples);
    std.mem.sort(u64, regions.sorted, {}, lessThanU64);

    var total: u128 = 0;
    for (samples) |value| total += value;
    return .{
        .min_ns = regions.sorted[0],
        .max_ns = regions.sorted[regions.sorted.len - 1],
        .mean_ns = @as(f64, @floatFromInt(total)) /
            @as(f64, @floatFromInt(samples.len)),
        .median_ns = percentile(regions.sorted, 50),
        .p75_ns = percentile(regions.sorted, 75),
        .p95_ns = percentile(regions.sorted, 95),
        .p99_ns = percentile(regions.sorted, 99),
        .total_ns = if (total > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(total),
        .confidence_intervals = bootstrapConfidenceIntervals(regions, bootstrap),
    };
}

pub fn percentile(sorted: []const u64, pct: u8) u64 {
    if (sorted.len == 0) return 0;
    return sorted[bench_bootstrap.nearestRank(sorted.len, pct, 100)];
}

fn lessThanU64(_: void, left: u64, right: u64) bool {
    return left < right;
}

fn bootstrapConfidenceIntervals(
    regions: storage_mod.Regions,
    config: model.BootstrapConfig,
) ?model.BootstrapConfidenceIntervals {
    if (config.iterations == 0) return null;
    const len = regions.sorted.len;
    const median_rank = bench_bootstrap.nearestRank(len, 50, 100);
    const p75_rank = bench_bootstrap.nearestRank(len, 75, 100);
    const p95_rank = bench_bootstrap.nearestRank(len, 95, 100);
    const p99_rank = bench_bootstrap.nearestRank(len, 99, 100);
    var prng = std.Random.DefaultPrng.init(config.seed);
    const random = prng.random();
    for (0..config.iterations) |index| {
        bench_bootstrap.resampleCounts(random, regions.counts);
        var total: u128 = 0;
        for (regions.sorted, regions.counts) |value, count| total += @as(u128, value) * count;
        regions.means[index] = @as(f64, @floatFromInt(total)) /
            @as(f64, @floatFromInt(len));
        regions.medians[index] = @floatFromInt(
            bench_bootstrap.rankValue(u64, regions.sorted, regions.counts, median_rank),
        );
        regions.p75s[index] = @floatFromInt(
            bench_bootstrap.rankValue(u64, regions.sorted, regions.counts, p75_rank),
        );
        regions.p95s[index] = @floatFromInt(
            bench_bootstrap.rankValue(u64, regions.sorted, regions.counts, p95_rank),
        );
        regions.p99s[index] = @floatFromInt(
            bench_bootstrap.rankValue(u64, regions.sorted, regions.counts, p99_rank),
        );
    }

    std.mem.sort(f64, regions.means, {}, std.sort.asc(f64));
    std.mem.sort(f64, regions.medians, {}, std.sort.asc(f64));
    std.mem.sort(f64, regions.p75s, {}, std.sort.asc(f64));
    std.mem.sort(f64, regions.p95s, {}, std.sort.asc(f64));
    std.mem.sort(f64, regions.p99s, {}, std.sort.asc(f64));
    return .{
        .confidence = @as(f64, @floatFromInt(config.confidence_per_mille)) / 1000.0,
        .iterations = config.iterations,
        .seed = config.seed,
        .mean_ns = interval(regions.means, config.confidence_per_mille),
        .median_ns = interval(regions.medians, config.confidence_per_mille),
        .p75_ns = interval(regions.p75s, config.confidence_per_mille),
        .p95_ns = interval(regions.p95s, config.confidence_per_mille),
        .p99_ns = interval(regions.p99s, config.confidence_per_mille),
    };
}

fn interval(sorted: []const f64, confidence_per_mille: u16) model.ConfidenceInterval {
    const bounds = bench_bootstrap.interval(sorted, confidence_per_mille, .nearest_rank);
    return .{ .low_ns = bounds.low, .high_ns = bounds.high };
}
