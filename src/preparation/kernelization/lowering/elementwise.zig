const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const alloc_fixed = @import("alloc_fixed");
const generated_abi = @import("abi.zig");
const generated_builder = @import("builder.zig");
const common = @import("common.zig");
const generated_guard = @import("guard.zig");
const generated_name = @import("name.zig");
const range_analysis = @import("range.zig");
const generated_schedule = @import("schedule.zig");

const ir = common.ir;
const dialect_mod = common.dialect_mod;
const kernel_root = common.kernel_root;
const bufferization = common.bufferization;
const kernelization_model = @import("../model/root.zig");
const schedule_planning = common.schedule_planning;
const shape_analysis = common.shape_analysis;
const i64_attr_list_stack_capacity = common.i64_attr_list_stack_capacity;
const externalInputIndex = common.externalInputIndex;
const readI64ListAttrBounded = common.readI64ListAttrBounded;
const mapKernelBuildError = common.mapKernelBuildError;
const isName = common.isName;

const ElementwiseKernel = kernelization_model.ElementwiseKernel;
const bufferSlotById = common.bufferSlotById;
const LoweredKernel = kernelization_model.LoweredKernel;

/// The kernel stage calls this once per try at emitting a kernel under one candidate schedule to
/// charge element-by-element scratch, so compilation can refuse a pass that would exceed the
/// caller's limits. That scratch belongs to the costs a pass declares before it runs, its work
/// bound. The bound covers the scratch kept while choosing a kernel body and while emitting either
/// body, including the vector fallback, the second body this file emits when the per-element form
/// does not apply. The bound is computed from the operation, value and operand counts of the
/// source. Kernel names, parameter lists, and the storage of the generated builder and the object
/// that owns the operations and values of the generated kernels are charged separately.
pub fn scratchStorageBound(source: @import("choir").passes.pass.work.Census) !u64 {
    const accounting = @import("choir").passes.pass.work;
    const per_op = @sizeOf(*ir.Operation) + @sizeOf(ElementwiseKernel) +
        @sizeOf(gpu_abi.DType) + 3 * @sizeOf(kernel_root.Value);
    const per_value = @sizeOf(gpu_abi.DType) + @sizeOf(kernel_root.Value);
    var bytes = try accounting.add(
        try accounting.multiply(source.operations, per_op),
        try accounting.multiply(source.values, per_value),
    );
    bytes = try accounting.add(bytes, 8 * @alignOf(kernel_root.Value));
    const walk = try accounting.add(
        try accounting.hashMapGrowth(*ir.Operation, void, source.operations),
        try accounting.arrayListGrowth(*ir.Value, source.operands),
    );
    bytes = try accounting.add(bytes, try accounting.multiply(2, walk));
    bytes = try accounting.add(bytes, try accounting.arrayListGrowth(VectorInput, source.values));
    const memo = try accounting.hashMapGrowth(*ir.Value, kernel_root.Value, source.values);
    bytes = try accounting.add(bytes, try accounting.multiply(6, memo));
    if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
    return bytes;
}

pub fn lower(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    shape_plan: *const shape_analysis.ShapeLayoutAnalysis,
    format: ?gpu.ArtifactFormat,
) common.LoweringError!LoweredKernel {
    if (work.kind != .elementwise_single and work.kind != .elementwise_fusion) {
        return error.UnsupportedOperation;
    }
    if (work.ops.len == 0) return error.UnsupportedOperation;
    if (outline.inputCount() > std.math.maxInt(u32)) return error.InvalidArtifact;
    const emit_ops = allocator.alloc(*ir.Operation, work.ops.len) catch return error.OutOfMemory;
    defer allocator.free(emit_ops);
    var emit_count: usize = 0;
    for (work.ops) |op| {
        if (isName(op.name.name, dialect_mod.AccyDialect.SliceOp.operation_name)) continue;
        if (isName(op.name.name, dialect_mod.AccyDialect.PadOp.operation_name)) continue;
        if (isName(op.name.name, dialect_mod.AccyDialect.GatherOp.operation_name)) continue;
        emit_ops[emit_count] = op;
        emit_count += 1;
    }
    if (emit_count == 0) return error.UnsupportedOperation;
    const emitted_ops = emit_ops[0..emit_count];
    if (emitted_ops[emit_count - 1] != work.ops[work.ops.len - 1]) {
        return error.UnsupportedOperation;
    }
    const kinds = allocator.alloc(ElementwiseKernel, emit_count) catch return error.OutOfMemory;
    defer allocator.free(kinds);
    for (emitted_ops, 0..) |op, index| {
        const kind = kernelForOperation(op) orelse return error.UnsupportedOperation;
        kinds[index] = kind;
        if (op.getNumOperands() != expectedInputCount(kind)) return error.UnsupportedOperation;
    }
    const result_dtypes = try collectResultDTypes(allocator, emitted_ops, kinds, shape_plan);
    defer allocator.free(result_dtypes);

    const output_slot = bufferSlotById(buffer_plan, outline.output_slot_id) orelse
        return error.InvalidArtifact;
    if (output_slot.dtype != work.dtype) return error.InvalidArtifact;

    const input_dtypes = try collectInputDTypes(allocator, outline, buffer_plan);
    defer allocator.free(input_dtypes);

    var abi = try generated_abi.flatTyped(allocator, output_slot.dtype, input_dtypes);
    defer abi.deinit(allocator);

    const contains_gather = try closureContainsGather(allocator, emitted_ops);
    const rank2 = if (contains_gather)
        try rank2ElementwiseForResult(work.root, work.element_count)
    else
        null;

    if (vectorLoweringEligible(format, work, output_slot, contains_gather)) {
        if (try lowerVector(
            allocator,
            ir_ctx,
            outline,
            work,
            buffer_plan,
            abi,
            emitted_ops,
            kinds,
            result_dtypes,
        )) |kernel| {
            return kernel;
        }
    }

    const entry_name = try generated_name.elementwise(allocator, kinds, work.id);
    errdefer allocator.free(entry_name);

    if (rank2) |rank2_value| {
        var lowered = try generated_builder.withLaunch(
            allocator,
            ir_ctx,
            work.id,
            entry_name,
            abi.params(),
            generated_schedule.matrixThreads(rank2_value.cols_threads, rank2_value.rows_threads),
            .{
                .abi = abi,
                .allocator = allocator,
                .work = work,
                .ops = emitted_ops,
                .kinds = kinds,
                .result_dtypes = result_dtypes,
                .outline = outline,
                .buffer_plan = buffer_plan,
                .rank2 = rank2_value,
            },
            emitRank2ElementwiseBody,
        );
        lowered.body = .{ .elementwise_rank2 = try rank2ElementwisePlan(rank2_value) };
        return lowered;
    }

    return generated_builder.withLaunch(
        allocator,
        ir_ctx,
        work.id,
        entry_name,
        abi.params(),
        generated_schedule.flat(),
        .{
            .abi = abi,
            .allocator = allocator,
            .work = work,
            .ops = emitted_ops,
            .kinds = kinds,
            .result_dtypes = result_dtypes,
            .outline = outline,
            .buffer_plan = buffer_plan,
        },
        emitElementwiseBody,
    );
}

fn vectorLoweringEligible(
    format: ?gpu.ArtifactFormat,
    work: schedule_planning.ScheduleWorkItem,
    output_slot: *const bufferization.BufferSlot,
    contains_gather: bool,
) bool {
    if (format != .cuda_ptx) return false;
    if (contains_gather) return false;
    if (work.dtype != .f32 or output_slot.dtype != .f32) return false;
    if (work.element_count < 4 or work.element_count % 4 != 0) return false;
    return true;
}

const VectorInput = struct {
    value: *ir.Value,
    input_index: usize,
};

fn lowerVector(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    abi: generated_abi.Flat,
    ops: []const *ir.Operation,
    kinds: []const ElementwiseKernel,
    result_dtypes: []const gpu_abi.DType,
) common.LoweringError!?LoweredKernel {
    const vector_inputs = try collectVectorInputs(allocator, ops, outline, buffer_plan);
    defer allocator.free(vector_inputs);

    const entry_name = try generated_name.elementwiseVector(allocator, kinds, work.id);
    var lowered = generated_builder.withLaunch(
        allocator,
        ir_ctx,
        work.id,
        entry_name,
        abi.params(),
        generated_schedule.flat(),
        .{
            .abi = abi,
            .allocator = allocator,
            .work = work,
            .ops = ops,
            .kinds = kinds,
            .result_dtypes = result_dtypes,
            .outline = outline,
            .buffer_plan = buffer_plan,
            .vector_inputs = vector_inputs,
        },
        emitVectorElementwiseBody,
    ) catch |err| switch (err) {
        error.UnsupportedOperation, error.CapabilityMismatch => {
            allocator.free(entry_name);
            return null;
        },
        else => {
            allocator.free(entry_name);
            return err;
        },
    };
    lowered.body = .{ .elementwise_vector = .{ .quads = work.element_count / 4 } };
    return lowered;
}

