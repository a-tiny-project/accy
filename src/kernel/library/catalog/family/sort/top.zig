const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const sort_mod = @import("../../../root.zig").sort;
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const SortQuery = query_mod.SortQuery;

pub fn selectTopKBlock(backing_allocator: std.mem.Allocator, query: SortQuery) !?OwnedDescriptor {
    if (query.dtype != .i32) return null;
    if (query.k == 0 or query.k > query.extent) return null;
    const structure = query.structure orelse .top_k_block;
    return switch (structure) {
        .top_k_block => selectTopKBlockKeys(backing_allocator, query),
        .top_k_block_pairs => selectTopKBlockPairs(backing_allocator, query),
        .radix_split, .radix_digit, .bitonic_block => null,
    };
}

fn selectTopKBlockKeys(backing_allocator: std.mem.Allocator, query: SortQuery) !?OwnedDescriptor {
    var instance = sort_mod.TopKBlock{
        .extent = query.extent,
        .k = query.k,
        .threads = sort_mod.bitonicBlockThreadsForExtent(query.extent) orelse return null,
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                instance.threads = threads;
            },
        }
    }
    if (!sort_mod.topKBlockInstanceValid(instance)) return null;
    var specialization = try sort_mod.topKBlockFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try sort_mod.topKBlockFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try sort_mod.topKBlockFamilyTarget(lifetime_allocator, instance),
            .version = sort_mod.top_k_block_family_version,
            .layer = .logical,
            .category = .sort,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.topKBlockDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn selectTopKBlockPairs(backing_allocator: std.mem.Allocator, query: SortQuery) !?OwnedDescriptor {
    var instance = sort_mod.TopKBlockPairs{
        .extent = query.extent,
        .k = query.k,
        .threads = sort_mod.bitonicBlockThreadsForExtent(query.extent) orelse return null,
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                instance.threads = threads;
            },
        }
    }
    if (!sort_mod.topKBlockPairsInstanceValid(instance)) return null;
    var specialization = try sort_mod.topKBlockPairsFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try sort_mod.topKBlockPairsFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try sort_mod.topKBlockPairsFamilyTarget(lifetime_allocator, instance),
            .version = sort_mod.top_k_block_pairs_family_version,
            .layer = .logical,
            .category = .sort,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.topKBlockPairsDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}
