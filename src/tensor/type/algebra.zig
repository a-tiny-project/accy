const std = @import("std");
const axis_roles = @import("../../axis/root.zig").roles;
const dim_mod = @import("dim.zig");

const Dim = dim_mod.Dim;
const Type = dim_mod.Type;
const findDim = dim_mod.findDim;
const sameDims = dim_mod.sameDims;

pub fn unionDims(allocator: std.mem.Allocator, lhs: []const Dim, rhs: []const Dim) ![]const Dim {
    var count: usize = lhs.len;
    for (rhs) |dim| {
        if (findDim(lhs, dim.name)) |index| {
            if (lhs[index].extent != dim.extent) return error.AxisExtentMismatch;
        } else {
            count += 1;
        }
    }
    const result = try allocator.alloc(Dim, count);
    for (lhs, 0..) |dim, index| {
        result[index] = dim;
    }
    var out: usize = lhs.len;
    for (rhs) |dim| {
        if (findDim(lhs, dim.name) == null) {
            result[out] = dim;
            out += 1;
        }
    }
    return result;
}

pub const Alignment = struct {
    permutation: ?[]const i64 = null,
    mapping: ?[]const i64 = null,

    pub fn identity(self: Alignment) bool {
        return self.permutation == null and self.mapping == null;
    }
};

pub fn alignment(
    allocator: std.mem.Allocator,
    operand: []const Dim,
    target: []const Dim,
) !Alignment {
    if (sameDims(operand, target)) return .{};

    const positions = try allocator.alloc(i64, operand.len);
    for (operand, positions) |dim, *slot| {
        const index = findDim(target, dim.name) orelse return error.AxisNotFound;
        if (target[index].extent != dim.extent) return error.AxisExtentMismatch;
        slot.* = @intCast(index);
    }

    var increasing = true;
    for (positions, 0..) |position, index| {
        if (index > 0 and positions[index - 1] >= position) {
            increasing = false;
            break;
        }
    }

    if (increasing) {
        return .{ .mapping = positions };
    }

    const order = try allocator.alloc(i64, operand.len);
    for (order, 0..) |*slot, index| {
        slot.* = @intCast(index);
    }
    std.mem.sort(i64, @constCast(order), positions, positionLessThan);

    const mapping = try allocator.alloc(i64, operand.len);
    for (order, mapping) |source, *slot| {
        slot.* = positions[@intCast(source)];
    }
    return .{ .permutation = order, .mapping = mapping };
}

fn positionLessThan(positions: []const i64, lhs: i64, rhs: i64) bool {
    return positions[@intCast(lhs)] < positions[@intCast(rhs)];
}

pub fn axisIndices(
    allocator: std.mem.Allocator,
    dims: []const Dim,
    names: []const []const u8,
) ![]const i64 {
    if (names.len == 0) return error.AxisNotFound;
    const indices = try allocator.alloc(i64, names.len);
    for (names, 0..) |name, position| {
        const index = findDim(dims, name) orelse return error.AxisNotFound;
        for (indices[0..position]) |seen| {
            if (seen == @as(i64, @intCast(index))) return error.DuplicateAxis;
        }
        indices[position] = @intCast(index);
    }
    std.mem.sort(i64, @constCast(indices), {}, std.sort.asc(i64));
    return indices;
}

pub fn removeAxes(allocator: std.mem.Allocator, dims: []const Dim, axes: []const i64) ![]const Dim {
    try validateAxes(dims.len, axes);
    const result = try allocator.alloc(Dim, dims.len - axes.len);
    var out: usize = 0;
    for (dims, 0..) |dim, index| {
        if (!containsAxis(axes, index)) {
            result[out] = dim;
            out += 1;
        }
    }
    return result;
}

pub fn reducedExtentProduct(dims: []const Dim, axes: []const i64) !usize {
    var product: usize = 1;
    for (axes) |axis| {
        const extent = dims[@intCast(axis)].extent;
        product = std.math.mul(usize, product, @intCast(
            extent,
        )) catch return error.ShapeElementOverflow;
    }
    return product;
}

