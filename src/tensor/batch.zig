const std = @import("std");
const emit = @import("emit.zig");
const hook = @import("hook.zig");
const interpret = @import("interpret/root.zig");
const program_mod = @import("program.zig");
const trace = @import("trace/root.zig");
const transform = @import("transform.zig");
const types = @import("type/root.zig");

pub const Axis = union(enum) {
    none,
    axis: usize,
};

pub const Options = struct {
    axis_size: i64,
    in_axes: []const Axis,
    out_axis: usize = 0,
    axis_name: []const u8 = &.{},
};

const default_axis_name = "#batch";

const BatchValue = struct {
    value: trace.Value,
    axis: ?usize,
};

pub fn mapped(axis_index: usize) Axis {
    return .{ .axis = axis_index };
}

pub fn vmap(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: Options,
) !program_mod.Program {
    try validate(source, options);

    var builder = try trace.Builder.init(allocator, source.name);
    errdefer builder.deinit();

    const resolved = try resolveAxisName(builder.arena.allocator(), source, options);
    const graph = interpret.Graph{ .builder = &builder };
    return try interpret.run(allocator, source, semantics(graph, resolved));
}

pub fn vmapWith(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: Options,
    hooks: anytype,
) !program_mod.Program {
    try validate(source, options);

    var builder = try trace.Builder.init(allocator, source.name);
    errdefer builder.deinit();

    const resolved = try resolveAxisName(builder.arena.allocator(), source, options);
    const graph = interpret.Graph{ .builder = &builder };
    return try interpret.run(allocator, source, semantics(
        hook.attach("batch", hooks, graph),
        resolved,
    ));
}

fn resolveAxisName(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: Options,
) !Options {
    var resolved = options;
    if (options.axis_name.len != 0) {
        try types.validateName(options.axis_name);
        return resolved;
    }
    var attempt: usize = 0;
    var name: []const u8 = default_axis_name;
    while (programHasAxis(source, name)) {
        attempt += 1;
        name = try std.fmt.allocPrint(allocator, "{s}{d}", .{ default_axis_name, attempt });
    }
    resolved.axis_name = name;
    return resolved;
}

fn programHasAxis(source: *const program_mod.Program, name: []const u8) bool {
    for (source.values) |ty| {
        if (types.findDim(ty.dims, name) != null) return true;
    }
    for (source.operations) |op| {
        if (op.kind == .scan and subgraphHasAxis(op.kind.scan.body, name)) return true;
    }
    return false;
}

fn subgraphHasAxis(body: *const program_mod.Subgraph, name: []const u8) bool {
    for (body.values) |ty| {
        if (types.findDim(ty.dims, name) != null) return true;
    }
    for (body.operations) |op| {
        if (op.kind == .scan and subgraphHasAxis(op.kind.scan.body, name)) return true;
    }
    return false;
}

pub fn semantics(next: anytype, options: Options) Semantics(@TypeOf(next)) {
    return .{
        .next = next,
        .options = options,
    };
}

pub fn semanticsWith(next: anytype, options: Options, hooks: anytype) Semantics(
    @TypeOf(hook.attach("batch", hooks, next)),
) {
    return semantics(hook.attach("batch", hooks, next), options);
}

pub fn Semantics(comptime Next: type) type {
    return struct {
        next: Next,
        options: Options,

        pub const Value: type = BatchValue;
        pub const Result: type = Next.Result;

        pub fn operation(self: *@This(), step: *interpret.Step(Value)) !Value {
            return batchOperation(self, step.op, step.values);
        }

        pub fn finish(self: *@This(), outputs: []const Value) !Result {
            const values = try self.builderHandle().arena.allocator().alloc(
                trace.Value,
                outputs.len,
            );
            for (outputs, 0..) |output, index| {
                values[index] = if (output.axis) |axis|
                    try moveBatchAxis(self, output.value, axis, self.options.out_axis)
                else
                    try broadcastOutputAxis(self, output.value, self.options);
            }
            return self.next.finish(values);
        }

        pub fn builderHandle(self: *@This()) *trace.Builder {
            return self.next.builderHandle();
        }

        pub fn axisName(self: *@This()) []const u8 {
            if (self.options.axis_name.len != 0) return self.options.axis_name;
            return default_axis_name;
        }
    };
}

fn batchDim(layer: anytype) types.Dim {
    return .{ .name = layer.axisName(), .extent = layer.options.axis_size };
}

