const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const SegmentedQuery = query_mod.SegmentedQuery;

pub fn select(query: SegmentedQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (query.segments == 0 or query.total == 0) return null;
    for (registry.descriptors) |descriptor| {
        if (match_mod.segmentSumDescriptorMatches(descriptor, query)) return descriptor;
    }
    return null;
}
