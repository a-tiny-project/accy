const std = @import("std");
const gpu_abi = @import("gpu_abi");
const generated_abi = @import("abi.zig");
const generated_builder = @import("builder.zig");
const common = @import("common.zig");
const elementwise = @import("elementwise.zig");
const generated_guard = @import("guard.zig");
const generated_name = @import("name.zig");
const generated_schedule = @import("schedule.zig");

const ir = common.ir;
const dialect_mod = common.dialect_mod;
const kernel_root = common.kernel_root;
const bufferization = common.bufferization;
const kernelization_model = @import("../model/root.zig");
const schedule_planning = common.schedule_planning;
const i64_attr_list_stack_capacity = common.i64_attr_list_stack_capacity;
const bufferSlotById = common.bufferSlotById;
const readI64ListAttrBounded = common.readI64ListAttrBounded;
const readIntegerAttr = common.readIntegerAttr;
const mapKernelBuildError = common.mapKernelBuildError;
const isName = common.isName;

const ShapeKernel = kernelization_model.ShapeKernel;
const LoweredKernel = kernelization_model.LoweredKernel;

pub fn lower(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) common.LoweringError!LoweredKernel {
    if (work.kind != .shape) return error.UnsupportedOperation;
    if (work.ops.len != 1) return error.UnsupportedOperation;
    const kind = kernelForOperation(work.ops[0]) orelse return error.UnsupportedOperation;
    const expected_inputs: usize = switch (kind) {
        .iota => 0,
        .broadcast_in_dim, .reshape, .transpose, .slice => 1,
        .pad, .gather => 2,
        .scatter => 3,
        .concatenate => work.ops[0].getNumOperands(),
    };
    if (outline.inputCount() != expected_inputs) return error.UnsupportedOperation;
    if (!executableShapeDType(work.dtype)) return error.CapabilityMismatch;

    const output_slot = bufferSlotById(buffer_plan, outline.output_slot_id) orelse
        return error.InvalidArtifact;
    if (output_slot.dtype != work.dtype or output_slot.element_count == null) {
        return error.CapabilityMismatch;
    }

    const input_slots = allocator.alloc(
        bufferization.BufferSlot,
        outline.inputCount(),
    ) catch return error.OutOfMemory;
    defer allocator.free(input_slots);
    for (outline.input_slot_ids, 0..) |slot_id, index| {
        const input_slot = bufferSlotById(buffer_plan, slot_id) orelse return error.InvalidArtifact;
        input_slots[index] = input_slot.*;
        const indices_input = (kind == .gather or kind == .scatter) and index == 1;
        const expected_dtype = if (indices_input) gpu_abi.DType.i32 else work.dtype;
        if (input_slot.dtype != expected_dtype or input_slot.element_count == null) {
            return error.CapabilityMismatch;
        }
    }

    switch (kind) {
        .iota => {},
        .reshape, .transpose => if (input_slots[0].element_count.? !=
            output_slot.element_count.?) return error.InvalidArtifact,
        .broadcast_in_dim, .slice => {},
        .pad => {
            if (input_slots[1].dims.len != 0) return error.CapabilityMismatch;
            if (input_slots[1].element_count.? != 1) return error.CapabilityMismatch;
        },
        .concatenate => try validateConcatenateSlots(work.ops[0], input_slots, output_slot.*),
        .gather => try validateGatherSlots(work.ops[0], input_slots, output_slot.*),
        .scatter => try validateScatterSlots(work.ops[0], input_slots, output_slot.*),
    }

    const entry_name = try generated_name.shape(allocator, kind, work.id);
    errdefer allocator.free(entry_name);

    var abi = switch (kind) {
        .gather => try generated_abi.gather(allocator, work.dtype),
        .scatter => try generated_abi.scatter(allocator, work.dtype),
        else => try generated_abi.flat(allocator, work.dtype, outline.inputCount()),
    };
    defer abi.deinit(allocator);

    const inputs = allocator.alloc(
        kernel_root.Value,
        outline.inputCount(),
    ) catch return error.OutOfMemory;
    defer allocator.free(inputs);

    return generated_builder.withLaunch(
        allocator,
        ir_ctx,
        work.id,
        entry_name,
        abi.params(),
        generated_schedule.flat(),
        .{
            .abi = abi,
            .kind = kind,
            .op = work.ops[0],
            .input_slots = input_slots,
            .output_slot = output_slot.*,
            .inputs = inputs,
        },
        emitShapeBody,
    );
}

