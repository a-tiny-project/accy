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
        .matrix_vector_product => |matrix_vector_product| selectMatrixVectorProduct(matrix_vector_product),
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

fn selectMatrixVectorProduct(request: FusedMatrixVectorProductSelectionRequest) ?SelectedFusedKernel {
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

test "logical fused selection chooses vector bias gelu catalog entry" {
    const selected = selectCatalog(.{ .vector = .{
        .dtype = .f32,
        .kind = .{ .bias_activation = .gelu },
        .extent = 8,
    } }) orelse return error.TestExpectedBiasGeluSelection;

    try std.testing.expect(std.meta.eql(FusedKernelKind{ .vector = .{ .bias_activation = .gelu } }, selected.kind));
    try std.testing.expectEqualStrings(library.fused.BiasGelu8F32.target, selected.descriptor.metadata.target);
}

test "logical fused selection chooses vector bias relu and silu catalog entries" {
    const relu = selectCatalog(.{ .vector = .{
        .dtype = .f32,
        .kind = .{ .bias_activation = .relu },
        .extent = 8,
    } }) orelse return error.TestExpectedBiasReluSelection;
    const silu = selectCatalog(.{ .vector = .{
        .dtype = .f32,
        .kind = .{ .bias_activation = .silu },
        .extent = 8,
    } }) orelse return error.TestExpectedBiasSiluSelection;

    try std.testing.expect(std.meta.eql(FusedKernelKind{ .vector = .{ .bias_activation = .relu } }, relu.kind));
    try std.testing.expectEqualStrings(library.fused.BiasRelu8F32.target, relu.descriptor.metadata.target);
    try std.testing.expect(std.meta.eql(FusedKernelKind{ .vector = .{ .bias_activation = .silu } }, silu.kind));
    try std.testing.expectEqualStrings(library.fused.BiasSilu8F32.target, silu.descriptor.metadata.target);
}

test "logical fused selection chooses vector swiglu catalog entry" {
    const selected = selectCatalog(.{ .vector = .{
        .dtype = .f32,
        .kind = .{ .gated_activation = .silu },
        .extent = 8,
    } }) orelse return error.TestExpectedSwiGluSelection;

    try std.testing.expect(std.meta.eql(FusedKernelKind{ .vector = .{ .gated_activation = .silu } }, selected.kind));
    try std.testing.expectEqualStrings(library.fused.SwiGlu8F32.target, selected.descriptor.metadata.target);
}

test "logical fused selection chooses vector geglu catalog entry" {
    const selected = selectCatalog(.{ .vector = .{
        .dtype = .f32,
        .kind = .{ .gated_activation = .gelu },
        .extent = 8,
    } }) orelse return error.TestExpectedGeGluSelection;

    try std.testing.expect(std.meta.eql(FusedKernelKind{ .vector = .{ .gated_activation = .gelu } }, selected.kind));
    try std.testing.expectEqualStrings(library.fused.GeGlu8F32.target, selected.descriptor.metadata.target);
}

test "logical fused selection chooses vector reglu catalog entry" {
    const selected = selectCatalog(.{ .vector = .{
        .dtype = .f32,
        .kind = .{ .gated_activation = .relu },
        .extent = 8,
    } }) orelse return error.TestExpectedReGluSelection;

    try std.testing.expect(std.meta.eql(FusedKernelKind{ .vector = .{ .gated_activation = .relu } }, selected.kind));
    try std.testing.expectEqualStrings(library.fused.ReGlu8F32.target, selected.descriptor.metadata.target);
}

test "logical fused selection chooses matrix product bias gelu catalog entry" {
    const lhs_dims = [_]i64{ 2, 4 };
    const rhs_dims = [_]i64{ 4, 3 };
    const bias_dims = [_]i64{3};
    const output_dims = [_]i64{ 2, 3 };

    const selected = selectCatalog(.{ .matrix_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .gelu },
        .lhs_indices = "mk",
        .rhs_indices = "kn",
        .bias_indices = "n",
        .output_indices = "mn",
        .lhs_dims = &lhs_dims,
        .rhs_dims = &rhs_dims,
        .bias_dims = &bias_dims,
        .output_dims = &output_dims,
    } }) orelse return error.TestExpectedMatrixProductBiasGeluSelection;

    try std.testing.expect(std.meta.eql(FusedKernelKind{ .matrix_product = .{ .bias_activation = .gelu } }, selected.kind));
    try std.testing.expectEqualStrings(library.fused.MatrixProductBiasGelu2x3x4F32.target, selected.descriptor.metadata.target);
}

