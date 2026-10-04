pub const MatrixProductShape = struct {
    m: u64,
    n: u64,
    k: u64,
};
pub const BatchedMatrixProductShape = struct {
    batch: u64,
    m: u64,
    n: u64,
    k: u64,
};
pub const AttentionShape = struct {
    batch: u64,
    queries: u64,
    keys: u64,
    qk: u64,
    value: u64,
};
pub const MatrixVectorProductShape = struct {
    m: u64,
    k: u64,
};
pub const OuterProductShape = struct {
    m: u64,
    n: u64,
};
pub const TransposeShape = struct {
    rows: u64,
    cols: u64,
};
pub const ReductionShape = struct {
    extent: u64,
};
