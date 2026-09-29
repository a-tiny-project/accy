const library = @import("../../../root.zig");

const entry = library.entry;

pub fn spmvMatches(specialization: entry.Specialization, facts: anytype) bool {
    return specialization.operationIs(.{ .sparse = .ell_spmv }) and
        specialization.inputs.len == 3 and
        specialization.outputs.len == 1 and
        specialization.inputHasExtents(0, &.{ facts.slots, facts.rows }) and
        specialization.inputHasExtents(1, &.{ facts.slots, facts.rows }) and
        specialization.inputHasExtents(2, &.{facts.x_extent}) and
        specialization.outputHasExtents(0, &.{facts.rows});
}