test "logical fused selection chooses schedule-specialized matrix product catalog entry" {
    const lhs_dims = [_]i64{ 2, 4 };
    const rhs_dims = [_]i64{ 4, 3 };
    const bias_dims = [_]i64{3};
    const output_dims = [_]i64{ 2, 3 };

    const selected = selectCatalog(.{ .matrix_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .gelu },
        .lhs_indices = "mk",
        .rhs_indices = "kn",
        .bias_indices = "n",
        .output_indices = "mn",
        .lhs_dims = &lhs_dims,
        .rhs_dims = &rhs_dims,
        .bias_dims = &bias_dims,
        .output_dims = &output_dims,
        .schedule = .{ .thread_blocks = .{ .x = 1, .y = 2 } },
    } }) orelse return error.TestExpectedMatrixProductBiasGeluSelection;

    try std.testing.expect(std.meta.eql(FusedKernelKind{ .matrix_product = .{ .bias_activation = .gelu } }, selected.kind));
    try std.testing.expectEqualStrings(library.fused.MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32.target, selected.descriptor.metadata.target);
    try std.testing.expectEqual(@as(u32, 1), selected.descriptor.metadata.specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), selected.descriptor.metadata.specialization.launch.?.threadgroup[1]);
}

test "logical fused selection chooses matrix product bias relu and silu catalog entries" {
    const lhs_dims = [_]i64{ 2, 4 };
    const rhs_dims = [_]i64{ 4, 3 };
    const bias_dims = [_]i64{3};
    const output_dims = [_]i64{ 2, 3 };

    const relu = selectCatalog(.{ .matrix_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .relu },
        .lhs_indices = "mk",
        .rhs_indices = "kn",
        .bias_indices = "n",
        .output_indices = "mn",
        .lhs_dims = &lhs_dims,
        .rhs_dims = &rhs_dims,
        .bias_dims = &bias_dims,
        .output_dims = &output_dims,
    } }) orelse return error.TestExpectedMatrixProductBiasReluSelection;
    const silu = selectCatalog(.{ .matrix_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .silu },
        .lhs_indices = "mk",
        .rhs_indices = "kn",
        .bias_indices = "n",
        .output_indices = "mn",
        .lhs_dims = &lhs_dims,
        .rhs_dims = &rhs_dims,
        .bias_dims = &bias_dims,
        .output_dims = &output_dims,
    } }) orelse return error.TestExpectedMatrixProductBiasSiluSelection;

    try std.testing.expect(std.meta.eql(FusedKernelKind{ .matrix_product = .{ .bias_activation = .relu } }, relu.kind));
    try std.testing.expectEqualStrings(library.fused.MatrixProductBiasRelu2x3x4F32.target, relu.descriptor.metadata.target);
    try std.testing.expect(std.meta.eql(FusedKernelKind{ .matrix_product = .{ .bias_activation = .silu } }, silu.kind));
    try std.testing.expectEqualStrings(library.fused.MatrixProductBiasSilu2x3x4F32.target, silu.descriptor.metadata.target);
}

