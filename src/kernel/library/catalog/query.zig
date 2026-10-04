const gpu_abi = @import("gpu_abi");
const activation_mod = @import("../../../choir/root.zig").activation;
const library = @import("../root.zig");

const entry = library.entry;
const histogram = library.histogram;

pub const Query = union(enum) {
    activation: ActivationQuery,
    attention: AttentionQuery,
    batched_matrix_product: BatchedMatrixProductQuery,
    fused: FusedQuery,
    gather: GatherQuery,
    layout: LayoutQuery,
    matrix_product: MatrixProductQuery,
    matrix_vector_product: MatrixVectorProductQuery,
    filter: FilterQuery,
    outer_product: OuterProductQuery,
    random: RandomQuery,
    reduction: ReductionQuery,
    row_normalization: RowNormalizationQuery,
    row_sparse_cross_entropy: RowSparseCrossEntropyQuery,
    scan: ScanQuery,
    sort: SortQuery,
    sparse: SparseQuery,
    spatial: SpatialQuery,
    image: ImageQuery,
    factor: FactorQuery,
    scatter: ScatterQuery,
    scatter_add: ScatterAddQuery,
    histogram: HistogramQuery,
    segmented: SegmentedQuery,
    stencil: StencilQuery,
};

pub const ActivationKind = activation_mod.Kind;

pub const ActivationQuery = struct {
    dtype: gpu_abi.DType,
    kind: ActivationKind,
    extent: u64,
};

pub const AttentionKind = entry.AttentionOperator;

pub const AttentionSchedule = union(enum) {
    thread_blocks: entry.Threads3D,
};

pub const AttentionQuery = struct {
    dtype: gpu_abi.DType,
    kind: AttentionKind,
    query_indices: []const u8,
    key_indices: []const u8,
    value_indices: []const u8,
    output_indices: []const u8,
    query_dims: []const i64,
    key_dims: []const i64,
    value_dims: []const i64,
    output_dims: []const i64,
    schedule: ?AttentionSchedule = null,
};

pub const FusedQuery = union(enum) {
    vector: FusedVectorQuery,
    matrix_product: FusedMatrixProductQuery,
    matrix_vector_product: FusedMatrixVectorProductQuery,
    row_normalization: FusedRowNormalizationQuery,
};

pub const FusedVectorKind = union(enum) {
    bias_activation: ActivationKind,
    gated_activation: ActivationKind,
};

pub const FusedVectorQuery = struct {
    dtype: gpu_abi.DType,
    kind: FusedVectorKind,
    extent: u64,
};

pub const FusedLinalgEpilogue = union(enum) {
    bias_activation: ActivationKind,
};

pub const FusedMatrixProductQuery = struct {
    dtype: gpu_abi.DType,
    epilogue: FusedLinalgEpilogue,
    lhs_indices: []const u8,
    rhs_indices: []const u8,
    bias_indices: []const u8,
    output_indices: []const u8,
    lhs_dims: []const i64,
    rhs_dims: []const i64,
    bias_dims: []const i64,
    output_dims: []const i64,
    schedule: ?MatrixProductSchedule = null,
};

pub const FusedMatrixVectorProductQuery = struct {
    dtype: gpu_abi.DType,
    epilogue: FusedLinalgEpilogue,
    matrix_indices: []const u8,
    vector_indices: []const u8,
    bias_indices: []const u8,
    output_indices: []const u8,
    matrix_dims: []const i64,
    vector_dims: []const i64,
    bias_dims: []const i64,
    output_dims: []const i64,
    schedule: ?MatrixVectorProductSchedule = null,
};

pub const MatrixProductSchedule = union(enum) {
    thread_blocks: entry.Threads2D,
};

pub const BatchedMatrixProductSchedule = union(enum) {
    thread_blocks: entry.Threads3D,
};

pub const MatrixVectorProductSchedule = union(enum) {
    thread_blocks: u32,
};

pub const OuterProductSchedule = union(enum) {
    thread_blocks: entry.Threads2D,
};

pub const FusedRowNormalizationKind = union(enum) {
    residual: RowNormalizationKind,
};

pub const FusedRowNormalizationQuery = struct {
    dtype: gpu_abi.DType,
    kind: FusedRowNormalizationKind,
    rows: u64,
    cols: u64,
    schedule: ?RowNormalizationSchedule = null,
};

pub const LayoutKind = entry.LayoutOperator;

pub const LayoutQuery = struct {
    dtype: gpu_abi.DType,
    kind: LayoutKind,
    input_indices: []const u8,
    output_indices: []const u8,
    input_dims: []const i64,
    output_dims: []const i64,
};

pub const TransposeQuery = LayoutQuery;

pub const MatrixProductQuery = struct {
    dtype: gpu_abi.DType,
    lhs_indices: []const u8,
    rhs_indices: []const u8,
    output_indices: []const u8,
    lhs_dims: []const i64,
    rhs_dims: []const i64,
    output_dims: []const i64,
    schedule: ?MatrixProductSchedule = null,
};

