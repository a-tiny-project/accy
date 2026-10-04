const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const FilterQuery = query_mod.FilterQuery;

pub fn select(query: FilterQuery) ?Descriptor {
    if (query.extent == 0) return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.filterDescriptorMatches(descriptor, query)) return descriptor;
    }
    return null;
}
