const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const common = @import("../root.zig");
const schedule_match = @import("schedule.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const GatherQuery = catalog.GatherQuery;
const GatherSchedule = catalog.GatherSchedule;
const selectableSpecialization = common.selectableSpecialization;

pub fn gatherDescriptorMatches(descriptor: Descriptor, query: GatherQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .indexing) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .indexing = .gather })) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 0) return false;
    return specialization.inputHasExtents(0, &.{ query.outer, query.axis_size, query.inner }) and
        specialization.inputHasExtents(1, &.{query.gathered}) and
        specialization.outputHasExtents(0, &.{ query.outer, query.gathered, query.inner }) and
        gatherScheduleMatches(specialization, query.schedule);
}

fn gatherScheduleMatches(specialization: entry.Specialization, schedule: ?GatherSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| schedule_match.threadBlocksMatch(specialization, threads),
    };
}