pub fn permuted(
    allocator: std.mem.Allocator,
    dims: []const Dim,
    permutation: []const i64,
) ![]const Dim {
    try validatePermutation(dims.len, permutation);
    const result = try allocator.alloc(Dim, dims.len);
    for (permutation, 0..) |axis, index| {
        result[index] = dims[@intCast(axis)];
    }
    return result;
}

pub fn insertDim(
    allocator: std.mem.Allocator,
    dims: []const Dim,
    index: usize,
    inserted: Dim,
) ![]const Dim {
    if (index > dims.len) return error.AxisOutOfRange;
    if (findDim(dims, inserted.name) != null) return error.DuplicateAxis;
    const result = try allocator.alloc(Dim, dims.len + 1);
    for (dims[0..index], 0..) |dim, out| {
        result[out] = dim;
    }
    result[index] = inserted;
    for (dims[index..], index + 1..) |dim, out| {
        result[out] = dim;
    }
    return result;
}

pub fn appendDims(
    allocator: std.mem.Allocator,
    dims: []const Dim,
    added: []const Dim,
) ![]const Dim {
    for (added) |dim| {
        if (findDim(dims, dim.name) != null) return error.DuplicateAxis;
    }
    const result = try allocator.alloc(Dim, dims.len + added.len);
    for (dims, 0..) |dim, index| {
        result[index] = dim;
    }
    for (added, dims.len..) |dim, index| {
        result[index] = dim;
    }
    return result;
}

pub fn renamed(
    allocator: std.mem.Allocator,
    dims: []const Dim,
    old_name: []const u8,
    new_name: []const u8,
) ![]const Dim {
    const index = findDim(dims, old_name) orelse return error.AxisNotFound;
    if (findDim(dims, new_name) != null) return error.DuplicateAxis;
    const result = try allocator.alloc(Dim, dims.len);
    for (dims, result) |dim, *slot| {
        slot.* = dim;
    }
    result[index] = .{ .name = new_name, .extent = dims[index].extent };
    return result;
}

pub fn splitDims(
    allocator: std.mem.Allocator,
    dims: []const Dim,
    axis_name: []const u8,
    parts: []const Dim,
) ![]const Dim {
    const index = findDim(dims, axis_name) orelse return error.AxisNotFound;
    var product: i64 = 1;
    for (parts, 0..) |part, position| {
        if (part.extent < 0) return error.InvalidDimension;
        product = std.math.mul(i64, product, part.extent) catch return error.ShapeElementOverflow;
        for (parts[0..position]) |seen| {
            if (std.mem.eql(u8, seen.name, part.name)) return error.DuplicateAxis;
        }
    }
    if (product != dims[index].extent) return error.SplitExtentMismatch;
    for (parts) |part| {
        if (findDim(dims, part.name)) |existing| {
            if (existing != index) return error.DuplicateAxis;
        }
    }
    const result = try allocator.alloc(Dim, dims.len - 1 + parts.len);
    var out: usize = 0;
    for (dims[0..index]) |dim| {
        result[out] = dim;
        out += 1;
    }
    for (parts) |part| {
        result[out] = part;
        out += 1;
    }
    for (dims[index + 1 ..]) |dim| {
        result[out] = dim;
        out += 1;
    }
    return result;
}

pub const Merge = struct {
    permutation: ?[]const i64 = null,
    result: []const Dim,
};

