const std = @import("std");
const gpu_abi = @import("gpu_abi");
const testing = std.testing;

const choir = @import("choir");
const choir_root = @import("../root.zig");
const planner = @import("planner.zig");
const spec = @import("spec.zig");

const ir = choir.ir;
const rewrite = ir.rewrite;
const DType = gpu_abi.DType;
const Equation = spec.Equation;
const IndexSet = spec.IndexSet;
const Plan = planner.Plan;
const Step = planner.Step;
const AccyDialect = choir_root.AccyDialect;

pub const LowerError = error{
    InputCountMismatch,
    InvalidPlan,
    InvalidDimension,
} || std.mem.Allocator.Error;

const State = struct {
    value: ?*ir.Value = null,
    order: []const u8 = &.{},
    owned: bool = false,
};

/// Four figures for one call of `lowerPlan`: bytes of local scratch, structural
/// visits, operations requested from the IR sink, and tensor types requested
/// from it, so a compiler pass can charge one lowering against its work budget
/// before it runs it. The figures assume an equation from `parse` and a plan
/// from `createPlan`, so at most 62 labels, at most 63 inputs, and exactly one
/// step fewer than inputs. Growth of the caller's arena, the internals of the
/// context and of the sink, rewriter queues, parsing and planning are left out,
/// and their owners add their own charges, as the einsum pass does.
pub const LoweringBounds = struct {
    scratch_bytes: u64,
    structural_visits: u64,
    operation_requests: u64,
    tensor_type_requests: u64,

    /// Bytes charged for one list of `T`: four times its grown capacity for 62
    /// items, alignment slack for each allocation, and one more slice for a
    /// final owned copy, so the bound functions can charge one list of at most
    /// 62 items.
    fn listBytes(comptime T: type) u64 {
        return 4 * std.ArrayList(T).growCapacity(62) * @sizeOf(T) +
            4 * @alignOf(T) + sliceBytes(T);
    }

    fn sliceBytes(comptime T: type) u64 {
        return 62 * @sizeOf(T) + @alignOf(T) - 1;
    }

    /// Scratch charged for one contraction step: the reduction of each operand,
    /// the batch and contracted axis lists, the broadcast-and-reduce path, and
    /// the final transpose, so `loweringBounds` can multiply it by the step
    /// count to charge the scratch of a whole plan. The charge is 11 byte
    /// lists, 6 axis lists, 14 slices of dimensions or permutations, and 1 kept
    /// order.
    fn stepScratch() u64 {
        return 11 * listBytes(u8) + 6 * listBytes(i64) +
            14 * sliceBytes(i64) + sliceBytes(u8);
    }
};

/// Returns the figures for an equation with `input_count` inputs, or
/// `error.EmptyEquation` for none and `error.TooManyInputs` above 63, and that
/// check keeps every product in range. The einsum pass calls this with the
/// operand count to add the lowering's share to its work estimate. Each step is
/// charged for both operand reductions and for the general broadcast-and-reduce
/// path, even when the matrix-product path skips them. One reduction may
/// transpose, make a zero, reshape, reduce, and reshape back. The operation
/// figure is 19 per step and the tensor-type figure 17 per step, and a single
/// input is charged 3 of each for its own reduction and the final transpose.
/// Visits count searches over labels and axes, which grow with the square of
/// the rank, together with local copies and cleanup. Visits measure neither
/// machine instructions nor tensor execution.
pub fn loweringBounds(input_count: usize) !LoweringBounds {
    if (input_count == 0) return error.EmptyEquation;
    if (input_count > 63) return error.TooManyInputs;
    const steps: u64 = input_count - 1;
    const states: u64 = input_count + steps;
    const scratch = states * @sizeOf(State) + @alignOf(State) - 1 + if (steps == 0)
        LoweringBounds.listBytes(u8) + LoweringBounds.listBytes(i64) +
            3 * LoweringBounds.sliceBytes(i64)
    else
        steps * LoweringBounds.stepScratch();
    return .{
        .scratch_bytes = scratch,
        .structural_visits = 8 * scratch + 64 * 63 * 63 * @max(steps, 1) + 8 * states,
        .operation_requests = if (steps == 0) 3 else 19 * steps,
        .tensor_type_requests = if (steps == 0) 3 else 17 * steps,
    };
}

pub fn lowerPlan(
    allocator: std.mem.Allocator,
    fb: *choir_root.semantic.FunctionBuilder,
    equation: *const Equation,
    plan: *const Plan,
    inputs: []const *ir.Value,
    dtype: DType,
) !*ir.Value {
    var sink = FunctionSink{ .fb = fb };
    return try lowerPlanWithSink(allocator, &sink, equation, plan, inputs, dtype);
}