pub const BatchedMatrixProductQuery = struct {
    dtype: gpu_abi.DType,
    lhs_indices: []const u8,
    rhs_indices: []const u8,
    output_indices: []const u8,
    lhs_dims: []const i64,
    rhs_dims: []const i64,
    output_dims: []const i64,
    schedule: ?BatchedMatrixProductSchedule = null,
};

pub const MatrixVectorProductQuery = struct {
    dtype: gpu_abi.DType,
    matrix_indices: []const u8,
    vector_indices: []const u8,
    output_indices: []const u8,
    matrix_dims: []const i64,
    vector_dims: []const i64,
    output_dims: []const i64,
    schedule: ?MatrixVectorProductSchedule = null,
};

pub const OuterProductQuery = struct {
    dtype: gpu_abi.DType,
    lhs_indices: []const u8,
    rhs_indices: []const u8,
    output_indices: []const u8,
    lhs_dims: []const i64,
    rhs_dims: []const i64,
    output_dims: []const i64,
    schedule: ?OuterProductSchedule = null,
};

pub const ReductionKind = entry.ReductionOperator;

pub const ReductionOperand = struct {
    indices: []const u8,
    dims: []const i64,
};

pub const ReductionQuery = struct {
    dtype: gpu_abi.DType,
    kind: ReductionKind,
    inputs: []const ReductionOperand,
    output_indices: []const u8,
    output_dims: []const i64,
};

pub const RowNormalizationParameterization = entry.RowNormalizationParameterization;
pub const RowNormalizationKind = entry.RowNormalizationOperator;

pub const RowNormalizationSchedule = union(enum) {
    thread_blocks: entry.Threads2D,
};

pub const RowNormalizationQuery = struct {
    dtype: gpu_abi.DType,
    kind: RowNormalizationKind,
    rows: u64,
    cols: u64,
    schedule: ?RowNormalizationSchedule = null,
};

pub const RowSparseCrossEntropySchedule = union(enum) {
    thread_blocks: u32,
};

pub const RowSparseCrossEntropyQuery = struct {
    dtype: gpu_abi.DType,
    rows: u64,
    classes: u64,
    schedule: ?RowSparseCrossEntropySchedule = null,
};

pub const GatherSchedule = union(enum) {
    thread_blocks: u32,
};

pub const GatherQuery = struct {
    dtype: gpu_abi.DType,
    outer: u64 = 1,
    axis_size: u64,
    gathered: u64,
    inner: u64 = 1,
    schedule: ?GatherSchedule = null,
};

pub const CompactionPredicateKind = enum {
    nonzero,
    greater_than,
};

pub const FilterSchedule = union(enum) {
    thread_blocks: u32,
};

pub const FilterQuery = struct {
    dtype: gpu_abi.DType,
    predicate: CompactionPredicateKind = .nonzero,
    extent: u64,
    schedule: ?FilterSchedule = null,
};

pub const RandomAlgorithm = enum {
    philox,
    threefry,
    squares,
};

pub const RandomSchedule = union(enum) {
    thread_blocks: u32,
};

pub const RandomQuery = struct {
    dtype: gpu_abi.DType,
    algorithm: RandomAlgorithm = .philox,
    count: u64,
    rounds: u32 = 0,
    schedule: ?RandomSchedule = null,
};

pub const ScatterSchedule = union(enum) {
    thread_blocks: u32,
};

pub const ScatterAddSchedule = union(enum) {
    thread_blocks: u32,
    shared_bins: u32,
};

pub const HistogramSchedule = union(enum) {
    thread_blocks: u32,
    shared_bins: u32,
};

pub const HistogramBinningPolicy = histogram.HistogramBinningPolicy;

pub const HistogramQuery = struct {
    dtype: gpu_abi.DType,
    bins: u64,
    count: u64,
    binning: HistogramBinningPolicy = .lower_inclusive_upper_exclusive,
    schedule: ?HistogramSchedule = null,
};

pub const ScatterAddQuery = struct {
    dtype: gpu_abi.DType,
    outer: u64 = 1,
    axis_size: u64,
    updates: u64,
    inner: u64 = 1,
    schedule: ?ScatterAddSchedule = null,
};

pub const ScatterQuery = struct {
    dtype: gpu_abi.DType,
    outer: u64 = 1,
    axis_size: u64,
    updates: u64,
    inner: u64 = 1,
    schedule: ?ScatterSchedule = null,
};

pub const ScanKind = entry.ScanOperator;

pub const ScanSchedule = union(enum) {
    thread_blocks: u32,
};

pub const ScanQuery = struct {
    dtype: gpu_abi.DType,
    kind: ScanKind,
    extent: u64,
    schedule: ?ScanSchedule = null,
};

pub const SortKind = entry.SortOperator;

pub const SortSchedule = union(enum) {
    thread_blocks: u32,
};

