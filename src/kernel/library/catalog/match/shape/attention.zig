const catalog = @import("../../root.zig");

const query_mod = catalog;
const dimension = @import("dimension.zig");
const model = @import("model.zig");

const AttentionQuery = query_mod.AttentionQuery;
const AttentionShape = model.AttentionShape;
const positiveDim = dimension.positiveDim;

pub fn attentionShape(query: AttentionQuery) ?AttentionShape {
    if (!canonicalAttentionRoles(query.query_indices, query.key_indices, query.value_indices, query.output_indices)) return null;
    if (query.query_dims.len != 3 or query.key_dims.len != 3 or query.value_dims.len != 3 or query.output_dims.len != 3) return null;
    const batch = positiveDim(query.query_dims[0]) orelse return null;
    const queries = positiveDim(query.query_dims[1]) orelse return null;
    const qk = positiveDim(query.query_dims[2]) orelse return null;
    const key_batch = positiveDim(query.key_dims[0]) orelse return null;
    const keys = positiveDim(query.key_dims[1]) orelse return null;
    const key_qk = positiveDim(query.key_dims[2]) orelse return null;
    const value_batch = positiveDim(query.value_dims[0]) orelse return null;
    const value_keys = positiveDim(query.value_dims[1]) orelse return null;
    const value = positiveDim(query.value_dims[2]) orelse return null;
    const out_batch = positiveDim(query.output_dims[0]) orelse return null;
    const out_queries = positiveDim(query.output_dims[1]) orelse return null;
    const out_value = positiveDim(query.output_dims[2]) orelse return null;
    if (batch != key_batch or batch != value_batch or batch != out_batch) return null;
    if (queries != out_queries or qk != key_qk or keys != value_keys or value != out_value) return null;
    return .{ .batch = batch, .queries = queries, .keys = keys, .qk = qk, .value = value };
}

fn canonicalAttentionRoles(query_indices: []const u8, key_indices: []const u8, value_indices: []const u8, output_indices: []const u8) bool {
    if (query_indices.len != 3 or key_indices.len != 3 or value_indices.len != 3 or output_indices.len != 3) return false;
    const batch = query_indices[0];
    const query = query_indices[1];
    const qk = query_indices[2];
    const key_batch = key_indices[0];
    const key = key_indices[1];
    const key_qk = key_indices[2];
    const value_batch = value_indices[0];
    const value_key = value_indices[1];
    const value = value_indices[2];
    if (batch == query or batch == key or batch == qk or batch == value or query == key or query == qk or query == value or key == qk or key == value or qk == value) return false;
    return batch == key_batch and
        batch == value_batch and
        qk == key_qk and
        key == value_key and
        output_indices[0] == batch and
        output_indices[1] == query and
        output_indices[2] == value;
}