fn batchOperation(
    layer: anytype,
    op: *const program_mod.Operation,
    map: []const BatchValue,
) !BatchValue {
    return switch (op.kind) {
        .parameter => |parameter| batchParameter(layer, op, parameter.index),
        .constant, .iota => .{ .value = try emitUnbatched(layer, op, map), .axis = null },
        .unary => |unary| blk: {
            const input = map[unary.input.index];
            break :blk .{ .value = try layer.next.bind(op, &.{input.value}), .axis = input.axis };
        },
        .binary => |binary| batchBinary(layer, op, map[binary.lhs.index], map[binary.rhs.index]),
        .reshape => |reshape| blk: {
            const input = map[reshape.input.index];
            if (input.axis) |axis| {
                const allocator = layer.builderHandle().arena.allocator();
                const dims = try types.insertDim(allocator, op.result.dims, axis, batchDim(layer));
                var batched_op = op.*;
                batched_op.result = .{ .dtype = op.result.dtype, .dims = dims };
                batched_op.kind = .{ .reshape = .{
                    .input = reshape.input,
                    .new_shape = try types.extents(allocator, dims),
                } };
                break :blk .{
                    .value = try layer.next.bind(&batched_op, &.{input.value}),
                    .axis = axis,
                };
            }
            break :blk .{ .value = try emitUnbatched(layer, op, map), .axis = null };
        },
        .broadcast => |broadcast| batchBroadcast(layer, op, broadcast, map[broadcast.input.index]),
        .broadcast_in_dim => |broadcast| batchBroadcastInDim(
            layer,
            op,
            broadcast,
            map[broadcast.input.index],
        ),
        .transpose => |transpose| batchTranspose(layer, op, transpose, map[transpose.input.index]),
        .reduce => |reduce| batchReduce(
            layer,
            op,
            reduce,
            map[reduce.input.index],
            map[reduce.init.index],
        ),
        .gather => |gather| batchGather(
            layer,
            op,
            map[gather.input.index],
            map[gather.indices.index],
        ),
        .scatter_add => |scatter_add| batchScatterAdd(
            layer,
            op,
            map[scatter_add.input.index],
            map[scatter_add.indices.index],
            map[scatter_add.updates.index],
        ),
        .sparse_cross_entropy => |sparse_cross_entropy| batchSparseCrossEntropy(
            layer,
            op,
            map[sparse_cross_entropy.logits.index],
            map[sparse_cross_entropy.targets.index],
        ),
        .dot_general => |dot| batchDot(layer, op, dot, map[dot.lhs.index], map[dot.rhs.index]),
        .compare => |compare| batchBinary(
            layer,
            op,
            map[compare.lhs.index],
            map[compare.rhs.index],
        ),
        .select => |select| batchSelect(
            layer,
            op,
            map[select.pred.index],
            map[select.on_true.index],
            map[select.on_false.index],
        ),
        .custom_call => error.CustomCallRequiresBatchContract,
        .scan => |scan| batchScan(layer, op, scan, map),
        .projection => |projection| blk: {
            const source = map[projection.source.index];
            break :blk .{ .value = try layer.next.bind(op, &.{source.value}), .axis = source.axis };
        },
    };
}

fn batchScan(
    layer: anytype,
    op: *const program_mod.Operation,
    scan: program_mod.Scan,
    map: []const BatchValue,
) anyerror!BatchValue {
    var any_batched = false;
    for (scan.inits) |init_id| {
        if (map[init_id.index].axis != null) any_batched = true;
    }
    if (!any_batched) {
        var buffer: [program_mod.max_scan_carries]trace.Value = undefined;
        for (scan.inits, 0..) |init_id, index| buffer[index] = map[init_id.index].value;
        return .{ .value = try layer.next.bind(op, buffer[0..scan.inits.len]), .axis = null };
    }

    const builder = layer.builderHandle();
    var inits: [program_mod.max_scan_carries]trace.Value = undefined;
    for (scan.inits, 0..) |init_id, index| {
        const carried = map[init_id.index];
        inits[index] = if (carried.axis) |axis|
            try moveBatchAxis(layer, carried.value, axis, 0)
        else
            try broadcastToBatchAxis(layer, carried.value, 0);
    }

    var body_program = program_mod.Program{
        .arena = std.heap.ArenaAllocator.init(builder.allocator),
        .name = "scan_body",
        .values = scan.body.values,
        .operations = scan.body.operations,
        .parameters = scan.body.parameters,
        .outputs = scan.body.outputs,
    };
    defer body_program.deinit();

    var axes: [program_mod.max_scan_carries]Axis = undefined;
    for (0..scan.inits.len) |index| axes[index] = mapped(0);
    var batched_body = try vmap(builder.allocator, &body_program, .{
        .axis_size = layer.options.axis_size,
        .in_axes = axes[0..scan.inits.len],
        .axis_name = layer.axisName(),
    });
    defer batched_body.deinit();

    const body_view = program_mod.Subgraph{
        .values = batched_body.values,
        .operations = batched_body.operations,
        .parameters = batched_body.parameters,
        .outputs = batched_body.outputs,
    };
    var batched_op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = inits[0].ty,
        .kind = .{ .scan = .{ .length = scan.length, .inits = scan.inits, .body = &body_view } },
    };
    return .{ .value = try layer.next.bind(&batched_op, inits[0..scan.inits.len]), .axis = 0 };
}

