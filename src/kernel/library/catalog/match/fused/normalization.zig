const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const common = @import("../root.zig");
const normalization = common;

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const FusedRowNormalizationQuery = catalog.FusedRowNormalizationQuery;
const RowNormalizationKind = catalog.RowNormalizationKind;
const rowNormalizationScheduleMatches = normalization.rowNormalizationScheduleMatches;
const selectableSpecialization = common.selectableSpecialization;

pub fn fusedRowNormalizationDescriptorMatches(descriptor: Descriptor, query: FusedRowNormalizationQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .fused) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.outputs.len != 1) return false;
    if (!specialization.outputHasExtents(0, &.{ query.rows, query.cols })) return false;
    if (!rowNormalizationScheduleMatches(specialization, query.schedule)) return false;
    return switch (query.kind) {
        .residual => |kind| fusedRowResidualNormalizationDescriptorMatches(specialization, query.rows, query.cols, kind),
    };
}

fn fusedRowResidualNormalizationDescriptorMatches(
    specialization: entry.Specialization,
    rows: u64,
    cols: u64,
    kind: RowNormalizationKind,
) bool {
    if (!specialization.operationIs(.{ .row_normalization = kind })) return false;
    return switch (kind) {
        .rmsnorm => |parameterization| fusedRowResidualRmsNormDescriptorMatches(specialization, rows, cols, parameterization),
        .softmax,
        .log_softmax,
        .layernorm,
        => false,
    };
}

fn fusedRowResidualRmsNormDescriptorMatches(
    specialization: entry.Specialization,
    rows: u64,
    cols: u64,
    parameterization: entry.RowNormalizationParameterization,
) bool {
    if (parameterization != .scale) return false;
    return specialization.inputs.len == 3 and
        specialization.inputHasExtents(0, &.{ rows, cols }) and
        specialization.inputHasExtents(1, &.{ rows, cols }) and
        specialization.inputHasExtents(2, &.{cols}) and
        specialization.input_transforms.len == 1 and
        specialization.inputTransformMatches(0, .{
            .operator = .residual_add,
            .input_index = 1,
            .extents = &.{ rows, cols },
        }) and
        specialization.epilogues.len == 0 and
        specialization.reductions.len == 1 and
        specialization.reductionMatches(0, .{
            .name = "row_sum_squares",
            .operator = .sum_squares,
            .extents = &.{cols},
        });
}