fn executableShapeDType(dtype: gpu_abi.DType) bool {
    return switch (dtype) {
        .i1, .f32, .f64, .i8, .i16, .i32, .u8, .u16, .u32, .i64, .u64, .f16, .bf16, .key => true,
    };
}

fn emitShapeBody(logical: anytype, ctx: anytype) !void {
    for (ctx.inputs, 0..) |*input, index| {
        input.* = ctx.abi.input(logical, index);
    }
    const logical_index = try logical.index1D("i", ctx.output_slot.element_count.?);
    try generated_guard.countIndexDo(logical, logical_index, ctx.abi.count(logical), .{
        .kind = ctx.kind,
        .op = ctx.op,
        .input_slots = ctx.input_slots,
        .output_slot = ctx.output_slot,
        .inputs = ctx.inputs,
        .out = ctx.abi.output(logical),
    }, struct {
        fn emit(guarded: anytype, index: kernel_root.Index1D, body_ctx: anytype) !void {
            const value = try shapeKernelOutputValue(
                guarded,
                body_ctx.kind,
                index.index,
                body_ctx.op,
                body_ctx.input_slots,
                body_ctx.output_slot,
                body_ctx.inputs,
            );
            try guarded.storeIndex(value, body_ctx.out, index);
        }
    }.emit);
}

fn shapeKernelOutputValue(
    builder: anytype,
    kind: ShapeKernel,
    output_index: kernel_root.Value,
    op: *ir.Operation,
    input_slots: []const bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
    inputs: []const kernel_root.Value,
) common.LoweringError!kernel_root.Value {
    return switch (kind) {
        .broadcast_in_dim => {
            const input_index = try elementwise.broadcastInDimSourceIndex(
                builder,
                output_index,
                op,
                &input_slots[0],
            );
            return builder.loadIndex(inputs[0], input_index) catch |err|
                return mapKernelBuildError(err);
        },
        .iota => iotaOutputValue(builder, output_index, op, output_slot),
        .reshape, .transpose, .slice => {
            const input_index = try shapeKernelInputIndex(
                builder,
                kind,
                output_index,
                op,
                input_slots[0],
                output_slot,
            );
            return builder.loadIndex(inputs[0], input_index) catch |err| return mapKernelBuildError(
                err,
            );
        },
        .pad => {
            const mapping = try padSourceMapping(
                builder,
                output_index,
                op,
                input_slots[0],
                output_slot,
            );
            const zero = builder.constantIndex(0) catch |err| return mapKernelBuildError(err);
            const safe_input_index = builder.select(
                mapping.in_input,
                mapping.input_index,
                zero,
            ) catch |err| return mapKernelBuildError(err);
            const source_value = builder.loadIndex(
                inputs[0],
                safe_input_index,
            ) catch |err| return mapKernelBuildError(err);
            const padding_value = builder.loadIndex(
                inputs[1],
                zero,
            ) catch |err| return mapKernelBuildError(err);
            return builder.select(
                mapping.in_input,
                source_value,
                padding_value,
            ) catch |err| return mapKernelBuildError(err);
        },
        .concatenate => concatenateOutputValue(
            builder,
            output_index,
            op,
            input_slots,
            output_slot,
            inputs,
        ),
        .gather => {
            const source_index = try gatherSourceIndex(
                builder,
                output_index,
                op,
                input_slots[0],
                input_slots[1],
                inputs[1],
            );
            return builder.loadIndex(
                inputs[0],
                source_index,
            ) catch |err| return mapKernelBuildError(err);
        },
        .scatter => scatterOutputValue(builder, output_index, op, input_slots, inputs),
    };
}

