const catalog = @import("../../root.zig");

const query_mod = catalog;
const dimension = @import("dimension.zig");
const model = @import("model.zig");

const TransposeQuery = query_mod.TransposeQuery;
const TransposeShape = model.TransposeShape;
const positiveDim = dimension.positiveDim;

pub fn transposeShape(query: TransposeQuery) ?TransposeShape {
    if (query.input_indices.len != 2 or query.output_indices.len != 2) return null;
    if (query.input_indices[0] == query.input_indices[1]) return null;
    if (query.output_indices[0] != query.input_indices[1]) return null;
    if (query.output_indices[1] != query.input_indices[0]) return null;
    if (query.input_dims.len != 2 or query.output_dims.len != 2) return null;
    const rows = positiveDim(query.input_dims[0]) orelse return null;
    const cols = positiveDim(query.input_dims[1]) orelse return null;
    const out_cols = positiveDim(query.output_dims[0]) orelse return null;
    const out_rows = positiveDim(query.output_dims[1]) orelse return null;
    if (rows != out_rows or cols != out_cols) return null;
    return .{ .rows = rows, .cols = cols };
}
