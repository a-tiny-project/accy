const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");

const entry = library.entry;
const random = library.random;
const Descriptor = catalog.Descriptor;
const RandomQuery = catalog.RandomQuery;
const RandomSchedule = catalog.RandomSchedule;

const selectableSpecialization = common.selectableSpecialization;

pub fn randomEffectiveRounds(query: RandomQuery) u32 {
    if (query.rounds != 0) return query.rounds;
    return switch (query.algorithm) {
        .philox => random.philox_default_rounds,
        .threefry => random.threefry_default_rounds,
        .squares => 4,
    };
}
pub fn randomOperationForQuery(query: RandomQuery) entry.Operation {
    const rounds = randomEffectiveRounds(query);
    return switch (query.algorithm) {
        .philox => .{ .random = .{ .philox = rounds } },
        .threefry => .{ .random = .{ .threefry = rounds } },
        .squares => .{ .random = .squares },
    };
}
pub fn randomDescriptorMatches(descriptor: Descriptor, query: RandomQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .random) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(randomOperationForQuery(query))) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 0 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 0) return false;
    return specialization.outputHasExtents(0, &.{query.count}) and
        randomScheduleMatches(specialization, query.schedule);
}
fn randomScheduleMatches(specialization: entry.Specialization, schedule: ?RandomSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| blk: {
            const launch = specialization.launch orelse break :blk false;
            break :blk launch.threadgroup[0] == threads;
        },
    };
}
