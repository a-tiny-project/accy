const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const RowNormalizationQuery = query_mod.RowNormalizationQuery;

pub fn select(query: RowNormalizationQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (query.rows == 0 or query.cols == 0) return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.rowNormalizationDescriptorMatches(descriptor, query)) return descriptor;
    }
    return null;
}
