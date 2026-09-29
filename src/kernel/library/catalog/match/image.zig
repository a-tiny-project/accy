const std = @import("std");

const catalog = @import("../root.zig");
const library = @import("../../root.zig");

const common = @import("common.zig");

const entry = library.entry;
const image = library.image;

const Descriptor = catalog.Descriptor;
const ImageQuery = catalog.ImageQuery;
const ImageSchedule = catalog.ImageSchedule;

const selectableSpecialization = common.selectableSpecialization;
const specializationThreadgroup2DMatches = common.specializationThreadgroup2DMatches;

pub fn imageDescriptorMatches(descriptor: Descriptor, query: ImageQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .image) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.accumulation_dtype != .f32) return false;
    if (!imageScheduleMatches(specialization, query.schedule)) return false;
    return switch (query.kind) {
        .blur_pass => |facts| blurPassDescriptorMatches(specialization, query, facts.radius, facts.axis),
        .resize_bilinear => |facts| resizeDescriptorMatches(specialization, query, facts.src_width, facts.src_height),
    };
}

fn blurPassDescriptorMatches(
    specialization: entry.Specialization,
    query: ImageQuery,
    radius: u32,
    axis: image.Axis,
) bool {
    if (!specialization.operationIs(.{ .image = .blur_pass })) return false;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 1 or specialization.static_parameters.len != 2) return false;
    if (!image.blurPassInstanceValid(.{
        .radius = radius,
        .axis = axis,
        .width = query.width,
        .height = query.height,
    })) return false;
    const taps = 2 * @as(u64, radius) + 1;
    return specialization.inputHasExtents(0, &.{ query.height, query.width }) and
        specialization.inputHasExtents(1, &.{taps}) and
        specialization.outputHasExtents(0, &.{ query.height, query.width }) and
        specialization.reductionMatches(0, .{
            .name = "blur_tap",
            .operator = .weighted_sum,
            .extents = &.{taps},
        }) and
        specialization.staticParameterMatches("radius", radius) and
        specialization.staticParameterMatches("axis", image.blurPassAxisParameter(axis));
}

fn resizeDescriptorMatches(
    specialization: entry.Specialization,
    query: ImageQuery,
    src_width: u64,
    src_height: u64,
) bool {
    if (!specialization.operationIs(.{ .image = .resize_bilinear })) return false;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 0 or specialization.static_parameters.len != 0) return false;
    if (!image.resizeInstanceValid(.{
        .dst_width = query.width,
        .dst_height = query.height,
        .src_width = src_width,
        .src_height = src_height,
    })) return false;
    return specialization.inputHasExtents(0, &.{ src_height, src_width }) and
        specialization.outputHasExtents(0, &.{ query.height, query.width });
}

fn imageScheduleMatches(specialization: entry.Specialization, schedule: ?ImageSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup2DMatches(specialization, threads),
    };
}

test {
    std.testing.refAllDecls(@This());
}
