const std = @import("std");

const sparse_mod = @import("../../../../root.zig").sparse;
const query_mod = @import("../../../root.zig");

const SparseQuery = query_mod.SparseQuery;

pub fn canonicalSparse(query: SparseQuery) bool {
    if (sparse_mod.sparseAccumulationDType(query.dtype) == null) return false;
    return switch (query.kind) {
        .sell_spmv => |facts| {
            if (facts.rows == 0 or facts.slice_size == 0 or facts.values_size == 0 or facts.x_extent == 0) return false;
            const extent_bound: u64 = @intCast(std.math.maxInt(i32));
            if (facts.rows > extent_bound or facts.slice_size > extent_bound or facts.values_size > extent_bound or facts.x_extent > extent_bound) return false;
            const slices = sparse_mod.spmvSellSliceCount(.{
                .rows = facts.rows,
                .slice_size = facts.slice_size,
                .values_size = facts.values_size,
                .x_extent = facts.x_extent,
            });
            if (slices + 1 > extent_bound) return false;
            return true;
        },
        .coo_spmv, .csr_spmv, .csr_spmm, .ell_spmv => false,
    };
}

pub fn sparseResolvedSellStructure(query: SparseQuery) ?sparse_mod.SpmvSellStructure {
    if (query.structure) |explicit| {
        return switch (explicit) {
            .row_thread => .row_thread,
            .element_thread, .row_warp, .row_column_thread => null,
        };
    }
    return switch (query.kind) {
        .sell_spmv => .row_thread,
        .coo_spmv, .csr_spmv, .csr_spmm, .ell_spmv => null,
    };
}
