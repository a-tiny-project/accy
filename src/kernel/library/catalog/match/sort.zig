const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");

const entry = library.entry;
const sort_mod = library.sort;
const Descriptor = catalog.Descriptor;
const SortQuery = catalog.SortQuery;
const SortSchedule = catalog.SortSchedule;

const selectableSpecialization = common.selectableSpecialization;
const specializationThreadgroup1DMatches = common.specializationThreadgroup1DMatches;

pub fn topKBlockDescriptorMatches(descriptor: Descriptor, query: SortQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .sort) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .sort = .top_k_smallest })) return false;
    if (!specialization.structureIs(sort_mod.top_k_block_structure_name)) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 0) return false;
    return specialization.inputHasExtents(0, &.{query.extent}) and
        specialization.outputHasExtents(0, &.{query.k}) and
        sortScheduleMatches(specialization, query.schedule);
}
pub fn topKBlockPairsDescriptorMatches(descriptor: Descriptor, query: SortQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .sort) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .sort = .top_k_smallest })) return false;
    if (!specialization.structureIs(sort_mod.top_k_block_pairs_structure_name)) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 2) return false;
    if (specialization.reductions.len != 0) return false;
    return specialization.inputHasExtents(0, &.{query.extent}) and
        specialization.inputHasExtents(1, &.{query.extent}) and
        specialization.outputHasExtents(0, &.{query.k}) and
        specialization.outputHasExtents(1, &.{query.k}) and
        sortScheduleMatches(specialization, query.schedule);
}
fn sortScheduleMatches(specialization: entry.Specialization, schedule: ?SortSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup1DMatches(specialization, threads),
    };
}
