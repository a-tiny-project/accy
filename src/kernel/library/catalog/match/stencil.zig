const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");

const entry = library.entry;
const stencil = library.stencil;

const Descriptor = catalog.Descriptor;
const StencilQuery = catalog.StencilQuery;
const StencilSchedule = catalog.StencilSchedule;

const selectableSpecialization = common.selectableSpecialization;
const specializationThreadgroup2DMatches = common.specializationThreadgroup2DMatches;

pub fn stencilWindowDescriptorMatches(descriptor: Descriptor, query: StencilQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .stencil) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .stencil = .window })) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.accumulation_dtype != stencil.windowAccumulationDType(query.dtype)) {
        return false;
    }
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 1) return false;
    if (!stencil.windowRadiusValid(query.radius)) return false;
    const side = 2 * @as(u64, query.radius) + 1;
    const taps = side * side;
    const padded_rows = query.rows + 2 * @as(u64, query.radius);
    const padded_cols = query.cols + 2 * @as(u64, query.radius);
    return specialization.inputHasExtents(0, &.{ padded_rows, padded_cols }) and
        specialization.inputHasExtents(1, &.{taps}) and
        specialization.outputHasExtents(0, &.{ query.rows, query.cols }) and
        specialization.reductionMatches(0, .{
            .name = "window",
            .operator = .weighted_sum,
            .extents = &.{taps},
        }) and stencilWindowScheduleMatches(specialization, query.schedule);
}
fn stencilWindowScheduleMatches(
    specialization: entry.Specialization,
    schedule: ?StencilSchedule,
) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup2DMatches(specialization, threads),
    };
}
