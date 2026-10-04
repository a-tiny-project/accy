const std = @import("std");

const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const common = @import("../root.zig");
const shapes = @import("../shape/root.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const OuterProductSchedule = catalog.OuterProductSchedule;
const OuterProductShape = shapes.OuterProductShape;
const selectableSpecialization = common.selectableSpecialization;
const specializationThreadgroup2DMatches = common.specializationThreadgroup2DMatches;

pub fn outerProductDescriptorMatches(
    descriptor: Descriptor,
    shape: OuterProductShape,
    schedule: ?OuterProductSchedule,
) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .linalg) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .linalg = .outer_product })) return false;
    if (specialization.dtype != .f32) return false;
    const equation = specialization.equation orelse return false;
    if (!std.mem.eql(u8, equation, "m,n->mn")) return false;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 0) return false;
    return outerProductSpecializationMatches(specialization, shape) and
        outerProductScheduleMatches(specialization, schedule);
}

fn outerProductScheduleMatches(
    specialization: entry.Specialization,
    schedule: ?OuterProductSchedule,
) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup2DMatches(specialization, threads),
    };
}

fn outerProductSpecializationMatches(
    specialization: entry.Specialization,
    shape: OuterProductShape,
) bool {
    return specialization.inputHasExtents(0, &.{shape.m}) and
        specialization.inputHasExtents(1, &.{shape.n}) and
        specialization.outputHasExtents(0, &.{ shape.m, shape.n });
}
