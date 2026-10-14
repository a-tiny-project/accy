const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const RowNormalizationQuery = catalog.RowNormalizationQuery;
const RowNormalizationSchedule = catalog.RowNormalizationSchedule;

const selectableSpecialization = common.selectableSpecialization;
const specializationThreadgroup2DMatches = common.specializationThreadgroup2DMatches;

pub fn rowNormalizationDescriptorMatches(
    descriptor: Descriptor,
    query: RowNormalizationQuery,
) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .normalization) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .row_normalization = query.kind })) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len < 1 or specialization.outputs.len != 1) return false;
    if (!specialization.inputHasExtents(0, &.{ query.rows, query.cols })) return false;
    if (!specialization.outputHasExtents(0, &.{ query.rows, query.cols })) return false;
    if (!rowNormalizationScheduleMatches(specialization, query.schedule)) return false;
    return switch (query.kind) {
        .softmax, .log_softmax => rowDistributionDescriptorMatches(
            specialization,
            query.rows,
            query.cols,
        ),
        .rmsnorm => |parameterization| rowRmsNormDescriptorMatches(
            specialization,
            query.rows,
            query.cols,
            parameterization,
        ),
        .layernorm => |parameterization| rowLayerNormDescriptorMatches(
            specialization,
            query.rows,
            query.cols,
            parameterization,
        ),
    };
}
pub fn rowNormalizationScheduleMatches(
    specialization: entry.Specialization,
    schedule: ?RowNormalizationSchedule,
) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup2DMatches(specialization, threads),
    };
}
fn rowDistributionDescriptorMatches(
    specialization: entry.Specialization,
    rows: u64,
    cols: u64,
) bool {
    return specialization.inputs.len == 1 and
        specialization.reductions.len == 2 and
        specialization.reduction_reuse.len == 2 and
        specialization.reductionMatches(0, .{
            .name = "row_max",
            .operator = .maximum,
            .extents = &.{cols},
        }) and
        specialization.reductionMatches(1, .{
            .name = "row_exp_sum",
            .operator = .sum_exp_shifted,
            .extents = &.{cols},
            .dependencies = &.{"row_max"},
        }) and
        specialization.reductionReuseMatches(0, .{
            .reduction = "row_max",
            .extents = &.{rows},
        }) and
        specialization.reductionReuseMatches(1, .{
            .reduction = "row_exp_sum",
            .extents = &.{rows},
        });
}
fn rowParameterizationInputsMatch(
    specialization: entry.Specialization,
    cols: u64,
    parameterization: entry.RowNormalizationParameterization,
) bool {
    return switch (parameterization) {
        .none => specialization.inputs.len == 1,
        .scale => specialization.inputs.len == 2 and
            specialization.inputHasExtents(1, &.{cols}),
        .scale_bias => specialization.inputs.len == 3 and
            specialization.inputHasExtents(1, &.{cols}) and
            specialization.inputHasExtents(2, &.{cols}),
    };
}
fn rowRmsNormDescriptorMatches(
    specialization: entry.Specialization,
    rows: u64,
    cols: u64,
    parameterization: entry.RowNormalizationParameterization,
) bool {
    return rowParameterizationInputsMatch(specialization, cols, parameterization) and
        specialization.reductions.len == 1 and
        specialization.reduction_reuse.len == 1 and
        specialization.reductionMatches(0, .{
            .name = "row_sum_squares",
            .operator = .sum_squares,
            .extents = &.{cols},
        }) and
        specialization.reductionReuseMatches(0, .{
            .reduction = "row_sum_squares",
            .extents = &.{rows},
        });
}
fn rowLayerNormDescriptorMatches(
    specialization: entry.Specialization,
    rows: u64,
    cols: u64,
    parameterization: entry.RowNormalizationParameterization,
) bool {
    return rowParameterizationInputsMatch(specialization, cols, parameterization) and
        specialization.reductions.len == 2 and
        specialization.reduction_reuse.len == 2 and
        specialization.reductionMatches(0, .{
            .name = "row_sum",
            .operator = .sum,
            .extents = &.{cols},
        }) and
        specialization.reductionMatches(1, .{
            .name = "row_variance_sum",
            .operator = .sum_squared_difference,
            .extents = &.{cols},
            .dependencies = &.{"row_sum"},
        }) and
        specialization.reductionReuseMatches(0, .{
            .reduction = "row_sum",
            .extents = &.{rows},
        }) and
        specialization.reductionReuseMatches(1, .{
            .reduction = "row_variance_sum",
            .extents = &.{rows},
        });
}
