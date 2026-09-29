const std = @import("std");

const library = @import("../../root.zig");
const model = @import("model.zig");
const naming = @import("naming.zig");
const shape = @import("shape.zig");

const entry = library.entry;
const geometry = library.geometry;
const tuning = library.tuning;
const Histogram = model.Histogram;
const HistogramVariant = model.HistogramVariant;

const histogram_thread_caps = geometry.ThreadCaps1D{};

pub const HistogramResolvedSchedule = struct {
    variant: HistogramVariant,
    threads: u32,
};

pub fn histogramTuningExtents(instance: Histogram) [2]u64 {
    return .{ instance.bins, instance.count };
}

pub fn histogramTuningOperation(instance: Histogram) entry.Operation {
    _ = instance;
    return .{ .indexing = .histogram };
}

pub fn histogramFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: Histogram,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try shape.histogramFamilyFingerprint(backing_allocator, instance);
    const extents = histogramTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(histogramTuningOperation(instance)),
        instance.dtype,
        model.histogram_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn resolveHistogramSchedule(
    backing_allocator: std.mem.Allocator,
    reader: tuning.FamilyTuningReader,
    instance: Histogram,
) !?HistogramResolvedSchedule {
    const key = try histogramFamilyTuningKey(backing_allocator, reader.device_fingerprint, instance);
    const record = reader.table.find(key) orelse return null;
    const thread_candidates = histogramThreadCandidatesForCount(instance.count);
    const variants = [_]HistogramVariant{ .direct, .shared_bins };
    for (variants) |variant| {
        for (thread_candidates.slice()) |threads| {
            var candidate = instance;
            candidate.variant = variant;
            candidate.threads = threads;
            if (variant == .shared_bins and candidate.bins > model.histogram_shared_bins_cap) continue;
            const target = try naming.histogramFamilyTarget(backing_allocator, candidate);
            defer backing_allocator.free(target);
            if (std.mem.eql(u8, target, record.target)) {
                return .{ .variant = variant, .threads = threads };
            }
        }
    }
    return null;
}

pub fn histogramThreadsForCount(count: u64) u32 {
    return geometry.threadsForExtent(count, histogram_thread_caps);
}

pub fn histogramThreadCandidatesForCount(count: u64) geometry.Thread1DCandidates {
    return geometry.threadCandidatesForExtent(count, histogram_thread_caps);
}

test "histogram tuning resolves schedule winners through family targets" {
    const allocator = std.testing.allocator;
    const device: u64 = 0xfeed_dead_beef_2684;
    const probe = Histogram{ .bins = 64, .count = 8192 };

    const histogram_key = try histogramFamilyTuningKey(allocator, device, probe);
    try std.testing.expectEqual(entry.operationFingerprint(.{ .indexing = .histogram }), histogram_key.operation_fingerprint);

    const thread_candidates = histogramThreadCandidatesForCount(probe.count);
    var winner = probe;
    winner.variant = .shared_bins;
    winner.threads = thread_candidates.slice()[0];
    const winner_target = try naming.histogramFamilyTarget(allocator, winner);
    defer allocator.free(winner_target);

    const records = [_]tuning.FamilyTuningRecord{.{
        .key = histogram_key,
        .target = winner_target,
        .winner_median_ns = 300,
        .runner_up_median_ns = 700,
        .sample_count = 30,
    }};
    const reader = tuning.FamilyTuningReader{
        .device_fingerprint = device,
        .table = .{ .records = records[0..] },
    };

    const resolved = (try resolveHistogramSchedule(allocator, reader, probe)) orelse
        return error.TestExpectedSchedule;
    try std.testing.expectEqual(HistogramVariant.shared_bins, resolved.variant);
    try std.testing.expectEqual(winner.threads, resolved.threads);
}
