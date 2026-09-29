const dimension = @import("dimension.zig");
const model = @import("model.zig");

const MatrixProductShape = model.MatrixProductShape;
const BatchedMatrixProductShape = model.BatchedMatrixProductShape;
const MatrixVectorProductShape = model.MatrixVectorProductShape;
const OuterProductShape = model.OuterProductShape;
const positiveDim = dimension.positiveDim;

pub fn batchedMatrixProductShape(lhs_dims: []const i64, rhs_dims: []const i64, output_dims: []const i64) ?BatchedMatrixProductShape {
    if (lhs_dims.len != 3 or rhs_dims.len != 3 or output_dims.len != 3) return null;
    const batch = positiveDim(lhs_dims[0]) orelse return null;
    const m = positiveDim(lhs_dims[1]) orelse return null;
    const k = positiveDim(lhs_dims[2]) orelse return null;
    const rhs_batch = positiveDim(rhs_dims[0]) orelse return null;
    const rhs_k = positiveDim(rhs_dims[1]) orelse return null;
    const n = positiveDim(rhs_dims[2]) orelse return null;
    const out_batch = positiveDim(output_dims[0]) orelse return null;
    const out_m = positiveDim(output_dims[1]) orelse return null;
    const out_n = positiveDim(output_dims[2]) orelse return null;
    if (batch != rhs_batch or batch != out_batch or k != rhs_k or m != out_m or n != out_n) return null;
    return .{ .batch = batch, .m = m, .n = n, .k = k };
}
pub fn matrixProductShape(lhs_dims: []const i64, rhs_dims: []const i64, output_dims: []const i64) ?MatrixProductShape {
    if (lhs_dims.len != 2 or rhs_dims.len != 2 or output_dims.len != 2) return null;
    const m = positiveDim(lhs_dims[0]) orelse return null;
    const k = positiveDim(lhs_dims[1]) orelse return null;
    const rhs_k = positiveDim(rhs_dims[0]) orelse return null;
    const n = positiveDim(rhs_dims[1]) orelse return null;
    const out_m = positiveDim(output_dims[0]) orelse return null;
    const out_n = positiveDim(output_dims[1]) orelse return null;
    if (k != rhs_k or m != out_m or n != out_n) return null;
    return .{ .m = m, .n = n, .k = k };
}
pub fn matrixVectorProductShape(matrix_dims: []const i64, vector_dims: []const i64, output_dims: []const i64) ?MatrixVectorProductShape {
    if (matrix_dims.len != 2 or vector_dims.len != 1 or output_dims.len != 1) return null;
    const m = positiveDim(matrix_dims[0]) orelse return null;
    const k = positiveDim(matrix_dims[1]) orelse return null;
    const vector_k = positiveDim(vector_dims[0]) orelse return null;
    const out_m = positiveDim(output_dims[0]) orelse return null;
    if (k != vector_k or m != out_m) return null;
    return .{ .m = m, .k = k };
}
pub fn outerProductShape(lhs_dims: []const i64, rhs_dims: []const i64, output_dims: []const i64) ?OuterProductShape {
    if (lhs_dims.len != 1 or rhs_dims.len != 1 or output_dims.len != 2) return null;
    const m = positiveDim(lhs_dims[0]) orelse return null;
    const n = positiveDim(rhs_dims[0]) orelse return null;
    const out_m = positiveDim(output_dims[0]) orelse return null;
    const out_n = positiveDim(output_dims[1]) orelse return null;
    if (m != out_m or n != out_n) return null;
    return .{ .m = m, .n = n };
}