const OperandWalk = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayListUnmanaged(*ir.Value) = .empty,
    expanded: std.AutoHashMap(*ir.Operation, void),

    fn init(allocator: std.mem.Allocator) OperandWalk {
        return .{
            .allocator = allocator,
            .expanded = std.AutoHashMap(*ir.Operation, void).init(allocator),
        };
    }

    fn deinit(self: *OperandWalk) void {
        self.pending.deinit(self.allocator);
        self.expanded.deinit();
    }

    fn expand(self: *OperandWalk, op: *ir.Operation) error{OutOfMemory}!void {
        const entry = try self.expanded.getOrPut(op);
        if (entry.found_existing) return;
        const operands = op.getOperandValues();
        var remaining = operands.len;
        while (remaining != 0) {
            remaining -= 1;
            try self.pending.append(self.allocator, operands[remaining]);
        }
    }

    fn next(self: *OperandWalk) ?*ir.Value {
        return self.pending.pop();
    }
};

fn collectVectorInputs(
    allocator: std.mem.Allocator,
    ops: []const *ir.Operation,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) common.LoweringError![]VectorInput {
    var collected: std.ArrayListUnmanaged(VectorInput) = .empty;
    errdefer collected.deinit(allocator);
    var walk = OperandWalk.init(allocator);
    defer walk.deinit();
    var remaining = ops.len;
    while (remaining != 0) {
        remaining -= 1;
        try walk.expand(ops[remaining]);
    }
    while (walk.next()) |value| {
        try collectVectorInputValue(&walk, &collected, value, ops, outline, buffer_plan);
    }
    return collected.toOwnedSlice(allocator);
}

