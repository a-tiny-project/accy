const std = @import("std");

const sparse_mod = @import("../../../../root.zig").sparse;
const query_mod = @import("../../../root.zig");

const SparseQuery = query_mod.SparseQuery;

pub fn canonicalSparse(query: SparseQuery) bool {
    if (sparse_mod.sparseAccumulationDType(query.dtype) == null) return false;
    return switch (query.kind) {
        .csr_spmm => |facts| {
            if (facts.rows == 0 or facts.columns == 0 or facts.nnz == 0 or facts.x_extent == 0) return false;
            const extent_bound: u64 = @intCast(std.math.maxInt(i32));
            if (facts.rows + 1 > extent_bound) return false;
            return facts.columns <= extent_bound and facts.nnz <= extent_bound and facts.x_extent <= extent_bound;
        },
        .coo_spmv, .csr_spmv, .ell_spmv, .sell_spmv => false,
    };
}

pub fn sparseResolvedSpmmStructure(query: SparseQuery) ?sparse_mod.SpmmCsrStructure {
    if (query.structure) |explicit| {
        return switch (explicit) {
            .row_column_thread => .row_column_thread,
            .element_thread, .row_thread, .row_warp => null,
        };
    }
    return switch (query.kind) {
        .csr_spmm => .row_column_thread,
        .coo_spmv, .csr_spmv, .ell_spmv, .sell_spmv => null,
    };
}
