const std = @import("std");

const sparse_mod = @import("../../../../root.zig").sparse;
const query_mod = @import("../../../root.zig");

const SparseQuery = query_mod.SparseQuery;

pub fn canonicalSparse(query: SparseQuery) bool {
    if (sparse_mod.sparseAccumulationDType(query.dtype) == null) return false;
    return switch (query.kind) {
        .coo_spmv => |facts| {
            const structure = sparseResolvedCooStructure(query) orelse return false;
            if (sparse_mod.spmvCooAccumulationDTypeForStructure(structure, query.dtype) == null) {
                return false;
            }
            if (facts.rows == 0 or facts.nnz == 0 or facts.x_extent == 0) return false;
            const extent_bound: u64 = @intCast(std.math.maxInt(i32));
            return facts.rows <= extent_bound and
                facts.nnz <= extent_bound and facts.x_extent <= extent_bound;
        },
        .csr_spmv, .csr_spmm, .ell_spmv, .sell_spmv => false,
    };
}

pub fn sparseResolvedCooStructure(query: SparseQuery) ?sparse_mod.SpmvCooStructure {
    if (query.structure) |explicit| {
        return switch (explicit) {
            .element_thread => .element_thread,
            .row_thread => .row_thread,
            .row_warp, .row_column_thread => null,
        };
    }
    return switch (query.kind) {
        .coo_spmv => sparse_mod.spmvCooDefaultStructure(query.dtype),
        .csr_spmv, .csr_spmm, .ell_spmv, .sell_spmv => null,
    };
}
