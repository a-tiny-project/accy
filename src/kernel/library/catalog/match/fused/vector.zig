const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const common = @import("../root.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const ActivationKind = catalog.ActivationKind;
const FusedVectorKind = catalog.FusedVectorKind;
const FusedVectorQuery = catalog.FusedVectorQuery;
const selectableSpecialization = common.selectableSpecialization;

pub fn fusedVectorDescriptorMatches(descriptor: Descriptor, query: FusedVectorQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .fused) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(fusedVectorOperation(query.kind))) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    return switch (query.kind) {
        .bias_activation => |activation| fusedBiasActivationDescriptorMatches(
            specialization,
            query.extent,
            activation,
        ),
        .gated_activation => |activation| fusedGatedDescriptorMatches(
            specialization,
            query.extent,
            activation,
        ),
    };
}

fn fusedVectorOperation(kind: FusedVectorKind) entry.Operation {
    return switch (kind) {
        .bias_activation => .{ .elementwise = .add },
        .gated_activation => .{ .elementwise = .mul },
    };
}

fn fusedBiasActivationDescriptorMatches(
    specialization: entry.Specialization,
    extent: u64,
    activation: ActivationKind,
) bool {
    return specialization.epilogues.len == 1 and
        specialization.input_transforms.len == 0 and
        specialization.epilogueMatches(0, .{ .operator = .{ .activation = activation } }) and
        specialization.inputHasExtents(0, &.{extent}) and
        specialization.inputHasExtents(1, &.{extent}) and
        specialization.outputHasExtents(0, &.{extent});
}

fn fusedGatedDescriptorMatches(
    specialization: entry.Specialization,
    extent: u64,
    activation: ActivationKind,
) bool {
    return specialization.epilogues.len == 0 and
        specialization.input_transforms.len == 1 and
        specialization.inputTransformMatches(0, .{
            .operator = .{ .activation = activation },
            .input_index = 0,
            .extents = &.{extent},
        }) and
        specialization.inputHasExtents(0, &.{extent}) and
        specialization.inputHasExtents(1, &.{extent}) and
        specialization.outputHasExtents(0, &.{extent});
}