fn batchGather(
    layer: anytype,
    op: *const program_mod.Operation,
    input: BatchValue,
    indices: BatchValue,
) !BatchValue {
    if (input.axis == null and indices.axis == null) {
        return .{
            .value = try layer.next.bind(op, &.{ input.value, indices.value }),
            .axis = null,
        };
    }
    const gather = op.kind.gather;
    if (input.axis != null and indices.axis != null) {
        const moved_input = try moveBatchAxis(layer, input.value, input.axis.?, 0);
        const moved_indices = try moveBatchAxis(layer, indices.value, indices.axis.?, 0);
        return .{
            .value = try pairedGather(
                layer,
                moved_input,
                moved_indices,
                try leadingAxis(gather.axis),
            ),
            .axis = 0,
        };
    }
    if (input.axis) |axis| {
        const moved_input = try moveBatchAxis(layer, input.value, axis, 0);
        return .{
            .value = try emit.gather(
                layer,
                moved_input,
                indices.value,
                try leadingAxis(gather.axis),
            ),
            .axis = 0,
        };
    }
    const moved_indices = try moveBatchAxis(layer, indices.value, indices.axis.?, 0);
    return .{
        .value = try emit.gather(layer, input.value, moved_indices, gather.axis),
        .axis = @intCast(gather.axis),
    };
}

fn batchScatterAdd(
    layer: anytype,
    op: *const program_mod.Operation,
    input: BatchValue,
    indices: BatchValue,
    updates: BatchValue,
) !BatchValue {
    if (input.axis == null and indices.axis == null and updates.axis == null) {
        return .{
            .value = try layer.next.bind(op, &.{ input.value, indices.value, updates.value }),
            .axis = null,
        };
    }
    const scatter_add = op.kind.scatter_add;
    const moved_input = if (input.axis) |axis|
        try moveBatchAxis(layer, input.value, axis, 0)
    else
        try broadcastToBatchAxis(layer, input.value, 0);
    const moved_updates = if (updates.axis) |axis|
        try moveBatchAxis(layer, updates.value, axis, 0)
    else
        try broadcastToBatchAxis(layer, updates.value, 0);
    if (indices.axis) |axis| {
        const moved_indices = try moveBatchAxis(layer, indices.value, axis, 0);
        return .{
            .value = try pairedScatterAdd(
                layer,
                moved_input,
                moved_indices,
                moved_updates,
                try leadingAxis(scatter_add.axis),
            ),
            .axis = 0,
        };
    }
    return .{
        .value = try emit.scatterAdd(
            layer,
            moved_input,
            indices.value,
            moved_updates,
            try leadingAxis(scatter_add.axis),
        ),
        .axis = 0,
    };
}

fn batchSparseCrossEntropy(
    layer: anytype,
    op: *const program_mod.Operation,
    logits: BatchValue,
    targets: BatchValue,
) !BatchValue {
    if (logits.axis == null and targets.axis == null) {
        return .{
            .value = try layer.next.bind(op, &.{ logits.value, targets.value }),
            .axis = null,
        };
    }
    const sparse_cross_entropy = op.kind.sparse_cross_entropy;
    const moved_logits = if (logits.axis) |axis|
        try moveBatchAxis(layer, logits.value, axis, 0)
    else
        try broadcastToBatchAxis(layer, logits.value, 0);
    const moved_targets = if (targets.axis) |axis|
        try moveBatchAxis(layer, targets.value, axis, 0)
    else
        try broadcastToBatchAxis(layer, targets.value, 0);
    return .{
        .value = try emit.sparseCrossEntropy(
            layer,
            moved_logits,
            moved_targets,
            try leadingAxis(sparse_cross_entropy.axis),
        ),
        .axis = 0,
    };
}