fn collectVectorInputValue(
    walk: *OperandWalk,
    collected: *std.ArrayListUnmanaged(VectorInput),
    value: *ir.Value,
    ops: []const *ir.Operation,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) common.LoweringError!void {
    for (collected.items) |existing| {
        if (existing.value == value) return;
    }
    if (value.getDefiningOp()) |def_any| {
        const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
        for (ops) |op| {
            if (op == def_op) return;
        }
        if (isName(def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) return;
        if (isName(def_op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name)) {
            return;
        }
        if (buffer_plan.getSlot(value) == null) {
            if (kernelForOperation(def_op) != null) try walk.expand(def_op);
            return;
        }
    }
    const slot = buffer_plan.getSlot(value) orelse return;
    if (slot.dtype != .f32) return;
    const input_index = externalInputIndex(outline, slot.id) orelse return;
    try collected.append(walk.allocator, .{ .value = value, .input_index = input_index });
}

fn emit_vector_elementwise_quad(
    guarded: anytype,
    base: kernel_root.Value,
    body_ctx: anytype,
) !void {
    const loaded_vectors = try body_ctx.allocator.alloc(
        kernel_root.Value,
        body_ctx.vector_inputs.len,
    );
    defer body_ctx.allocator.free(loaded_vectors);
    for (body_ctx.vector_inputs, 0..) |vector_input, input_slot| {
        loaded_vectors[input_slot] = try guarded.loadVector(
            body_ctx.abi.input(guarded, vector_input.input_index),
            base,
            4,
        );
    }

    const op_results = try body_ctx.allocator.alloc(kernel_root.Value, body_ctx.ops.len);
    defer body_ctx.allocator.free(op_results);

    var lane_results: [4]kernel_root.Value = undefined;
    for (0..4) |lane| {
        var memo_storage: ?ValueMemo = ValueMemo.init(body_ctx.allocator);
        defer if (memo_storage) |*memo| memo.deinit();
        if (memo_storage) |*memo| {
            for (body_ctx.vector_inputs, 0..) |vector_input, input_slot| {
                const lane_value = try guarded.extractLane(
                    loaded_vectors[input_slot],
                    @intCast(lane),
                    .f32,
                );
                memo.put(vector_input.value, lane_value) catch return error.OutOfMemory;
            }
        }
        const flat_index = try guarded.add(
            base,
            try guarded.constantIndex(@as(i64, @intCast(lane))),
        );
        lane_results[lane] = try emitChainAtPosition(
            guarded,
            &memo_storage,
            flat_index,
            .{},
            op_results,
            body_ctx,
        );
    }

    const packed_result = try guarded.packVector(lane_results);
    try guarded.storeIndex(packed_result, body_ctx.out, base);
}

fn emitVectorElementwiseBody(logical: anytype, ctx: anytype) !void {
    const logical_index = try logical.index1D("i", ctx.work.element_count / 4);
    try generated_guard.countQuadDo(logical, logical_index, ctx.abi.count(logical), .{
        .allocator = ctx.allocator,
        .work = ctx.work,
        .ops = ctx.ops,
        .kinds = ctx.kinds,
        .result_dtypes = ctx.result_dtypes,
        .outline = ctx.outline,
        .buffer_plan = ctx.buffer_plan,
        .abi = ctx.abi,
        .out = ctx.abi.output(logical),
        .vector_inputs = ctx.vector_inputs,
    }, emit_vector_elementwise_quad);
}

fn emitChainAtPosition(
    builder: anytype,
    memo: anytype,
    flat_index: kernel_root.Value,
    facts: IndexFacts,
    op_results: []kernel_root.Value,
    body_ctx: anytype,
) !kernel_root.Value {
    for (body_ctx.ops, 0..) |op, op_index| {
        const kind = body_ctx.kinds[op_index];
        var inputs: [3]kernel_root.Value = undefined;
        const operands = op.getOperandValues();
        for (operands, 0..) |operand, operand_index| {
            inputs[operand_index] = try elementwiseOperandValue(
                builder,
                memo,
                flat_index,
                facts,
                operand,
                body_ctx.ops,
                op_index,
                op_results,
                body_ctx.outline,
                body_ctx.buffer_plan,
                body_ctx.abi,
            );
        }
        op_results[op_index] = try emitElementwiseValue(
            builder,
            kind,
            inputs[0..operands.len],
            body_ctx.result_dtypes[op_index],
            op,
        );
    }
    return elementwiseOutputValue(body_ctx.work, body_ctx.ops, op_results) orelse
        error.InvalidArtifact;
}

fn closureContainsGather(
    allocator: std.mem.Allocator,
    ops: []const *ir.Operation,
) error{OutOfMemory}!bool {
    var walk = OperandWalk.init(allocator);
    defer walk.deinit();
    for (ops) |op| {
        if (isName(op.name.name, dialect_mod.AccyDialect.GatherOp.operation_name)) return true;
        try walk.expand(op);
    }
    while (walk.next()) |value| {
        const def_any = value.getDefiningOp() orelse continue;
        const op: *ir.Operation = @ptrCast(@alignCast(def_any));
        if (isName(op.name.name, dialect_mod.AccyDialect.GatherOp.operation_name)) return true;
        try walk.expand(op);
    }
    return false;
}

const rank2_tile_width = 32;
const rank2_tile_height = 8;

const Rank2Elementwise = struct {
    rows: i64,
    cols: i64,
    total: i64,
    rows_threads: u32 = rank2_tile_height,
    cols_threads: u32 = rank2_tile_width,
};

const Rank2IndexFacts = struct {
    rows: i64,
    cols: i64,
    row: kernel_root.Value,
    col: kernel_root.Value,

    fn coordinate(self: Rank2IndexFacts, shape: []const i64, dim_index: usize) ?kernel_root.Value {
        if (shape.len != 2) return null;
        if (shape[0] != self.rows or shape[1] != self.cols) return null;
        return switch (dim_index) {
            0 => self.row,
            1 => self.col,
            else => null,
        };
    }
};

const IndexFacts = struct {
    rank2: ?Rank2IndexFacts = null,
};

fn rank2ElementwiseForResult(
    root: *ir.Operation,
    element_count: u64,
) common.LoweringError!?Rank2Elementwise {
    const result = root.getResult(0) orelse return error.InvalidArtifact;
    var dims_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
    const dims = try decodedDims(result, dims_buffer[0..]);
    return rank2ElementwiseForDims(dims, element_count);
}

fn rank2ElementwiseForDims(dims: []const i64, element_count: u64) ?Rank2Elementwise {
    if (dims.len != 2) return null;
    const rows = dims[0];
    const cols = dims[1];
    if (rows <= 0 or cols <= 0) return null;
    if (@rem(rows, rank2_tile_height) != 0 or @rem(cols, rank2_tile_width) != 0) return null;
    const total = std.math.mul(i64, rows, cols) catch return null;
    const count = std.math.cast(i64, element_count) orelse return null;
    if (total != count) return null;
    if (total > std.math.maxInt(i32)) return null;
    return .{
        .rows = rows,
        .cols = cols,
        .total = total,
    };
}

fn rank2ElementwisePlan(
    rank2: Rank2Elementwise,
) common.LoweringError!kernelization_model.ElementwiseRank2Plan {
    return .{
        .rows = std.math.cast(u32, rank2.rows) orelse return error.CapabilityMismatch,
        .cols = std.math.cast(u32, rank2.cols) orelse return error.CapabilityMismatch,
        .threads_x = rank2.cols_threads,
        .threads_y = rank2.rows_threads,
    };
}

fn collectResultDTypes(
    allocator: std.mem.Allocator,
    ops: []const *ir.Operation,
    kinds: []const ElementwiseKernel,
    shape_plan: *const shape_analysis.ShapeLayoutAnalysis,
) common.LoweringError![]gpu_abi.DType {
    const result_dtypes = allocator.alloc(gpu_abi.DType, ops.len) catch return error.OutOfMemory;
    errdefer allocator.free(result_dtypes);

    for (ops, kinds, 0..) |op, kind, index| {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const result_dtype = try valueDType(shape_plan, result);
        try validateOperationDTypes(op, kind, result_dtype, shape_plan);
        result_dtypes[index] = result_dtype;
    }

    return result_dtypes;
}

fn collectInputDTypes(
    allocator: std.mem.Allocator,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) common.LoweringError![]gpu_abi.DType {
    const input_dtypes = allocator.alloc(
        gpu_abi.DType,
        outline.inputCount(),
    ) catch return error.OutOfMemory;
    errdefer allocator.free(input_dtypes);

    for (outline.input_slot_ids, 0..) |slot_id, index| {
        const input_slot = bufferSlotById(buffer_plan, slot_id) orelse return error.InvalidArtifact;
        if (!executableBufferDType(input_slot.dtype)) return error.CapabilityMismatch;
        input_dtypes[index] = input_slot.dtype;
    }

    return input_dtypes;
}

fn validateOperationDTypes(
    op: *ir.Operation,
    kind: ElementwiseKernel,
    result_dtype: gpu_abi.DType,
    shape_plan: *const shape_analysis.ShapeLayoutAnalysis,
) common.LoweringError!void {
    const operands = op.getOperandValues();
    switch (kind) {
        .convert => {
            const input_dtype = try valueDType(shape_plan, operands[0]);
            if (!executableDataDType(input_dtype)) return error.CapabilityMismatch;
            if (!executableDataDType(result_dtype)) return error.CapabilityMismatch;
        },
        .compare => {
            if (result_dtype != .i1) return error.InvalidArtifact;
            const lhs_dtype = try valueDType(shape_plan, operands[0]);
            const rhs_dtype = try valueDType(shape_plan, operands[1]);
            if (lhs_dtype != rhs_dtype) return error.InvalidArtifact;
            if (!executableDataDType(lhs_dtype)) return error.CapabilityMismatch;
        },
        .select => {
            if ((try valueDType(shape_plan, operands[0])) != .i1) return error.InvalidArtifact;
            const true_dtype = try valueDType(shape_plan, operands[1]);
            const false_dtype = try valueDType(shape_plan, operands[2]);
            if (true_dtype != false_dtype or result_dtype != true_dtype) {
                return error.InvalidArtifact;
            }
            if (!executableBufferDType(result_dtype)) return error.CapabilityMismatch;
        },
        .pow,
        .atan2,
        .sqrt,
        .exp,
        .log,
        .tanh,
        .sin,
        .cos,
        .tan,
        .floor,
        .round,
        .trunc,
        => {
            try validateSameDataDType(operands, result_dtype, shape_plan);
            if (result_dtype != .f32 and result_dtype != .f16) return error.CapabilityMismatch;
        },
        .add,
        .sub,
        .mul,
        .div,
        .min,
        .max,
        .neg,
        .abs,
        => {
            try validateSameDataDType(operands, result_dtype, shape_plan);
            if (!executableDataDType(result_dtype)) return error.CapabilityMismatch;
        },
    }
}

fn validateSameDataDType(
    operands: []const *ir.Value,
    result_dtype: gpu_abi.DType,
    shape_plan: *const shape_analysis.ShapeLayoutAnalysis,
) common.LoweringError!void {
    for (operands) |operand| {
        if ((try valueDType(shape_plan, operand)) != result_dtype) return error.InvalidArtifact;
    }
}

fn valueDType(
    shape_plan: *const shape_analysis.ShapeLayoutAnalysis,
    value: *ir.Value,
) common.LoweringError!gpu_abi.DType {
    return (shape_plan.get(value) orelse return error.InvalidArtifact).dtype;
}

fn executableDataDType(dtype: gpu_abi.DType) bool {
    return dtype == .f32 or dtype == .f16 or dtype == .bf16 or dtype == .f64 or dtype == .i8 or
        dtype == .i16 or dtype == .i32 or dtype == .u8 or dtype == .u16 or
        dtype == .u32 or dtype == .i64 or dtype == .u64;
}

fn executableBufferDType(dtype: gpu_abi.DType) bool {
    return executableDataDType(dtype) or dtype == .i1;
}

fn emit_elementwise_index(
    guarded: anytype,
    index: kernel_root.Index1D,
    body_ctx: anytype,
) !void {
    const flat_index = index.index;
    const op_results = try body_ctx.allocator.alloc(kernel_root.Value, body_ctx.ops.len);
    defer body_ctx.allocator.free(op_results);
    var memo_storage: ?ValueMemo = ValueMemo.init(body_ctx.allocator);
    defer if (memo_storage) |*memo| memo.deinit();
    const result = try emitChainAtPosition(
        guarded,
        &memo_storage,
        flat_index,
        .{},
        op_results,
        body_ctx,
    );
    try guarded.storeIndex(result, body_ctx.out, flat_index);
}

fn emit_rank2_elementwise_guarded(guarded_inner: anytype, guarded_ctx: anytype) !void {
    const op_results = try guarded_ctx.payload.allocator.alloc(
        kernel_root.Value,
        guarded_ctx.payload.ops.len,
    );
    defer guarded_ctx.payload.allocator.free(op_results);
    var memo_storage: ?ValueMemo = ValueMemo.init(guarded_ctx.payload.allocator);
    defer if (memo_storage) |*memo| memo.deinit();
    const facts = IndexFacts{
        .rank2 = .{
            .rows = guarded_ctx.payload.rank2.rows,
            .cols = guarded_ctx.payload.rank2.cols,
            .row = guarded_ctx.row,
            .col = guarded_ctx.col,
        },
    };
    const result = try emitChainAtPosition(
        guarded_inner,
        &memo_storage,
        guarded_ctx.flat_index,
        facts,
        op_results,
        guarded_ctx.payload,
    );
    try guarded_inner.storeIndex(
        result,
        guarded_ctx.payload.out,
        guarded_ctx.flat_index,
    );
}

fn emit_rank2_elementwise_index(
    inner: anytype,
    active: kernel_root.Index2D,
    body_ctx: anytype,
) !void {
    const flat_index = try active.linear(inner);
    const zero = try inner.constantIndex(0);
    const count = try inner.loadIndex(body_ctx.count_buffer, zero);
    const index_i32 = try inner.cast(flat_index, .i32);
    const in_bounds = try inner.compare(.lt, index_i32, count);
    try inner.guardDo(in_bounds, .{
        .flat_index = flat_index,
        .row = active.y.index,
        .col = active.x.index,
        .payload = body_ctx,
    }, emit_rank2_elementwise_guarded);
}

fn emitElementwiseBody(logical: anytype, ctx: anytype) !void {
    const logical_index = try logical.index1D("i", ctx.work.element_count);
    try generated_guard.countIndexDo(logical, logical_index, ctx.abi.count(logical), .{
        .allocator = ctx.allocator,
        .work = ctx.work,
        .ops = ctx.ops,
        .kinds = ctx.kinds,
        .result_dtypes = ctx.result_dtypes,
        .outline = ctx.outline,
        .buffer_plan = ctx.buffer_plan,
        .abi = ctx.abi,
        .out = ctx.abi.output(logical),
    }, emit_elementwise_index);
}

fn emitRank2ElementwiseBody(logical: anytype, ctx: anytype) !void {
    const rows: u64 = @intCast(ctx.rank2.rows);
    const cols: u64 = @intCast(ctx.rank2.cols);
    const index = try logical.index2D(.{
        .x = .{ .name = "col", .extent = cols },
        .y = .{ .name = "row", .extent = rows },
    });
    try logical.guardIndex2DDo(index, .{
        .allocator = ctx.allocator,
        .work = ctx.work,
        .ops = ctx.ops,
        .kinds = ctx.kinds,
        .result_dtypes = ctx.result_dtypes,
        .outline = ctx.outline,
        .buffer_plan = ctx.buffer_plan,
        .abi = ctx.abi,
        .out = ctx.abi.output(logical),
        .rank2 = ctx.rank2,
        .count_buffer = ctx.abi.count(logical),
    }, emit_rank2_elementwise_index);
}

fn elementwiseOperandValue(
    builder: anytype,
    memo: anytype,
    index: kernel_root.Value,
    facts: IndexFacts,
    operand: *ir.Value,
    ops: []const *ir.Operation,
    op_index: usize,
    op_results: []const kernel_root.Value,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    abi: generated_abi.Flat,
) common.LoweringError!kernel_root.Value {
    if (elementwiseChainValue(operand, ops, op_index, op_results)) |value| return value;
    if (try broadcastInDimElementwiseOperandValue(
        builder,
        index,
        operand,
        outline,
        buffer_plan,
        abi,
    )) |value| return value;
    return evaluateValueAtPosition(
        builder,
        memo,
        index,
        facts,
        operand,
        outline,
        buffer_plan,
        abi,
        max_recompute_depth,
    );
}

pub const max_shape_read_depth = 8;
pub const max_recompute_depth = 32;

pub const ValueMemo = std.AutoHashMap(*ir.Value, kernel_root.Value);

const ValueReadQuery = union(enum) {
    value: *ir.Value,
    slice: *ir.Operation,
    gather: *ir.Operation,
    pad: *ir.Operation,
};

pub fn shapeReadValue(
    builder: anytype,
    index: kernel_root.Value,
    value: *ir.Value,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    abi: anytype,
    depth: usize,
) common.LoweringError!kernel_root.Value {
    var memo_storage: ?ValueMemo = null;
    defer if (memo_storage) |*memo| memo.deinit();
    return evaluateValueAtPosition(
        builder,
        &memo_storage,
        index,
        .{},
        value,
        outline,
        buffer_plan,
        abi,
        depth,
    );
}

pub fn evaluateValueAtIndex(
    builder: anytype,
    memo: anytype,
    index: kernel_root.Value,
    value: *ir.Value,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    abi: anytype,
    depth: usize,
) common.LoweringError!kernel_root.Value {
    return evaluateValueAtPosition(
        builder,
        memo,
        index,
        .{},
        value,
        outline,
        buffer_plan,
        abi,
        depth,
    );
}

fn evaluateValueAtPosition(
    builder: anytype,
    memo: anytype,
    index: kernel_root.Value,
    facts: IndexFacts,
    value: *ir.Value,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    abi: anytype,
    depth: usize,
) common.LoweringError!kernel_root.Value {
    return readValueAtPosition(
        builder,
        memo,
        index,
        facts,
        .{ .value = value },
        outline,
        buffer_plan,
        abi,
        depth,
    );
}

fn readValueAtPosition(
    builder: anytype,
    memo: anytype,
    index: kernel_root.Value,
    facts: IndexFacts,
    query: ValueReadQuery,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    abi: anytype,
    depth: usize,
) common.LoweringError!kernel_root.Value {
    switch (query) {
        .value => |value| {
            if (depth == 0) return error.UnsupportedOperation;
            if (memo.*) |*existing| {
                if (existing.get(value)) |cached| return cached;
            }

            const resolved = resolved: {
                if (value.getDefiningOp()) |def_any| {
                    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
                    if (isName(
                        def_op.name.name,
                        dialect_mod.AccyDialect.ConstantOp.operation_name,
                    )) {
                        if (try common.optionalSplatConstantValue(
                            builder,
                            def_op,
                        )) |scalar| break :resolved scalar;
                    }
                    if (isName(
                        def_op.name.name,
                        dialect_mod.AccyDialect.BroadcastInDimOp.operation_name,
                    )) {
                        const operands = def_op.getOperandValues();
                        if (operands.len != 1) return error.InvalidArtifact;
                        if (operands[0].getDefiningOp()) |source_any| {
                            const source_op: *ir.Operation = @ptrCast(@alignCast(source_any));
                            if (isName(
                                source_op.name.name,
                                dialect_mod.AccyDialect.ConstantOp.operation_name,
                            )) {
                                if (try common.optionalSplatConstantValue(
                                    builder,
                                    source_op,
                                )) |scalar| break :resolved scalar;
                            }
                        }
                        const source_slot = buffer_plan.getSlot(operands[0]) orelse
                            return error.UnsupportedOperation;
                        const source_input_index = externalInputIndex(
                            outline,
                            source_slot.id,
                        ) orelse return error.UnsupportedOperation;
                        const source_index = try broadcastInDimSourceIndex(
                            builder,
                            index,
                            def_op,
                            source_slot,
                        );
                        break :resolved builder.loadIndex(
                            abi.input(builder, source_input_index),
                            source_index,
                        ) catch |err| return mapKernelBuildError(err);
                    }
                    if (isName(
                        def_op.name.name,
                        dialect_mod.AccyDialect.BroadcastOp.operation_name,
                    )) {
                        const operands = def_op.getOperandValues();
                        if (operands.len != 1) return error.InvalidArtifact;
                        if (operands[0].getDefiningOp()) |source_any| {
                            const source_op: *ir.Operation = @ptrCast(@alignCast(source_any));
                            if (isName(
                                source_op.name.name,
                                dialect_mod.AccyDialect.ConstantOp.operation_name,
                            )) {
                                if (try common.optionalSplatConstantValue(
                                    builder,
                                    source_op,
                                )) |scalar| break :resolved scalar;
                            }
                        }
                    }
                }

                if (buffer_plan.getSlot(value)) |slot| {
                    const input_index = externalInputIndex(outline, slot.id) orelse
                        return error.UnsupportedOperation;
                    break :resolved builder.loadIndex(
                        abi.input(builder, input_index),
                        index,
                    ) catch |err| return mapKernelBuildError(err);
                }

                const def_any = value.getDefiningOp() orelse return error.UnsupportedOperation;
                const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
                if (isName(def_op.name.name, dialect_mod.AccyDialect.IotaOp.operation_name)) {
                    break :resolved try iotaValueAtIndex(builder, index, facts, def_op, value);
                }
                if (isName(def_op.name.name, dialect_mod.AccyDialect.SliceOp.operation_name)) {
                    break :resolved try readValueAtPosition(
                        builder,
                        memo,
                        index,
                        facts,
                        .{ .slice = def_op },
                        outline,
                        buffer_plan,
                        abi,
                        depth,
                    );
                }
                if (isName(def_op.name.name, dialect_mod.AccyDialect.PadOp.operation_name)) {
                    break :resolved try readValueAtPosition(
                        builder,
                        memo,
                        index,
                        facts,
                        .{ .pad = def_op },
                        outline,
                        buffer_plan,
                        abi,
                        depth,
                    );
                }
                if (isName(def_op.name.name, dialect_mod.AccyDialect.GatherOp.operation_name)) {
                    break :resolved try readValueAtPosition(
                        builder,
                        memo,
                        index,
                        facts,
                        .{ .gather = def_op },
                        outline,
                        buffer_plan,
                        abi,
                        depth,
                    );
                }
                if (kernelForOperation(def_op)) |kind| {
                    const operands = def_op.getOperandValues();
                    if (operands.len > 3) return error.UnsupportedOperation;
                    var inputs: [3]kernel_root.Value = undefined;
                    for (operands, 0..) |operand, operand_index| {
                        inputs[operand_index] = try readValueAtPosition(
                            builder,
                            memo,
                            index,
                            facts,
                            .{ .value = operand },
                            outline,
                            buffer_plan,
                            abi,
                            depth - 1,
                        );
                    }
                    var dtype_arena_buffer: [160]u8 = undefined;
                    var dtype_arena = alloc_fixed.FixedBuffer.init(dtype_arena_buffer[0..]);
                    const result_type = dialect_mod.decodeTensorType(
                        dtype_arena.allocator(),
                        value.type,
                    ) catch return error.InvalidArtifact;
                    break :resolved emitElementwiseValue(
                        builder,
                        kind,
                        inputs[0..operands.len],
                        result_type.dtype,
                        def_op,
                    ) catch |err| return common.mapGeneratedKernelError(err);
                }
                return error.UnsupportedOperation;
            };

            if (memo.*) |*existing| {
                existing.put(value, resolved) catch return error.OutOfMemory;
            }
            return resolved;
        },
        .slice => |def_op| {
            const operands = def_op.getOperandValues();
            if (operands.len != 1) return error.InvalidArtifact;
            const result = def_op.getResult(0) orelse return error.InvalidArtifact;

            var result_dims_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
            const result_dims = try decodedDims(result, result_dims_buffer[0..]);
            var source_dims_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
            const source_dims = try decodedDims(operands[0], source_dims_buffer[0..]);
            if (result_dims.len != source_dims.len) return error.InvalidArtifact;

            var starts_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
            const starts = try readI64ListAttrBounded(
                def_op,
                "starts",
                dialect_mod.AccyDialect.SliceOp.dialectAttrName("starts"),
                &starts_buffer,
            );
            var strides_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
            const strides = try readI64ListAttrBounded(
                def_op,
                "strides",
                dialect_mod.AccyDialect.SliceOp.dialectAttrName("strides"),
                &strides_buffer,
            );
            if (starts.len != result_dims.len or strides.len != result_dims.len) {
                return error.InvalidArtifact;
            }

            var source_index = builder.constantIndex(0) catch |err| return mapKernelBuildError(err);
            for (result_dims, 0..) |dim, dim_index| {
                if (dim <= 0) return error.CapabilityMismatch;
                if (strides[dim_index] <= 0) return error.CapabilityMismatch;
                const coord = try coordinateFromShape(
                    builder,
                    index,
                    facts,
                    result_dims,
                    dim_index,
                );
                const source_stride = try rowMajorStrideAt(source_dims, dim_index);
                var source_coord = coord;
                if (strides[dim_index] != 1) {
                    const stride_value = builder.constantIndex(
                        strides[dim_index],
                    ) catch |err| return mapKernelBuildError(err);
                    source_coord = builder.mul(
                        source_coord,
                        stride_value,
                    ) catch |err| return mapKernelBuildError(err);
                }
                if (starts[dim_index] != 0) {
                    const start_value = builder.constantIndex(
                        starts[dim_index],
                    ) catch |err| return mapKernelBuildError(err);
                    source_coord = builder.add(
                        source_coord,
                        start_value,
                    ) catch |err| return mapKernelBuildError(err);
                }
                const term = if (source_stride == 1) source_coord else blk: {
                    const stride_value = builder.constantIndex(
                        source_stride,
                    ) catch |err| return mapKernelBuildError(err);
                    break :blk builder.mul(
                        source_coord,
                        stride_value,
                    ) catch |err| return mapKernelBuildError(err);
                };
                source_index = builder.add(
                    source_index,
                    term,
                ) catch |err| return mapKernelBuildError(err);
            }
            var shifted_memo: ?ValueMemo = null;
            defer if (shifted_memo) |*existing| existing.deinit();
            return readValueAtPosition(
                builder,
                &shifted_memo,
                source_index,
                .{},
                .{ .value = operands[0] },
                outline,
                buffer_plan,
                abi,
                depth - 1,
            );
        },
        .gather => |def_op| {
            const operands = def_op.getOperandValues();
            if (operands.len != 2) return error.InvalidArtifact;
            const axis = try common.readIntegerAttr(def_op, "axis");
            if (axis != 0) return error.UnsupportedOperation;
            var src_dims_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
            const src_dims = try decodedDims(operands[0], src_dims_buffer[0..]);
            if (src_dims.len != 1) return error.UnsupportedOperation;
            const axis_size = src_dims[0];
            if (axis_size <= 0) return error.CapabilityMismatch;

            const source_index = if (try gatherIotaSourceIndex(
                builder,
                index,
                facts,
                operands[1],
                axis_size,
            )) |proven_index|
                proven_index
            else if (try range_analysis.gatherIndexProvenInBounds(operands[1], axis_size, depth -
                1))
            blk: {
                const idx_value = try readValueAtPosition(
                    builder,
                    memo,
                    index,
                    facts,
                    .{ .value = operands[1] },
                    outline,
                    buffer_plan,
                    abi,
                    depth - 1,
                );
                break :blk builder.castIndex(idx_value) catch |err| return mapKernelBuildError(err);
            } else blk: {
                const idx_value = try readValueAtPosition(
                    builder,
                    memo,
                    index,
                    facts,
                    .{ .value = operands[1] },
                    outline,
                    buffer_plan,
                    abi,
                    depth - 1,
                );
                const zero_i32 = builder.constantInt(
                    .i32,
                    0,
                ) catch |err| return mapKernelBuildError(err);
                const limit_value = @min(axis_size - 1, @as(i64, std.math.maxInt(i32)));
                const limit_i32 = builder.constantInt(
                    .i32,
                    limit_value,
                ) catch |err| return mapKernelBuildError(err);
                const lower_clamped = builder.max(
                    idx_value,
                    zero_i32,
                ) catch |err| return mapKernelBuildError(err);
                const clamped = builder.min(
                    lower_clamped,
                    limit_i32,
                ) catch |err| return mapKernelBuildError(err);
                break :blk builder.castIndex(clamped) catch |err| return mapKernelBuildError(err);
            };

            if (buffer_plan.getSlot(operands[0])) |slot| {
                if (externalInputIndex(outline, slot.id)) |input_index| {
                    return builder.loadIndex(
                        abi.input(builder, input_index),
                        source_index,
                    ) catch |err| return mapKernelBuildError(err);
                }
            }
            var shifted_memo: ?ValueMemo = null;
            defer if (shifted_memo) |*existing| existing.deinit();
            return readValueAtPosition(
                builder,
                &shifted_memo,
                source_index,
                .{},
                .{ .value = operands[0] },
                outline,
                buffer_plan,
                abi,
                depth - 1,
            );
        },
        .pad => |def_op| {
            const operands = def_op.getOperandValues();
            if (operands.len != 2) return error.InvalidArtifact;
            const result = def_op.getResult(0) orelse return error.InvalidArtifact;

            var result_dims_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
            const result_dims = try decodedDims(result, result_dims_buffer[0..]);
            var source_dims_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
            const source_dims = try decodedDims(operands[0], source_dims_buffer[0..]);
            if (result_dims.len != source_dims.len) return error.InvalidArtifact;

            var low_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
            const edge_low = try readI64ListAttrBounded(
                def_op,
                "edge_low",
                dialect_mod.AccyDialect.PadOp.dialectAttrName("edge_low"),
                &low_buffer,
            );
            var interior_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
            const interior = try readI64ListAttrBounded(
                def_op,
                "interior",
                dialect_mod.AccyDialect.PadOp.dialectAttrName("interior"),
                &interior_buffer,
            );
            if (edge_low.len != result_dims.len or interior.len != result_dims.len) {
                return error.InvalidArtifact;
            }
            for (interior) |dilation| if (dilation != 0) return error.UnsupportedOperation;

            const zero = builder.constantIndex(0) catch |err| return mapKernelBuildError(err);
            var source_index = zero;
            var in_bounds: ?kernel_root.Value = null;
            for (result_dims, 0..) |dim, dim_index| {
                if (dim <= 0) return error.CapabilityMismatch;
                const coord = try coordinateFromShape(
                    builder,
                    index,
                    facts,
                    result_dims,
                    dim_index,
                );
                var source_coord = coord;
                if (edge_low[dim_index] != 0) {
                    const low_value = builder.constantIndex(
                        edge_low[dim_index],
                    ) catch |err| return mapKernelBuildError(err);
                    source_coord = builder.sub(
                        source_coord,
                        low_value,
                    ) catch |err| return mapKernelBuildError(err);
                }
                const dim_extent = builder.constantIndex(
                    source_dims[dim_index],
                ) catch |err| return mapKernelBuildError(err);
                const dim_edge = builder.constantIndex(source_dims[dim_index] -
                    1) catch |err| return mapKernelBuildError(err);
                const low_ok = builder.compare(
                    .ge,
                    source_coord,
                    zero,
                ) catch |err| return mapKernelBuildError(err);
                const high_ok = builder.compare(
                    .lt,
                    source_coord,
                    dim_extent,
                ) catch |err| return mapKernelBuildError(err);
                in_bounds = if (in_bounds) |previous| blk: {
                    const with_low = builder.select(
                        low_ok,
                        previous,
                        low_ok,
                    ) catch |err| return mapKernelBuildError(err);
                    break :blk builder.select(
                        high_ok,
                        with_low,
                        high_ok,
                    ) catch |err| return mapKernelBuildError(err);
                } else blk: {
                    break :blk builder.select(
                        low_ok,
                        high_ok,
                        low_ok,
                    ) catch |err| return mapKernelBuildError(err);
                };
                const clamped_low = builder.max(
                    source_coord,
                    zero,
                ) catch |err| return mapKernelBuildError(err);
                const clamped = builder.min(
                    clamped_low,
                    dim_edge,
                ) catch |err| return mapKernelBuildError(err);
                const source_stride = try rowMajorStrideAt(source_dims, dim_index);
                const term = if (source_stride == 1) clamped else blk: {
                    const stride_value = builder.constantIndex(
                        source_stride,
                    ) catch |err| return mapKernelBuildError(err);
                    break :blk builder.mul(
                        clamped,
                        stride_value,
                    ) catch |err| return mapKernelBuildError(err);
                };
                source_index = builder.add(
                    source_index,
                    term,
                ) catch |err| return mapKernelBuildError(err);
            }

            var shifted_memo: ?ValueMemo = null;
            defer if (shifted_memo) |*existing| existing.deinit();
            const loaded = try readValueAtPosition(
                builder,
                &shifted_memo,
                source_index,
                .{},
                .{ .value = operands[0] },
                outline,
                buffer_plan,
                abi,
                depth - 1,
            );

            const pad_slot = buffer_plan.getSlot(operands[1]) orelse
                return error.UnsupportedOperation;
            const pad_input_index = externalInputIndex(outline, pad_slot.id) orelse
                return error.UnsupportedOperation;
            const pad_value = builder.loadIndex(
                abi.input(builder, pad_input_index),
                zero,
            ) catch |err| return mapKernelBuildError(err);

            const bounds = in_bounds orelse return error.InvalidArtifact;
            return builder.select(bounds, loaded, pad_value) catch |err| return mapKernelBuildError(
                err,
            );
        },
    }
}

fn gatherIotaSourceIndex(
    builder: anytype,
    index: kernel_root.Value,
    facts: IndexFacts,
    value: *ir.Value,
    axis_size: i64,
) common.LoweringError!?kernel_root.Value {
    const def_any = value.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!isName(def_op.name.name, dialect_mod.AccyDialect.IotaOp.operation_name)) return null;

    const axis_attr = def_op.getAttrAs(
        ir.Attribute.IntegerAttr,
        "iota_dimension",
    ) orelse return error.InvalidArtifact;
    const axis = axis_attr.getValue();
    if (axis < 0) return error.InvalidArtifact;

    var dims_arena_buffer: [256]u8 = undefined;
    var dims_arena = alloc_fixed.FixedBuffer.init(dims_arena_buffer[0..]);
    const result_type = dialect_mod.decodeTensorType(
        dims_arena.allocator(),
        value.type,
    ) catch return error.InvalidArtifact;
    if (axis >= result_type.dims.len) return error.InvalidArtifact;
    const axis_dim = result_type.dims[@intCast(axis)];
    if (axis_dim <= 0) return error.CapabilityMismatch;
    if (axis_dim > axis_size) return null;
    if (!nonNegativeIotaRangeFitsDType(axis_dim, result_type.dtype)) return null;

    return try coordinateFromShape(builder, index, facts, result_type.dims, @intCast(axis));
}

