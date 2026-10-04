const std = @import("std");

const sparse_mod = @import("../../../../root.zig").sparse;
const query_mod = @import("../../../root.zig");

const SparseQuery = query_mod.SparseQuery;

pub const spmv_csr_row_thread_density_bound: u64 = 4;

pub fn canonicalSparse(query: SparseQuery) bool {
    if (sparse_mod.sparseAccumulationDType(query.dtype) == null) return false;
    return switch (query.kind) {
        .csr_spmv => |facts| {
            if (facts.rows == 0 or facts.nnz == 0 or facts.x_extent == 0) return false;
            const extent_bound: u64 = @intCast(std.math.maxInt(i32));
            if (facts.rows + 1 > extent_bound) return false;
            return facts.nnz <= extent_bound and facts.x_extent <= extent_bound;
        },
        .coo_spmv, .csr_spmm, .ell_spmv, .sell_spmv => false,
    };
}

pub fn sparseResolvedSpmvStructure(query: SparseQuery) ?sparse_mod.SpmvCsrStructure {
    if (query.structure) |explicit| {
        return switch (explicit) {
            .row_thread => .row_thread,
            .row_warp => .row_warp,
            .element_thread, .row_column_thread => null,
        };
    }
    return switch (query.kind) {
        .csr_spmv => |facts| if (facts.nnz /
            facts.rows < spmv_csr_row_thread_density_bound) .row_thread else .row_warp,
        .coo_spmv, .csr_spmm, .ell_spmv, .sell_spmv => null,
    };
}
