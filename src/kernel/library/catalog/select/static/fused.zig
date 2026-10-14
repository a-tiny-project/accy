const descriptor_mod = @import("../../root.zig");
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;
const registry = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const FusedQuery = query_mod.FusedQuery;
const FusedVectorQuery = query_mod.FusedVectorQuery;
const FusedMatrixProductQuery = query_mod.FusedMatrixProductQuery;
const FusedMatrixVectorProductQuery = query_mod.FusedMatrixVectorProductQuery;
const FusedRowNormalizationQuery = query_mod.FusedRowNormalizationQuery;

pub fn select(query: FusedQuery) ?Descriptor {
    return switch (query) {
        .vector => |vector| selectVector(vector),
        .matrix_product => |matrix_product| selectMatrixProduct(matrix_product),
        .matrix_vector_product => |matrix_vector_product| selectMatrixVectorProduct(
            matrix_vector_product,
        ),
        .row_normalization => |row_normalization| selectRowNormalization(row_normalization),
    };
}

fn selectVector(query: FusedVectorQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (query.extent == 0) return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.fusedVectorDescriptorMatches(descriptor, query)) return descriptor;
    }
    return null;
}

fn selectMatrixProduct(query: FusedMatrixProductQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    const shape = match_mod.fusedMatrixProductShape(query) orelse return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.fusedMatrixProductDescriptorMatches(descriptor, query, shape)) {
            return descriptor;
        }
    }
    return null;
}

fn selectMatrixVectorProduct(query: FusedMatrixVectorProductQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    const shape = match_mod.fusedMatrixVectorProductShape(query) orelse return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.fusedMatrixVectorProductDescriptorMatches(descriptor, query, shape)) {
            return descriptor;
        }
    }
    return null;
}

fn selectRowNormalization(query: FusedRowNormalizationQuery) ?Descriptor {
    if (query.dtype != .f32) return null;
    if (query.rows == 0 or query.cols == 0) return null;

    for (registry.descriptors) |descriptor| {
        if (match_mod.fusedRowNormalizationDescriptorMatches(descriptor, query)) return descriptor;
    }
    return null;
}
