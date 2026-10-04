const query_mod = @import("../../../root.zig");

const coo = @import("coo.zig");
const csr = @import("csr.zig");
const ell = @import("ell.zig");
const sell = @import("sell.zig");
const spmm = @import("spmm.zig");

const SparseQuery = query_mod.SparseQuery;

pub const spmv_csr_row_thread_density_bound = csr.spmv_csr_row_thread_density_bound;

pub fn canonicalSparse(query: SparseQuery) bool {
    return switch (query.kind) {
        .coo_spmv => coo.canonicalSparse(query),
        .csr_spmv => csr.canonicalSparse(query),
        .ell_spmv => ell.canonicalSparse(query),
        .sell_spmv => sell.canonicalSparse(query),
        .csr_spmm => spmm.canonicalSparse(query),
    };
}

pub const sparseResolvedCooStructure = coo.sparseResolvedCooStructure;
pub const sparseResolvedSpmvStructure = csr.sparseResolvedSpmvStructure;
pub const sparseResolvedEllStructure = ell.sparseResolvedEllStructure;
pub const sparseResolvedSellStructure = sell.sparseResolvedSellStructure;
pub const sparseResolvedSpmmStructure = spmm.sparseResolvedSpmmStructure;
