const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const ActivationQuery = query_mod.ActivationQuery;

pub fn select(query: ActivationQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (query.extent == 0) return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.activationDescriptorMatches(descriptor, query)) return descriptor;
    }
    return null;
}