pub fn mergeDims(
    allocator: std.mem.Allocator,
    dims: []const Dim,
    names: []const []const u8,
    merged_name: []const u8,
) !Merge {
    if (names.len == 0) return error.AxisNotFound;
    const merge_indices = try allocator.alloc(usize, names.len);
    var block_start: usize = dims.len;
    var extent: i64 = 1;
    for (names, merge_indices) |name, *slot| {
        const index = findDim(dims, name) orelse return error.AxisNotFound;
        for (merge_indices[0 .. slot - merge_indices.ptr]) |seen| {
            if (seen == index) return error.DuplicateAxis;
        }
        slot.* = index;
        block_start = @min(block_start, index);
        extent = std.math.mul(
            i64,
            extent,
            dims[index].extent,
        ) catch return error.MergeExtentOverflow;
    }
    if (findDim(dims, merged_name)) |existing| {
        if (!containsIndex(merge_indices, existing)) return error.DuplicateAxis;
    }

    const permutation = try allocator.alloc(i64, dims.len);
    var out: usize = 0;
    for (dims, 0..) |_, index| {
        if (index == block_start) {
            for (merge_indices) |merge_index| {
                permutation[out] = @intCast(merge_index);
                out += 1;
            }
        }
        if (!containsIndex(merge_indices, index)) {
            permutation[out] = @intCast(index);
            out += 1;
        }
    }

    var is_identity = true;
    for (permutation, 0..) |axis, index| {
        if (axis != @as(i64, @intCast(index))) {
            is_identity = false;
            break;
        }
    }

    const result = try allocator.alloc(Dim, dims.len - names.len + 1);
    out = 0;
    for (dims, 0..) |dim, index| {
        if (index == block_start) {
            result[out] = .{ .name = merged_name, .extent = extent };
            out += 1;
        }
        if (!containsIndex(merge_indices, index)) {
            result[out] = dim;
            out += 1;
        }
    }

    return .{
        .permutation = if (is_identity) null else permutation,
        .result = result,
    };
}

fn containsIndex(indices: []const usize, index: usize) bool {
    for (indices) |candidate| {
        if (candidate == index) return true;
    }
    return false;
}

pub const Contraction = struct {
    lhs_contract: []const i64,
    rhs_contract: []const i64,
    lhs_batch: []const i64,
    rhs_batch: []const i64,
    result: []const Dim,
};

pub fn contraction(
    allocator: std.mem.Allocator,
    lhs: []const Dim,
    rhs: []const Dim,
    names: []const []const u8,
) !Contraction {
    if (names.len == 0) return error.AxisNotFound;
    const lhs_contract = try allocator.alloc(i64, names.len);
    const rhs_contract = try allocator.alloc(i64, names.len);
    for (names, 0..) |name, position| {
        const lhs_index = findDim(lhs, name) orelse return error.AxisNotFound;
        const rhs_index = findDim(rhs, name) orelse return error.AxisNotFound;
        if (lhs[lhs_index].extent != rhs[rhs_index].extent) return error.AxisExtentMismatch;
        for (lhs_contract[0..position]) |seen| {
            if (seen == @as(i64, @intCast(lhs_index))) return error.DuplicateAxis;
        }
        lhs_contract[position] = @intCast(lhs_index);
        rhs_contract[position] = @intCast(rhs_index);
    }

    var batch_count: usize = 0;
    for (lhs, 0..) |dim, index| {
        if (containsAxis(lhs_contract, index)) continue;
        if (findDim(rhs, dim.name) != null) batch_count += 1;
    }

    const lhs_batch = try allocator.alloc(i64, batch_count);
    const rhs_batch = try allocator.alloc(i64, batch_count);
    var result_count: usize = batch_count;
    var batch_out: usize = 0;
    for (lhs, 0..) |dim, index| {
        if (containsAxis(lhs_contract, index)) continue;
        if (findDim(rhs, dim.name)) |rhs_index| {
            if (dim.extent != rhs[rhs_index].extent) return error.AxisExtentMismatch;
            lhs_batch[batch_out] = @intCast(index);
            rhs_batch[batch_out] = @intCast(rhs_index);
            batch_out += 1;
        } else {
            result_count += 1;
        }
    }
    for (rhs, 0..) |_, index| {
        if (containsAxis(rhs_contract, index)) continue;
        if (containsAxis(rhs_batch, index)) continue;
        result_count += 1;
    }

    const result = try allocator.alloc(Dim, result_count);
    var out: usize = 0;
    for (lhs_batch) |index| {
        result[out] = lhs[@intCast(index)];
        out += 1;
    }
    for (lhs, 0..) |dim, index| {
        if (containsAxis(lhs_contract, index) or containsAxis(lhs_batch, index)) continue;
        result[out] = dim;
        out += 1;
    }
    for (rhs, 0..) |dim, index| {
        if (containsAxis(rhs_contract, index) or containsAxis(rhs_batch, index)) continue;
        if (findDim(result[0..out], dim.name) != null) return error.DuplicateAxis;
        result[out] = dim;
        out += 1;
    }

    return .{
        .lhs_contract = lhs_contract,
        .rhs_contract = rhs_contract,
        .lhs_batch = lhs_batch,
        .rhs_batch = rhs_batch,
        .result = result,
    };
}

