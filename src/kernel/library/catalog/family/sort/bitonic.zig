const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const sort_mod = @import("../../../root.zig").sort;
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const SortQuery = query_mod.SortQuery;

pub fn selectBitonicBlockSort(
    backing_allocator: std.mem.Allocator,
    query: SortQuery,
) !?OwnedDescriptor {
    var instance = sort_mod.BitonicBlock{
        .extent = query.extent,
        .threads = sort_mod.bitonicBlockThreadsForExtent(query.extent) orelse return null,
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                instance.threads = threads;
            },
        }
    }
    if (!sort_mod.bitonicBlockInstanceValid(instance)) return null;
    var specialization = try sort_mod.bitonicBlockFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const target = try sort_mod.bitonicBlockFamilyTarget(lifetime_allocator, instance);
    const descriptor = Descriptor{
        .name = target,
        .metadata = .{
            .target = target,
            .version = sort_mod.bitonic_block_family_version,
            .layer = .logical,
            .category = .sort,
            .specialization = specialization.value,
        },
    };
    return .{ .descriptor = descriptor, .specialization = specialization };
}