fn pairedGather(layer: anytype, input: trace.Value, indices: trace.Value, axis: i64) !trace.Value {
    if (!input.ty.dtype.isNumeric()) return error.UnsupportedBatching;
    const axis_index = try batchIndexAxis(input, indices, axis);
    const allocator = layer.builderHandle().arena.allocator();
    const index_dims = indices.ty.dims[1..];
    const expanded_dims = try pairedExpandedDims(allocator, input.ty.dims, index_dims, axis_index);
    const source_positions = try emitIota(layer, .i32, expanded_dims, axis_index);
    const broadcasted_indices = try broadcastPairedIndices(
        layer,
        indices,
        expanded_dims,
        axis_index,
    );
    const broadcasted_input = try broadcastPairedInput(
        layer,
        input,
        expanded_dims,
        axis_index,
        index_dims.len,
    );
    const mask = try emit.compare(layer, .eq, source_positions, broadcasted_indices);
    const zero = try broadcastZero(layer, input.ty.dtype, expanded_dims);
    const selected = try emit.select(layer, mask, broadcasted_input, zero);
    const init = try emit.zeros(layer, trace.Type.scalar(input.ty.dtype));
    return emit.reduce(layer, selected, init, .sum, &.{axis});
}

fn pairedScatterAdd(
    layer: anytype,
    input: trace.Value,
    indices: trace.Value,
    updates: trace.Value,
    axis: i64,
) !trace.Value {
    if (!input.ty.dtype.isNumeric()) return error.UnsupportedBatching;
    const axis_index = try batchIndexAxis(input, indices, axis);
    const allocator = layer.builderHandle().arena.allocator();
    const index_dims = indices.ty.dims[1..];
    const expanded_dims = try pairedExpandedDims(allocator, input.ty.dims, index_dims, axis_index);
    const source_positions = try emitIota(layer, .i32, expanded_dims, axis_index);
    const broadcasted_indices = try broadcastPairedIndices(
        layer,
        indices,
        expanded_dims,
        axis_index,
    );
    const broadcasted_updates = try broadcastPairedUpdates(
        layer,
        updates,
        expanded_dims,
        axis_index,
    );
    const mask = try emit.compare(layer, .eq, source_positions, broadcasted_indices);
    const zero = try broadcastZero(layer, input.ty.dtype, expanded_dims);
    const selected = try emit.select(layer, mask, broadcasted_updates, zero);

    const reduced = if (index_dims.len == 0)
        selected
    else blk: {
        const reduce_axes = try allocator.alloc(i64, index_dims.len);
        for (reduce_axes, 0..) |*slot, index| slot.* = @intCast(axis_index + 1 + index);
        const init = try emit.zeros(layer, trace.Type.scalar(input.ty.dtype));
        break :blk try emit.reduce(layer, selected, init, .sum, reduce_axes);
    };
    return emit.binary(layer, .add, input, reduced);
}

fn batchIndexAxis(input: trace.Value, indices: trace.Value, axis: i64) !usize {
    if (axis <= 0) return error.AxisOutOfRange;
    const axis_index = std.math.cast(usize, axis) orelse return error.AxisOutOfRange;
    if (axis_index >= input.ty.rank()) return error.AxisOutOfRange;
    if (indices.ty.rank() == 0) return error.AxisOutOfRange;
    if (indices.ty.dims[0].extent != input.ty.dims[0].extent) return error.ShapeMismatch;
    return axis_index;
}

fn pairedExpandedDims(
    allocator: std.mem.Allocator,
    input_dims: []const trace.Dim,
    index_dims: []const trace.Dim,
    axis: usize,
) ![]const trace.Dim {
    const result = try allocator.alloc(trace.Dim, input_dims.len + index_dims.len);
    var out: usize = 0;
    for (input_dims[0 .. axis + 1]) |dim| {
        result[out] = dim;
        out += 1;
    }
    for (index_dims) |dim| {
        result[out] = dim;
        out += 1;
    }
    for (input_dims[axis + 1 ..]) |dim| {
        result[out] = dim;
        out += 1;
    }
    try types.validateDims(result);
    return result;
}

fn broadcastPairedInput(
    layer: anytype,
    input: trace.Value,
    expanded_dims: []const trace.Dim,
    axis: usize,
    index_rank: usize,
) !trace.Value {
    const allocator = layer.builderHandle().arena.allocator();
    const mapping = try allocator.alloc(i64, input.ty.rank());
    for (mapping, 0..) |*slot, index| {
        slot.* = if (index <= axis)
            @intCast(index)
        else
            @intCast(index + index_rank);
    }
    return emit.broadcastInDim(layer, input, expanded_dims, mapping);
}

