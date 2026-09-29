const library = @import("../../../root.zig");

const entry = library.entry;

pub fn csrMatches(specialization: entry.Specialization, facts: anytype) bool {
    return specialization.operationIs(.{ .sparse = .csr_spmm }) and
        specialization.inputs.len == 4 and
        specialization.outputs.len == 1 and
        specialization.inputHasExtents(0, &.{facts.rows + 1}) and
        specialization.inputHasExtents(1, &.{facts.nnz}) and
        specialization.inputHasExtents(2, &.{facts.nnz}) and
        specialization.inputHasExtents(3, &.{ facts.x_extent, facts.columns }) and
        specialization.outputHasExtents(0, &.{ facts.rows, facts.columns });
}
