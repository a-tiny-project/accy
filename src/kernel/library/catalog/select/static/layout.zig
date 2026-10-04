const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const LayoutQuery = query_mod.LayoutQuery;
const TransposeQuery = query_mod.TransposeQuery;

pub fn select(query: LayoutQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    return switch (query.kind) {
        .transpose => selectTranspose(query),
    };
}

fn selectTranspose(query: TransposeQuery) ?Descriptor {
    const shape = match_mod.transposeShape(query) orelse return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.transposeDescriptorMatches(descriptor, query, shape)) return descriptor;
    }
    return null;
}