test "logical fused selection chooses matrix vector product bias gelu catalog entry" {
    const matrix_dims = [_]i64{ 4, 8 };
    const vector_dims = [_]i64{8};
    const bias_dims = [_]i64{4};
    const output_dims = [_]i64{4};

    const selected = selectCatalog(.{ .matrix_vector_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .gelu },
        .matrix_indices = "mk",
        .vector_indices = "k",
        .bias_indices = "m",
        .output_indices = "m",
        .matrix_dims = &matrix_dims,
        .vector_dims = &vector_dims,
        .bias_dims = &bias_dims,
        .output_dims = &output_dims,
    } }) orelse return error.TestExpectedMatrixVectorProductBiasGeluSelection;

    try std.testing.expect(std.meta.eql(FusedKernelKind{ .matrix_vector_product = .{ .bias_activation = .gelu } }, selected.kind));
    try std.testing.expectEqualStrings(library.fused.MatrixVectorProductBiasGelu4x8F32.target, selected.descriptor.metadata.target);
}

test "logical fused selection chooses matrix vector product bias relu and silu catalog entries" {
    const matrix_dims = [_]i64{ 4, 8 };
    const vector_dims = [_]i64{8};
    const bias_dims = [_]i64{4};
    const output_dims = [_]i64{4};

    const relu = selectCatalog(.{ .matrix_vector_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .relu },
        .matrix_indices = "mk",
        .vector_indices = "k",
        .bias_indices = "m",
        .output_indices = "m",
        .matrix_dims = &matrix_dims,
        .vector_dims = &vector_dims,
        .bias_dims = &bias_dims,
        .output_dims = &output_dims,
    } }) orelse return error.TestExpectedMatrixVectorProductBiasReluSelection;
    const silu = selectCatalog(.{ .matrix_vector_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .silu },
        .matrix_indices = "mk",
        .vector_indices = "k",
        .bias_indices = "m",
        .output_indices = "m",
        .matrix_dims = &matrix_dims,
        .vector_dims = &vector_dims,
        .bias_dims = &bias_dims,
        .output_dims = &output_dims,
    } }) orelse return error.TestExpectedMatrixVectorProductBiasSiluSelection;

    try std.testing.expect(std.meta.eql(FusedKernelKind{ .matrix_vector_product = .{ .bias_activation = .relu } }, relu.kind));
    try std.testing.expectEqualStrings(library.fused.MatrixVectorProductBiasRelu4x8F32.target, relu.descriptor.metadata.target);
    try std.testing.expect(std.meta.eql(FusedKernelKind{ .matrix_vector_product = .{ .bias_activation = .silu } }, silu.kind));
    try std.testing.expectEqualStrings(library.fused.MatrixVectorProductBiasSilu4x8F32.target, silu.descriptor.metadata.target);
}

test "logical fused selection chooses row residual rmsnorm catalog entry" {
    const selected = selectCatalog(.{ .row_normalization = .{
        .dtype = .f32,
        .kind = .{ .residual = .{ .rmsnorm = .scale } },
        .rows = 2,
        .cols = 4,
    } }) orelse return error.TestExpectedRowResidualRmsNormSelection;

    try std.testing.expect(std.meta.eql(FusedKernelKind{ .row_normalization = .{ .residual = .{ .rmsnorm = .scale } } }, selected.kind));
    try std.testing.expectEqualStrings(library.normalization.RowResidualRmsNorm2x4F32.target, selected.descriptor.metadata.target);
}

