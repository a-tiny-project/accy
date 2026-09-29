const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");

const entry = library.entry;
const segmented = library.segmented;
const Descriptor = catalog.Descriptor;
const SegmentedQuery = catalog.SegmentedQuery;

const selectableSpecialization = common.selectableSpecialization;

pub fn segmentSumDescriptorMatches(descriptor: Descriptor, query: SegmentedQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .segmented) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .segmented = .segment_sum })) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 0) return false;
    return specialization.inputHasExtents(0, &.{query.total}) and
        specialization.inputHasExtents(1, &.{query.segments + 1}) and
        specialization.outputHasExtents(0, &.{query.segments}) and
        segmentedScheduleMatches(specialization, query);
}
fn segmentedScheduleMatches(specialization: entry.Specialization, query: SegmentedQuery) bool {
    const requested = query.schedule orelse return true;
    const launch = specialization.launch orelse return false;
    const granularity = segmented.segmentSumGranularityFromLaunch(launch, query.segments) orelse return false;
    return switch (requested) {
        .thread_blocks => |threads| granularity == .thread and launch.threadgroup[0] == threads,
        .warp_blocks => |threads| granularity == .warp and launch.threadgroup[0] == threads,
    };
}
