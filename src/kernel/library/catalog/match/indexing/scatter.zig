const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const common = @import("../root.zig");
const schedule_match = @import("schedule.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const ScatterQuery = catalog.ScatterQuery;
const ScatterSchedule = catalog.ScatterSchedule;
const selectableSpecialization = common.selectableSpecialization;

pub fn scatterDescriptorMatches(descriptor: Descriptor, query: ScatterQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .indexing) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .indexing = .scatter })) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 3 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 0) return false;
    return specialization.inputHasExtents(0, &.{ query.outer, query.axis_size, query.inner }) and
        specialization.inputHasExtents(1, &.{query.updates}) and
        specialization.inputHasExtents(2, &.{ query.outer, query.updates, query.inner }) and
        specialization.outputHasExtents(0, &.{ query.outer, query.axis_size, query.inner }) and
        scatterScheduleMatches(specialization, query.schedule);
}

fn scatterScheduleMatches(specialization: entry.Specialization, schedule: ?ScatterSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| schedule_match.threadBlocksMatch(specialization, threads),
    };
}