test "logical fused selection rejects unavailable catalog entries" {
    const lhs_dims = [_]i64{ 2, 4 };
    const rhs_dims = [_]i64{ 4, 3 };
    const bias_dims = [_]i64{3};
    const wrong_bias_dims = [_]i64{4};
    const output_dims = [_]i64{ 2, 3 };
    const matrix_dims = [_]i64{ 4, 8 };
    const vector_dims = [_]i64{8};
    const matvec_bias_dims = [_]i64{4};
    const wrong_matvec_bias_dims = [_]i64{5};
    const matvec_output_dims = [_]i64{4};

    try std.testing.expect(selectCatalog(.{ .vector = .{
        .dtype = .i32,
        .kind = .{ .bias_activation = .gelu },
        .extent = 8,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .vector = .{
        .dtype = .f32,
        .kind = .{ .bias_activation = .gelu },
        .extent = 16,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .vector = .{
        .dtype = .i32,
        .kind = .{ .gated_activation = .gelu },
        .extent = 8,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .vector = .{
        .dtype = .f32,
        .kind = .{ .gated_activation = .gelu },
        .extent = 16,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .vector = .{
        .dtype = .i32,
        .kind = .{ .gated_activation = .relu },
        .extent = 8,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .vector = .{
        .dtype = .f32,
        .kind = .{ .gated_activation = .relu },
        .extent = 16,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .vector = .{
        .dtype = .i32,
        .kind = .{ .gated_activation = .silu },
        .extent = 8,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .vector = .{
        .dtype = .f32,
        .kind = .{ .gated_activation = .silu },
        .extent = 16,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .matrix_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .gelu },
        .lhs_indices = "mk",
        .rhs_indices = "kn",
        .bias_indices = "n",
        .output_indices = "mn",
        .lhs_dims = &lhs_dims,
        .rhs_dims = &rhs_dims,
        .bias_dims = &wrong_bias_dims,
        .output_dims = &output_dims,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .matrix_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .gelu },
        .lhs_indices = "mk",
        .rhs_indices = "kn",
        .bias_indices = "m",
        .output_indices = "mn",
        .lhs_dims = &lhs_dims,
        .rhs_dims = &rhs_dims,
        .bias_dims = &bias_dims,
        .output_dims = &output_dims,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .matrix_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .gelu },
        .lhs_indices = "mk",
        .rhs_indices = "kn",
        .bias_indices = "n",
        .output_indices = "mn",
        .lhs_dims = &lhs_dims,
        .rhs_dims = &rhs_dims,
        .bias_dims = &bias_dims,
        .output_dims = &output_dims,
        .schedule = .{ .thread_blocks = .{ .x = 8, .y = 2 } },
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .matrix_vector_product = .{
        .dtype = .i32,
        .epilogue = .{ .bias_activation = .gelu },
        .matrix_indices = "mk",
        .vector_indices = "k",
        .bias_indices = "m",
        .output_indices = "m",
        .matrix_dims = &matrix_dims,
        .vector_dims = &vector_dims,
        .bias_dims = &matvec_bias_dims,
        .output_dims = &matvec_output_dims,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .matrix_vector_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .gelu },
        .matrix_indices = "mk",
        .vector_indices = "k",
        .bias_indices = "k",
        .output_indices = "m",
        .matrix_dims = &matrix_dims,
        .vector_dims = &vector_dims,
        .bias_dims = &matvec_bias_dims,
        .output_dims = &matvec_output_dims,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .matrix_vector_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .gelu },
        .matrix_indices = "mk",
        .vector_indices = "k",
        .bias_indices = "m",
        .output_indices = "m",
        .matrix_dims = &matrix_dims,
        .vector_dims = &vector_dims,
        .bias_dims = &wrong_matvec_bias_dims,
        .output_dims = &matvec_output_dims,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .matrix_vector_product = .{
        .dtype = .f32,
        .epilogue = .{ .bias_activation = .gelu },
        .matrix_indices = "mk",
        .vector_indices = "k",
        .bias_indices = "m",
        .output_indices = "m",
        .matrix_dims = &matrix_dims,
        .vector_dims = &vector_dims,
        .bias_dims = &matvec_bias_dims,
        .output_dims = &matvec_output_dims,
        .schedule = .{ .thread_blocks = 8 },
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .row_normalization = .{
        .dtype = .i32,
        .kind = .{ .residual = .{ .rmsnorm = .scale } },
        .rows = 2,
        .cols = 4,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .row_normalization = .{
        .dtype = .f32,
        .kind = .{ .residual = .{ .rmsnorm = .none } },
        .rows = 2,
        .cols = 4,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .row_normalization = .{
        .dtype = .f32,
        .kind = .{ .residual = .{ .rmsnorm = .scale } },
        .rows = 2,
        .cols = 5,
    } }) == null);
    try std.testing.expect(selectCatalog(.{ .row_normalization = .{
        .dtype = .f32,
        .kind = .{ .residual = .{ .rmsnorm = .scale } },
        .rows = 2,
        .cols = 4,
        .schedule = .{ .thread_blocks = .{ .x = 8, .y = 2 } },
    } }) == null);
}