pub fn dotGeneralDims(
    allocator: std.mem.Allocator,
    lhs: []const Dim,
    rhs: []const Dim,
    lhs_contract: []const i64,
    rhs_contract: []const i64,
    lhs_batch: []const i64,
    rhs_batch: []const i64,
) ![]const Dim {
    try validateAxes(lhs.len, lhs_contract);
    try validateAxes(rhs.len, rhs_contract);
    try validateAxes(lhs.len, lhs_batch);
    try validateAxes(rhs.len, rhs_batch);
    if (axis_roles.groupsOverlap(&.{ lhs_contract, lhs_batch })) {
        return error.DuplicateAxis;
    }
    if (axis_roles.groupsOverlap(&.{ rhs_contract, rhs_batch })) {
        return error.DuplicateAxis;
    }
    if (lhs_contract.len != rhs_contract.len) return error.RankMismatch;
    if (lhs_batch.len != rhs_batch.len) return error.RankMismatch;
    for (lhs_contract, rhs_contract) |lhs_axis, rhs_axis| {
        if (lhs[@intCast(lhs_axis)].extent != rhs[@intCast(rhs_axis)].extent) {
            return error.AxisExtentMismatch;
        }
    }
    for (lhs_batch, rhs_batch) |lhs_axis, rhs_axis| {
        if (lhs[@intCast(lhs_axis)].extent != rhs[@intCast(rhs_axis)].extent) {
            return error.AxisExtentMismatch;
        }
    }

    var result_count: usize = lhs_batch.len;
    for (lhs, 0..) |_, index| {
        if (containsAxis(lhs_contract, index) or containsAxis(lhs_batch, index)) continue;
        result_count += 1;
    }
    for (rhs, 0..) |_, index| {
        if (containsAxis(rhs_contract, index) or containsAxis(rhs_batch, index)) continue;
        result_count += 1;
    }

    const result = try allocator.alloc(Dim, result_count);
    var out: usize = 0;
    for (lhs_batch) |axis| {
        result[out] = lhs[@intCast(axis)];
        out += 1;
    }
    for (lhs, 0..) |dim, index| {
        if (containsAxis(lhs_contract, index) or containsAxis(lhs_batch, index)) continue;
        result[out] = dim;
        out += 1;
    }
    for (rhs, 0..) |dim, index| {
        if (containsAxis(rhs_contract, index) or containsAxis(rhs_batch, index)) continue;
        result[out] = dim;
        out += 1;
    }
    for (result, 0..) |dim, index| {
        for (result[0..index]) |seen| {
            if (std.mem.eql(u8, seen.name, dim.name)) return error.DuplicateAxis;
        }
    }
    return result;
}

pub fn gather(allocator: std.mem.Allocator, input: Type, indices: Type, axis: i64) !Type {
    if (indices.dtype != .i32) return error.DTypeMismatch;
    try validateAxes(input.rank(), &.{axis});

    const result = try allocator.alloc(Dim, input.rank() - 1 + indices.rank());
    defer allocator.free(result);
    const position: usize = @intCast(axis);
    var out: usize = 0;
    for (input.dims[0..position]) |dim| {
        result[out] = dim;
        out += 1;
    }
    for (indices.dims) |dim| {
        result[out] = dim;
        out += 1;
    }
    for (input.dims[position + 1 ..]) |dim| {
        result[out] = dim;
        out += 1;
    }
    return Type.init(allocator, input.dtype, result);
}