pub const SortStructure = enum {
    radix_split,
    radix_digit,
    bitonic_block,
    top_k_block,
    top_k_block_pairs,
};

/// A caller fills this request to get a sort kernel from the kernel library, the package's
/// hand-written kernel families, chosen by a typed request. The request names the element type, the
/// sort operation, the number of elements, and `k` for the operations that keep only the first `k`
/// results. `structure` picks one way to carry out the sort, such as a radix pass or a bitonic
/// block, and `schedule` picks a thread-block size. Setting `structure` or `schedule` changes how
/// the sort is built and leaves the sort that is computed the same.
pub const SortQuery = struct {
    dtype: gpu_abi.DType,
    kind: SortKind,
    extent: u64,
    k: u64 = 0,
    structure: ?SortStructure = null,
    schedule: ?SortSchedule = null,
};

pub const FactorTileLayout = enum {
    row_major,
    interleaved,
};

pub const FactorKind = union(enum) {
    batched_cholesky: struct { n: u32, batch: u64 },
    batched_cholesky_solve: struct { n: u32, batch: u64 },
    batched_inverse: struct { n: u32, batch: u64 },
};

pub const FactorSchedule = union(enum) {
    thread_blocks: u32,
};

/// A caller fills this request to get a batched Cholesky factorization, Cholesky solve or matrix
/// inverse from the kernel library. The request names the element type, the operation with its
/// matrix size `n` and batch count, the buffer layout, and an optional thread-block count. `layout`
/// states how the matrices sit in the device buffer, row by row or interleaved across the batch.
/// Because the layout changes where each element is read, it is part of which kernel the request
/// names, and it enters the kernel's name.
pub const FactorQuery = struct {
    dtype: gpu_abi.DType,
    kind: FactorKind,
    layout: FactorTileLayout = .row_major,
    schedule: ?FactorSchedule = null,
};

pub const SparseStructure = enum {
    element_thread,
    row_thread,
    row_warp,
    row_column_thread,
};

pub const SparseKind = union(enum) {
    coo_spmv: struct { rows: u64, nnz: u64, x_extent: u64 },
    csr_spmv: struct { rows: u64, nnz: u64, x_extent: u64 },
    csr_spmm: struct { rows: u64, columns: u64, nnz: u64, x_extent: u64 },
    ell_spmv: struct { rows: u64, slots: u64, x_extent: u64 },
    sell_spmv: struct { rows: u64, slice_size: u64, values_size: u64, x_extent: u64 },
};

pub const SparseSchedule = union(enum) {
    thread_blocks: u32,
    thread_blocks_2d: entry.Threads2D,
};

pub const SparseQuery = struct {
    dtype: gpu_abi.DType,
    kind: SparseKind,
    structure: ?SparseStructure = null,
    schedule: ?SparseSchedule = null,
};

pub const SpatialKind = union(enum) {
    grid_cells,
    grid_count: struct { cells: u32 },
    grid_neighbor_count: struct { cells: u32, stride: u32 },
};

pub const SpatialSchedule = union(enum) {
    thread_blocks: u32,
};

/// A caller fills this request to get a grid kernel for points in the plane, such as assigning
/// points to cells or counting neighbors. The request names the element type, the grid operation,
/// the number of points, and an optional thread-block count. Each operation also carries the sizes
/// fixed when the kernel is compiled, such as the cell count and, for neighbor counting, the
/// stride, beside the point count, which is given at run time.
pub const SpatialQuery = struct {
    dtype: gpu_abi.DType,
    kind: SpatialKind,
    count: u64,
    schedule: ?SpatialSchedule = null,
};

pub const ImageKind = union(enum) {
    blur_pass: struct {
        radius: u32 = 1,
        axis: library.image.Axis,
    },
    resize_bilinear: struct {
        src_width: u64,
        src_height: u64,
    },
};

pub const ImageSchedule = union(enum) {
    thread_blocks: entry.Threads2D,
};

pub const ImageQuery = struct {
    dtype: gpu_abi.DType,
    kind: ImageKind,
    width: u64,
    height: u64,
    schedule: ?ImageSchedule = null,
};

pub const SegmentedKind = entry.SegmentedOperator;

pub const SegmentedSchedule = union(enum) {
    thread_blocks: u32,
    warp_blocks: u32,
};

pub const SegmentedQuery = struct {
    dtype: gpu_abi.DType,
    kind: SegmentedKind,
    segments: u64,
    total: u64,
    schedule: ?SegmentedSchedule = null,
};

pub const StencilKind = entry.StencilOperator;

pub const StencilSchedule = union(enum) {
    thread_blocks: entry.Threads2D,
};

pub const StencilQuery = struct {
    dtype: gpu_abi.DType,
    kind: StencilKind,
    rows: u64,
    cols: u64,
    radius: u32 = 1,
    schedule: ?StencilSchedule = null,
};

pub const ArtifactRequest = struct {
    target: []const u8,
    version: u32 = 1,
    options: entry.ArtifactOptions,
};
