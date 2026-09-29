const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const RowSparseCrossEntropyQuery = catalog.RowSparseCrossEntropyQuery;
const RowSparseCrossEntropySchedule = catalog.RowSparseCrossEntropySchedule;
const selectableSpecialization = common.selectableSpecialization;

pub fn rowSparseCrossEntropyDescriptorMatches(descriptor: Descriptor, query: RowSparseCrossEntropyQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .loss) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .loss = .row_sparse_cross_entropy })) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 0) return false;
    return specialization.inputHasExtents(0, &.{ query.rows, query.classes }) and
        specialization.inputHasExtents(1, &.{query.rows}) and
        specialization.outputHasExtents(0, &.{query.rows}) and
        rowSparseCrossEntropyScheduleMatches(specialization, query.schedule);
}

fn rowSparseCrossEntropyScheduleMatches(
    specialization: entry.Specialization,
    schedule: ?RowSparseCrossEntropySchedule,
) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| threadBlocksMatch(specialization, threads),
    };
}

fn threadBlocksMatch(specialization: entry.Specialization, threads: u32) bool {
    const launch = specialization.launch orelse return false;
    return launch.threadgroup[0] == threads;
}
