const catalog = @import("../../root.zig");

const query_mod = catalog;
const dimension = @import("dimension.zig");
const model = @import("model.zig");
const product = @import("product.zig");
const vector = @import("vector.zig");
const matrix = @import("matrix.zig");

const FusedMatrixProductQuery = query_mod.FusedMatrixProductQuery;
const FusedMatrixVectorProductQuery = query_mod.FusedMatrixVectorProductQuery;
const MatrixProductShape = model.MatrixProductShape;
const MatrixVectorProductShape = model.MatrixVectorProductShape;
const positiveDim = dimension.positiveDim;
const canonicalMatrixProductRoles = product.canonicalMatrixProductRoles;
const canonicalMatrixVectorProductRoles = vector.canonicalMatrixVectorProductRoles;
const matrixProductShape = matrix.matrixProductShape;
const matrixVectorProductShape = matrix.matrixVectorProductShape;

pub fn fusedMatrixProductShape(query: FusedMatrixProductQuery) ?MatrixProductShape {
    if (!canonicalMatrixProductRoles(query.lhs_indices, query.rhs_indices, query.output_indices)) {
        return null;
    }
    if (query.bias_indices.len != 1 or query.bias_dims.len != 1) return null;
    if (query.bias_indices[0] != query.rhs_indices[1]) return null;
    const shape = matrixProductShape(
        query.lhs_dims,
        query.rhs_dims,
        query.output_dims,
    ) orelse return null;
    const bias_n = positiveDim(query.bias_dims[0]) orelse return null;
    if (bias_n != shape.n) return null;
    return shape;
}
pub fn fusedMatrixVectorProductShape(
    query: FusedMatrixVectorProductQuery,
) ?MatrixVectorProductShape {
    if (!canonicalMatrixVectorProductRoles(
        query.matrix_indices,
        query.vector_indices,
        query.output_indices,
    )) return null;
    if (query.bias_indices.len != 1 or query.bias_dims.len != 1) return null;
    if (query.bias_indices[0] != query.output_indices[0]) return null;
    const shape = matrixVectorProductShape(
        query.matrix_dims,
        query.vector_dims,
        query.output_dims,
    ) orelse return null;
    const bias_m = positiveDim(query.bias_dims[0]) orelse return null;
    if (bias_m != shape.m) return null;
    return shape;
}
