const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");

const compaction = library.compaction;
const entry = library.entry;
const Descriptor = catalog.Descriptor;
const FilterQuery = catalog.FilterQuery;
const FilterSchedule = catalog.FilterSchedule;

const selectableSpecialization = common.selectableSpecialization;

pub fn filterOperationForQuery(query: FilterQuery) entry.Operation {
    return switch (query.predicate) {
        .nonzero => .{ .compaction = .{ .blocks = .nonzero } },
        .greater_than => .{ .compaction = .{ .blocks = .greater_than } },
    };
}
pub fn filterDescriptorMatches(descriptor: Descriptor, query: FilterQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .compaction) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(filterOperationForQuery(query))) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 0) return false;
    return specialization.inputHasExtents(0, &.{query.extent}) and
        filterScheduleMatches(specialization, query.schedule);
}
fn filterScheduleMatches(specialization: entry.Specialization, schedule: ?FilterSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| blk: {
            const launch = specialization.launch orelse break :blk false;
            break :blk launch.threadgroup[0] == threads;
        },
    };
}
