const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const common = @import("../root.zig");
const schedule_match = @import("schedule.zig");

const entry = library.entry;
const histogram_library = library.histogram;
const Descriptor = catalog.Descriptor;
const HistogramQuery = catalog.HistogramQuery;
const HistogramSchedule = catalog.HistogramSchedule;
const selectableSpecialization = common.selectableSpecialization;

pub fn histogramDescriptorMatches(descriptor: Descriptor, query: HistogramQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .indexing) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .indexing = .histogram })) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 0) return false;
    if (specialization.static_parameters.len != 1) return false;
    if (!specialization.staticParameterMatches(
        histogram_library.histogram_binning_policy_parameter,
        histogram_library.histogramBinningPolicyCode(query.binning),
    )) return false;
    return specialization.inputHasExtents(0, &.{query.count}) and
        specialization.outputHasExtents(0, &.{query.bins}) and
        histogramScheduleMatches(specialization, query.schedule);
}

fn histogramScheduleMatches(
    specialization: entry.Specialization,
    schedule: ?HistogramSchedule,
) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| schedule_match.directThreadBlocksMatch(specialization, threads),
        .shared_bins => |threads| schedule_match.sharedBinsThreadBlocksMatch(
            specialization,
            threads,
        ),
    };
}
