const catalog = @import("../../root.zig");

const query_mod = catalog;

const OuterProductQuery = query_mod.OuterProductQuery;

pub fn canonicalOuterProduct(query: OuterProductQuery) bool {
    if (!canonicalOuterProductRoles(query.lhs_indices, query.rhs_indices, query.output_indices)) return false;
    return query.lhs_dims.len == 1 and query.rhs_dims.len == 1 and query.output_dims.len == 2;
}
fn canonicalOuterProductRoles(lhs_indices: []const u8, rhs_indices: []const u8, output_indices: []const u8) bool {
    if (lhs_indices.len != 1 or rhs_indices.len != 1 or output_indices.len != 2) return false;
    const row = lhs_indices[0];
    const col = rhs_indices[0];
    if (row == col) return false;
    return output_indices[0] == row and output_indices[1] == col;
}