fn nonNegativeIotaRangeFitsDType(axis_dim: i64, dtype: gpu_abi.DType) bool {
    if (axis_dim <= 0) return false;
    const last = axis_dim - 1;
    return switch (dtype) {
        .i8 => last <= std.math.maxInt(i8),
        .i16 => last <= std.math.maxInt(i16),
        .i32 => last <= std.math.maxInt(i32),
        .i64 => true,
        .u8 => last <= std.math.maxInt(u8),
        .u16 => last <= std.math.maxInt(u16),
        .u32 => last <= std.math.maxInt(u32),
        .u64 => true,
        else => false,
    };
}

fn decodedDims(value: *ir.Value, buffer: []i64) common.LoweringError![]const i64 {
    var arena_buffer: [256]u8 = undefined;
    var arena = alloc_fixed.FixedBuffer.init(arena_buffer[0..]);
    const decoded = dialect_mod.decodeTensorType(
        arena.allocator(),
        value.type,
    ) catch return error.InvalidArtifact;
    if (decoded.dims.len > buffer.len) return error.CapabilityMismatch;
    @memcpy(buffer[0..decoded.dims.len], decoded.dims);
    return buffer[0..decoded.dims.len];
}

fn rowMajorStrideAt(dims: []const i64, dim_index: usize) common.LoweringError!i64 {
    var stride: i64 = 1;
    for (dims[dim_index + 1 ..]) |dim| {
        if (dim <= 0) return error.CapabilityMismatch;
        stride = std.math.mul(i64, stride, dim) catch return error.CapabilityMismatch;
    }
    return stride;
}