fn scatterOutputValue(
    builder: anytype,
    output_index: kernel_root.Value,
    op: *ir.Operation,
    input_slots: []const bufferization.BufferSlot,
    inputs: []const kernel_root.Value,
) common.LoweringError!kernel_root.Value {
    const data_slot = input_slots[0];
    const indices_slot = input_slots[1];
    const axis = try axisForOperation(op, "axis", data_slot.dims.len);
    const axis_size = data_slot.dims[axis];
    if (axis_size <= 0) return error.CapabilityMismatch;
    const inner = try dimsProductI64(data_slot.dims[axis + 1 ..]);
    const update_count = indices_slot.dims[0];
    if (update_count <= 0) return error.CapabilityMismatch;
    const axis_block = std.math.mul(i64, axis_size, inner) catch return error.CapabilityMismatch;

    const inner_value = builder.constantIndex(inner) catch |err| return mapKernelBuildError(err);
    const axis_block_value = builder.constantIndex(
        axis_block,
    ) catch |err| return mapKernelBuildError(err);

    const outer_coord = builder.div(
        output_index,
        axis_block_value,
    ) catch |err| return mapKernelBuildError(err);
    const outer_consumed = builder.mul(
        outer_coord,
        axis_block_value,
    ) catch |err| return mapKernelBuildError(err);
    const axis_rem = builder.sub(
        output_index,
        outer_consumed,
    ) catch |err| return mapKernelBuildError(err);
    const axis_coord = builder.div(axis_rem, inner_value) catch |err| return mapKernelBuildError(
        err,
    );
    const axis_consumed = builder.mul(
        axis_coord,
        inner_value,
    ) catch |err| return mapKernelBuildError(err);
    const within = builder.sub(axis_rem, axis_consumed) catch |err| return mapKernelBuildError(err);

    const update_block = std.math.mul(
        i64,
        update_count,
        inner,
    ) catch return error.CapabilityMismatch;
    const update_block_value = builder.constantIndex(
        update_block,
    ) catch |err| return mapKernelBuildError(err);
    const update_base = builder.mul(
        outer_coord,
        update_block_value,
    ) catch |err| return mapKernelBuildError(err);

    const fold_lower = builder.constantIndex(0) catch |err| return mapKernelBuildError(err);
    const fold_upper = builder.constantIndex(
        update_count,
    ) catch |err| return mapKernelBuildError(err);
    const fold_step = builder.constantIndex(1) catch |err| return mapKernelBuildError(err);
    const initial = builder.loadIndex(
        inputs[0],
        output_index,
    ) catch |err| return mapKernelBuildError(err);

    return builder.fold(fold_lower, fold_upper, fold_step, initial, .{
        .axis_coord = axis_coord,
        .within = within,
        .update_base = update_base,
        .inner_value = inner_value,
        .indices = inputs[1],
        .updates = inputs[2],
    }, struct {
        fn apply(
            fold_inner: anytype,
            update_position: kernel_root.Value,
            current: kernel_root.Value,
            fold_ctx: anytype,
        ) !kernel_root.Value {
            const loaded = try fold_inner.loadIndex(fold_ctx.indices, update_position);
            const target = try fold_inner.castIndex(loaded);
            const match = try fold_inner.compare(.eq, target, fold_ctx.axis_coord);
            const update_row = try fold_inner.mul(update_position, fold_ctx.inner_value);
            const update_offset = try fold_inner.add(fold_ctx.update_base, update_row);
            const update_index = try fold_inner.add(update_offset, fold_ctx.within);
            const candidate = try fold_inner.loadIndex(fold_ctx.updates, update_index);
            return fold_inner.select(match, candidate, current);
        }
    }.apply) catch |err| return mapKernelBuildError(err);
}

fn validateScatterSlots(
    op: *ir.Operation,
    input_slots: []const bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
) common.LoweringError!void {
    const data_slot = input_slots[0];
    const indices_slot = input_slots[1];
    const updates_slot = input_slots[2];
    if (data_slot.dims.len == 0) return error.CapabilityMismatch;
    if (indices_slot.dims.len != 1) return error.CapabilityMismatch;
    const axis = try axisForOperation(op, "axis", data_slot.dims.len);
    if (!std.mem.eql(i64, output_slot.dims, data_slot.dims)) return error.InvalidArtifact;
    if (updates_slot.dims.len != data_slot.dims.len) return error.InvalidArtifact;
    if (!std.mem.eql(i64, updates_slot.dims[0..axis], data_slot.dims[0..axis])) {
        return error.InvalidArtifact;
    }
    if (updates_slot.dims[axis] != indices_slot.dims[0]) return error.InvalidArtifact;
    if (!std.mem.eql(i64, updates_slot.dims[axis + 1 ..], data_slot.dims[axis + 1 ..])) {
        return error.InvalidArtifact;
    }
}