pub fn lowerPlanWithRewriter(
    allocator: std.mem.Allocator,
    rewriter: *rewrite.PatternRewriter,
    equation: *const Equation,
    plan: *const Plan,
    inputs: []const *ir.Value,
    dtype: DType,
) !*ir.Value {
    var sink = RewriterSink{ .rewriter = rewriter };
    return try lowerPlanWithSink(allocator, &sink, equation, plan, inputs, dtype);
}

const FunctionSink = struct {
    fb: *choir_root.semantic.FunctionBuilder,

    fn context(self: *FunctionSink) *ir.Context {
        return self.fb.ctx;
    }

    fn constant(self: *FunctionSink, result_type: ir.Type, bytes: []const u8) !*ir.Value {
        return try self.fb.constant(result_type, bytes);
    }

    fn dotGeneral(
        self: *FunctionSink,
        lhs: *ir.Value,
        rhs: *ir.Value,
        result_type: ir.Type,
        contracting_lhs: []const i64,
        contracting_rhs: []const i64,
        batching_lhs: []const i64,
        batching_rhs: []const i64,
    ) !*ir.Value {
        return try self.fb.dotGeneral(
            lhs,
            rhs,
            result_type,
            contracting_lhs,
            contracting_rhs,
            batching_lhs,
            batching_rhs,
        );
    }

    fn reduce(
        self: *FunctionSink,
        input: *ir.Value,
        init: *ir.Value,
        result_type: ir.Type,
        reducer_kind: []const u8,
        dimensions: []const i64,
    ) !*ir.Value {
        return try self.fb.reduce(input, init, result_type, reducer_kind, dimensions);
    }

    fn reshape(self: *FunctionSink, input: *ir.Value, result_type: ir.Type, new_shape: []const i64) !*ir.Value {
        return try self.fb.reshape(input, result_type, new_shape);
    }

    fn broadcastInDim(
        self: *FunctionSink,
        input: *ir.Value,
        result_type: ir.Type,
        result_shape: []const i64,
        broadcast_dims: []const i64,
    ) !*ir.Value {
        return try self.fb.broadcastInDim(input, result_type, result_shape, broadcast_dims);
    }

    fn mul(self: *FunctionSink, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
        return try self.fb.mul(lhs, rhs);
    }

    fn transpose(self: *FunctionSink, input: *ir.Value, result_type: ir.Type, permutation: []const i64) !*ir.Value {
        return try self.fb.transpose(input, result_type, permutation);
    }
};

const RewriterSink = struct {
    rewriter: *rewrite.PatternRewriter,

    fn context(self: *RewriterSink) *ir.Context {
        return self.rewriter.ir_ctx;
    }

    fn constant(self: *RewriterSink, result_type: ir.Type, bytes: []const u8) !*ir.Value {
        const op = try AccyDialect.ConstantOp.create(self.rewriter.ir_ctx, ir.Location.getUnknown(), bytes, result_type);
        _ = try self.rewriter.insert(op.op);
        return op.getResult();
    }

    fn dotGeneral(
        self: *RewriterSink,
        lhs: *ir.Value,
        rhs: *ir.Value,
        result_type: ir.Type,
        contracting_lhs: []const i64,
        contracting_rhs: []const i64,
        batching_lhs: []const i64,
        batching_rhs: []const i64,
    ) !*ir.Value {
        const op = try AccyDialect.DotGeneralOp.create(
            self.rewriter.ir_ctx,
            ir.Location.getUnknown(),
            lhs,
            rhs,
            result_type,
            batching_lhs,
            batching_rhs,
            contracting_lhs,
            contracting_rhs,
        );
        _ = try self.rewriter.insert(op.op);
        return op.getResult();
    }

    fn reduce(
        self: *RewriterSink,
        input: *ir.Value,
        init: *ir.Value,
        result_type: ir.Type,
        reducer_kind: []const u8,
        dimensions: []const i64,
    ) !*ir.Value {
        const op = try AccyDialect.ReduceOp.create(
            self.rewriter.ir_ctx,
            ir.Location.getUnknown(),
            input,
            init,
            result_type,
            reducer_kind,
            dimensions,
        );
        _ = try self.rewriter.insert(op.op);
        return op.getResult();
    }

    fn reshape(self: *RewriterSink, input: *ir.Value, result_type: ir.Type, new_shape: []const i64) !*ir.Value {
        const op = try AccyDialect.ReshapeOp.create(
            self.rewriter.ir_ctx,
            ir.Location.getUnknown(),
            input,
            result_type,
            new_shape,
        );
        _ = try self.rewriter.insert(op.op);
        return op.getResult();
    }

    fn broadcastInDim(
        self: *RewriterSink,
        input: *ir.Value,
        result_type: ir.Type,
        result_shape: []const i64,
        broadcast_dims: []const i64,
    ) !*ir.Value {
        const op = try AccyDialect.BroadcastInDimOp.create(
            self.rewriter.ir_ctx,
            ir.Location.getUnknown(),
            input,
            result_type,
            broadcast_dims,
            result_shape,
        );
        _ = try self.rewriter.insert(op.op);
        return op.getResult();
    }

    fn mul(self: *RewriterSink, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
        const op = try AccyDialect.MulOp.create(self.rewriter.ir_ctx, ir.Location.getUnknown(), lhs, rhs);
        _ = try self.rewriter.insert(op.op);
        return op.getResult();
    }

    fn transpose(self: *RewriterSink, input: *ir.Value, result_type: ir.Type, permutation: []const i64) !*ir.Value {
        const op = try AccyDialect.TransposeOp.create(
            self.rewriter.ir_ctx,
            ir.Location.getUnknown(),
            input,
            result_type,
            permutation,
        );
        _ = try self.rewriter.insert(op.op);
        return op.getResult();
    }
};