fn broadcastPairedIndices(
    layer: anytype,
    indices: trace.Value,
    expanded_dims: []const trace.Dim,
    axis: usize,
) !trace.Value {
    const allocator = layer.builderHandle().arena.allocator();
    const mapping = try allocator.alloc(i64, indices.ty.rank());
    mapping[0] = 0;
    for (mapping[1..], 0..) |*slot, index| slot.* = @intCast(axis + 1 + index);
    return emit.broadcastInDim(layer, indices, expanded_dims, mapping);
}

fn broadcastPairedUpdates(
    layer: anytype,
    updates: trace.Value,
    expanded_dims: []const trace.Dim,
    axis: usize,
) !trace.Value {
    const allocator = layer.builderHandle().arena.allocator();
    const mapping = try allocator.alloc(i64, updates.ty.rank());
    for (mapping, 0..) |*slot, index| {
        slot.* = if (index < axis)
            @intCast(index)
        else
            @intCast(index + 1);
    }
    return emit.broadcastInDim(layer, updates, expanded_dims, mapping);
}

fn broadcastZero(layer: anytype, dtype: trace.DType, dims: []const trace.Dim) !trace.Value {
    const zero = try emit.zeros(layer, trace.Type.scalar(dtype));
    return emit.broadcastInDim(layer, zero, dims, &.{});
}

fn emitIota(layer: anytype, dtype: trace.DType, dims: []const trace.Dim, axis: usize) !trace.Value {
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = .{ .dtype = dtype, .dims = dims },
        .kind = .{ .iota = .{ .axis = @intCast(axis) } },
    };
    return layer.next.bind(&op, &.{});
}

fn leadingAxis(axis: i64) !i64 {
    if (axis < 0) return error.AxisOutOfRange;
    return std.math.add(i64, axis, 1) catch error.AxisOutOfRange;
}

fn batchParameter(layer: anytype, op: *const program_mod.Operation, index: usize) !BatchValue {
    return switch (layer.options.in_axes[index]) {
        .none => .{ .value = try layer.next.bind(op, &.{}), .axis = null },
        .axis => |axis| blk: {
            var batched_op = op.*;
            batched_op.result = .{
                .dtype = op.result.dtype,
                .dims = try types.insertDim(
                    layer.builderHandle().arena.allocator(),
                    op.result.dims,
                    axis,
                    batchDim(layer),
                ),
            };
            break :blk .{ .value = try layer.next.bind(&batched_op, &.{}), .axis = axis };
        },
    };
}

fn batchSelect(
    layer: anytype,
    op: *const program_mod.Operation,
    pred: BatchValue,
    on_true: BatchValue,
    on_false: BatchValue,
) !BatchValue {
    const batch_axis = pred.axis orelse on_true.axis orelse on_false.axis orelse {
        return .{
            .value = try layer.next.bind(op, &.{ pred.value, on_true.value, on_false.value }),
            .axis = null,
        };
    };
    const aligned_pred = try alignBatchOperand(layer, pred, batch_axis);
    const aligned_true = try alignBatchOperand(layer, on_true, batch_axis);
    const aligned_false = try alignBatchOperand(layer, on_false, batch_axis);
    return .{
        .value = try layer.next.bind(op, &.{ aligned_pred, aligned_true, aligned_false }),
        .axis = batch_axis,
    };
}

fn alignBatchOperand(layer: anytype, operand: BatchValue, batch_axis: usize) !trace.Value {
    if (operand.axis) |axis| {
        if (axis == batch_axis) return operand.value;
        return moveBatchAxis(layer, operand.value, axis, batch_axis);
    }
    return broadcastToBatchAxis(layer, operand.value, batch_axis);
}

fn broadcastToBatchAxis(layer: anytype, value: trace.Value, batch_axis: usize) !trace.Value {
    const allocator = layer.builderHandle().arena.allocator();
    const result_dims = try types.insertDim(allocator, value.ty.dims, batch_axis, batchDim(layer));
    const dims = try allocator.alloc(i64, value.ty.dims.len);
    var dim_index: usize = 0;
    for (0..result_dims.len) |axis| {
        if (axis == batch_axis) continue;
        dims[dim_index] = @intCast(axis);
        dim_index += 1;
    }
    var batched_op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = .{ .dtype = value.ty.dtype, .dims = result_dims },
        .kind = .{
            .broadcast_in_dim = .{ .input = program_mod.synthetic_id, .broadcast_dims = dims },
        },
    };
    return layer.next.bind(&batched_op, &.{value});
}

