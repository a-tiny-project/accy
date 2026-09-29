const std = @import("std");
const gpu_abi = @import("gpu_abi");

const library = @import("../../library/root.zig");

const DType = gpu_abi.DType;

pub const RowNormalizationKind = library.RowNormalizationKind;
pub const RowNormalizationParameterization = library.RowNormalizationParameterization;
pub const RowNormalizationSchedule = library.RowNormalizationSchedule;

pub const RowNormalizationSelectionRequest = struct {
    dtype: DType,
    kind: RowNormalizationKind,
    rows: u64,
    cols: u64,
    schedule: ?RowNormalizationSchedule = null,
};

pub const SelectedRowNormalizationKernel = struct {
    kind: RowNormalizationKind,
    descriptor: library.CatalogDescriptor,
};

pub fn selectCatalog(request: RowNormalizationSelectionRequest) ?SelectedRowNormalizationKernel {
    const descriptor = library.select(.{ .row_normalization = .{
        .dtype = request.dtype,
        .kind = request.kind,
        .rows = request.rows,
        .cols = request.cols,
        .schedule = request.schedule,
    } }) orelse return null;
    return .{
        .kind = request.kind,
        .descriptor = descriptor,
    };
}

test "logical row normalization selection chooses catalog entries" {
    const softmax = selectCatalog(.{
        .dtype = .f32,
        .kind = .softmax,
        .rows = 2,
        .cols = 4,
    }) orelse return error.TestExpectedRowSoftmaxSelection;
    const log_softmax = selectCatalog(.{
        .dtype = .f32,
        .kind = .log_softmax,
        .rows = 2,
        .cols = 4,
    }) orelse return error.TestExpectedRowLogSoftmaxSelection;
    const rmsnorm = selectCatalog(.{
        .dtype = .f32,
        .kind = .{ .rmsnorm = .scale },
        .rows = 2,
        .cols = 4,
    }) orelse return error.TestExpectedRowRmsNormSelection;
    const layernorm = selectCatalog(.{
        .dtype = .f32,
        .kind = .{ .layernorm = .none },
        .rows = 2,
        .cols = 4,
    }) orelse return error.TestExpectedRowLayerNormSelection;
    const affine_layernorm = selectCatalog(.{
        .dtype = .f32,
        .kind = .{ .layernorm = .scale_bias },
        .rows = 2,
        .cols = 4,
    }) orelse return error.TestExpectedRowAffineLayerNormSelection;

    try std.testing.expectEqual(RowNormalizationKind.softmax, softmax.kind);
    try std.testing.expectEqualStrings(library.normalization.RowSoftmax2x4F32.target, softmax.descriptor.metadata.target);
    try std.testing.expectEqual(RowNormalizationKind.log_softmax, log_softmax.kind);
    try std.testing.expectEqualStrings(library.normalization.RowLogSoftmax2x4F32.target, log_softmax.descriptor.metadata.target);
    try std.testing.expectEqualDeep(RowNormalizationKind{ .rmsnorm = .scale }, rmsnorm.kind);
    try std.testing.expectEqualStrings(library.normalization.RowRmsNorm2x4F32.target, rmsnorm.descriptor.metadata.target);
    try std.testing.expectEqualDeep(RowNormalizationKind{ .layernorm = .none }, layernorm.kind);
    try std.testing.expectEqualStrings(library.normalization.RowLayerNorm2x4F32.target, layernorm.descriptor.metadata.target);
    try std.testing.expectEqualDeep(RowNormalizationKind{ .layernorm = .scale_bias }, affine_layernorm.kind);
    try std.testing.expectEqualStrings(library.normalization.RowAffineLayerNorm2x4F32.target, affine_layernorm.descriptor.metadata.target);
}

test "logical row normalization selection chooses schedule-specialized catalog entries" {
    const softmax = selectCatalog(.{
        .dtype = .f32,
        .kind = .softmax,
        .rows = 2,
        .cols = 4,
        .schedule = .{ .thread_blocks = .{ .x = 2, .y = 2 } },
    }) orelse return error.TestExpectedRowSoftmaxScheduleSelection;

    try std.testing.expectEqual(RowNormalizationKind.softmax, softmax.kind);
    try std.testing.expectEqualStrings(library.normalization.RowSoftmax2x4ThreadBlocks2x2F32.target, softmax.descriptor.metadata.target);
    try std.testing.expectEqual(@as(u32, 2), softmax.descriptor.metadata.specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), softmax.descriptor.metadata.specialization.launch.?.threadgroup[1]);
}

test "logical row normalization selection rejects unavailable catalog entry" {
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .kind = .softmax,
        .rows = 3,
        .cols = 4,
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .kind = .log_softmax,
        .rows = 2,
        .cols = 5,
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .i32,
        .kind = .{ .rmsnorm = .scale },
        .rows = 2,
        .cols = 4,
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .kind = .{ .layernorm = .none },
        .rows = 2,
        .cols = 5,
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .kind = .{ .layernorm = .scale },
        .rows = 2,
        .cols = 4,
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .kind = .softmax,
        .rows = 2,
        .cols = 4,
        .schedule = .{ .thread_blocks = .{ .x = 8, .y = 2 } },
    }) == null);
}
