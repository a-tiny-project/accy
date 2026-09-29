const std = @import("std");

const descriptor_mod = @import("../root.zig");
const geometry = @import("../../root.zig").geometry;
const segmented = @import("../../root.zig").segmented;
const match_mod = @import("../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const SegmentedQuery = query_mod.SegmentedQuery;

pub const SegmentSumCandidateDescriptors = struct {
    count: usize = 0,
    items: [2 * geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const SegmentSumCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *SegmentSumCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectSegmentSum(backing_allocator: std.mem.Allocator, query: SegmentedQuery) !?OwnedDescriptor {
    if (!canonicalSegmentSum(query)) return null;
    const instance = segmentSumFamilyInstance(query) orelse return null;
    return try segmentSumDescriptorForInstance(backing_allocator, instance, query);
}

pub fn selectSegmentSumCandidates(
    backing_allocator: std.mem.Allocator,
    query: SegmentedQuery,
) !SegmentSumCandidateDescriptors {
    var result = SegmentSumCandidateDescriptors{};
    errdefer result.deinit();

    if (!canonicalSegmentSum(query)) return result;
    if (query.schedule != null) {
        if (try selectSegmentSum(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    const thread_candidates = segmented.segmentSumThreadCandidatesForSegments(query.segments);
    for (thread_candidates.slice()) |threads| {
        const instance = segmented.SegmentSum{
            .segments = query.segments,
            .total = query.total,
            .dtype = query.dtype,
            .threads = threads,
        };
        if (try segmentSumDescriptorForInstance(backing_allocator, instance, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
    }

    const warp_extent = query.segments * segmented.segment_sum_warp_size;
    const warp_candidates = segmented.segmentSumThreadCandidatesForSegments(warp_extent);
    for (warp_candidates.slice()) |threads| {
        if (!segmented.segmentSumGranularityValid(.warp, threads)) continue;
        const instance = segmented.SegmentSum{
            .segments = query.segments,
            .total = query.total,
            .dtype = query.dtype,
            .granularity = .warp,
            .threads = threads,
        };
        if (try segmentSumDescriptorForInstance(backing_allocator, instance, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
    }
    return result;
}

fn canonicalSegmentSum(query: SegmentedQuery) bool {
    if (query.kind != .segment_sum) return false;
    if (!segmented.segmentSumDTypeSupported(query.dtype)) return false;
    return query.segments != 0 and query.total != 0;
}

fn segmentSumDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: segmented.SegmentSum,
    query: SegmentedQuery,
) !?OwnedDescriptor {
    var specialization = try segmented.segmentSumFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try segmented.segmentSumFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try segmented.segmentSumFamilyTarget(lifetime_allocator, instance),
            .version = segmented.segment_sum_family_version,
            .layer = .logical,
            .category = .segmented,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.segmentSumDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn segmentSumFamilyInstance(query: SegmentedQuery) ?segmented.SegmentSum {
    var instance = segmented.SegmentSum{
        .segments = query.segments,
        .total = query.total,
        .dtype = query.dtype,
        .threads = segmented.segmentSumThreadsForSegments(query.segments),
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                if (@as(u64, threads) > query.segments) return null;
                instance.threads = threads;
            },
            .warp_blocks => |threads| {
                if (!segmented.segmentSumGranularityValid(.warp, threads)) return null;
                if (@as(u64, threads) > query.segments * segmented.segment_sum_warp_size) return null;
                instance.granularity = .warp;
                instance.threads = threads;
            },
        }
    }
    return instance;
}
