const std = @import("std");

const descriptor_mod = @import("../root.zig");
const entry = @import("../../root.zig").entry;
const compaction = @import("../../root.zig").compaction;
const match_mod = @import("../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const FilterQuery = query_mod.FilterQuery;

pub const FilterCandidateDescriptors = struct {
    count: usize = 0,
    items: [8]OwnedDescriptor = undefined,

    pub fn slice(self: *const FilterCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *FilterCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectFilter(backing_allocator: std.mem.Allocator, query: FilterQuery) !?OwnedDescriptor {
    if (!canonicalFilter(query)) return null;
    const instance = filterFamilyInstance(query) orelse return null;
    return try filterDescriptorForInstance(backing_allocator, instance, query);
}

pub fn selectFilterCandidates(
    backing_allocator: std.mem.Allocator,
    query: FilterQuery,
) !FilterCandidateDescriptors {
    var result = FilterCandidateDescriptors{};
    errdefer result.deinit();

    if (!canonicalFilter(query)) return result;
    if (query.schedule != null) {
        if (try selectFilter(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    const thread_candidates = compaction.filterThreadCandidatesForExtent(query.extent);
    for (thread_candidates.slice()) |threads| {
        const instance = compaction.Filter{
            .extent = query.extent,
            .dtype = query.dtype,
            .predicate = filterInstancePredicate(query.predicate),
            .threads = threads,
        };
        if (try filterDescriptorForInstance(backing_allocator, instance, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
    }
    return result;
}

fn filterInstancePredicate(predicate: query_mod.CompactionPredicateKind) entry.CompactionPredicate {
    return switch (predicate) {
        .nonzero => .nonzero,
        .greater_than => .greater_than,
    };
}

fn canonicalFilter(query: FilterQuery) bool {
    if (!compaction.filterDTypeSupported(query.dtype)) return false;
    return query.extent != 0;
}

fn filterDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: compaction.Filter,
    query: FilterQuery,
) !?OwnedDescriptor {
    if (!compaction.filterInstanceValid(instance)) return null;
    var specialization = try compaction.filterFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try compaction.filterFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try compaction.filterFamilyTarget(lifetime_allocator, instance),
            .version = compaction.filter_family_version,
            .layer = .logical,
            .category = .compaction,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.filterDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn filterFamilyInstance(query: FilterQuery) ?compaction.Filter {
    var instance = compaction.Filter{
        .extent = query.extent,
        .dtype = query.dtype,
        .predicate = filterInstancePredicate(query.predicate),
        .threads = compaction.filterThreadsForExtent(query.extent),
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                instance.threads = threads;
            },
        }
    }
    return instance;
}