fn iota_coordinate(
    inner: anytype,
    flat: kernel_root.Value,
    stride_value: i64,
    extent: i64,
) !kernel_root.Value {
    const stride_extent = try inner.constantIndex(stride_value);
    const scaled = try inner.div(flat, stride_extent);
    const extent_value = try inner.constantIndex(extent);
    const wraps = try inner.div(scaled, extent_value);
    return inner.sub(scaled, try inner.mul(wraps, extent_value));
}

fn iotaValueAtIndex(
    builder: anytype,
    index: kernel_root.Value,
    facts: IndexFacts,
    def_op: *ir.Operation,
    value: *ir.Value,
) common.LoweringError!kernel_root.Value {
    const axis_attr = def_op.getAttrAs(
        ir.Attribute.IntegerAttr,
        "iota_dimension",
    ) orelse return error.InvalidArtifact;
    const axis = axis_attr.getValue();
    if (axis < 0) return error.InvalidArtifact;

    var dims_arena_buffer: [256]u8 = undefined;
    var dims_arena = alloc_fixed.FixedBuffer.init(dims_arena_buffer[0..]);
    const result_type = dialect_mod.decodeTensorType(
        dims_arena.allocator(),
        value.type,
    ) catch return error.InvalidArtifact;
    if (axis >= result_type.dims.len) return error.InvalidArtifact;

    var stride: i64 = 1;
    var dim_index = result_type.dims.len;
    while (dim_index > @as(usize, @intCast(axis)) + 1) {
        dim_index -= 1;
        const dim = result_type.dims[dim_index];
        if (dim < 1) return error.UnsupportedOperation;
        stride *= dim;
    }
    const axis_dim = result_type.dims[@intCast(axis)];
    if (axis_dim < 1) return error.UnsupportedOperation;
    if (facts.rank2) |rank2| {
        if (rank2.coordinate(result_type.dims, @intCast(axis))) |coord| {
            return builder.cast(coord, result_type.dtype) catch |err| return mapKernelBuildError(
                err,
            );
        }
    }

    const coord = iota_coordinate(
        builder,
        index,
        stride,
        axis_dim,
    ) catch |err| return mapKernelBuildError(err);
    const casted = builder.cast(coord, result_type.dtype) catch |err| return mapKernelBuildError(
        err,
    );
    return casted;
}

