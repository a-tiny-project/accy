const std = @import("std");
const alloc_phase = @import("alloc_phase");
const stats = @import("root.zig");

const Storage = stats.Storage;
const BootstrapConfidenceIntervals = stats.BootstrapConfidenceIntervals;
const SampleSetCursor = stats.SampleSetCursor;
const IndexedDeltaTotals = stats.IndexedDeltaTotals;
const IndexedMemoryTotals = stats.IndexedMemoryTotals;
const percentile = stats.percentile;
const computeSampleStats = stats.computeSampleStats;
const computeSampleStatsWithBootstrap = stats.computeSampleStatsWithBootstrap;
const sampleSetValueCapacity = stats.sampleSetValueCapacity;
const nsPerUnit = stats.nsPerUnit;
const nsPerFloatUnit = stats.nsPerFloatUnit;

test "percentiles preserve the benchmark runner policy" {
    try std.testing.expectEqual(@as(u64, 0), percentile(&.{}, 50));
    try std.testing.expectEqual(@as(u64, 42), percentile(&.{42}, 99));
    const data = [_]u64{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    try std.testing.expectEqual(@as(u64, 60), percentile(&data, 50));
    try std.testing.expectEqual(@as(u64, 80), percentile(&data, 75));
    try std.testing.expectEqual(@as(u64, 100), percentile(&data, 99));
}

test "sample stats use benchmark-runner percentile policy" {
    const samples = [_]u64{ 100, 10, 40, 30, 20, 90, 80, 70, 60, 50 };
    var storage = try Storage.init(std.testing.allocator, .{ .samples = samples.len });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    const result = try computeSampleStats(&storage, &samples);

    try std.testing.expectEqual(@as(u64, 10), result.min_ns);
    try std.testing.expectEqual(@as(u64, 100), result.max_ns);
    try std.testing.expectEqual(@as(u64, 550), result.total_ns);
    try std.testing.expectEqual(@as(u64, 60), result.median_ns);
    try std.testing.expectEqual(@as(u64, 80), result.p75_ns);
    try std.testing.expectEqual(@as(u64, 100), result.p95_ns);
    try std.testing.expectEqual(@as(u64, 100), result.p99_ns);
    try std.testing.expect(result.confidence_intervals != null);
}

test "statistics storage rejects every limit at max plus one" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "bench_statistics_boundaries"),
        );
    }

    var storage = try Storage.init(std.testing.allocator, .{
        .samples = 3,
        .bootstrap_iterations = 20,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    try std.testing.expectError(error.EmptySampleSet, computeSampleStats(&storage, &.{}));
    try std.testing.expectError(
        error.SampleCapacityExceeded,
        computeSampleStats(&storage, &.{ 1, 2, 3, 4 }),
    );
    try std.testing.expectError(
        error.BootstrapIterationCapacityExceeded,
        computeSampleStatsWithBootstrap(&storage, &.{ 1, 2, 3 }, .{ .iterations = 21 }),
    );
    try std.testing.expectError(
        error.InvalidBootstrapConfidence,
        computeSampleStatsWithBootstrap(
            &storage,
            &.{ 1, 2, 3 },
            .{ .iterations = 1, .confidence_per_mille = 0 },
        ),
    );
    try std.testing.expectError(
        error.InvalidBootstrapConfidence,
        computeSampleStatsWithBootstrap(
            &storage,
            &.{ 1, 2, 3 },
            .{ .iterations = 1, .confidence_per_mille = 1001 },
        ),
    );
    try std.testing.expect(!storage.status().in_use);
    _ = try computeSampleStatsWithBootstrap(&storage, &.{ 1, 2, 3 }, .{ .iterations = 20 });
}

test "statistics storage preserves results and reusable state" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "bench_statistics_reuse"),
        );
    }

    var storage = try Storage.init(std.testing.allocator, .{
        .samples = 7,
        .bootstrap_iterations = 200,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    const samples = [_]u64{ 10, 20, 30, 40, 50, 60, 70 };
    const first = try computeSampleStatsWithBootstrap(
        &storage,
        &samples,
        .{ .iterations = 200, .seed = 99 },
    );
    try std.testing.expectEqual(BootstrapConfidenceIntervals{
        .confidence = 0.95,
        .iterations = 200,
        .seed = 99,
        .mean_ns = .{ .low_ns = 25.714285714285715, .high_ns = 54.285714285714285 },
        .median_ns = .{ .low_ns = 20, .high_ns = 60 },
        .p75_ns = .{ .low_ns = 30, .high_ns = 70 },
        .p95_ns = .{ .low_ns = 40, .high_ns = 70 },
        .p99_ns = .{ .low_ns = 40, .high_ns = 70 },
    }, first.confidence_intervals.?);
    var reversed = samples;
    std.mem.reverse(u64, &reversed);
    const second = try computeSampleStatsWithBootstrap(
        &storage,
        &reversed,
        .{ .iterations = 200, .seed = 99 },
    );
    try std.testing.expectEqual(first, second);
    try std.testing.expect(!storage.status().in_use);

    const regions = try storage.acquire(samples.len, .{ .iterations = 200 });
    _ = regions;
    try std.testing.expectError(
        error.StatisticsStorageInUse,
        storage.acquire(samples.len, .{ .iterations = 200 }),
    );
    storage.reset();
}

test "activated statistics storage performs no backing allocation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "bench_statistics_sealed_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "bench_statistics_sealed_foreign_risk"),
        );
    }

    const samples = [_]u64{ 13, 2, 11, 5, 7, 3, 17, 19, 23, 29, 31, 37, 41 };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var storage = try Storage.init(failing.allocator(), .{ .samples = samples.len });
    defer storage.deinit(failing.allocator());
    storage.activate();
    const alloc_index = failing.alloc_index;
    const result = try computeSampleStats(&storage, &samples);

    try std.testing.expectEqual(@as(usize, 1), alloc_index);
    try std.testing.expectEqual(alloc_index, failing.alloc_index);
    try std.testing.expectEqual(@as(usize, 40_156), failing.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 2), result.min_ns);
    try std.testing.expectEqual(@as(u64, 41), result.max_ns);
}

