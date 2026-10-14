const catalog = @import("../../root.zig");

const query_mod = catalog;

const MatrixVectorProductQuery = query_mod.MatrixVectorProductQuery;

pub fn canonicalMatrixVectorProduct(query: MatrixVectorProductQuery) bool {
    if (!canonicalMatrixVectorProductRoles(
        query.matrix_indices,
        query.vector_indices,
        query.output_indices,
    )) return false;
    return query.matrix_dims.len == 2 and query.vector_dims.len == 1 and query.output_dims.len == 1;
}
pub fn canonicalMatrixVectorProductRoles(
    matrix_indices: []const u8,
    vector_indices: []const u8,
    output_indices: []const u8,
) bool {
    if (matrix_indices.len != 2 or vector_indices.len != 1 or output_indices.len != 1) return false;
    const row = matrix_indices[0];
    const reduction_axis = matrix_indices[1];
    if (row == reduction_axis) return false;
    return vector_indices[0] == reduction_axis and output_indices[0] == row;
}