fn broadcastInDimElementwiseOperandValue(
    builder: anytype,
    index: kernel_root.Value,
    operand: *ir.Value,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    abi: generated_abi.Flat,
) common.LoweringError!?kernel_root.Value {
    const def_any = operand.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!isName(def_op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name)) {
        return null;
    }
    const operands = def_op.getOperandValues();
    if (operands.len != 1) return error.InvalidArtifact;

    const source_slot = buffer_plan.getSlot(operands[0]) orelse return error.UnsupportedOperation;
    const source_input_index = externalInputIndex(outline, source_slot.id) orelse
        return error.UnsupportedOperation;
    const source_index = try broadcastInDimSourceIndex(builder, index, def_op, source_slot);
    return builder.loadIndex(
        abi.input(builder, source_input_index),
        source_index,
    ) catch |err| return mapKernelBuildError(err);
}

pub fn broadcastInDimSourceIndex(
    builder: anytype,
    index: kernel_root.Value,
    op: *ir.Operation,
    source_slot: *const bufferization.BufferSlot,
) common.LoweringError!kernel_root.Value {
    var broadcast_dims_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
    const broadcast_dims = try readI64ListAttrBounded(
        op,
        "broadcast_dims",
        dialect_mod.AccyDialect.BroadcastInDimOp.dialectAttrName("broadcast_dims"),
        &broadcast_dims_buffer,
    );
    var result_shape_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
    const result_shape = try readI64ListAttrBounded(
        op,
        "result_shape",
        dialect_mod.AccyDialect.BroadcastInDimOp.dialectAttrName("result_shape"),
        &result_shape_buffer,
    );
    if (broadcast_dims.len != source_slot.dims.len) return error.InvalidArtifact;
    try validateBroadcastDims(broadcast_dims, result_shape.len);
    const source_strides = source_slot.row_major_strides orelse return error.CapabilityMismatch;
    if (source_strides.len != source_slot.dims.len) return error.InvalidArtifact;

    var source_index = builder.constantIndex(0) catch |err| return mapKernelBuildError(err);
    for (result_shape, 0..) |dim, dim_index| {
        if (dim <= 0) return error.CapabilityMismatch;
        const coord = try linearCoordinateFromShape(builder, index, result_shape, dim_index);

        const source_dim = (try sourceDimForOutputDim(broadcast_dims, dim_index)) orelse continue;
        if (source_dim >= source_slot.dims.len) return error.InvalidArtifact;
        const source_dim_size = source_slot.dims[source_dim];
        if (source_dim_size <= 0) return error.CapabilityMismatch;
        if (source_dim_size != 1 and source_dim_size != dim) return error.InvalidArtifact;
        if (source_dim_size == 1) continue;

        const source_stride = std.math.cast(i64, source_strides[source_dim]) orelse
            return error.CapabilityMismatch;
        const term = if (source_stride == 1) coord else blk: {
            const stride_value = builder.constantIndex(
                source_stride,
            ) catch |err| return mapKernelBuildError(err);
            break :blk builder.mul(coord, stride_value) catch |err| return mapKernelBuildError(err);
        };
        source_index = builder.add(source_index, term) catch |err| return mapKernelBuildError(err);
    }
    return source_index;
}

