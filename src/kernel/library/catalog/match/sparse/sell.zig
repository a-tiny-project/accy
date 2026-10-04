const library = @import("../../../root.zig");

const entry = library.entry;
const sparse_library = library.sparse;

pub fn spmvMatches(specialization: entry.Specialization, facts: anytype, dtype: anytype) bool {
    const accumulation_dtype = sparse_library.sparseAccumulationDType(dtype) orelse return false;
    const slice_offsets_extent = sparse_library.spmvSellSliceCount(.{
        .rows = facts.rows,
        .slice_size = facts.slice_size,
        .values_size = facts.values_size,
        .x_extent = facts.x_extent,
        .dtype = dtype,
        .accumulation_dtype = accumulation_dtype,
    }) + 1;
    return specialization.operationIs(.{ .sparse = .sell_spmv }) and
        specialization.inputs.len == 4 and
        specialization.outputs.len == 1 and
        specialization.static_parameters.len == 1 and
        specialization.staticParameterMatches(
            sparse_library.spmv_sell_slice_size_parameter,
            facts.slice_size,
        ) and
        specialization.inputHasExtents(0, &.{slice_offsets_extent}) and
        specialization.inputHasExtents(1, &.{facts.values_size}) and
        specialization.inputHasExtents(2, &.{facts.values_size}) and
        specialization.inputHasExtents(3, &.{facts.x_extent}) and
        specialization.outputHasExtents(0, &.{facts.rows});
}