pub fn scatterAdd(
    allocator: std.mem.Allocator,
    input: Type,
    indices: Type,
    updates: Type,
    axis: i64,
) !Type {
    if (!input.dtype.isNumeric()) return error.DTypeMismatch;
    if (updates.dtype != input.dtype) return error.DTypeMismatch;
    const expected_updates = try gather(allocator, input, indices, axis);
    defer allocator.free(@constCast(expected_updates.dims));
    if (!sameDims(updates.dims, expected_updates.dims)) return error.ShapeMismatch;
    return Type.init(allocator, input.dtype, input.dims);
}

pub fn sparseCrossEntropy(
    allocator: std.mem.Allocator,
    logits: Type,
    targets: Type,
    axis: i64,
) !Type {
    if (!logits.dtype.isFloat()) return error.DTypeMismatch;
    if (targets.dtype != .i32) return error.DTypeMismatch;
    try validateAxes(logits.rank(), &.{axis});

    const expected_targets = try removeAxes(allocator, logits.dims, &.{axis});
    defer allocator.free(@constCast(expected_targets));
    if (!sameDims(targets.dims, expected_targets)) return error.ShapeMismatch;
    return Type.init(allocator, logits.dtype, targets.dims);
}

pub fn reshaped(allocator: std.mem.Allocator, from: Type, new_dims: []const Dim) !Type {
    const result = try Type.init(allocator, from.dtype, new_dims);
    if (try from.elementCount() != try result.elementCount()) return error.ReshapeElementMismatch;
    return result;
}

pub fn broadcastInDim(
    allocator: std.mem.Allocator,
    input: Type,
    result_dims: []const Dim,
    broadcast_dims: []const i64,
) !Type {
    if (broadcast_dims.len != input.rank()) return error.BroadcastRankMismatch;
    try validateAxes(result_dims.len, broadcast_dims);
    for (broadcast_dims, 0..) |axis, input_index| {
        const target = result_dims[@intCast(axis)];
        const input_dim = input.dims[input_index];
        if (input_dim.extent != 1 and input_dim.extent != target.extent) {
            return error.BroadcastDimensionMismatch;
        }
    }
    return Type.init(allocator, input.dtype, result_dims);
}

pub fn select(allocator: std.mem.Allocator, pred: Type, on_true: Type, on_false: Type) !Type {
    if (pred.dtype != .i1) return error.DTypeMismatch;
    if (on_true.dtype != on_false.dtype) return error.DTypeMismatch;
    if (!sameDims(on_true.dims, on_false.dims)) return error.ShapeMismatch;
    if (pred.rank() != 0 and !sameDims(pred.dims, on_true.dims)) return error.ShapeMismatch;
    return Type.init(allocator, on_true.dtype, on_true.dims);
}

pub fn validateAxes(rank: usize, axes: []const i64) !void {
    try validateAxisGroups(rank, &.{axes});
}

fn validateAxisGroups(
    rank: usize,
    groups: []const []const i64,
) !void {
    if (axis_roles.check(rank, groups)) |failure| {
        return switch (failure) {
            .out_of_range => error.AxisOutOfRange,
            .duplicate => error.DuplicateAxis,
        };
    }
}

pub fn validatePermutation(rank: usize, permutation: []const i64) !void {
    if (rank != permutation.len) return error.RankMismatch;
    try validateAxes(rank, permutation);
}

fn containsAxis(axes: []const i64, index: usize) bool {
    for (axes) |axis| {
        if (axis == @as(i64, @intCast(index))) return true;
    }
    return false;
}

const testing_dims_ab = [_]Dim{
    .{ .name = "a", .extent = 2 },
    .{ .name = "b", .extent = 3 },
};