test "sample sets partition one exact caller region" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "bench_statistics_sets"),
        );
    }

    var values: [52]u64 = undefined;
    var cursor = SampleSetCursor.init(&values);
    const first = try cursor.take(1, 13);
    const partitioned = try cursor.take(3, 13);
    try std.testing.expectEqual(@as(usize, 52), try sampleSetValueCapacity(4, 13));
    try std.testing.expectEqual(@intFromPtr(&values), @intFromPtr(first[0].ptr));
    try std.testing.expectEqual(
        @intFromPtr(&values[13]),
        @intFromPtr(partitioned[0].ptr),
    );
    for (partitioned) |set| {
        try std.testing.expectEqualSlices(u64, &(@as([13]u64, @splat(0))), set);
    }
    try std.testing.expect(cursor.complete());
    try std.testing.expectError(error.SampleSetStorageTooSmall, cursor.take(1, 13));
    try std.testing.expect(cursor.complete());
}

test "sample sets need one exact caller acquisition" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const value_count = try sampleSetValueCapacity(4, 13);
    const values = try failing.allocator().alloc(u64, value_count);
    defer failing.allocator().free(values);
    var cursor = SampleSetCursor.init(values);
    _ = try cursor.take(4, 13);

    try std.testing.expect(cursor.complete());
    try std.testing.expectEqual(@as(usize, 1), failing.alloc_index);
    try std.testing.expectEqual(@as(usize, 416), failing.allocated_bytes);
}

test "indexed totals and unit rates retain zero denominator behavior" {
    var deltas = IndexedDeltaTotals(2){};
    deltas.record(0, 4, 16, 12);
    deltas.record(0, 8, 32, 24);
    try std.testing.expectEqual(@as(f64, 6), deltas.meanBefore(0, 2));
    try std.testing.expectEqual(@as(f64, 18), deltas.meanDelta(0, 2));

    var memory = IndexedMemoryTotals(1){};
    memory.record(0, 2, 1, 40);
    memory.record(0, 4, 3, 80);
    try std.testing.expectEqual(@as(f64, 3), memory.meanAllocCount(0, 2));
    try std.testing.expectEqual(@as(f64, 60), memory.meanAllocBytes(0, 2));
    try std.testing.expectEqual(@as(f64, 0), nsPerUnit(10, 0));
    try std.testing.expectEqual(@as(f64, 5), nsPerUnit(10, 2));
    try std.testing.expectEqual(@as(f64, 0), nsPerFloatUnit(10, 0));
    try std.testing.expectEqual(@as(f64, 2.5), nsPerFloatUnit(10, 4));
}

test "sample stats can disable bootstrap intervals" {
    var storage = try Storage.init(std.testing.allocator, .{
        .samples = 3,
        .bootstrap_iterations = 0,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    const result = try computeSampleStatsWithBootstrap(
        &storage,
        &.{ 10, 20, 30 },
        .{ .iterations = 0 },
    );
    try std.testing.expect(result.confidence_intervals == null);
}
