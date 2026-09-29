const std = @import("std");

const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const common = @import("../root.zig");
const shapes = @import("../shape/root.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const MatrixVectorProductSchedule = catalog.MatrixVectorProductSchedule;
const MatrixVectorProductShape = shapes.MatrixVectorProductShape;
const selectableSpecialization = common.selectableSpecialization;
const specializationThreadgroup1DMatches = common.specializationThreadgroup1DMatches;

pub fn matrixVectorProductDescriptorMatches(descriptor: Descriptor, shape: MatrixVectorProductShape, schedule: ?MatrixVectorProductSchedule) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .linalg) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .linalg = .matrix_vector_product })) return false;
    if (specialization.dtype != .f32) return false;
    const equation = specialization.equation orelse return false;
    if (!std.mem.eql(u8, equation, "mk,k->m")) return false;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    return matrixVectorProductSpecializationMatches(specialization, shape) and
        matrixVectorProductScheduleMatches(specialization, schedule);
}

pub fn matrixVectorProductScheduleMatches(specialization: entry.Specialization, schedule: ?MatrixVectorProductSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup1DMatches(specialization, threads),
    };
}

pub fn matrixVectorProductSpecializationMatches(specialization: entry.Specialization, shape: MatrixVectorProductShape) bool {
    if (specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 1) return false;
    return specialization.inputHasExtents(0, &.{ shape.m, shape.k }) and
        specialization.inputHasExtents(1, &.{shape.k}) and
        specialization.outputHasExtents(0, &.{shape.m}) and
        specialization.reductionMatches(0, .{
            .name = "dot",
            .operator = .dot_product,
            .extents = &.{shape.k},
        });
}
