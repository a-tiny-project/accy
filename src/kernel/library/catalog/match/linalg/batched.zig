const std = @import("std");

const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const common = @import("../root.zig");
const shapes = @import("../shape/root.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const BatchedMatrixProductSchedule = catalog.BatchedMatrixProductSchedule;
const BatchedMatrixProductShape = shapes.BatchedMatrixProductShape;
const selectableSpecialization = common.selectableSpecialization;
const specializationThreadgroup3DMatches = common.specializationThreadgroup3DMatches;

pub fn batchedMatrixProductDescriptorMatches(
    descriptor: Descriptor,
    shape: BatchedMatrixProductShape,
    schedule: ?BatchedMatrixProductSchedule,
) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .linalg) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .linalg = .batched_matrix_product })) return false;
    if (specialization.dtype != .f32) return false;
    const equation = specialization.equation orelse return false;
    if (!std.mem.eql(u8, equation, "bmk,bkn->bmn")) return false;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    return batchedMatrixProductSpecializationMatches(specialization, shape) and
        batchedMatrixProductScheduleMatches(specialization, schedule);
}

fn batchedMatrixProductScheduleMatches(
    specialization: entry.Specialization,
    schedule: ?BatchedMatrixProductSchedule,
) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup3DMatches(specialization, threads),
    };
}

fn batchedMatrixProductSpecializationMatches(
    specialization: entry.Specialization,
    shape: BatchedMatrixProductShape,
) bool {
    if (specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 1) return false;
    return specialization.inputHasExtents(0, &.{ shape.batch, shape.m, shape.k }) and
        specialization.inputHasExtents(1, &.{ shape.batch, shape.k, shape.n }) and
        specialization.outputHasExtents(0, &.{ shape.batch, shape.m, shape.n }) and
        specialization.reductionMatches(0, .{
            .name = "dot",
            .operator = .dot_product,
            .extents = &.{shape.k},
        });
}
