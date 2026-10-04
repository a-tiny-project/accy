const batched_matrix_product = @import("batch.zig");
const matrix_product = @import("matrix.zig");
const matrix_vector = @import("vector.zig");
const outer_product = @import("outer.zig");

pub const MatrixProductCandidateDescriptors = matrix_product.MatrixProductCandidateDescriptors;
pub const selectMatrixProduct = matrix_product.selectMatrixProduct;
pub const selectMatrixProductCandidates = matrix_product.selectMatrixProductCandidates;
pub const selectBatchedMatrixProduct = batched_matrix_product.selectBatchedMatrixProduct;
pub const selectMatrixVectorProduct = matrix_vector.selectMatrixVectorProduct;
pub const selectOuterProduct = outer_product.selectOuterProduct;
