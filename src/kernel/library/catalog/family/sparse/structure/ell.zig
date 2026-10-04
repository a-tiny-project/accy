const std = @import("std");

const sparse_mod = @import("../../../../root.zig").sparse;
const query_mod = @import("../../../root.zig");

const SparseQuery = query_mod.SparseQuery;

pub fn canonicalSparse(query: SparseQuery) bool {
    if (sparse_mod.sparseAccumulationDType(query.dtype) == null) return false;
    return switch (query.kind) {
        .ell_spmv => |facts| {
            if (facts.rows == 0 or facts.slots == 0 or facts.x_extent == 0) return false;
            const extent_bound: u64 = @intCast(std.math.maxInt(i32));
            return facts.rows <= extent_bound and
                facts.slots <= extent_bound and facts.x_extent <= extent_bound;
        },
        .coo_spmv, .csr_spmv, .csr_spmm, .sell_spmv => false,
    };
}

pub fn sparseResolvedEllStructure(query: SparseQuery) ?sparse_mod.SpmvEllStructure {
    if (query.structure) |explicit| {
        return switch (explicit) {
            .row_thread => .row_thread,
            .element_thread, .row_warp, .row_column_thread => null,
        };
    }
    return switch (query.kind) {
        .ell_spmv => .row_thread,
        .coo_spmv, .csr_spmv, .csr_spmm, .sell_spmv => null,
    };
}