fn resultStrideI64(result_shape: []const i64, dim_index: usize) common.LoweringError!i64 {
    var stride: i64 = 1;
    for (result_shape[dim_index + 1 ..]) |dim| {
        if (dim <= 0) return error.CapabilityMismatch;
        stride = std.math.mul(i64, stride, dim) catch return error.CapabilityMismatch;
    }
    return stride;
}

fn linearCoordinateFromShape(
    builder: anytype,
    linear_index: kernel_root.Value,
    shape: []const i64,
    dim_index: usize,
) common.LoweringError!kernel_root.Value {
    if (dim_index >= shape.len) return error.InvalidArtifact;
    const dim = shape[dim_index];
    if (dim <= 0) return error.CapabilityMismatch;
    const stride = try resultStrideI64(shape, dim_index);
    const quotient = if (stride == 1) linear_index else blk: {
        const stride_value = builder.constantIndex(
            stride,
        ) catch |err| return mapKernelBuildError(err);
        break :blk builder.div(linear_index, stride_value) catch |err| return mapKernelBuildError(
            err,
        );
    };
    const dim_value = builder.constantIndex(dim) catch |err| return mapKernelBuildError(err);
    const whole_dim_count = builder.div(quotient, dim_value) catch |err| return mapKernelBuildError(
        err,
    );
    const consumed = builder.mul(whole_dim_count, dim_value) catch |err| return mapKernelBuildError(
        err,
    );
    return builder.sub(quotient, consumed) catch |err| return mapKernelBuildError(err);
}

fn coordinateFromShape(
    builder: anytype,
    linear_index: kernel_root.Value,
    facts: IndexFacts,
    shape: []const i64,
    dim_index: usize,
) common.LoweringError!kernel_root.Value {
    if (facts.rank2) |rank2| {
        if (rank2.coordinate(shape, dim_index)) |coord| return coord;
    }
    return linearCoordinateFromShape(builder, linear_index, shape, dim_index);
}

fn validateBroadcastDims(
    broadcast_dims: []const i64,
    result_rank: usize,
) common.LoweringError!void {
    for (broadcast_dims, 0..) |dim, index| {
        const dim_index = std.math.cast(usize, dim) orelse return error.InvalidArtifact;
        if (dim_index >= result_rank) return error.InvalidArtifact;
        for (broadcast_dims[0..index]) |previous| {
            const previous_index = std.math.cast(usize, previous) orelse
                return error.InvalidArtifact;
            if (previous_index == dim_index) return error.InvalidArtifact;
        }
    }
}

fn sourceDimForOutputDim(
    broadcast_dims: []const i64,
    dim_index: usize,
) common.LoweringError!?usize {
    for (broadcast_dims, 0..) |output_dim, source_dim| {
        const output_dim_index = std.math.cast(usize, output_dim) orelse
            return error.InvalidArtifact;
        if (output_dim_index == dim_index) return source_dim;
    }
    return null;
}

fn elementwiseChainValue(
    operand: *ir.Value,
    ops: []const *ir.Operation,
    op_index: usize,
    op_results: []const kernel_root.Value,
) ?kernel_root.Value {
    const def_any = operand.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    for (ops[0..op_index], 0..) |op, index| {
        if (op == def_op) return op_results[index];
    }
    return null;
}

fn elementwiseOutputValue(
    work: schedule_planning.ScheduleWorkItem,
    ops: []const *ir.Operation,
    op_results: []const kernel_root.Value,
) ?kernel_root.Value {
    for (ops, 0..) |op, index| {
        if (op == work.root) return op_results[index];
    }
    if (op_results.len == 0) return null;
    return op_results[op_results.len - 1];
}

pub fn emitElementwiseValue(
    builder: anytype,
    kind: ElementwiseKernel,
    inputs: []const kernel_root.Value,
    work_dtype: gpu_abi.DType,
    op: *ir.Operation,
) !kernel_root.Value {
    return switch (kind) {
        .convert => try convertValue(builder, inputs[0], work_dtype),
        .compare => try builder.compare(try comparePredicate(op), inputs[0], inputs[1]),
        .select => try builder.select(inputs[0], inputs[1], inputs[2]),
        .add => try builder.add(inputs[0], inputs[1]),
        .sub => try builder.sub(inputs[0], inputs[1]),
        .mul => try builder.mul(inputs[0], inputs[1]),
        .div => try builder.div(inputs[0], inputs[1]),
        .min => try builder.min(inputs[0], inputs[1]),
        .max => try builder.max(inputs[0], inputs[1]),
        .neg => try builder.neg(inputs[0]),
        .abs => try builder.abs(inputs[0]),
        .sqrt => try builder.sqrt(inputs[0]),
        .exp => try builder.exp(inputs[0]),
        .log => try builder.log(inputs[0]),
        .tanh => try builder.tanh(inputs[0]),
        .sin => try builder.sin(inputs[0]),
        .cos => try builder.cos(inputs[0]),
        .tan => try builder.tan(inputs[0]),
        .floor => try builder.floor(inputs[0]),
        .round => try builder.round(inputs[0]),
        .trunc => try builder.trunc(inputs[0]),
        .pow => try builder.pow(inputs[0], inputs[1]),
        .atan2 => try builder.atan2(inputs[0], inputs[1]),
    };
}

fn comparePredicate(op: *ir.Operation) !kernel_root.Compare {
    const payload = try common.dialectAttrPayload(
        op,
        "compare_direction",
        dialect_mod.AccyDialect.CompareOp.dialectAttrName("compare_direction"),
    );
    if (std.mem.eql(u8, payload, "eq")) return .eq;
    if (std.mem.eql(u8, payload, "ne")) return .ne;
    if (std.mem.eql(u8, payload, "lt")) return .lt;
    if (std.mem.eql(u8, payload, "le")) return .le;
    if (std.mem.eql(u8, payload, "gt")) return .gt;
    if (std.mem.eql(u8, payload, "ge")) return .ge;
    return error.UnsupportedOperation;
}

fn convertValue(
    builder: anytype,
    value: kernel_root.Value,
    dtype: gpu_abi.DType,
) !kernel_root.Value {
    return switch (dtype) {
        .f32 => (try builder.castValue(value, .f32)).raw(),
        .i8 => (try builder.castValue(value, .i8)).raw(),
        .i16 => (try builder.castValue(value, .i16)).raw(),
        .i32 => (try builder.castValue(value, .i32)).raw(),
        .u8 => (try builder.castValue(value, .u8)).raw(),
        .u16 => (try builder.castValue(value, .u16)).raw(),
        .u32 => (try builder.castValue(value, .u32)).raw(),
        .i64 => (try builder.castValue(value, .i64)).raw(),
        .u64 => (try builder.castValue(value, .u64)).raw(),
        .f16 => (try builder.castValue(value, .f16)).raw(),
        .bf16 => (try builder.castValue(value, .bf16)).raw(),
        .f64 => (try builder.castValue(value, .f64)).raw(),
        else => error.CapabilityMismatch,
    };
}