fn gatherSourceIndex(
    builder: anytype,
    output_index: kernel_root.Value,
    op: *ir.Operation,
    data_slot: bufferization.BufferSlot,
    indices_slot: bufferization.BufferSlot,
    indices_buffer: kernel_root.Value,
) common.LoweringError!kernel_root.Value {
    const axis = try axisForOperation(op, "axis", data_slot.dims.len);
    const axis_size = data_slot.dims[axis];
    if (axis_size <= 0) return error.CapabilityMismatch;
    const inner = try dimsProductI64(data_slot.dims[axis + 1 ..]);
    const gathered = try dimsProductI64(indices_slot.dims);
    if (gathered <= 0) return error.CapabilityMismatch;
    const block = std.math.mul(i64, gathered, inner) catch return error.CapabilityMismatch;

    const inner_value = builder.constantIndex(inner) catch |err| return mapKernelBuildError(err);
    const block_value = builder.constantIndex(block) catch |err| return mapKernelBuildError(err);

    const outer_coord = builder.div(
        output_index,
        block_value,
    ) catch |err| return mapKernelBuildError(err);
    const outer_consumed = builder.mul(
        outer_coord,
        block_value,
    ) catch |err| return mapKernelBuildError(err);
    const block_rem = builder.sub(
        output_index,
        outer_consumed,
    ) catch |err| return mapKernelBuildError(err);
    const position = builder.div(block_rem, inner_value) catch |err| return mapKernelBuildError(
        err,
    );
    const position_consumed = builder.mul(
        position,
        inner_value,
    ) catch |err| return mapKernelBuildError(err);
    const within = builder.sub(block_rem, position_consumed) catch |err| return mapKernelBuildError(
        err,
    );

    const loaded = builder.loadIndex(
        indices_buffer,
        position,
    ) catch |err| return mapKernelBuildError(err);
    const zero_i32 = builder.constantInt(.i32, 0) catch |err| return mapKernelBuildError(err);
    const limit_value = @min(axis_size - 1, @as(i64, std.math.maxInt(i32)));
    const limit_i32 = builder.constantInt(.i32, limit_value) catch |err| return mapKernelBuildError(
        err,
    );
    const lower_clamped_i32 = builder.max(loaded, zero_i32) catch |err| return mapKernelBuildError(
        err,
    );
    const clamped_i32 = builder.min(
        lower_clamped_i32,
        limit_i32,
    ) catch |err| return mapKernelBuildError(err);
    const clamped = builder.castIndex(clamped_i32) catch |err| return mapKernelBuildError(err);

    const axis_stride = std.math.mul(i64, axis_size, inner) catch return error.CapabilityMismatch;
    const axis_stride_value = builder.constantIndex(
        axis_stride,
    ) catch |err| return mapKernelBuildError(err);
    const outer_offset = builder.mul(
        outer_coord,
        axis_stride_value,
    ) catch |err| return mapKernelBuildError(err);
    const gathered_offset = builder.mul(
        clamped,
        inner_value,
    ) catch |err| return mapKernelBuildError(err);
    const partial = builder.add(
        outer_offset,
        gathered_offset,
    ) catch |err| return mapKernelBuildError(err);
    return builder.add(partial, within) catch |err| return mapKernelBuildError(err);
}

fn validateGatherSlots(
    op: *ir.Operation,
    input_slots: []const bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
) common.LoweringError!void {
    const data_slot = input_slots[0];
    const indices_slot = input_slots[1];
    if (data_slot.dims.len == 0) return error.CapabilityMismatch;
    if (indices_slot.dims.len == 0) return error.CapabilityMismatch;
    const axis = try axisForOperation(op, "axis", data_slot.dims.len);
    if (output_slot.dims.len != data_slot.dims.len - 1 + indices_slot.dims.len) {
        return error.InvalidArtifact;
    }
    if (!std.mem.eql(i64, output_slot.dims[0..axis], data_slot.dims[0..axis])) {
        return error.InvalidArtifact;
    }
    if (!std.mem.eql(
        i64,
        output_slot.dims[axis .. axis + indices_slot.dims.len],
        indices_slot.dims,
    )) return error.InvalidArtifact;
    if (!std.mem.eql(
        i64,
        output_slot.dims[axis + indices_slot.dims.len ..],
        data_slot.dims[axis + 1 ..],
    )) return error.InvalidArtifact;
}

