const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");
const shapes = @import("shape/root.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const ReductionKind = catalog.ReductionKind;
const ReductionShape = shapes.ReductionShape;

const selectableSpecialization = common.selectableSpecialization;

pub fn reductionDescriptorMatches(descriptor: Descriptor, kind: ReductionKind, shape: ReductionShape) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .reduction) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .reduction = kind })) return false;
    if (specialization.dtype != .f32) return false;
    if (specialization.outputs.len != 1) return false;
    if (!specialization.outputHasExtents(0, &.{})) return false;
    return switch (kind) {
        .sum => sumReductionDescriptorMatches(specialization, shape.extent),
        .dot_product => dotProductReductionDescriptorMatches(specialization, shape.extent),
        else => false,
    };
}
fn sumReductionDescriptorMatches(specialization: entry.Specialization, extent: u64) bool {
    return specialization.inputs.len == 1 and
        specialization.inputHasExtents(0, &.{extent}) and
        specialization.reductions.len == 1 and
        specialization.reductionMatches(0, .{
            .name = "sum",
            .operator = .sum,
            .extents = &.{extent},
        });
}
fn dotProductReductionDescriptorMatches(specialization: entry.Specialization, extent: u64) bool {
    return specialization.inputs.len == 2 and
        specialization.inputHasExtents(0, &.{extent}) and
        specialization.inputHasExtents(1, &.{extent}) and
        specialization.reductions.len == 1 and
        specialization.reductionMatches(0, .{
            .name = "dot",
            .operator = .dot_product,
            .extents = &.{extent},
        });
}
