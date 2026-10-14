const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const common = @import("../root.zig");

const entry = library.entry;
const SparseQuery = catalog.SparseQuery;
const specializationThreadgroup1DMatches = common.specializationThreadgroup1DMatches;
const specializationThreadgroup2DMatches = common.specializationThreadgroup2DMatches;

pub fn sparseScheduleMatches(specialization: entry.Specialization, query: SparseQuery) bool {
    const requested = query.schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| switch (query.kind) {
            .coo_spmv, .csr_spmv, .ell_spmv, .sell_spmv => specializationThreadgroup1DMatches(
                specialization,
                threads,
            ),
            .csr_spmm => false,
        },
        .thread_blocks_2d => |threads| switch (query.kind) {
            .coo_spmv, .csr_spmv, .ell_spmv, .sell_spmv => false,
            .csr_spmm => specializationThreadgroup2DMatches(specialization, threads),
        },
    };
}
