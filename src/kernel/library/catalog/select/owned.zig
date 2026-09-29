const std = @import("std");

const descriptor_mod = @import("../root.zig");
const family_mod = @import("../family/root.zig");
const query_mod = descriptor_mod;

const static = @import("static/root.zig");

const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const Query = query_mod.Query;

pub fn selectOwned(backing_allocator: std.mem.Allocator, query: Query) !?OwnedDescriptor {
    if (static.select(query)) |descriptor| return .{ .descriptor = descriptor };
    return switch (query) {
        .batched_matrix_product => |batched_matrix_product| family_mod.selectBatchedMatrixProduct(backing_allocator, batched_matrix_product),
        .matrix_product => |matrix_product| family_mod.selectMatrixProduct(backing_allocator, matrix_product),
        .matrix_vector_product => |matrix_vector_product| family_mod.selectMatrixVectorProduct(backing_allocator, matrix_vector_product),
        .outer_product => |outer_product| family_mod.selectOuterProduct(backing_allocator, outer_product),
        .stencil => |stencil_query| family_mod.selectStencilWindow(backing_allocator, stencil_query),
        .gather => |gather_query| family_mod.selectGather(backing_allocator, gather_query),
        .scan => |scan_query| family_mod.selectPrefixSum(backing_allocator, scan_query),
        .sort => |sort_query| family_mod.selectSort(backing_allocator, sort_query),
        .sparse => |sparse_query| family_mod.selectSparse(backing_allocator, sparse_query),
        .factor => |factor_query| family_mod.selectFactor(backing_allocator, factor_query),
        .spatial => |spatial_query| family_mod.selectSpatial(backing_allocator, spatial_query),
        .image => |image_query| family_mod.selectImage(backing_allocator, image_query),
        .scatter => |scatter_query| family_mod.selectScatter(backing_allocator, scatter_query),
        .scatter_add => |scatter_add_query| family_mod.selectScatterAdd(backing_allocator, scatter_add_query),
        .row_sparse_cross_entropy => |loss_query| family_mod.selectRowSparseCrossEntropy(backing_allocator, loss_query),
        .histogram => |histogram_query| family_mod.selectHistogram(backing_allocator, histogram_query),
        .segmented => |segmented_query| family_mod.selectSegmentSum(backing_allocator, segmented_query),
        .random => |random_query| family_mod.selectRandom(backing_allocator, random_query),
        .filter => |filter_query| family_mod.selectFilter(backing_allocator, filter_query),
        else => null,
    };
}
