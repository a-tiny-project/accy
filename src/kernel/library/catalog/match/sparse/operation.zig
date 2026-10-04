const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const coo = @import("coo.zig");
const csr = @import("csr.zig");
const ell = @import("ell.zig");
const sell = @import("sell.zig");
const spmm = @import("spmm.zig");

const entry = library.entry;
const SparseQuery = catalog.SparseQuery;

pub fn sparseOperationMatches(specialization: entry.Specialization, query: SparseQuery) bool {
    return switch (query.kind) {
        .coo_spmv => |facts| coo.spmvMatches(specialization, facts),
        .csr_spmv => |facts| csr.spmvMatches(specialization, facts),
        .ell_spmv => |facts| ell.spmvMatches(specialization, facts),
        .sell_spmv => |facts| sell.spmvMatches(specialization, facts, query.dtype),
        .csr_spmm => |facts| spmm.csrMatches(specialization, facts),
    };
}
