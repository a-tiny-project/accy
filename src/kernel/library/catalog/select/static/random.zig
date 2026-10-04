const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const RandomQuery = query_mod.RandomQuery;

pub fn select(query: RandomQuery) ?Descriptor {
    if (query.count == 0) return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.randomDescriptorMatches(descriptor, query)) return descriptor;
    }
    return null;
}