fn lowerPlanWithSink(
    allocator: std.mem.Allocator,
    sink: anytype,
    equation: *const Equation,
    plan: *const Plan,
    inputs: []const *ir.Value,
    dtype: DType,
) !*ir.Value {
    if (inputs.len != equation.inputs.len) return error.InputCountMismatch;
    const state_count = equation.inputs.len + plan.steps.len;
    const states = try allocator.alloc(State, state_count);
    defer allocator.free(states);
    @memset(states, .{});
    defer {
        for (states) |state| {
            if (state.owned) allocator.free(state.order);
        }
    }

    for (inputs, 0..) |input, index| {
        states[index] = .{
            .value = input,
            .order = equation.inputs[index].indices,
        };
    }

    if (plan.steps.len == 0) {
        if (equation.inputs.len != 1) return error.InvalidPlan;
        return try lowerSingleInput(allocator, sink, equation, states[0], dtype);
    }

    for (plan.steps) |step| {
        try lowerStep(allocator, sink, equation, step, states, dtype);
    }

    const final_state = states[states.len - 1];
    return final_state.value orelse error.InvalidPlan;
}

fn lowerSingleInput(
    allocator: std.mem.Allocator,
    sink: anytype,
    equation: *const Equation,
    input: State,
    dtype: DType,
) !*ir.Value {
    var value = input.value orelse return error.InvalidPlan;
    var order = input.order;

    var reduce_axes = std.ArrayListUnmanaged(i64).empty;
    defer reduce_axes.deinit(allocator);
    var kept = std.ArrayListUnmanaged(u8).empty;
    defer kept.deinit(allocator);
    for (order, 0..) |index, axis| {
        if (equation.output_set.contains(index)) {
            try kept.append(allocator, index);
        } else {
            try reduce_axes.append(allocator, @intCast(axis));
        }
    }

    if (reduce_axes.items.len != 0) {
        const result_dims = try dimsForOrder(allocator, equation, kept.items);
        defer allocator.free(result_dims);
        const result_type = try choir_root.accyTensorType(sink.context(), dtype, result_dims);
        const scalar_type = try choir_root.accyTensorType(sink.context(), dtype, &.{});
        const zero = try zeroConstant(sink, scalar_type, dtype);
        value = try sink.reduce(value, zero, result_type, "sum", reduce_axes.items);
        order = kept.items;
    }

    return try transposeToOrder(allocator, sink, equation, value, order, equation.output, dtype);
}