fn dimsProductI64(dims: []const i64) common.LoweringError!i64 {
    var product: i64 = 1;
    for (dims) |dim| {
        if (dim <= 0) return error.CapabilityMismatch;
        product = std.math.mul(i64, product, dim) catch return error.CapabilityMismatch;
    }
    return product;
}

fn shapeKernelInputIndex(
    builder: anytype,
    kind: ShapeKernel,
    output_index: kernel_root.Value,
    op: *ir.Operation,
    input_slot: bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
) common.LoweringError!kernel_root.Value {
    return switch (kind) {
        .reshape => output_index,
        .transpose => transposeSourceIndex(builder, output_index, op, input_slot, output_slot),
        .slice => sliceSourceIndex(builder, output_index, op, input_slot, output_slot),
        .broadcast_in_dim, .iota, .pad, .concatenate, .gather, .scatter => unreachable,
    };
}

fn validateConcatenateSlots(
    op: *ir.Operation,
    input_slots: []const bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
) common.LoweringError!void {
    if (input_slots.len == 0) return error.UnsupportedOperation;
    if (output_slot.row_major_strides == null) return error.CapabilityMismatch;
    const axis = try axisForOperation(op, "dimension", output_slot.dims.len);
    if (output_slot.dims[axis] <= 0) return error.CapabilityMismatch;

    var axis_total: i64 = 0;
    for (input_slots) |input_slot| {
        if (input_slot.dims.len != output_slot.dims.len) return error.InvalidArtifact;
        if (input_slot.row_major_strides == null) return error.CapabilityMismatch;
        if (input_slot.dims[axis] <= 0) return error.CapabilityMismatch;
        axis_total = std.math.add(
            i64,
            axis_total,
            input_slot.dims[axis],
        ) catch return error.CapabilityMismatch;
        for (input_slot.dims, 0..) |dim, dim_index| {
            if (dim_index == axis) continue;
            if (dim != output_slot.dims[dim_index]) return error.InvalidArtifact;
        }
    }
    if (axis_total != output_slot.dims[axis]) return error.InvalidArtifact;
}

fn iotaOutputValue(
    builder: anytype,
    output_index: kernel_root.Value,
    op: *ir.Operation,
    output_slot: bufferization.BufferSlot,
) common.LoweringError!kernel_root.Value {
    const axis = try axisForOperation(op, "iota_dimension", output_slot.dims.len);
    const coord = try linearCoordinate(builder, output_index, output_slot, axis);
    return builder.cast(coord, output_slot.dtype) catch |err| return mapKernelBuildError(err);
}

fn concatenateOutputValue(
    builder: anytype,
    output_index: kernel_root.Value,
    op: *ir.Operation,
    input_slots: []const bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
    inputs: []const kernel_root.Value,
) common.LoweringError!kernel_root.Value {
    if (input_slots.len == 0 or input_slots.len != inputs.len) return error.InvalidArtifact;
    const axis = try axisForOperation(op, "dimension", output_slot.dims.len);
    const axis_coord = try linearCoordinate(builder, output_index, output_slot, axis);
    const zero = builder.constantIndex(0) catch |err| return mapKernelBuildError(err);

    var axis_start: i64 = 0;
    var selected_value: ?kernel_root.Value = null;
    for (input_slots, inputs) |input_slot, input| {
        const axis_end = std.math.add(
            i64,
            axis_start,
            input_slot.dims[axis],
        ) catch return error.CapabilityMismatch;
        const start_value = builder.constantIndex(
            axis_start,
        ) catch |err| return mapKernelBuildError(err);
        const end_value = builder.constantIndex(
            axis_end,
        ) catch |err| return mapKernelBuildError(err);
        const at_or_after_start = builder.compare(
            .ge,
            axis_coord,
            start_value,
        ) catch |err| return mapKernelBuildError(err);
        const before_end = builder.compare(
            .lt,
            axis_coord,
            end_value,
        ) catch |err| return mapKernelBuildError(err);
        const in_segment = builder.and_(
            at_or_after_start,
            before_end,
        ) catch |err| return mapKernelBuildError(err);
        const source_index = try concatenateSourceIndex(
            builder,
            output_index,
            output_slot,
            input_slot,
            axis,
            axis_start,
        );
        const safe_source_index = builder.select(
            in_segment,
            source_index,
            zero,
        ) catch |err| return mapKernelBuildError(err);
        const input_value = builder.loadIndex(
            input,
            safe_source_index,
        ) catch |err| return mapKernelBuildError(err);
        selected_value = if (selected_value) |current|
            builder.select(in_segment, input_value, current) catch |err| return mapKernelBuildError(
                err,
            )
        else
            input_value;
        axis_start = axis_end;
    }
    return selected_value orelse error.InvalidArtifact;
}

