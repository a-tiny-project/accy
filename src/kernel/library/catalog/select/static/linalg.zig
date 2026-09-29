const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const BatchedMatrixProductQuery = query_mod.BatchedMatrixProductQuery;
const MatrixProductQuery = query_mod.MatrixProductQuery;
const MatrixVectorProductQuery = query_mod.MatrixVectorProductQuery;
const OuterProductQuery = query_mod.OuterProductQuery;

pub fn selectBatchedMatrixProduct(query: BatchedMatrixProductQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (!match_mod.canonicalBatchedMatrixProduct(query)) return null;
    const shape = match_mod.batchedMatrixProductShape(query.lhs_dims, query.rhs_dims, query.output_dims) orelse return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.batchedMatrixProductDescriptorMatches(descriptor, shape, query.schedule)) return descriptor;
    }
    return null;
}

pub fn selectMatrixProduct(query: MatrixProductQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (!match_mod.canonicalMatrixProduct(query)) return null;
    const shape = match_mod.matrixProductShape(query.lhs_dims, query.rhs_dims, query.output_dims) orelse return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.matrixProductDescriptorMatches(descriptor, shape, query.schedule, query.dtype)) return descriptor;
    }
    return null;
}

pub fn selectMatrixVectorProduct(query: MatrixVectorProductQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (!match_mod.canonicalMatrixVectorProduct(query)) return null;
    const shape = match_mod.matrixVectorProductShape(query.matrix_dims, query.vector_dims, query.output_dims) orelse return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.matrixVectorProductDescriptorMatches(descriptor, shape, query.schedule)) return descriptor;
    }
    return null;
}

pub fn selectOuterProduct(query: OuterProductQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (!match_mod.canonicalOuterProduct(query)) return null;
    const shape = match_mod.outerProductShape(query.lhs_dims, query.rhs_dims, query.output_dims) orelse return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.outerProductDescriptorMatches(descriptor, shape, query.schedule)) return descriptor;
    }
    return null;
}