fn lowerStep(
    allocator: std.mem.Allocator,
    sink: anytype,
    equation: *const Equation,
    step: Step,
    states: []State,
    dtype: DType,
) !void {
    if (step.lhs >= states.len or step.rhs >= states.len or step.result >= states.len) return error.InvalidPlan;
    const lhs = states[step.lhs];
    const rhs = states[step.rhs];
    const initial_lhs_value = lhs.value orelse return error.InvalidPlan;
    const initial_rhs_value = rhs.value orelse return error.InvalidPlan;

    const initial_lhs_set = setFromOrder(lhs.order);
    const initial_rhs_set = setFromOrder(rhs.order);
    const reduced_lhs = try reduceOperandLocalSummedIndices(allocator, sink, equation, initial_lhs_value, lhs.order, step.summed_indices, initial_rhs_set, dtype);
    defer reduced_lhs.deinit(allocator);
    const reduced_rhs = try reduceOperandLocalSummedIndices(allocator, sink, equation, initial_rhs_value, rhs.order, step.summed_indices, initial_lhs_set, dtype);
    defer reduced_rhs.deinit(allocator);

    var lhs_batch = std.ArrayListUnmanaged(i64).empty;
    defer lhs_batch.deinit(allocator);
    var rhs_batch = std.ArrayListUnmanaged(i64).empty;
    defer rhs_batch.deinit(allocator);
    var lhs_contract = std.ArrayListUnmanaged(i64).empty;
    defer lhs_contract.deinit(allocator);
    var rhs_contract = std.ArrayListUnmanaged(i64).empty;
    defer rhs_contract.deinit(allocator);
    var contracted_order = std.ArrayListUnmanaged(u8).empty;
    defer contracted_order.deinit(allocator);
    var raw_order = std.ArrayListUnmanaged(u8).empty;
    defer raw_order.deinit(allocator);

    const rhs_set = setFromOrder(reduced_rhs.order);
    for (reduced_lhs.order, 0..) |index, axis| {
        if (!rhs_set.contains(index)) continue;
        if (step.result_indices.contains(index)) {
            try lhs_batch.append(allocator, @intCast(axis));
            try rhs_batch.append(allocator, try axisOf(reduced_rhs.order, index));
            try raw_order.append(allocator, index);
        }
    }

    for (reduced_lhs.order, 0..) |index, axis| {
        if (!step.summed_indices.contains(index)) continue;
        if (!rhs_set.contains(index)) return error.InvalidPlan;
        try lhs_contract.append(allocator, @intCast(axis));
        try rhs_contract.append(allocator, try axisOf(reduced_rhs.order, index));
        try contracted_order.append(allocator, index);
    }

    for (reduced_lhs.order) |index| {
        if (step.summed_indices.contains(index)) continue;
        if (contains(raw_order.items, index)) continue;
        try raw_order.append(allocator, index);
    }

    for (reduced_rhs.order) |index| {
        if (step.summed_indices.contains(index)) continue;
        if (contains(raw_order.items, index)) continue;
        try raw_order.append(allocator, index);
    }

    if (!setFromOrder(raw_order.items).eql(step.result_indices)) return error.InvalidPlan;

    const raw_dims = try dimsForOrder(allocator, equation, raw_order.items);
    defer allocator.free(raw_dims);
    const raw_type = try choir_root.accyTensorType(sink.context(), dtype, raw_dims);
    const raw_value = if (useDotGeneral(
        reduced_lhs.order,
        reduced_rhs.order,
        lhs_batch.items,
        rhs_batch.items,
        lhs_contract.items,
        rhs_contract.items,
        raw_order.items,
    ))
        try sink.dotGeneral(
            reduced_lhs.value,
            reduced_rhs.value,
            raw_type,
            lhs_contract.items,
            rhs_contract.items,
            lhs_batch.items,
            rhs_batch.items,
        )
    else
        try multiplyBroadcastReduce(
            allocator,
            sink,
            equation,
            raw_type,
            raw_dims,
            reduced_lhs,
            reduced_rhs,
            raw_order.items,
            contracted_order.items,
            dtype,
        );

    const final_mask = allInputsMask(equation.inputs.len);
    const desired = if (step.result_inputs == final_mask) equation.output else raw_order.items;
    const value = try transposeToOrder(allocator, sink, equation, raw_value, raw_order.items, desired, dtype);
    states[step.result] = .{
        .value = value,
        .order = try allocator.dupe(u8, desired),
        .owned = true,
    };
}

fn useDotGeneral(
    lhs_order: []const u8,
    rhs_order: []const u8,
    lhs_batch: []const i64,
    rhs_batch: []const i64,
    lhs_contract: []const i64,
    rhs_contract: []const i64,
    result_order: []const u8,
) bool {
    return lhs_batch.len == 0 and
        rhs_batch.len == 0 and
        lhs_contract.len == 1 and
        rhs_contract.len == 1 and
        lhs_order.len == 2 and
        rhs_order.len == 2 and
        result_order.len == 2;
}

fn multiplyBroadcastReduce(
    allocator: std.mem.Allocator,
    sink: anytype,
    equation: *const Equation,
    result_type: ir.Type,
    result_shape: []const i64,
    lhs: ReducedState,
    rhs: ReducedState,
    result_order: []const u8,
    contracted_order: []const u8,
    dtype: DType,
) !*ir.Value {
    var product_order = std.ArrayListUnmanaged(u8).empty;
    defer product_order.deinit(allocator);
    try product_order.appendSlice(allocator, result_order);
    try product_order.appendSlice(allocator, contracted_order);

    const product_shape = try dimsForOrder(allocator, equation, product_order.items);
    defer allocator.free(product_shape);
    const product_type = try choir_root.accyTensorType(sink.context(), dtype, product_shape);
    const lhs_dims = try broadcastDimsForOrder(allocator, product_order.items, lhs.order);
    defer allocator.free(lhs_dims);
    const rhs_dims = try broadcastDimsForOrder(allocator, product_order.items, rhs.order);
    defer allocator.free(rhs_dims);
    const lhs_value = try sink.broadcastInDim(lhs.value, product_type, product_shape, lhs_dims);
    const rhs_value = try sink.broadcastInDim(rhs.value, product_type, product_shape, rhs_dims);
    const product = try sink.mul(lhs_value, rhs_value);
    return try reduceToOrder(
        allocator,
        sink,
        equation,
        product,
        product_order.items,
        result_order,
        dtype,
        result_type,
        result_shape,
    );
}

const ReducedState = struct {
    value: *ir.Value,
    order: []const u8,
    owned: bool = false,

    fn deinit(self: ReducedState, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.order);
    }
};

