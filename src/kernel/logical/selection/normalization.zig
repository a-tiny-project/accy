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
