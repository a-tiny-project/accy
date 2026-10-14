const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const ReductionQuery = query_mod.ReductionQuery;

pub fn select(query: ReductionQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    const shape = match_mod.reductionShape(query) orelse return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.reductionDescriptorMatches(descriptor, query.kind, shape)) return descriptor;
    }
    return null;
}
