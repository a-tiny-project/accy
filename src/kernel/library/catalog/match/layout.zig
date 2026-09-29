const std = @import("std");

const catalog = @import("../root.zig");

const common = @import("common.zig");
const shapes = @import("shape/root.zig");

const Descriptor = catalog.Descriptor;
const TransposeQuery = catalog.TransposeQuery;
const TransposeShape = shapes.TransposeShape;

const selectableSpecialization = common.selectableSpecialization;

pub fn transposeDescriptorMatches(descriptor: Descriptor, query: TransposeQuery, shape: TransposeShape) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .layout) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .layout = query.kind })) return false;
    if (specialization.dtype != query.dtype) return false;
    const equation = specialization.equation orelse return false;
    if (!std.mem.eql(u8, equation, "ij->ji")) return false;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return false;
    return specialization.inputHasExtents(0, &.{ shape.rows, shape.cols }) and
        specialization.outputHasExtents(0, &.{ shape.cols, shape.rows });
}
