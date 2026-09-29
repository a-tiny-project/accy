const catalog = @import("../../root.zig");

const query_mod = catalog;
const dimension = @import("dimension.zig");
const model = @import("model.zig");

const ReductionQuery = query_mod.ReductionQuery;
const ReductionShape = model.ReductionShape;
const positiveDim = dimension.positiveDim;

pub fn reductionShape(query: ReductionQuery) ?ReductionShape {
    if (query.output_indices.len != 0 or query.output_dims.len != 0) return null;
    return switch (query.kind) {
        .sum => sumReductionShape(query),
        .dot_product => dotProductReductionShape(query),
        else => null,
    };
}
fn sumReductionShape(query: ReductionQuery) ?ReductionShape {
    if (query.inputs.len != 1) return null;
    const input = query.inputs[0];
    if (input.indices.len != 1 or input.dims.len != 1) return null;
    const extent = positiveDim(input.dims[0]) orelse return null;
    return .{ .extent = extent };
}
fn dotProductReductionShape(query: ReductionQuery) ?ReductionShape {
    if (query.inputs.len != 2) return null;
    const lhs = query.inputs[0];
    const rhs = query.inputs[1];
    if (lhs.indices.len != 1 or rhs.indices.len != 1) return null;
    if (lhs.indices[0] != rhs.indices[0]) return null;
    if (lhs.dims.len != 1 or rhs.dims.len != 1) return null;
    const extent = positiveDim(lhs.dims[0]) orelse return null;
    const rhs_extent = positiveDim(rhs.dims[0]) orelse return null;
    if (extent != rhs_extent) return null;
    return .{ .extent = extent };
}