fn batchBinary(
    layer: anytype,
    op: *const program_mod.Operation,
    lhs: BatchValue,
    rhs: BatchValue,
) !BatchValue {
    if (lhs.axis == null and rhs.axis == null) {
        return .{ .value = try layer.next.bind(op, &.{ lhs.value, rhs.value }), .axis = null };
    }

    if (lhs.axis) |lhs_axis| {
        if (rhs.axis) |rhs_axis| {
            const aligned_rhs = if (rhs_axis == lhs_axis)
                rhs.value
            else
                try moveBatchAxis(layer, rhs.value, rhs_axis, lhs_axis);
            return .{
                .value = try layer.next.bind(op, &.{ lhs.value, aligned_rhs }),
                .axis = lhs_axis,
            };
        }
        const lifted_rhs = try broadcastToBatchAxis(layer, rhs.value, lhs_axis);
        return .{ .value = try layer.next.bind(op, &.{ lhs.value, lifted_rhs }), .axis = lhs_axis };
    }

    const rhs_axis = rhs.axis.?;
    const lifted_lhs = try broadcastToBatchAxis(layer, lhs.value, rhs_axis);
    return .{ .value = try layer.next.bind(op, &.{ lifted_lhs, rhs.value }), .axis = rhs_axis };
}

fn batchBroadcast(
    layer: anytype,
    op: *const program_mod.Operation,
    broadcast: program_mod.Broadcast,
    input: BatchValue,
) !BatchValue {
    if (input.axis == null) {
        return .{ .value = try layer.next.bind(op, &.{input.value}), .axis = null };
    }

    const moved = try moveBatchAxis(layer, input.value, input.axis.?, 0);
    if (input.value.ty.rank() != 1) return error.UnsupportedBatching;
    const result_dims = try types.insertDim(
        layer.builderHandle().arena.allocator(),
        op.result.dims,
        0,
        batchDim(layer),
    );
    var batched_op = op.*;
    batched_op.result = .{ .dtype = op.result.dtype, .dims = result_dims };
    batched_op.kind = .{
        .broadcast_in_dim = .{ .input = broadcast.input, .broadcast_dims = &.{0} },
    };
    return .{ .value = try layer.next.bind(&batched_op, &.{moved}), .axis = 0 };
}

fn batchBroadcastInDim(
    layer: anytype,
    op: *const program_mod.Operation,
    broadcast: program_mod.BroadcastInDim,
    input: BatchValue,
) !BatchValue {
    if (input.axis == null) {
        return .{ .value = try layer.next.bind(op, &.{input.value}), .axis = null };
    }

    const moved = try moveBatchAxis(layer, input.value, input.axis.?, 0);
    const result_dims = try types.insertDim(
        layer.builderHandle().arena.allocator(),
        op.result.dims,
        0,
        batchDim(layer),
    );
    const dims = try shiftAxesWithLeading(
        layer.builderHandle().arena.allocator(),
        broadcast.broadcast_dims,
    );
    var batched_op = op.*;
    batched_op.result = .{ .dtype = op.result.dtype, .dims = result_dims };
    batched_op.kind = .{
        .broadcast_in_dim = .{ .input = broadcast.input, .broadcast_dims = dims },
    };
    return .{ .value = try layer.next.bind(&batched_op, &.{moved}), .axis = 0 };
}

fn batchTranspose(
    layer: anytype,
    op: *const program_mod.Operation,
    transpose: program_mod.Transpose,
    input: BatchValue,
) !BatchValue {
    if (input.axis == null) {
        return .{ .value = try layer.next.bind(op, &.{input.value}), .axis = null };
    }

    const allocator = layer.builderHandle().arena.allocator();
    const moved = try moveBatchAxis(layer, input.value, input.axis.?, 0);
    const permutation = try shiftAxesWithLeading(allocator, transpose.permutation);
    var batched_op = op.*;
    batched_op.result = .{
        .dtype = input.value.ty.dtype,
        .dims = try types.permuted(allocator, moved.ty.dims, permutation),
    };
    batched_op.kind = .{ .transpose = .{ .input = transpose.input, .permutation = permutation } };
    return .{ .value = try layer.next.bind(&batched_op, &.{moved}), .axis = 0 };
}

