const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const ScatterQuery = query_mod.ScatterQuery;

pub fn select(query: ScatterQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (query.outer == 0 or query.axis_size == 0 or query.updates == 0 or query.inner == 0) return null;
    for (registry.descriptors) |descriptor| {
        if (match_mod.scatterDescriptorMatches(descriptor, query)) return descriptor;
    }
    return null;
}