fn concatenateSourceIndex(
    builder: anytype,
    output_index: kernel_root.Value,
    output_slot: bufferization.BufferSlot,
    input_slot: bufferization.BufferSlot,
    axis: usize,
    axis_start: i64,
) common.LoweringError!kernel_root.Value {
    const input_strides = input_slot.row_major_strides orelse return error.CapabilityMismatch;
    var source_index = builder.constantIndex(0) catch |err| return mapKernelBuildError(err);
    for (input_slot.dims, 0..) |_, dim_index| {
        var coord = try linearCoordinate(builder, output_index, output_slot, dim_index);
        if (dim_index == axis and axis_start != 0) {
            const start_value = builder.constantIndex(
                axis_start,
            ) catch |err| return mapKernelBuildError(err);
            coord = builder.sub(coord, start_value) catch |err| return mapKernelBuildError(err);
        }
        const stride = std.math.cast(i64, input_strides[dim_index]) orelse
            return error.CapabilityMismatch;
        const term = if (stride == 1) coord else blk: {
            const stride_value = builder.constantIndex(
                stride,
            ) catch |err| return mapKernelBuildError(err);
            break :blk builder.mul(coord, stride_value) catch |err| return mapKernelBuildError(err);
        };
        source_index = builder.add(source_index, term) catch |err| return mapKernelBuildError(err);
    }
    return source_index;
}

