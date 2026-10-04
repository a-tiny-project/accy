const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const geometry = @import("../../../root.zig").geometry;
const indexing = @import("../../../root.zig").indexing;
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const ScatterQuery = query_mod.ScatterQuery;

pub const ScatterCandidateDescriptors = struct {
    count: usize = 0,
    items: [geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const ScatterCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *ScatterCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectScatter(backing_allocator: std.mem.Allocator, query: ScatterQuery) !?OwnedDescriptor {
    if (!canonicalScatter(query)) return null;
    const instance = scatterFamilyInstance(query) orelse return null;
    return try scatterDescriptorForInstance(backing_allocator, instance, query);
}

pub fn selectScatterCandidates(
    backing_allocator: std.mem.Allocator,
    query: ScatterQuery,
) !ScatterCandidateDescriptors {
    var result = ScatterCandidateDescriptors{};
    errdefer result.deinit();

    if (!canonicalScatter(query)) return result;
    if (query.schedule != null) {
        if (try selectScatter(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    const total = query.outer * query.axis_size * query.inner;
    const thread_candidates = indexing.scatterThreadCandidatesForTotal(total);
    for (thread_candidates.slice()) |threads| {
        const instance = indexing.Scatter{
            .outer = query.outer,
            .axis_size = query.axis_size,
            .updates = query.updates,
            .inner = query.inner,
            .dtype = query.dtype,
            .threads = threads,
        };
        if (try scatterDescriptorForInstance(backing_allocator, instance, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
    }
    return result;
}

fn canonicalScatter(query: ScatterQuery) bool {
    if (!indexing.scatterDTypeSupported(query.dtype)) return false;
    return query.outer != 0 and query.axis_size != 0 and query.updates != 0 and query.inner != 0;
}

fn scatterDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: indexing.Scatter,
    query: ScatterQuery,
) !?OwnedDescriptor {
    var specialization = try indexing.scatterFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try indexing.scatterFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try indexing.scatterFamilyTarget(lifetime_allocator, instance),
            .version = indexing.scatter_family_version,
            .layer = .logical,
            .category = .indexing,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.scatterDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn scatterFamilyInstance(query: ScatterQuery) ?indexing.Scatter {
    const total = query.outer * query.axis_size * query.inner;
    var instance = indexing.Scatter{
        .outer = query.outer,
        .axis_size = query.axis_size,
        .updates = query.updates,
        .inner = query.inner,
        .dtype = query.dtype,
        .threads = indexing.scatterThreadsForTotal(total),
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