pub fn kernelForOperation(op: *ir.Operation) ?ElementwiseKernel {
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ConvertOp.operation_name)) {
        return .convert;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.CompareOp.operation_name)) {
        return .compare;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.SelectOp.operation_name)) {
        return .select;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.AddOp.operation_name)) return .add;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.SubOp.operation_name)) return .sub;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.MulOp.operation_name)) return .mul;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.DivOp.operation_name)) return .div;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.MinOp.operation_name)) return .min;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.MaxOp.operation_name)) return .max;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.NegOp.operation_name)) return .neg;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.AbsOp.operation_name)) return .abs;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.SqrtOp.operation_name)) return .sqrt;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ExpOp.operation_name)) return .exp;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.LogOp.operation_name)) return .log;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.TanhOp.operation_name)) return .tanh;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.SinOp.operation_name)) return .sin;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.CosOp.operation_name)) return .cos;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.TanOp.operation_name)) return .tan;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.FloorOp.operation_name)) {
        return .floor;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.RoundOp.operation_name)) {
        return .round;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.TruncOp.operation_name)) {
        return .trunc;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.PowOp.operation_name)) return .pow;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.Atan2Op.operation_name)) {
        return .atan2;
    }
    return null;
}

pub fn expectedInputCount(kind: ElementwiseKernel) usize {
    return switch (kind) {
        .add, .sub, .mul, .div, .min, .max, .pow, .atan2, .compare => 2,
        .neg, .abs, .sqrt, .exp, .log, .tanh, .sin, .cos, .tan, .floor, .round, .trunc, .convert => 1,
        .select => 3,
    };
}

const testing = std.testing;
const semantic = @import("../../../choir/root.zig").semantic;

const OperandFixture = struct {
    module: *semantic.SemanticModule,
    root: *ir.Operation,
    inputs: [2]*ir.Value,
};

fn operandFixture(
    source: *semantic.Builder,
    depth: usize,
    shared: bool,
    gather: bool,
) !OperandFixture {
    const typ = try source.tensor(.f32, &.{4});
    const index_type = try source.tensor(.i32, &.{4});
    var function = try source.beginFunction("operand_walk", &.{ typ, typ, index_type }, &.{typ});
    const inputs = [2]*ir.Value{ function.parameter(0), function.parameter(1) };
    var value = inputs[0];
    if (gather) value = try function.gather(value, function.parameter(2), typ, 0);
    for (0..depth) |_| {
        value = if (shared) try function.add(value, value) else try function.neg(value);
    }
    value = try function.add(inputs[1], value);
    try function.return_(&.{value});
    try function.finish();
    return .{
        .module = try source.finish(),
        .root = @ptrCast(@alignCast(value.getDefiningOp().?)),
        .inputs = inputs,
    };
}

test "kernelization operand walk finds gathers beyond former depth and capacity limits" {
    for ([_]usize{ 0, 31, 32, 33, 127, 128, 129, 257 }) |depth| {
        for ([_]bool{ false, true }) |gather| {
            var source = try semantic.Builder.init(testing.allocator, .standard);
            defer source.deinit();
            const fixture = try operandFixture(&source, depth, false, gather);
            defer fixture.module.deinit();
            try testing.expectEqual(
                gather,
                try closureContainsGather(testing.allocator, &.{fixture.root}),
            );
        }
    }
}

test "kernelization operand walk expands shared definitions once" {
    for ([_]usize{ 0, 32, 129, 257 }) |depth| {
        var source = try semantic.Builder.init(testing.allocator, .standard);
        defer source.deinit();
        const fixture = try operandFixture(&source, depth, true, false);
        defer fixture.module.deinit();
        var walk = OperandWalk.init(testing.allocator);
        defer walk.deinit();
        try walk.expand(fixture.root);
        var edges: usize = 0;
        while (walk.next()) |value| {
            edges += 1;
            try testing.expect(edges <= 2 * (depth + 1));
            if (value.getDefiningOp()) |def| try walk.expand(@ptrCast(@alignCast(def)));
        }
        try testing.expectEqual(depth + 1, walk.expanded.count());
        try testing.expectEqual(2 * (depth + 1), edges);
        try testing.expectEqual(
            false,
            try closureContainsGather(testing.allocator, &.{fixture.root}),
        );
    }
}

fn inputFixture(inputs: [2]*ir.Value) !bufferization.BufferPlanAnalysis {
    var plan = bufferization.BufferPlanAnalysis.init(testing.allocator);
    errdefer plan.deinit();
    for (inputs, 0..) |value, index| {
        try plan.slots.append(testing.allocator, .{
            .id = index,
            .value = value,
            .producer = null,
            .function = null,
            .role = .{ .input = true },
            .dtype = .f32,
            .dims = &.{},
            .element_count = 4,
            .row_major_strides = null,
            .byte_size = 16,
        });
        try plan.value_to_slot.put(value, index);
    }
    return plan;
}

fn checkVectorInputWalk(allocator: std.mem.Allocator) !void {
    var source = try semantic.Builder.init(testing.allocator, .standard);
    defer source.deinit();
    const fixture = try operandFixture(&source, 40, true, false);
    defer fixture.module.deinit();
    var buffers = try inputFixture(fixture.inputs);
    defer buffers.deinit();
    var input_ids = [_]usize{ 0, 1 };
    const outline = kernelization_model.KernelOutline{
        .id = 0,
        .name = &.{},
        .kind = .elementwise,
        .work_item_id = 0,
        .root = fixture.root,
        .input_slot_ids = &input_ids,
        .output_slot_id = 2,
        .element_count = 4,
        .op_count = 1,
    };
    const inputs = try collectVectorInputs(allocator, &.{fixture.root}, outline, &buffers);
    defer allocator.free(inputs);
    try testing.expectEqual(@as(usize, 2), inputs.len);
    try testing.expect(inputs[0].value == fixture.inputs[1]);
    try testing.expectEqual(@as(usize, 1), inputs[0].input_index);
    try testing.expect(inputs[1].value == fixture.inputs[0]);
    try testing.expectEqual(@as(usize, 0), inputs[1].input_index);
}

test "kernelization operand walk collects ordered unique deep vector inputs with host OOM" {
    try testing.checkAllAllocationFailures(testing.allocator, checkVectorInputWalk, .{});
}

fn checkGatherWalkFailure(allocator: std.mem.Allocator, gather: bool) !void {
    var source = try semantic.Builder.init(testing.allocator, .standard);
    defer source.deinit();
    const fixture = try operandFixture(&source, 40, false, gather);
    defer fixture.module.deinit();
    try testing.expectEqual(gather, try closureContainsGather(allocator, &.{fixture.root}));
}

test "kernelization operand walk preserves gather discovery allocation failure" {
    for ([_]bool{ false, true }) |gather| {
        try testing.checkAllAllocationFailures(
            testing.allocator,
            checkGatherWalkFailure,
            .{gather},
        );
    }
}

test "kernelization operand walk fits graph derived reserved storage" {
    for ([_]usize{ 0, 32, 129, 257 }) |depth| {
        try checkOperandWalkStorage(depth);
    }
}

fn checkOperandWalkStorage(depth: usize) !void {
    const accounting = @import("choir").passes.pass.work;
    var source = try semantic.Builder.init(testing.allocator, .standard);
    defer source.deinit();
    const fixture = try operandFixture(&source, depth, true, false);
    defer fixture.module.deinit();
    const census = try accounting.Census.inspect(fixture.module.choir_module);
    const bound = try accounting.add(
        try accounting.hashMapGrowth(*ir.Operation, void, census.operations),
        try accounting.arrayListGrowth(*ir.Value, census.operands),
    );
    const bytes = try testing.allocator.alignedAlloc(u8, .@"64", @intCast(bound));
    defer testing.allocator.free(bytes);
    var backing = alloc_fixed.Tracked.init(bytes);
    var retained = alloc_fixed.Monotonic.init(backing.allocator(), bytes.len);
    var walk = OperandWalk.init(retained.allocator());
    defer walk.deinit();
    try walk.expand(fixture.root);
    var visits: usize = 0;
    while (walk.next()) |value| {
        visits += 1;
        try testing.expect(visits <= census.operands);
        if (value.getDefiningOp()) |def| try walk.expand(@ptrCast(@alignCast(def)));
    }
    try testing.expectEqual(2 * (depth + 1), visits);
    try testing.expect(walk.expanded.count() <= census.operations);
    const used = if (retained.current) |*current| alloc_fixed.used(current) else 0;
    try testing.expect(used <= bound);
    try testing.expect(!backing.exhausted);
}