fn reduceOperandLocalSummedIndices(
    allocator: std.mem.Allocator,
    sink: anytype,
    equation: *const Equation,
    value: *ir.Value,
    order: []const u8,
    summed: IndexSet,
    other: IndexSet,
    dtype: DType,
) !ReducedState {
    var reduce_axes = std.ArrayListUnmanaged(i64).empty;
    defer reduce_axes.deinit(allocator);
    var kept = std.ArrayListUnmanaged(u8).empty;
    defer kept.deinit(allocator);

    for (order, 0..) |index, axis| {
        if (summed.contains(index) and !other.contains(index)) {
            try reduce_axes.append(allocator, @intCast(axis));
        } else {
            try kept.append(allocator, index);
        }
    }

    if (reduce_axes.items.len == 0) {
        return .{
            .value = value,
            .order = order,
        };
    }

    const owned_order = try kept.toOwnedSlice(allocator);
    errdefer allocator.free(owned_order);
    const result_dims = try dimsForOrder(allocator, equation, owned_order);
    defer allocator.free(result_dims);
    const result_type = try choir_root.accyTensorType(sink.context(), dtype, result_dims);
    const reduced = try reduceToOrder(allocator, sink, equation, value, order, owned_order, dtype, result_type, result_dims);
    return .{
        .value = reduced,
        .order = owned_order,
        .owned = true,
    };
}

fn reduceToOrder(
    allocator: std.mem.Allocator,
    sink: anytype,
    equation: *const Equation,
    value: *ir.Value,
    source: []const u8,
    target: []const u8,
    dtype: DType,
    target_type: ir.Type,
    target_shape: []const i64,
) !*ir.Value {
    if (std.mem.eql(u8, source, target)) return value;

    var reduced_order = std.ArrayListUnmanaged(u8).empty;
    defer reduced_order.deinit(allocator);
    for (source) |index| {
        if (!contains(target, index)) try reduced_order.append(allocator, index);
    }
    if (reduced_order.items.len == 0) return try transposeToOrder(allocator, sink, equation, value, source, target, dtype);

    var canonical_order = std.ArrayListUnmanaged(u8).empty;
    defer canonical_order.deinit(allocator);
    try canonical_order.appendSlice(allocator, target);
    try canonical_order.appendSlice(allocator, reduced_order.items);
    const canonical = try transposeToOrder(allocator, sink, equation, value, source, canonical_order.items, dtype);

    const reduced_elements = try elementCountI64(equation, reduced_order.items);
    const scalar_type = try choir_root.accyTensorType(sink.context(), dtype, &.{});
    const zero = try zeroConstant(sink, scalar_type, dtype);
    if (target.len == 0 and reduced_order.items.len == 1 and canonical_order.items.len == 1) {
        return try sink.reduce(canonical, zero, target_type, "sum", &.{0});
    }
    if (target.len == 1 and reduced_order.items.len == 1 and canonical_order.items.len == 2) {
        return try sink.reduce(canonical, zero, target_type, "sum", &.{1});
    }
    if (target.len == 0) {
        const flat_shape = [_]i64{reduced_elements};
        const flat_type = try choir_root.accyTensorType(sink.context(), dtype, &flat_shape);
        const flat = try sink.reshape(canonical, flat_type, &flat_shape);
        return try sink.reduce(flat, zero, target_type, "sum", &.{0});
    }

    const kept_elements = try elementCountI64(equation, target);
    const flat_shape = [_]i64{ kept_elements, reduced_elements };
    const flat_type = try choir_root.accyTensorType(sink.context(), dtype, &flat_shape);
    const flat = try sink.reshape(canonical, flat_type, &flat_shape);
    const reduced_shape = [_]i64{kept_elements};
    const reduced_type = try choir_root.accyTensorType(sink.context(), dtype, &reduced_shape);
    const reduced = try sink.reduce(flat, zero, reduced_type, "sum", &.{1});
    return try sink.reshape(reduced, target_type, target_shape);
}

fn transposeToOrder(
    allocator: std.mem.Allocator,
    sink: anytype,
    equation: *const Equation,
    value: *ir.Value,
    source: []const u8,
    target: []const u8,
    dtype: DType,
) !*ir.Value {
    if (std.mem.eql(u8, source, target)) return value;
    const permutation = try permutationForOrder(allocator, source, target);
    defer allocator.free(permutation);
    const dims = try dimsForOrder(allocator, equation, target);
    defer allocator.free(dims);
    const result_type = try choir_root.accyTensorType(sink.context(), dtype, dims);
    return try sink.transpose(value, result_type, permutation);
}

fn zeroConstant(sink: anytype, scalar_type: ir.Type, dtype: DType) !*ir.Value {
    var bytes = @as([8]u8, @splat(0));
    return try sink.constant(scalar_type, bytes[0..dtype.sizeOf()]);
}

