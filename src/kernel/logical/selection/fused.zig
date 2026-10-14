const std = @import("std");
const gpu_abi = @import("gpu_abi");

const library = @import("../../library/root.zig");

const DType = gpu_abi.DType;

pub const FusedVectorKind = library.FusedVectorKind;
pub const FusedRowNormalizationKind = library.FusedRowNormalizationKind;
pub const FusedMatrixProductSchedule = library.MatrixProductSchedule;
pub const FusedMatrixVectorProductSchedule = library.MatrixVectorProductSchedule;
pub const FusedRowNormalizationSchedule = library.RowNormalizationSchedule;

pub const FusedVectorSelectionRequest = struct {
    dtype: DType,
    kind: FusedVectorKind,
    extent: u64,
};

pub const FusedLinalgEpilogue = library.FusedLinalgEpilogue;

pub const FusedMatrixProductSelectionRequest = struct {
    dtype: DType,
    epilogue: FusedLinalgEpilogue,
    lhs_indices: []const u8,
    rhs_indices: []const u8,
    bias_indices: []const u8,
    output_indices: []const u8,
    lhs_dims: []const i64,
    rhs_dims: []const i64,
    bias_dims: []const i64,
    output_dims: []const i64,
    schedule: ?FusedMatrixProductSchedule = null,
};

pub const FusedMatrixVectorProductSelectionRequest = struct {
    dtype: DType,
    epilogue: FusedLinalgEpilogue,
    matrix_indices: []const u8,
    vector_indices: []const u8,
    bias_indices: []const u8,
    output_indices: []const u8,
    matrix_dims: []const i64,
    vector_dims: []const i64,
    bias_dims: []const i64,
    output_dims: []const i64,
    schedule: ?FusedMatrixVectorProductSchedule = null,
};

pub const FusedRowNormalizationSelectionRequest = struct {
    dtype: DType,
    kind: FusedRowNormalizationKind,
    rows: u64,
    cols: u64,
    schedule: ?FusedRowNormalizationSchedule = null,
};

pub const FusedSelectionRequest = union(enum) {
    vector: FusedVectorSelectionRequest,
    matrix_product: FusedMatrixProductSelectionRequest,
    matrix_vector_product: FusedMatrixVectorProductSelectionRequest,
    row_normalization: FusedRowNormalizationSelectionRequest,
};

pub const FusedKernelKind = union(enum) {
    vector: FusedVectorKind,
    matrix_product: FusedLinalgEpilogue,
    matrix_vector_product: FusedLinalgEpilogue,
    row_normalization: FusedRowNormalizationKind,
};

pub const SelectedFusedKernel = struct {
    kind: FusedKernelKind,
    descriptor: library.CatalogDescriptor,
};

pub fn selectCatalog(request: FusedSelectionRequest) ?SelectedFusedKernel {
    return switch (request) {
        .vector => |vector| selectVector(vector),
        .matrix_product => |matrix_product| selectMatrixProduct(matrix_product),
        .matrix_vector_product => |matrix_vector_product| selectMatrixVectorProduct(
            matrix_vector_product,
        ),
        .row_normalization => |row_normalization| selectRowNormalization(row_normalization),
    };
}

fn selectVector(request: FusedVectorSelectionRequest) ?SelectedFusedKernel {
    const descriptor = library.select(.{ .fused = .{ .vector = .{
        .dtype = request.dtype,
        .kind = request.kind,
        .extent = request.extent,
    } } }) orelse return null;
    return .{
        .kind = .{ .vector = request.kind },
        .descriptor = descriptor,
    };
}

fn selectMatrixProduct(request: FusedMatrixProductSelectionRequest) ?SelectedFusedKernel {
    const descriptor = library.select(.{ .fused = .{ .matrix_product = .{
        .dtype = request.dtype,
        .epilogue = request.epilogue,
        .lhs_indices = request.lhs_indices,
        .rhs_indices = request.rhs_indices,
        .bias_indices = request.bias_indices,
        .output_indices = request.output_indices,
        .lhs_dims = request.lhs_dims,
        .rhs_dims = request.rhs_dims,
        .bias_dims = request.bias_dims,
        .output_dims = request.output_dims,
        .schedule = request.schedule,
    } } }) orelse return null;
    return .{
        .kind = .{ .matrix_product = request.epilogue },
        .descriptor = descriptor,
    };
}

fn selectMatrixVectorProduct(
    request: FusedMatrixVectorProductSelectionRequest,
) ?SelectedFusedKernel {
    const descriptor = library.select(.{ .fused = .{ .matrix_vector_product = .{
        .dtype = request.dtype,
        .epilogue = request.epilogue,
        .matrix_indices = request.matrix_indices,
        .vector_indices = request.vector_indices,
        .bias_indices = request.bias_indices,
        .output_indices = request.output_indices,
        .matrix_dims = request.matrix_dims,
        .vector_dims = request.vector_dims,
        .bias_dims = request.bias_dims,
        .output_dims = request.output_dims,
        .schedule = request.schedule,
    } } }) orelse return null;
    return .{
        .kind = .{ .matrix_vector_product = request.epilogue },
        .descriptor = descriptor,
    };
}

fn selectRowNormalization(request: FusedRowNormalizationSelectionRequest) ?SelectedFusedKernel {
    const descriptor = library.select(.{ .fused = .{ .row_normalization = .{
        .dtype = request.dtype,
        .kind = request.kind,
        .rows = request.rows,
        .cols = request.cols,
        .schedule = request.schedule,
    } } }) orelse return null;
    return .{
        .kind = .{ .row_normalization = request.kind },
        .descriptor = descriptor,
    };
}
