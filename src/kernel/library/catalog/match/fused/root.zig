const matrix = @import("matrix/root.zig");
const row_normalization = @import("normalization.zig");
const vector = @import("vector.zig");

pub const fusedVectorDescriptorMatches = vector.fusedVectorDescriptorMatches;
pub const fusedMatrixProductDescriptorMatches = matrix.fusedMatrixProductDescriptorMatches;
pub const fusedMatrixVectorProductDescriptorMatches =
    matrix.fusedMatrixVectorProductDescriptorMatches;
pub const fusedRowNormalizationDescriptorMatches =
    row_normalization.fusedRowNormalizationDescriptorMatches;
