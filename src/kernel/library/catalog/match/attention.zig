const std = @import("std");

const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");
const shapes = @import("shape/root.zig");

const entry = library.entry;
const Descriptor = catalog.Descriptor;
const AttentionQuery = catalog.AttentionQuery;
const AttentionSchedule = catalog.AttentionSchedule;
const AttentionShape = shapes.AttentionShape;

const selectableSpecialization = common.selectableSpecialization;
const specializationThreadgroup3DMatches = common.specializationThreadgroup3DMatches;

pub fn attentionDescriptorMatches(descriptor: Descriptor, query: AttentionQuery, shape: AttentionShape) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .attention) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .attention = query.kind })) return false;
    if (specialization.dtype != query.dtype) return false;
    const equation = specialization.equation orelse return false;
    if (!std.mem.eql(u8, equation, "bqh,bkh,bkv->bqv")) return false;
    if (specialization.inputs.len != 3 or specialization.outputs.len != 1) return false;
    return attentionSpecializationMatches(specialization, shape) and
        attentionScheduleMatches(specialization, query.schedule);
}
fn attentionScheduleMatches(specialization: entry.Specialization, schedule: ?AttentionSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup3DMatches(specialization, threads),
    };
}
fn attentionSpecializationMatches(specialization: entry.Specialization, shape: AttentionShape) bool {
    if (specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 4) return false;
    if (specialization.reduction_reuse.len != 3) return false;
    return specialization.inputHasExtents(0, &.{ shape.batch, shape.queries, shape.qk }) and
        specialization.inputHasExtents(1, &.{ shape.batch, shape.keys, shape.qk }) and
        specialization.inputHasExtents(2, &.{ shape.batch, shape.keys, shape.value }) and
        specialization.outputHasExtents(0, &.{ shape.batch, shape.queries, shape.value }) and
        specialization.reductionMatches(0, .{
            .name = "score_dot",
            .operator = .dot_product,
            .extents = &.{shape.qk},
        }) and
        specialization.reductionMatches(1, .{
            .name = "score_max",
            .operator = .maximum,
            .extents = &.{shape.keys},
            .dependencies = &.{"score_dot"},
        }) and
        specialization.reductionMatches(2, .{
            .name = "score_exp_sum",
            .operator = .sum_exp_shifted,
            .extents = &.{shape.keys},
            .dependencies = &.{"score_max"},
        }) and
        specialization.reductionMatches(3, .{
            .name = "value_weighted_sum",
            .operator = .weighted_sum,
            .extents = &.{shape.keys},
            .dependencies = &.{"score_exp_sum"},
        }) and
        specialization.reductionReuseMatches(0, .{
            .reduction = "score_dot",
            .extents = &.{ shape.batch, shape.queries, shape.keys },
        }) and
        specialization.reductionReuseMatches(1, .{
            .reduction = "score_max",
            .extents = &.{ shape.batch, shape.queries },
        }) and
        specialization.reductionReuseMatches(2, .{
            .reduction = "score_exp_sum",
            .extents = &.{ shape.batch, shape.queries },
        });
}
