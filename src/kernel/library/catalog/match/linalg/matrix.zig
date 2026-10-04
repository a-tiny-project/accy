const std = @import("std");
const gpu_abi = @import("gpu_abi");

const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const common = @import("../root.zig");
const shapes = @import("../shape/root.zig");

const entry = library.entry;
const linalg = library.linalg;
const Descriptor = catalog.Descriptor;
const MatrixProductSchedule = catalog.MatrixProductSchedule;
const MatrixProductShape = shapes.MatrixProductShape;
const selectableSpecialization = common.selectableSpecialization;
const specializationThreadgroup2DMatches = common.specializationThreadgroup2DMatches;

pub fn matrixProductDescriptorMatches(
    descriptor: Descriptor,
    shape: MatrixProductShape,
    schedule: ?MatrixProductSchedule,
    dtype: gpu_abi.DType,
) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .linalg) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .linalg = .matrix_product })) return false;
    if (specialization.dtype != dtype) return false;
    if (specialization.accumulation_dtype != linalg.matrixProductAccumulationDType(dtype)) {
        return false;
    }
    const equation = specialization.equation orelse return false;
    if (!std.mem.eql(u8, equation, "mk,kn->mn")) return false;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    return matrixProductSpecializationMatches(specialization, shape) and
        matrixProductScheduleMatches(specialization, schedule);
}

pub fn matrixProductScheduleMatches(
    specialization: entry.Specialization,
    schedule: ?MatrixProductSchedule,
) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup2DMatches(specialization, threads),
    };
}

pub fn matrixProductSpecializationMatches(
    specialization: entry.Specialization,
    shape: MatrixProductShape,
) bool {
    if (specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 1) return false;
    return specialization.inputHasExtents(0, &.{ shape.m, shape.k }) and
        specialization.inputHasExtents(1, &.{ shape.k, shape.n }) and
        specialization.outputHasExtents(0, &.{ shape.m, shape.n }) and
        specialization.reductionMatches(0, .{
            .name = "dot",
            .operator = .dot_product,
            .extents = &.{shape.k},
        });
}
