const std = @import("std");

const catalog = @import("../../../root.zig");

const common = @import("../../root.zig");
const epilogue = @import("epilogue.zig");
const linalg_match = @import("../../linalg/root.zig");
const shapes = @import("../../shape/root.zig");

const Descriptor = catalog.Descriptor;
const FusedMatrixProductQuery = catalog.FusedMatrixProductQuery;
const MatrixProductShape = shapes.MatrixProductShape;
const matrixProductScheduleMatches = linalg_match.matrixProductScheduleMatches;
const matrixProductSpecializationMatches = linalg_match.matrixProductSpecializationMatches;
const selectableSpecialization = common.selectableSpecialization;

pub fn fusedMatrixProductDescriptorMatches(descriptor: Descriptor, query: FusedMatrixProductQuery, shape: MatrixProductShape) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .fused) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .linalg = .matrix_product })) return false;
    if (specialization.dtype != query.dtype) return false;
    const equation = specialization.equation orelse return false;
    if (!std.mem.eql(u8, equation, "mk,kn,n->mn")) return false;
    if (specialization.inputs.len != 3) return false;
    return matrixProductSpecializationMatches(specialization, shape) and
        specialization.inputHasExtents(2, &.{shape.n}) and
        epilogue.fusedLinalgEpilogueMatches(specialization, query.epilogue, shape.n) and
        matrixProductScheduleMatches(specialization, query.schedule);
}
