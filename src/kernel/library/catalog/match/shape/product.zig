const catalog = @import("../../root.zig");

const query_mod = catalog;

const BatchedMatrixProductQuery = query_mod.BatchedMatrixProductQuery;
const MatrixProductQuery = query_mod.MatrixProductQuery;

pub fn canonicalBatchedMatrixProduct(query: BatchedMatrixProductQuery) bool {
    if (!canonicalBatchedMatrixProductRoles(query.lhs_indices, query.rhs_indices, query.output_indices)) return false;
    return query.lhs_dims.len == 3 and query.rhs_dims.len == 3 and query.output_dims.len == 3;
}
fn canonicalBatchedMatrixProductRoles(lhs_indices: []const u8, rhs_indices: []const u8, output_indices: []const u8) bool {
    if (lhs_indices.len != 3 or rhs_indices.len != 3 or output_indices.len != 3) return false;
    const batch = lhs_indices[0];
    const row = lhs_indices[1];
    const reduction_axis = lhs_indices[2];
    const rhs_batch = rhs_indices[0];
    const rhs_reduction_axis = rhs_indices[1];
    const col = rhs_indices[2];
    if (batch == row or batch == reduction_axis or batch == col or row == reduction_axis or row == col or reduction_axis == col) return false;
    return batch == rhs_batch and
        reduction_axis == rhs_reduction_axis and
        output_indices[0] == batch and
        output_indices[1] == row and
        output_indices[2] == col;
}
pub fn canonicalMatrixProduct(query: MatrixProductQuery) bool {
    if (!canonicalMatrixProductRoles(query.lhs_indices, query.rhs_indices, query.output_indices)) return false;
    return query.lhs_dims.len == 2 and query.rhs_dims.len == 2 and query.output_dims.len == 2;
}
pub fn canonicalMatrixProductRoles(lhs_indices: []const u8, rhs_indices: []const u8, output_indices: []const u8) bool {
    if (lhs_indices.len != 2 or rhs_indices.len != 2 or output_indices.len != 2) return false;
    const row = lhs_indices[0];
    const reduction_axis = lhs_indices[1];
    const rhs_reduction_axis = rhs_indices[0];
    const col = rhs_indices[1];
    if (row == reduction_axis or row == col or reduction_axis == col) return false;
    return reduction_axis == rhs_reduction_axis and
        output_indices[0] == row and
        output_indices[1] == col;
}
