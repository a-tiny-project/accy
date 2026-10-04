const std = @import("std");

const descriptor_mod = @import("../root.zig");
const geometry = @import("../../root.zig").geometry;
const histogram_mod = @import("../../root.zig").histogram;
const match_mod = @import("../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const HistogramQuery = query_mod.HistogramQuery;

pub const HistogramCandidateDescriptors = struct {
    count: usize = 0,
    items: [2 * geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const HistogramCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *HistogramCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectHistogram(
    backing_allocator: std.mem.Allocator,
    query: HistogramQuery,
) !?OwnedDescriptor {
    if (!canonicalHistogram(query)) return null;
    const instance = histogramFamilyInstance(query) orelse return null;
    return try histogramDescriptorForInstance(backing_allocator, instance, query);
}

pub fn selectHistogramCandidates(
    backing_allocator: std.mem.Allocator,
    query: HistogramQuery,
) !HistogramCandidateDescriptors {
    var result = HistogramCandidateDescriptors{};
    errdefer result.deinit();

    if (!canonicalHistogram(query)) return result;
    if (query.schedule != null) {
        if (try selectHistogram(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    const thread_candidates = histogram_mod.histogramThreadCandidatesForCount(query.count);
    const variants = [_]histogram_mod.HistogramVariant{ .direct, .shared_bins };
    for (variants) |variant| {
        for (thread_candidates.slice()) |threads| {
            const instance = histogram_mod.Histogram{
                .bins = query.bins,
                .count = query.count,
                .dtype = query.dtype,
                .binning = query.binning,
                .variant = variant,
                .threads = threads,
            };
            if (!histogram_mod.histogramInstanceValid(instance)) continue;
            if (result.count >= result.items.len) break;
            if (try histogramDescriptorForInstance(
                backing_allocator,
                instance,
                query,
            )) |descriptor| {
                result.items[result.count] = descriptor;
                result.count += 1;
            }
        }
    }
    return result;
}

fn canonicalHistogram(query: HistogramQuery) bool {
    if (!histogram_mod.histogramDTypeSupported(query.dtype)) return false;
    return query.bins != 0 and query.count != 0;
}

fn histogramDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: histogram_mod.Histogram,
    query: HistogramQuery,
) !?OwnedDescriptor {
    var specialization = try histogram_mod.histogramFamilySpecialization(
        backing_allocator,
        instance,
    );
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try histogram_mod.histogramFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try histogram_mod.histogramFamilyTarget(lifetime_allocator, instance),
            .version = histogram_mod.histogram_family_version,
            .layer = .logical,
            .category = .indexing,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.histogramDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn histogramFamilyInstance(query: HistogramQuery) ?histogram_mod.Histogram {
    var instance = histogram_mod.Histogram{
        .bins = query.bins,
        .count = query.count,
        .dtype = query.dtype,
        .binning = query.binning,
        .threads = histogram_mod.histogramThreadsForCount(query.count),
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                if (@as(u64, threads) > query.count) return null;
                instance.threads = threads;
            },
            .shared_bins => |threads| {
                if (threads == 0) return null;
                if (@as(u64, threads) > query.count) return null;
                instance.variant = .shared_bins;
                instance.threads = threads;
            },
        }
    }
    if (!histogram_mod.histogramInstanceValid(instance)) return null;
    return instance;
}
