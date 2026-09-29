const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const SpatialQuery = catalog.SpatialQuery;
const SpatialSchedule = catalog.SpatialSchedule;

const selectableSpecialization = common.selectableSpecialization;
const specializationThreadgroup1DMatches = common.specializationThreadgroup1DMatches;

pub fn spatialDescriptorMatches(descriptor: Descriptor, query: SpatialQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .spatial) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.reductions.len != 0) return false;
    if (!spatialScheduleMatches(specialization, query.schedule)) return false;
    return switch (query.kind) {
        .grid_cells => specialization.operationIs(.{ .spatial = .grid_cells }) and
            specialization.inputs.len == 2 and
            specialization.outputs.len == 1 and
            specialization.inputHasExtents(0, &.{query.count}) and
            specialization.inputHasExtents(1, &.{query.count}) and
            specialization.outputHasExtents(0, &.{query.count}),
        .grid_count => |facts| specialization.operationIs(.{ .spatial = .grid_count }) and
            specialization.inputs.len == 1 and
            specialization.outputs.len == 1 and
            specialization.inputHasExtents(0, &.{query.count}) and
            specialization.outputs[0].axes.len == 2 and
            specialization.outputs[0].axes[0].extent == facts.cells,
        .grid_neighbor_count => |facts| specialization.operationIs(.{ .spatial = .grid_neighbor_count }) and
            specialization.inputs.len == 4 and
            specialization.outputs.len == 1 and
            specialization.inputHasExtents(0, &.{query.count}) and
            specialization.inputHasExtents(3, &.{@as(u64, facts.cells) * facts.stride}) and
            specialization.outputHasExtents(0, &.{query.count}),
    };
}
fn spatialScheduleMatches(specialization: entry.Specialization, schedule: ?SpatialSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup1DMatches(specialization, threads),
    };
}
