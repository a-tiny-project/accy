const std = @import("std");

const descriptor_mod = @import("../root.zig");
const geometry = @import("../../root.zig").geometry;
const indexing = @import("../../root.zig").indexing;
const match_mod = @import("../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const GatherQuery = query_mod.GatherQuery;

pub const GatherCandidateDescriptors = struct {
    count: usize = 0,
    items: [geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const GatherCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *GatherCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectGather(backing_allocator: std.mem.Allocator, query: GatherQuery) !?OwnedDescriptor {
    if (!canonicalGather(query)) return null;
    const instance = gatherFamilyInstance(query) orelse return null;
    return try gatherDescriptorForInstance(backing_allocator, instance, query);
}

pub fn selectGatherCandidates(
    backing_allocator: std.mem.Allocator,
    query: GatherQuery,
) !GatherCandidateDescriptors {
    var result = GatherCandidateDescriptors{};
    errdefer result.deinit();

    if (!canonicalGather(query)) return result;
    if (query.schedule != null) {
        if (try selectGather(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    const total = query.outer * query.gathered * query.inner;
    const thread_candidates = indexing.gatherThreadCandidatesForTotal(total);
    for (thread_candidates.slice()) |threads| {
        const instance = indexing.Gather{
            .outer = query.outer,
            .axis_size = query.axis_size,
            .gathered = query.gathered,
            .inner = query.inner,
            .dtype = query.dtype,
            .threads = threads,
        };
        if (try gatherDescriptorForInstance(backing_allocator, instance, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
    }
    return result;
}

fn canonicalGather(query: GatherQuery) bool {
    if (!indexing.gatherDTypeSupported(query.dtype)) return false;
    return query.outer != 0 and query.axis_size != 0 and query.gathered != 0 and query.inner != 0;
}

fn gatherDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: indexing.Gather,
    query: GatherQuery,
) !?OwnedDescriptor {
    var specialization = try indexing.gatherFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try indexing.gatherFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try indexing.gatherFamilyTarget(lifetime_allocator, instance),
            .version = indexing.gather_family_version,
            .layer = .logical,
            .category = .indexing,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.gatherDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn gatherFamilyInstance(query: GatherQuery) ?indexing.Gather {
    const total = query.outer * query.gathered * query.inner;
    var instance = indexing.Gather{
        .outer = query.outer,
        .axis_size = query.axis_size,
        .gathered = query.gathered,
        .inner = query.inner,
        .dtype = query.dtype,
        .threads = indexing.gatherThreadsForTotal(total),
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                if (@as(u64, threads) > total) return null;
                instance.threads = threads;
            },
        }
    }
    return instance;
}
