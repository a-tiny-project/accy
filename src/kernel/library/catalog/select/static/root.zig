const descriptor_mod = @import("../../root.zig");
const query_mod = descriptor_mod;

const activation = @import("activation.zig");
const attention = @import("attention.zig");
const filter = @import("filter.zig");
const fused = @import("fused.zig");
const gather = @import("gather.zig");
const layout = @import("layout.zig");
const linalg = @import("linalg.zig");
const normalization = @import("normalization.zig");
const random = @import("random.zig");
const reduction = @import("reduction.zig");
const scan = @import("scan.zig");
const scatter = @import("scatter.zig");
const segmented = @import("segmented.zig");
const stencil = @import("stencil.zig");

const Descriptor = descriptor_mod.Descriptor;
const Query = query_mod.Query;

pub fn select(query: Query) ?Descriptor {
    return switch (query) {
        .activation => |activation_query| activation.select(activation_query),
        .attention => |attention_query| attention.select(attention_query),
        .batched_matrix_product => |matrix_product| linalg.selectBatchedMatrixProduct(matrix_product),
        .fused => |fused_query| fused.select(fused_query),
        .filter => |filter_query| filter.select(filter_query),
        .gather => |gather_query| gather.select(gather_query),
        .layout => |layout_query| layout.select(layout_query),
        .matrix_product => |matrix_product| linalg.selectMatrixProduct(matrix_product),
        .matrix_vector_product => |matrix_vector_product| linalg.selectMatrixVectorProduct(matrix_vector_product),
        .outer_product => |outer_product| linalg.selectOuterProduct(outer_product),
        .random => |random_query| random.select(random_query),
        .reduction => |reduction_query| reduction.select(reduction_query),
        .row_normalization => |row_normalization| normalization.select(row_normalization),
        .row_sparse_cross_entropy => null,
        .scan => |scan_query| scan.select(scan_query),
        .sort => null,
        .sparse => null,
        .spatial => null,
        .image => null,
        .factor => null,
        .scatter => |scatter_query| scatter.select(scatter_query),
        .scatter_add => null,
        .histogram => null,
        .segmented => |segmented_query| segmented.select(segmented_query),
        .stencil => |stencil_query| stencil.select(stencil_query),
    };
}
