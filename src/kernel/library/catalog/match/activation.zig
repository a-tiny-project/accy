const catalog = @import("../root.zig");
const common = @import("common.zig");

const Descriptor = catalog.Descriptor;
const ActivationQuery = catalog.ActivationQuery;

const selectableSpecialization = common.selectableSpecialization;

pub fn activationDescriptorMatches(descriptor: Descriptor, query: ActivationQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .elementwise) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .activation = query.kind })) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return false;
    return specialization.inputHasExtents(0, &.{query.extent}) and
        specialization.outputHasExtents(0, &.{query.extent});
}