fn dimsForOrder(allocator: std.mem.Allocator, equation: *const Equation, order: []const u8) ![]i64 {
    const dims = try allocator.alloc(i64, order.len);
    errdefer allocator.free(dims);
    for (order, 0..) |index, axis| {
        const dim = equation.dimension(index);
        if (dim > @as(u64, @intCast(std.math.maxInt(i64)))) return error.InvalidDimension;
        dims[axis] = @intCast(dim);
    }
    return dims;
}

fn elementCountI64(equation: *const Equation, order: []const u8) !i64 {
    const count = equation.elementCount(setFromOrder(order));
    if (count > @as(u128, @intCast(std.math.maxInt(i64)))) return error.InvalidDimension;
    return @intCast(count);
}

fn permutationForOrder(allocator: std.mem.Allocator, source: []const u8, target: []const u8) ![]i64 {
    if (source.len != target.len) return error.InvalidPlan;
    const permutation = try allocator.alloc(i64, target.len);
    errdefer allocator.free(permutation);
    for (target, 0..) |index, axis| {
        permutation[axis] = try axisOf(source, index);
    }
    return permutation;
}

fn broadcastDimsForOrder(allocator: std.mem.Allocator, result: []const u8, source: []const u8) ![]i64 {
    const dims = try allocator.alloc(i64, source.len);
    errdefer allocator.free(dims);
    for (source, 0..) |index, axis| {
        dims[axis] = try axisOf(result, index);
    }
    return dims;
}

fn setFromOrder(order: []const u8) IndexSet {
    var set: IndexSet = .{};
    for (order) |index| set.add(index);
    return set;
}

fn axisOf(order: []const u8, index: u8) !i64 {
    for (order, 0..) |candidate, axis| {
        if (candidate == index) return @intCast(axis);
    }
    return error.InvalidPlan;
}

fn contains(order: []const u8, index: u8) bool {
    for (order) |candidate| {
        if (candidate == index) return true;
    }
    return false;
}

fn allInputsMask(input_count: usize) u64 {
    return (@as(u64, 1) << @intCast(input_count)) - 1;
}

test "einsum lowering emits planned dot_general chain" {
    const shapes = [_][]const u64{ &.{ 1000, 2 }, &.{ 2, 100 }, &.{ 100, 10 } };
    var equation = try spec.parse(testing.allocator, "ik,kl,lj->ij", &shapes);
    defer equation.deinit();
    var plan = try planner.createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer plan.deinit();

    var builder = try choir_root.SemanticBuilder.init(testing.allocator, choir_root.SemanticBuilder.ContextLimits.testing);
    defer builder.deinit();
    const a_ty = try builder.tensor(.f32, &.{ 1000, 2 });
    const b_ty = try builder.tensor(.f32, &.{ 2, 100 });
    const c_ty = try builder.tensor(.f32, &.{ 100, 10 });
    const out_ty = try builder.tensor(.f32, &.{ 1000, 10 });
    var fb = try builder.beginFunction("einsum_lower_chain", &.{ a_ty, b_ty, c_ty }, &.{out_ty});

    const value = try lowerPlan(
        testing.allocator,
        &fb,
        &equation,
        &plan,
        &.{ fb.parameter(0), fb.parameter(1), fb.parameter(2) },
        .f32,
    );
    try fb.return_(&.{value});
    try fb.finish();

    const module = try builder.finish();
    defer module.deinit();
    try module.verify();
    try testing.expectEqual(@as(usize, 2), ir.inspection.countOperationsNamed(module.choir_module, choir_root.AccyDialect.DotGeneralOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, choir_root.AccyDialect.TransposeOp.operation_name));
}

test "einsum lowering transposes final output order" {
    const shapes = [_][]const u64{ &.{ 2, 3 }, &.{ 3, 5 } };
    var equation = try spec.parse(testing.allocator, "ab,bc->ca", &shapes);
    defer equation.deinit();
    var plan = try planner.createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer plan.deinit();

    var builder = try choir_root.SemanticBuilder.init(testing.allocator, choir_root.SemanticBuilder.ContextLimits.testing);
    defer builder.deinit();
    const a_ty = try builder.tensor(.f32, &.{ 2, 3 });
    const b_ty = try builder.tensor(.f32, &.{ 3, 5 });
    const out_ty = try builder.tensor(.f32, &.{ 5, 2 });
    var fb = try builder.beginFunction("einsum_lower_transpose", &.{ a_ty, b_ty }, &.{out_ty});

    const value = try lowerPlan(testing.allocator, &fb, &equation, &plan, &.{ fb.parameter(0), fb.parameter(1) }, .f32);
    try fb.return_(&.{value});
    try fb.finish();

    const module = try builder.finish();
    defer module.deinit();
    try module.verify();
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, choir_root.AccyDialect.DotGeneralOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, choir_root.AccyDialect.TransposeOp.operation_name));
}

