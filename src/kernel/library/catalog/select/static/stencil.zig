const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const StencilQuery = query_mod.StencilQuery;

pub fn select(query: StencilQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (query.rows == 0 or query.cols == 0) return null;
    return switch (query.kind) {
        .window => selectWindow(query),
    };
}

fn selectWindow(query: StencilQuery) ?Descriptor {
    for (registry.descriptors) |descriptor| {
        if (match_mod.stencilWindowDescriptorMatches(descriptor, query)) return descriptor;
    }
    return null;
}