fn linearCoordinate(
    builder: anytype,
    linear_index: kernel_root.Value,
    slot: bufferization.BufferSlot,
    dim_index: usize,
) common.LoweringError!kernel_root.Value {
    const strides = slot.row_major_strides orelse return error.CapabilityMismatch;
    if (dim_index >= slot.dims.len or dim_index >= strides.len) return error.InvalidArtifact;
    const dim = slot.dims[dim_index];
    if (dim <= 0) return error.CapabilityMismatch;
    const stride = std.math.cast(i64, strides[dim_index]) orelse return error.CapabilityMismatch;
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

fn axisForOperation(
    op: *ir.Operation,
    attr_name: []const u8,
    rank: usize,
) common.LoweringError!usize {
    if (rank == 0) return error.CapabilityMismatch;
    const axis_value = try readIntegerAttr(op, attr_name);
    if (axis_value < 0) return error.InvalidArtifact;
    const axis = std.math.cast(usize, axis_value) orelse return error.InvalidArtifact;
    if (axis >= rank) return error.InvalidArtifact;
    return axis;
}

const PadSourceMapping = struct {
    in_input: kernel_root.Value,
    input_index: kernel_root.Value,
};

fn padSourceMapping(
    builder: anytype,
    output_index: kernel_root.Value,
    op: *ir.Operation,
    input_slot: bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
) common.LoweringError!PadSourceMapping {
    var low_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
    var high_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
    var interior_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
    const edge_low = try readI64ListAttrBounded(
        op,
        "edge_low",
        dialect_mod.AccyDialect.PadOp.dialectAttrName("edge_low"),
        &low_buffer,
    );
    const edge_high = try readI64ListAttrBounded(
        op,
        "edge_high",
        dialect_mod.AccyDialect.PadOp.dialectAttrName("edge_high"),
        &high_buffer,
    );
    const interior = try readI64ListAttrBounded(
        op,
        "interior",
        dialect_mod.AccyDialect.PadOp.dialectAttrName("interior"),
        &interior_buffer,
    );
    if (edge_low.len != input_slot.dims.len or
        edge_high.len != input_slot.dims.len or interior.len != input_slot.dims.len)
    {
        return error.InvalidArtifact;
    }
    if (output_slot.dims.len != input_slot.dims.len) return error.InvalidArtifact;
    const input_strides = input_slot.row_major_strides orelse return error.CapabilityMismatch;
    const output_strides = output_slot.row_major_strides orelse return error.CapabilityMismatch;
    if (input_strides.len != input_slot.dims.len or output_strides.len != output_slot.dims.len) {
        return error.InvalidArtifact;
    }

    var source_index = builder.constantIndex(0) catch |err| return mapKernelBuildError(err);
    var in_input = builder.constantBool(true) catch |err| return mapKernelBuildError(err);
    for (output_slot.dims, 0..) |dim, dim_index| {
        if (dim <= 0 or input_slot.dims[dim_index] <= 0) return error.CapabilityMismatch;
        const low = edge_low[dim_index];
        const high = edge_high[dim_index];
        const gap = interior[dim_index];
        if (gap != 0) return error.CapabilityMismatch;
        const expected_dim = low + input_slot.dims[dim_index] + high;
        if (dim != expected_dim) return error.InvalidArtifact;

        const coord = try linearCoordinate(builder, output_index, output_slot, dim_index);

        const low_value = builder.constantIndex(low) catch |err| return mapKernelBuildError(err);
        const upper_value = builder.constantIndex(low +
            input_slot.dims[dim_index]) catch |err| return mapKernelBuildError(err);
        const at_or_after_low = builder.compare(
            .ge,
            coord,
            low_value,
        ) catch |err| return mapKernelBuildError(err);
        const before_upper = builder.compare(
            .lt,
            coord,
            upper_value,
        ) catch |err| return mapKernelBuildError(err);
        const dim_in_input = builder.and_(
            at_or_after_low,
            before_upper,
        ) catch |err| return mapKernelBuildError(err);
        in_input = builder.and_(in_input, dim_in_input) catch |err| return mapKernelBuildError(err);

        const source_coord = if (low == 0)
            coord
        else
            builder.sub(coord, low_value) catch |err| return mapKernelBuildError(err);
        const input_stride = std.math.cast(i64, input_strides[dim_index]) orelse
            return error.CapabilityMismatch;
        const term = if (input_stride == 1) source_coord else blk: {
            const stride_value = builder.constantIndex(
                input_stride,
            ) catch |err| return mapKernelBuildError(err);
            break :blk builder.mul(
                source_coord,
                stride_value,
            ) catch |err| return mapKernelBuildError(err);
        };
        source_index = builder.add(source_index, term) catch |err| return mapKernelBuildError(err);
    }
    return .{
        .in_input = in_input,
        .input_index = source_index,
    };
}

fn transposeSourceIndex(
    builder: anytype,
    output_index: kernel_root.Value,
    op: *ir.Operation,
    input_slot: bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
) common.LoweringError!kernel_root.Value {
    var permutation_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
    const permutation = try readI64ListAttrBounded(
        op,
        "permutation",
        dialect_mod.AccyDialect.TransposeOp.dialectAttrName("permutation"),
        &permutation_buffer,
    );
    if (permutation.len != input_slot.dims.len or permutation.len != output_slot.dims.len) {
        return error.InvalidArtifact;
    }
    try validatePermutation(permutation);
    const input_strides = input_slot.row_major_strides orelse return error.CapabilityMismatch;
    const output_strides = output_slot.row_major_strides orelse return error.CapabilityMismatch;
    if (input_strides.len != input_slot.dims.len or output_strides.len != output_slot.dims.len) {
        return error.InvalidArtifact;
    }

    var source_index = builder.constantIndex(0) catch |err| return mapKernelBuildError(err);
    for (output_slot.dims, 0..) |dim, output_dim| {
        if (dim <= 0) return error.CapabilityMismatch;
        const coord = try linearCoordinate(builder, output_index, output_slot, output_dim);

        const input_dim = std.math.cast(usize, permutation[output_dim]) orelse
            return error.InvalidArtifact;
        if (input_slot.dims[input_dim] != dim) return error.InvalidArtifact;
        const input_stride = std.math.cast(i64, input_strides[input_dim]) orelse
            return error.CapabilityMismatch;
        const term = if (input_stride == 1) coord else blk: {
            const stride_value = builder.constantIndex(
                input_stride,
            ) catch |err| return mapKernelBuildError(err);
            break :blk builder.mul(coord, stride_value) catch |err| return mapKernelBuildError(err);
        };
        source_index = builder.add(source_index, term) catch |err| return mapKernelBuildError(err);
    }
    return source_index;
}

fn validatePermutation(permutation: []const i64) common.LoweringError!void {
    for (permutation, 0..) |dim, index| {
        const dim_index = std.math.cast(usize, dim) orelse return error.InvalidArtifact;
        if (dim_index >= permutation.len) return error.InvalidArtifact;
        for (permutation[0..index]) |previous| {
            const previous_index = std.math.cast(usize, previous) orelse
                return error.InvalidArtifact;
            if (previous_index == dim_index) return error.InvalidArtifact;
        }
    }
}

fn sliceSourceIndex(
    builder: anytype,
    output_index: kernel_root.Value,
    op: *ir.Operation,
    input_slot: bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
) common.LoweringError!kernel_root.Value {
    var starts_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
    var limits_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
    var strides_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
    const starts = try readI64ListAttrBounded(
        op,
        "starts",
        dialect_mod.AccyDialect.SliceOp.dialectAttrName("starts"),
        &starts_buffer,
    );
    const limits = try readI64ListAttrBounded(
        op,
        "limits",
        dialect_mod.AccyDialect.SliceOp.dialectAttrName("limits"),
        &limits_buffer,
    );
    const strides = try readI64ListAttrBounded(
        op,
        "strides",
        dialect_mod.AccyDialect.SliceOp.dialectAttrName("strides"),
        &strides_buffer,
    );
    if (starts.len != input_slot.dims.len or
        limits.len != input_slot.dims.len or strides.len != input_slot.dims.len)
    {
        return error.InvalidArtifact;
    }
    if (output_slot.dims.len != input_slot.dims.len) return error.InvalidArtifact;
    const input_strides = input_slot.row_major_strides orelse return error.CapabilityMismatch;
    const output_strides = output_slot.row_major_strides orelse return error.CapabilityMismatch;
    if (input_strides.len != input_slot.dims.len or output_strides.len != output_slot.dims.len) {
        return error.InvalidArtifact;
    }

    var source_index = builder.constantIndex(0) catch |err| return mapKernelBuildError(err);
    for (output_slot.dims, 0..) |dim, dim_index| {
        if (dim <= 0 or input_slot.dims[dim_index] <= 0) return error.CapabilityMismatch;
        const start = starts[dim_index];
        const limit = limits[dim_index];
        const stride = strides[dim_index];
        if (stride <= 0 or start < 0 or limit < start or limit > input_slot.dims[dim_index]) {
            return error.InvalidArtifact;
        }
        const span = limit - start;
        const expected_dim = @divTrunc(span + stride - 1, stride);
        if (dim != expected_dim) return error.InvalidArtifact;

        const coord = try linearCoordinate(builder, output_index, output_slot, dim_index);

        const stepped_coord = if (stride == 1) coord else blk: {
            const stride_value = builder.constantIndex(
                stride,
            ) catch |err| return mapKernelBuildError(err);
            break :blk builder.mul(coord, stride_value) catch |err| return mapKernelBuildError(err);
        };
        const source_coord = if (start == 0) stepped_coord else blk: {
            const start_value = builder.constantIndex(
                start,
            ) catch |err| return mapKernelBuildError(err);
            break :blk builder.add(
                start_value,
                stepped_coord,
            ) catch |err| return mapKernelBuildError(err);
        };
        const input_stride = std.math.cast(i64, input_strides[dim_index]) orelse
            return error.CapabilityMismatch;
        const term = if (input_stride == 1) source_coord else blk: {
            const stride_value = builder.constantIndex(
                input_stride,
            ) catch |err| return mapKernelBuildError(err);
            break :blk builder.mul(
                source_coord,
                stride_value,
            ) catch |err| return mapKernelBuildError(err);
        };
        source_index = builder.add(source_index, term) catch |err| return mapKernelBuildError(err);
    }
    return source_index;
}

pub fn kernelForOperation(op: *ir.Operation) ?ShapeKernel {
    if (isName(op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name)) {
        return .broadcast_in_dim;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.IotaOp.operation_name)) return .iota;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ReshapeOp.operation_name)) {
        return .reshape;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.TransposeOp.operation_name)) {
        return .transpose;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.SliceOp.operation_name)) {
        return .slice;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.PadOp.operation_name)) return .pad;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ConcatenateOp.operation_name)) {
        return .concatenate;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.GatherOp.operation_name)) {
        return .gather;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ScatterOp.operation_name)) {
        return .scatter;
    }
    return null;
}