fn batchReduce(
    layer: anytype,
    op: *const program_mod.Operation,
    reduce: program_mod.Reduce,
    input: BatchValue,
    init: BatchValue,
) !BatchValue {
    if (input.axis == null and init.axis == null) {
        return .{ .value = try layer.next.bind(op, &.{ input.value, init.value }), .axis = null };
    }
    if (init.axis != null) return error.UnsupportedBatching;
    if (input.axis == null) return error.UnsupportedBatching;

    const allocator = layer.builderHandle().arena.allocator();
    const moved = try moveBatchAxis(layer, input.value, input.axis.?, 0);
    const dimensions = try shiftAxes(allocator, reduce.dimensions, 1);
    var batched_op = op.*;
    batched_op.result = .{
        .dtype = op.result.dtype,
        .dims = try types.removeAxes(allocator, moved.ty.dims, dimensions),
    };
    batched_op.kind = .{ .reduce = .{
        .input = reduce.input,
        .init = reduce.init,
        .reducer = reduce.reducer,
        .dimensions = dimensions,
    } };
    return .{ .value = try layer.next.bind(&batched_op, &.{ moved, init.value }), .axis = 0 };
}

fn batchDot(
    layer: anytype,
    op: *const program_mod.Operation,
    dot: program_mod.DotGeneral,
    lhs: BatchValue,
    rhs: BatchValue,
) !BatchValue {
    if (lhs.axis == null and rhs.axis == null) {
        return .{ .value = try layer.next.bind(op, &.{ lhs.value, rhs.value }), .axis = null };
    }

    const allocator = layer.builderHandle().arena.allocator();
    const lhs_value = if (lhs.axis) |axis|
        try moveBatchAxis(layer, lhs.value, axis, 0)
    else
        try broadcastToBatchAxis(layer, lhs.value, 0);
    const rhs_value = if (rhs.axis) |axis|
        try moveBatchAxis(layer, rhs.value, axis, 0)
    else
        try broadcastToBatchAxis(layer, rhs.value, 0);
    const lhs_contract = try shiftAxes(allocator, dot.lhs_contract, 1);
    const rhs_contract = try shiftAxes(allocator, dot.rhs_contract, 1);
    const lhs_batch = try shiftAxesWithLeading(allocator, dot.lhs_batch);
    const rhs_batch = try shiftAxesWithLeading(allocator, dot.rhs_batch);
    const result_dims = try types.dotGeneralDims(
        allocator,
        lhs_value.ty.dims,
        rhs_value.ty.dims,
        lhs_contract,
        rhs_contract,
        lhs_batch,
        rhs_batch,
    );
    var batched_op = op.*;
    batched_op.result = .{ .dtype = op.result.dtype, .dims = result_dims };
    batched_op.kind = .{
        .dot_general = .{
            .lhs = dot.lhs,
            .rhs = dot.rhs,
            .lhs_contract = lhs_contract,
            .rhs_contract = rhs_contract,
            .lhs_batch = lhs_batch,
            .rhs_batch = rhs_batch,
        },
    };
    return .{ .value = try layer.next.bind(&batched_op, &.{ lhs_value, rhs_value }), .axis = 0 };
}

fn emitUnbatched(
    layer: anytype,
    op: *const program_mod.Operation,
    map: []const BatchValue,
) !trace.Value {
    return switch (op.kind) {
        .parameter, .constant, .iota => layer.next.bind(op, &.{}),
        .unary => |unary| layer.next.bind(op, &.{map[unary.input.index].value}),
        .binary => |binary| layer.next.bind(
            op,
            &.{ map[binary.lhs.index].value, map[binary.rhs.index].value },
        ),
        .broadcast => |broadcast| layer.next.bind(op, &.{map[broadcast.input.index].value}),
        .broadcast_in_dim => |broadcast| layer.next.bind(op, &.{map[broadcast.input.index].value}),
        .reshape => |reshape| layer.next.bind(op, &.{map[reshape.input.index].value}),
        .transpose => |transpose| layer.next.bind(op, &.{map[transpose.input.index].value}),
        .reduce => |reduce| layer.next.bind(
            op,
            &.{ map[reduce.input.index].value, map[reduce.init.index].value },
        ),
        .gather => |gather| layer.next.bind(
            op,
            &.{ map[gather.input.index].value, map[gather.indices.index].value },
        ),
        .scatter_add => |scatter_add| layer.next.bind(op, &.{
            map[scatter_add.input.index].value,
            map[scatter_add.indices.index].value,
            map[scatter_add.updates.index].value,
        }),
        .sparse_cross_entropy => |sparse_cross_entropy| layer.next.bind(op, &.{
            map[sparse_cross_entropy.logits.index].value,
            map[sparse_cross_entropy.targets.index].value,
        }),
        .compare => |compare| layer.next.bind(
            op,
            &.{ map[compare.lhs.index].value, map[compare.rhs.index].value },
        ),
        .select => |select| layer.next.bind(op, &.{
            map[select.pred.index].value,
            map[select.on_true.index].value,
            map[select.on_false.index].value,
        }),
        .custom_call => error.CustomCallRequiresBatchContract,
        .dot_general => |dot| layer.next.bind(
            op,
            &.{ map[dot.lhs.index].value, map[dot.rhs.index].value },
        ),
        .scan, .projection => error.ScanBatchingUnsupported,
    };
}