test "einsum lowering emits single input reduction" {
    const shapes = [_][]const u64{&.{ 4, 7 }};
    var equation = try spec.parse(testing.allocator, "ij->i", &shapes);
    defer equation.deinit();
    var plan = try planner.createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer plan.deinit();

    var builder = try choir_root.SemanticBuilder.init(testing.allocator, choir_root.SemanticBuilder.ContextLimits.testing);
    defer builder.deinit();
    const input_ty = try builder.tensor(.f32, &.{ 4, 7 });
    const out_ty = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("einsum_lower_reduce", &.{input_ty}, &.{out_ty});

    const value = try lowerPlan(testing.allocator, &fb, &equation, &plan, &.{fb.parameter(0)}, .f32);
    try fb.return_(&.{value});
    try fb.finish();

    const module = try builder.finish();
    defer module.deinit();
    try module.verify();
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, choir_root.AccyDialect.ReduceOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, choir_root.AccyDialect.DotGeneralOp.operation_name));
}

test "einsum lowering reduces operand-local summed axes before dot" {
    const shapes = [_][]const u64{ &.{ 2, 3 }, &.{ 5, 7 } };
    var equation = try spec.parse(testing.allocator, "ab,cd->ac", &shapes);
    defer equation.deinit();
    var plan = try planner.createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer plan.deinit();

    var builder = try choir_root.SemanticBuilder.init(testing.allocator, choir_root.SemanticBuilder.ContextLimits.testing);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 2, 3 });
    const rhs_ty = try builder.tensor(.f32, &.{ 5, 7 });
    const out_ty = try builder.tensor(.f32, &.{ 2, 5 });
    var fb = try builder.beginFunction("einsum_lower_local_reductions", &.{ lhs_ty, rhs_ty }, &.{out_ty});

    const value = try lowerPlan(testing.allocator, &fb, &equation, &plan, &.{ fb.parameter(0), fb.parameter(1) }, .f32);
    try fb.return_(&.{value});
    try fb.finish();

    const module = try builder.finish();
    defer module.deinit();
    try module.verify();
    try testing.expectEqual(@as(usize, 2), ir.inspection.countOperationsNamed(module.choir_module, choir_root.AccyDialect.ReduceOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, choir_root.AccyDialect.DotGeneralOp.operation_name));
    try testing.expectEqual(@as(usize, 2), ir.inspection.countOperationsNamed(module.choir_module, choir_root.AccyDialect.BroadcastInDimOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, choir_root.AccyDialect.MulOp.operation_name));
}

const BoundSink = enum { function, rewriter };

fn boundTensorType(
    builder: *choir_root.SemanticBuilder,
    dimensions: []const u64,
) !ir.Type {
    var dims: [62]i64 = undefined;
    for (dimensions, 0..) |dimension, index| dims[index] = @intCast(dimension);
    return builder.tensor(.f32, dims[0..dimensions.len]);
}

fn boundLoweredImage(
    scratch: std.mem.Allocator,
    equation: *const Equation,
    plan: *const Plan,
    mode: BoundSink,
) ![]u8 {
    var builder = try choir_root.SemanticBuilder.init(
        testing.allocator,
        choir_root.SemanticBuilder.ContextLimits.testing,
    );
    defer builder.deinit();
    var types: [63]ir.Type = undefined;
    for (equation.inputs, 0..) |input, index| {
        types[index] = try boundTensorType(&builder, input.dims);
    }
    const dims = try dimsForOrder(testing.allocator, equation, equation.output);
    defer testing.allocator.free(dims);
    const output_type = try builder.tensor(.f32, dims);
    var fb = try builder.beginFunction(
        "lower_bound",
        types[0..equation.inputs.len],
        &.{output_type},
    );
    var inputs: [63]*ir.Value = undefined;
    for (0..equation.inputs.len) |index| inputs[index] = fb.parameter(index);
    const operands = inputs[0..equation.inputs.len];
    const before = fb.ctx.operationCount();
    var rewriter = rewrite.PatternRewriter.init(testing.allocator, fb.ctx);
    defer rewriter.deinit();
    rewriter.setInsertionPoint(fb.entry);
    const result = switch (mode) {
        .function => try lowerPlan(scratch, &fb, equation, plan, operands, .f32),
        .rewriter => try lowerPlanWithRewriter(scratch, &rewriter, equation, plan, operands, .f32),
    };
    const bound = try loweringBounds(equation.inputs.len);
    try testing.expect(fb.ctx.operationCount() - before <= bound.operation_requests);
    try fb.return_(&.{result});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();
    rewriter.finalize(module.choir_module);
    try module.verify();
    return choir.bytecode.encodeModule(testing.allocator, module.choir_module);
}

