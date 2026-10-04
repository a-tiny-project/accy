const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const AttentionQuery = query_mod.AttentionQuery;

pub fn select(query: AttentionQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (query.kind != .scaled_dot_product) return null;
    const shape = match_mod.attentionShape(query) orelse return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.attentionDescriptorMatches(descriptor, query, shape)) return descriptor;
    }
    return null;
}