fn broadcastOutputAxis(layer: anytype, value: trace.Value, options: Options) !trace.Value {
    return broadcastToBatchAxis(layer, value, options.out_axis);
}

fn moveBatchAxis(layer: anytype, value: trace.Value, from: usize, to: usize) !trace.Value {
    if (from == to) return value;
    const rank = value.ty.rank();
    if (from >= rank or to >= rank) return error.AxisOutOfRange;
    const permutation = try layer.builderHandle().arena.allocator().alloc(i64, rank);
    var remaining: usize = 0;
    for (permutation, 0..) |*axis, index| {
        if (index == to) {
            axis.* = @intCast(from);
        } else {
            while (remaining == from) remaining += 1;
            axis.* = @intCast(remaining);
            remaining += 1;
        }
    }
    return emit.transpose(layer, value, permutation);
}

fn shiftAxesWithLeading(allocator: std.mem.Allocator, axes: []const i64) ![]const i64 {
    const result = try allocator.alloc(i64, axes.len + 1);
    result[0] = 0;
    for (axes, 0..) |axis, index| {
        result[index + 1] = axis + 1;
    }
    return result;
}

fn shiftAxes(allocator: std.mem.Allocator, axes: []const i64, amount: i64) ![]const i64 {
    const result = try allocator.alloc(i64, axes.len);
    for (axes, 0..) |axis, index| {
        result[index] = axis + amount;
    }
    return result;
}

pub fn validate(source: *const program_mod.Program, options: Options) !void {
    if (options.axis_size < 0) return error.InvalidDimension;
    if (options.in_axes.len != source.parameters.len) return error.InAxisCountMismatch;
    for (source.parameters) |id| {
        const parameter = source.operation(id).kind.parameter;
        switch (options.in_axes[parameter.index]) {
            .none => {},
            .axis => |axis| if (axis > source.typeOf(id).rank()) return error.AxisOutOfRange,
        }
    }
}

fn elementwiseBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try (try args[0].mul(args[1])).tanh();
}

fn expectExtents(expected: []const i64, ty: trace.Type) !void {
    try std.testing.expectEqual(expected.len, ty.dims.len);
    for (expected, ty.dims) |extent, dim| {
        try std.testing.expectEqual(extent, dim.extent);
    }
}

fn unmappedOutputBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return args[1];
}

const GeneratedCounts = struct {
    broadcast_in_dim: usize = 0,
    transpose: usize = 0,
};

const GeneratedCounter = struct {
    counts: *GeneratedCounts,

    pub fn broadcastInDim(self: *@This(), ctx: anytype) !trace.Value {
        self.counts.broadcast_in_dim += 1;
        return ctx.default();
    }

    pub fn transpose(self: *@This(), ctx: anytype) !trace.Value {
        self.counts.transpose += 1;
        return ctx.default();
    }
};

const GeneratedBroadcastRewrite = struct {
    seen: *usize,

    pub fn broadcastInDim(self: *@This(), ctx: *transform.Context) !?trace.Value {
        self.seen.* += 1;
        try std.testing.expect(!ctx.isZero(0));
        try std.testing.expect(ctx.constantPayload(0) == null);
        return null;
    }
};

fn gatherBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return args[0].gather(args[1], .vocab);
}

fn scatterAddBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return args[0].scatterAdd(args[1], args[2], .vocab);
}

fn identityBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return args[0];
}

fn contractBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try args[0].contract(args[1], .k);
}

fn addZeroBody(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const zero = try builder.full(.f32, .{ .lane = 4 }, 0.0);
    return try args[0].add(zero);
}

const BatchDropAddZero = struct {
    pub fn add(_: *@This(), ctx: *transform.Context) !?trace.Value {
        if (ctx.isZero(1)) return ctx.arg(0);
        if (ctx.isZero(0)) return ctx.arg(1);
        return null;
    }
};
