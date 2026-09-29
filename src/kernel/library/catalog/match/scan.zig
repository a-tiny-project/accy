const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const ScanQuery = catalog.ScanQuery;
const ScanSchedule = catalog.ScanSchedule;

const selectableSpecialization = common.selectableSpecialization;

pub fn prefixSumDescriptorMatches(descriptor: Descriptor, query: ScanQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .scan) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .scan = query.kind })) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 0) return false;
    return specialization.inputHasExtents(0, &.{query.extent}) and
        specialization.outputHasExtents(0, &.{query.extent}) and
        scanScheduleMatches(specialization, query.schedule);
}
fn scanScheduleMatches(specialization: entry.Specialization, schedule: ?ScanSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| blk: {
            const launch = specialization.launch orelse break :blk false;
            break :blk launch.threadgroup[0] == threads;
        },
    };
}
