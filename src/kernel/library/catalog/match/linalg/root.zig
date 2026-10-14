const batched = @import("batched.zig");
const matrix = @import("matrix.zig");
const outer = @import("outer.zig");
const vector = @import("vector.zig");

pub const batchedMatrixProductDescriptorMatches = batched.batchedMatrixProductDescriptorMatches;
pub const matrixProductDescriptorMatches = matrix.matrixProductDescriptorMatches;
pub const matrixVectorProductDescriptorMatches = vector.matrixVectorProductDescriptorMatches;
pub const outerProductDescriptorMatches = outer.outerProductDescriptorMatches;
pub const matrixProductScheduleMatches = matrix.matrixProductScheduleMatches;
pub const matrixVectorProductScheduleMatches = vector.matrixVectorProductScheduleMatches;
pub const matrixProductSpecializationMatches = matrix.matrixProductSpecializationMatches;
pub const matrixVectorProductSpecializationMatches =
    vector.matrixVectorProductSpecializationMatches;
