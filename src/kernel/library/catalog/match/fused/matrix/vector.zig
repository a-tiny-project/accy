const std = @import("std");

const catalog = @import("../../../root.zig");

const common = @import("../../root.zig");
const epilogue = @import("epilogue.zig");
const linalg_match = @import("../../linalg/root.zig");
const shapes = @import("../../shape/root.zig");

const Descriptor = catalog.Descriptor;
const FusedMatrixVectorProductQuery = catalog.FusedMatrixVectorProductQuery;
const MatrixVectorProductShape = shapes.MatrixVectorProductShape;
const matrixVectorProductScheduleMatches = linalg_match.matrixVectorProductScheduleMatches;
const matrixVectorProductSpecializationMatches =
    linalg_match.matrixVectorProductSpecializationMatches;
const selectableSpecialization = common.selectableSpecialization;

pub fn fusedMatrixVectorProductDescriptorMatches(
    descriptor: Descriptor,
    query: FusedMatrixVectorProductQuery,
    shape: MatrixVectorProductShape,
) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .fused) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .linalg = .matrix_vector_product })) return false;
    if (specialization.dtype != query.dtype) return false;
    const equation = specialization.equation orelse return false;
    if (!std.mem.eql(u8, equation, "mk,k,m->m")) return false;
    if (specialization.inputs.len != 3) return false;
    return matrixVectorProductSpecializationMatches(specialization, shape) and
        specialization.inputHasExtents(2, &.{shape.m}) and
        epilogue.fusedLinalgEpilogueMatches(specialization, query.epilogue, shape.m) and
        matrixVectorProductScheduleMatches(specialization, query.schedule);
}