fn loweringStorageWitness(text: []const u8, shapes: []const []const u64) !void {
    var equation = try spec.parse(testing.allocator, text, shapes);
    defer equation.deinit();
    var plan = try planner.createPlan(testing.allocator, &equation, .{
        .strategy = .left_to_right,
    });
    defer plan.deinit();
    const expected = try boundLoweredImage(testing.allocator, &equation, &plan, .function);
    defer testing.allocator.free(expected);
    const bound = try loweringBounds(shapes.len);
    const bytes = try testing.allocator.alloc(u8, @intCast(bound.scratch_bytes));
    defer testing.allocator.free(bytes);
    for (comptime std.meta.tags(BoundSink)) |mode| {
        var buffer = std.heap.FixedBufferAllocator.init(bytes);
        const base = buffer.allocator();
        const vtable: std.mem.Allocator.VTable = .{
            .alloc = base.vtable.alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = std.mem.Allocator.noFree,
        };
        const allocator: std.mem.Allocator = .{ .ptr = base.ptr, .vtable = &vtable };
        const actual = try boundLoweredImage(allocator, &equation, &plan, mode);
        defer testing.allocator.free(actual);
        try testing.expectEqualSlices(u8, expected, actual);
        try testing.expect(buffer.end_index <= bound.scratch_bytes);
    }
}

test "einsum lowering bounds preserve both sinks across contractions and reductions" {
    try loweringStorageWitness("->", &.{&.{}});
    try loweringStorageWitness("a->a", &.{&.{3}});
    try loweringStorageWitness("ab->ba", &.{&.{ 2, 3 }});
    try loweringStorageWitness("abc->ca", &.{&.{ 2, 3, 4 }});
    try loweringStorageWitness("ab,bc->ca", &.{ &.{ 2, 3 }, &.{ 3, 5 } });
    try loweringStorageWitness("abc,acd->abd", &.{ &.{ 2, 3, 4 }, &.{ 2, 4, 5 } });
    try loweringStorageWitness("ab,cd->ac", &.{ &.{ 2, 3 }, &.{ 5, 7 } });
    try loweringStorageWitness("abcd,defg->ga", &.{ &.{ 2, 3, 4, 5 }, &.{ 5, 6, 7, 8 } });
    try loweringStorageWitness("ab,bc,cd->da", &.{ &.{ 2, 3 }, &.{ 3, 4 }, &.{ 4, 5 } });
}

test "einsum lowering bounds cover full alphabet and maximum plan arity" {
    const labels = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const dims: [labels.len]u64 = @splat(1);
    const shapes: [63][]const u64 = @splat(&dims);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (shapes, 0..) |_, index| {
        if (index != 0) try text.append(testing.allocator, ',');
        try text.appendSlice(testing.allocator, labels);
    }
    try text.appendSlice(testing.allocator, "->");
    var reversed: [labels.len]u8 = undefined;
    for (labels, 0..) |label, index| reversed[labels.len - index - 1] = label;
    try text.appendSlice(testing.allocator, &reversed);
    try loweringStorageWitness(text.items, &shapes);
}

test "einsum lowering bounds reject invalid arity and preserve dimension failure" {
    try testing.expectError(error.EmptyEquation, loweringBounds(0));
    try testing.expectError(error.TooManyInputs, loweringBounds(64));
    try testing.expectError(error.TooManyInputs, loweringBounds(std.math.maxInt(usize)));
    const shapes = [_][]const u64{ &.{ 4_000_000_000, 4_000_000_000 }, &.{ 2, 3 } };
    var equation = try spec.parse(testing.allocator, "ab,cd->", &shapes);
    defer equation.deinit();
    var plan = try planner.createPlan(testing.allocator, &equation, .{
        .strategy = .left_to_right,
    });
    defer plan.deinit();
    const bound = try loweringBounds(shapes.len);
    const bytes = try testing.allocator.alloc(u8, @intCast(bound.scratch_bytes));
    defer testing.allocator.free(bytes);
    for (comptime std.meta.tags(BoundSink)) |mode| {
        var buffer = std.heap.FixedBufferAllocator.init(bytes);
        try testing.expectError(error.InvalidDimension, boundLoweredImage(
            buffer.allocator(),
            &equation,
            &plan,
            mode,
        ));
    }
}

fn loweringAllocationWitness(allocator: std.mem.Allocator, mode: BoundSink) !void {
    const shapes = [_][]const u64{ &.{ 2, 3, 4, 5 }, &.{ 5, 6, 7, 8 } };
    var equation = try spec.parse(testing.allocator, "abcd,defg->ga", &shapes);
    defer equation.deinit();
    var plan = try planner.createPlan(testing.allocator, &equation, .{
        .strategy = .left_to_right,
    });
    defer plan.deinit();
    const image = try boundLoweredImage(allocator, &equation, &plan, mode);
    defer testing.allocator.free(image);
}

test "einsum lowering releases scratch after every partial allocation" {
    for (comptime std.meta.tags(BoundSink)) |mode| {
        try testing.checkAllAllocationFailures(
            testing.allocator,
            loweringAllocationWitness,
            .{mode},
        );
    }
}
