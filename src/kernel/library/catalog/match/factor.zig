const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");

const entry = library.entry;
const linalg = library.linalg;
const Descriptor = catalog.Descriptor;
const FactorQuery = catalog.FactorQuery;
const FactorSchedule = catalog.FactorSchedule;

const selectableSpecialization = common.selectableSpecialization;
const specializationThreadgroup1DMatches = common.specializationThreadgroup1DMatches;

pub fn factorDescriptorMatches(descriptor: Descriptor, query: FactorQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .linalg) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.reductions.len != 0) return false;
    if (!factorScheduleMatches(specialization, query.schedule)) return false;
    if (!specialization.layoutIs(@tagName(query.layout))) return false;
    return switch (query.kind) {
        .batched_cholesky => |facts| specialization.operationIs(
            .{ .linalg = .batched_cholesky },
        ) and
            specialization.inputs.len == 1 and
            specialization.outputs.len == 1 and
            specialization.inputHasExtents(0, &.{ facts.batch, facts.n, facts.n }) and
            specialization.outputHasExtents(0, &.{ facts.batch, facts.n, facts.n }),
        .batched_cholesky_solve => |facts| specialization.operationIs(
            .{ .linalg = .batched_cholesky_solve },
        ) and
            specialization.inputs.len == 2 and
            specialization.outputs.len == 1 and
            specialization.inputHasExtents(0, &.{ facts.batch, facts.n, facts.n }) and
            specialization.inputHasExtents(1, &.{ facts.batch, facts.n }) and
            specialization.outputHasExtents(0, &.{ facts.batch, facts.n }),
        .batched_inverse => |facts| specialization.operationIs(.{ .linalg = .batched_inverse }) and
            specialization.inputs.len == 1 and
            specialization.outputs.len == 1 and
            specialization.inputHasExtents(0, &.{ facts.batch, facts.n, facts.n }) and
            specialization.outputHasExtents(0, &.{ facts.batch, facts.n, facts.n }),
    };
}
fn factorScheduleMatches(specialization: entry.Specialization, schedule: ?FactorSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup1DMatches(specialization, threads),
    };
}
