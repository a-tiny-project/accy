const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const alloc_fixed = @import("alloc_fixed");
const generated_abi = @import("abi.zig");
const generated_builder = @import("builder.zig");
const common = @import("common.zig");
const generated_elementwise = @import("elementwise.zig");
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
const constantPayloadForSlot = common.constantPayloadForSlot;
const externalInputIndex = common.externalInputIndex;
const staticPositiveDimU32 = common.staticPositiveDimU32;
const dialectAttrPayload = common.dialectAttrPayload;
const isName = common.isName;

const ReductionStaticDims = kernelization_model.ReductionStaticDims;
const ReductionKind = kernelization_model.ReductionKind;
const ReductionDescription = kernelization_model.ReductionDescription;
const ReductionInit = kernelization_model.ReductionInit;
const ReductionInitValue = kernelization_model.ReductionInitValue;
const LoweredKernel = kernelization_model.LoweredKernel;

pub fn reductionDescriptionForWork(
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) gpu.BackendError!ReductionDescription {
    if (work.kind != .reduction) return error.UnsupportedOperation;
    if (work.ops.len == 0) return error.UnsupportedOperation;
    const root = work.ops[work.ops.len - 1];
    if (isName(root.name.name, dialect_mod.AccyDialect.ConcatenateOp.operation_name)) {
        return concatReductionDescription(root, outline, work, buffer_plan);
    }
    const op = root;
    if (!isName(op.name.name, dialect_mod.AccyDialect.ReduceOp.operation_name)) {
        return error.UnsupportedOperation;
    }
    const operands = op.getOperandValues();
    if (operands.len != 2) return error.UnsupportedOperation;

    const fused = reductionWorkIsFused(work, buffer_plan);
    if (!fused) {
        const input_slot = buffer_plan.getSlot(operands[0]) orelse return error.InvalidArtifact;
        if (externalInputIndex(outline, input_slot.id) != 0) return error.UnsupportedOperation;
    }

    var input_arena_buffer: [256]u8 = undefined;
    var input_arena = alloc_fixed.FixedBuffer.init(input_arena_buffer[0..]);
    const input_type = dialect_mod.decodeTensorType(
        input_arena.allocator(),
        operands[0].type,
    ) catch return error.InvalidArtifact;

    const init_slot = buffer_plan.getSlot(operands[1]) orelse return error.InvalidArtifact;
    const output_slot = bufferSlotById(buffer_plan, outline.output_slot_id) orelse
        return error.InvalidArtifact;
    var axes_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
    const axes = try readI64ListAttrBounded(
        op,
        "dimensions",
        dialect_mod.AccyDialect.ReduceOp.dialectAttrName("dimensions"),
        &axes_buffer,
    );

    const dims = try reductionStaticDims(input_type.dims, output_slot.dims, axes);
    try validateReductionDTypes(input_type.dtype, output_slot.dtype, work);
    const kind = try reductionKindForOp(op);
    const init = try reductionInitValue(init_slot.*, input_type.dtype, outline);

    return .{
        .kind = kind,
        .input_dtype = input_type.dtype,
        .output_dtype = output_slot.dtype,
        .dims = dims,
        .init = init,
    };
}

pub fn reductionWorkIsFused(
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) bool {
    if (work.ops.len == 0) return false;
    if (isName(
        work.ops[work.ops.len - 1].name.name,
        dialect_mod.AccyDialect.ConcatenateOp.operation_name,
    )) return true;
    if (work.ops.len > 1) return true;
    const op = work.ops[work.ops.len - 1];
    const operands = op.getOperandValues();
    if (operands.len != 2) return false;
    if (buffer_plan.getSlot(operands[0]) == null) return true;
    const def_any = operands[0].getDefiningOp() orelse return false;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    return isName(def_op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name);
}

pub fn lower(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    format: ?gpu.ArtifactFormat,
) common.LoweringError!LoweredKernel {
    const desc = try reductionDescriptionForWork(outline, work, buffer_plan);

    if (reductionWorkIsFused(work, buffer_plan)) {
        return lowerFused(allocator, ir_ctx, outline, work, buffer_plan, desc, format);
    }

    const abi = generated_abi.reduction(
        desc.input_dtype,
        desc.output_dtype,
        desc.init == .input_buffer,
    );

    if (format == .cuda_ptx) if (kernelization_model.reductionAtomicPlanFor(
        desc.dims,
        desc.kind,
        desc.input_dtype,
        desc.init == .constant,
    )) |atomic_plan| {
        const entry_name = try generated_name.reductionAtomic(
            allocator,
            desc,
            atomic_plan,
            work.id,
        );
        errdefer allocator.free(entry_name);
        var lowered = try generated_builder.withoutLaunch(
            allocator,
            ir_ctx,
            work.id,
            entry_name,
            abi.params(),
            generated_schedule.flatThreads(atomic_plan.threads),
            .{
                .abi = abi,
                .kind = desc.kind,
                .dtype = desc.input_dtype,
                .dims = desc.dims,
                .plan = atomic_plan,
            },
            emitAtomicReductionBody,
        );
        lowered.output_fill_pattern = reductionInitFillPattern(desc.init) orelse
            return error.InvalidArtifact;
        lowered.body = .{ .reduction_atomic = atomic_plan };
        return lowered;
    };

    if (format == .cuda_ptx) if (kernelization_model.reductionSingleBlockThreads(
        desc.dims,
    )) |threads| {
        const entry_name = try generated_name.reductionSingleBlock(
            allocator,
            desc,
            threads,
            work.id,
        );
        errdefer allocator.free(entry_name);
        var lowered = try generated_builder.withoutLaunch(
            allocator,
            ir_ctx,
            work.id,
            entry_name,
            abi.params(),
            generated_schedule.flatThreads(threads),
            .{
                .abi = abi,
                .kind = desc.kind,
                .dtype = desc.input_dtype,
                .dims = desc.dims,
                .init = desc.init,
                .threads = threads,
            },
            emitSingleBlockReductionBody,
        );
        lowered.body = .{ .reduction_single_block = threads };
        return lowered;
    };

    if (format == .cuda_ptx and
        desc.init == .constant) if (kernelization_model.reductionWarpRowsThreads(desc.dims)) |_|
    {
        return lowerFused(allocator, ir_ctx, outline, work, buffer_plan, desc, format);
    };

    const entry_name = try generated_name.reduction(allocator, desc, work.id);
    errdefer allocator.free(entry_name);

    return generated_builder.withoutLaunch(
        allocator,
        ir_ctx,
        work.id,
        entry_name,
        abi.params(),
        generated_schedule.flat(),
        .{
            .abi = abi,
            .kind = desc.kind,
            .dtype = desc.input_dtype,
            .dims = desc.dims,
            .init = desc.init,
        },
        emitReductionBody,
    );
}

const max_prologue_depth = 32;

const max_concat_group = 8;

const ConcatMember = struct {
    reduce: *ir.Operation,
    input_value: *ir.Value,
    kind: ReductionKind,
    init: ReductionInit,
    dims: ReductionStaticDims,
    base: u32,
};

fn concatReductionMembers(
    root: *ir.Operation,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    buffer: []ConcatMember,
) gpu.BackendError![]ConcatMember {
    const operands = root.getOperandValues();
    if (operands.len < 2 or operands.len > buffer.len) return error.UnsupportedOperation;
    var base: u32 = 0;
    for (operands, 0..) |operand, index| {
        const def_any = operand.getDefiningOp() orelse return error.UnsupportedOperation;
        const reduce: *ir.Operation = @ptrCast(@alignCast(def_any));
        if (!isName(reduce.name.name, dialect_mod.AccyDialect.ReduceOp.operation_name)) {
            return error.UnsupportedOperation;
        }
        const reduce_operands = reduce.getOperandValues();
        if (reduce_operands.len != 2) return error.UnsupportedOperation;

        var input_arena_buffer: [256]u8 = undefined;
        var input_arena = alloc_fixed.FixedBuffer.init(input_arena_buffer[0..]);
        const input_type = dialect_mod.decodeTensorType(
            input_arena.allocator(),
            reduce_operands[0].type,
        ) catch return error.InvalidArtifact;
        var output_arena_buffer: [256]u8 = undefined;
        var output_arena = alloc_fixed.FixedBuffer.init(output_arena_buffer[0..]);
        const output_type = dialect_mod.decodeTensorType(
            output_arena.allocator(),
            operand.type,
        ) catch return error.InvalidArtifact;

        var axes_buffer: [i64_attr_list_stack_capacity]i64 = undefined;
        const axes = try readI64ListAttrBounded(
            reduce,
            "dimensions",
            dialect_mod.AccyDialect.ReduceOp.dialectAttrName("dimensions"),
            &axes_buffer,
        );
        const dims = try reductionStaticDims(input_type.dims, output_type.dims, axes);
        const init_slot = buffer_plan.getSlot(reduce_operands[1]) orelse
            return error.InvalidArtifact;
        const init = try reductionInitValue(init_slot.*, input_type.dtype, outline);
        if (init != .constant) return error.UnsupportedOperation;

        buffer[index] = .{
            .reduce = reduce,
            .input_value = reduce_operands[0],
            .kind = try reductionKindForOp(reduce),
            .init = init,
            .dims = dims,
            .base = base,
        };
        base = std.math.add(
            u32,
            base,
            dims.output_element_count,
        ) catch return error.CapabilityMismatch;
    }
    for (buffer[1..operands.len]) |member| {
        if (member.dims.output_element_count != buffer[0].dims.output_element_count) {
            return error.UnsupportedOperation;
        }
        if (member.dims.input_rank != buffer[0].dims.input_rank) return error.UnsupportedOperation;
        if (member.dims.axis != buffer[0].dims.axis) return error.UnsupportedOperation;
        if (member.dims.cols != buffer[0].dims.cols) return error.UnsupportedOperation;
    }
    return buffer[0..operands.len];
}

fn concatReductionDescription(
    root: *ir.Operation,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) gpu.BackendError!ReductionDescription {
    var member_buffer: [max_concat_group]ConcatMember = undefined;
    const members = try concatReductionMembers(root, outline, buffer_plan, member_buffer[0..]);
    const output_slot = bufferSlotById(buffer_plan, outline.output_slot_id) orelse
        return error.InvalidArtifact;
    const first = members[0];
    const group: u32 = @intCast(members.len);
    const total_outputs = std.math.mul(
        u32,
        first.dims.output_element_count,
        group,
    ) catch return error.CapabilityMismatch;
    const total_inputs = std.math.mul(
        u32,
        first.dims.input_element_count,
        group,
    ) catch return error.CapabilityMismatch;
    if (work.dtype != output_slot.dtype) return error.InvalidArtifact;

    return .{
        .kind = first.kind,
        .input_dtype = output_slot.dtype,
        .output_dtype = output_slot.dtype,
        .dims = .{
            .input_rank = first.dims.input_rank,
            .axis = first.dims.axis,
            .input_element_count = total_inputs,
            .output_element_count = total_outputs,
            .rows = total_outputs,
            .cols = first.dims.cols,
            .inner = first.dims.inner,
        },
        .init = first.init,
    };
}

fn lowerConcatWarpRows(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    desc: ReductionDescription,
    format: ?gpu.ArtifactFormat,
    root: *ir.Operation,
) common.LoweringError!LoweredKernel {
    var member_buffer: [max_concat_group]ConcatMember = undefined;
    const members = try concatReductionMembers(root, outline, buffer_plan, member_buffer[0..]);
    const rows = members[0].dims.output_element_count;

    const input_dtypes = allocator.alloc(
        gpu_abi.DType,
        outline.inputCount(),
    ) catch return error.OutOfMemory;
    defer allocator.free(input_dtypes);
    for (outline.input_slot_ids, 0..) |slot_id, index| {
        const slot = bufferSlotById(buffer_plan, slot_id) orelse return error.InvalidArtifact;
        input_dtypes[index] = slot.dtype;
    }

    var abi = try generated_abi.flatTyped(allocator, desc.output_dtype, input_dtypes);
    defer abi.deinit(allocator);

    const entry_name = try generated_name.reductionConcat(allocator, desc, members.len, work.id);
    errdefer allocator.free(entry_name);

    if (format == .cuda_ptx and
        kernelization_model.reductionWarpRowsThreads(members[0].dims) != null)
    {
        const threads = kernelization_model.reduction_warp_rows_threads;
        var lowered = try generated_builder.withoutLaunch(
            allocator,
            ir_ctx,
            work.id,
            entry_name,
            abi.params(),
            generated_schedule.flatThreads(threads),
            .{
                .abi = abi,
                .allocator = allocator,
                .dtype = desc.input_dtype,
                .members = members,
                .rows = rows,
                .outline = outline,
                .buffer_plan = buffer_plan,
            },
            emitConcatWarpRowsBody,
        );
        lowered.body = .{ .reduction_warp_rows = .{ .threads = threads, .rows = rows } };
        return lowered;
    }

    return generated_builder.withoutLaunch(
        allocator,
        ir_ctx,
        work.id,
        entry_name,
        abi.params(),
        generated_schedule.flat(),
        .{
            .abi = abi,
            .allocator = allocator,
            .dtype = desc.input_dtype,
            .members = members,
            .rows = rows,
            .outline = outline,
            .buffer_plan = buffer_plan,
        },
        emitConcatSerialBody,
    );
}

fn emit_concat_serial_index(
    guarded: anytype,
    index: kernel_root.Index1D,
    body_ctx: anytype,
) !void {
    const members = body_ctx.members;
    if (body_ctx.dtype == .f16) return error.UnsupportedOperation;
    const lower_bound = try guarded.constantIndex(0);
    const cols = try guarded.constantIndex(members[0].dims.cols);
    const step = try guarded.constantIndex(1);

    var init_args: [max_concat_group]kernel_root.Value = undefined;
    var result_types: [max_concat_group]kernel_root.Type = undefined;
    for (members, 0..) |member, member_index| {
        init_args[member_index] = try choirReductionInitial(guarded, member.init, null);
        result_types[member_index] = init_args[member_index].valueType();
    }

    var scope = try guarded.forScope(
        lower_bound,
        cols,
        step,
        init_args[0..members.len],
        result_types[0..members.len],
    );
    errdefer scope.abort();
    const reduce_index = scope.inductionVar();
    const input_index = try choirReductionInputIndex(
        guarded,
        members[0].dims,
        index.index,
        reduce_index,
    );

    var memo: ?generated_elementwise.ValueMemo = generated_elementwise.ValueMemo.init(
        body_ctx.allocator,
    );
    defer if (memo) |*existing| existing.deinit();
    var updated: [max_concat_group]kernel_root.Value = undefined;
    for (members, 0..) |member, member_index| {
        const value = try emitPrologueValue(
            guarded,
            &memo,
            input_index,
            member.input_value,
            body_ctx.outline,
            body_ctx.buffer_plan,
            body_ctx.abi,
            max_prologue_depth,
        );
        const current = scope.iterArg(member_index) orelse return error.UnsupportedOperation;
        updated[member_index] = try emitReductionValue(guarded, member.kind, current, value);
    }
    try scope.leave(updated[0..members.len]);

    for (members, 0..) |member, member_index| {
        const total = scope.result(member_index) orelse return error.UnsupportedOperation;
        const base = try guarded.constantIndex(member.base);
        const address = try guarded.add(base, index.index);
        try guarded.storeIndex(total, body_ctx.out, address);
    }
}

fn emitConcatSerialBody(logical: anytype, ctx: anytype) !void {
    const rows: u64 = ctx.rows;
    const domain = try logical.index1D("out", rows);
    try generated_guard.countIndexDo(logical, domain, ctx.abi.count(logical), .{
        .abi = ctx.abi,
        .allocator = ctx.allocator,
        .dtype = ctx.dtype,
        .members = ctx.members,
        .outline = ctx.outline,
        .buffer_plan = ctx.buffer_plan,
        .out = ctx.abi.output(logical),
    }, emit_concat_serial_index);
}

fn store_concat_warp_row(store_inner: anytype, store_ctx: anytype) !void {
    const initial = try choirReductionInitial(store_inner, store_ctx.member.init, null);
    const combined = try emitReductionValue(
        store_inner,
        store_ctx.member.kind,
        initial,
        store_ctx.total,
    );
    const base = try store_inner.constantIndex(store_ctx.member.base);
    const address = try store_inner.add(base, store_ctx.row);
    try store_inner.storeIndex(combined, store_ctx.out, address);
}

fn emit_concat_warp_row(inner: anytype, guard_ctx: anytype) !void {
    const members = guard_ctx.members;
    const cols = try inner.constantIndex(members[0].dims.cols);
    const step = try inner.constantIndex(32);
    const widen = guard_ctx.dtype == .f16;
    if (widen) return error.UnsupportedOperation;

    var init_args: [max_concat_group]kernel_root.Value = undefined;
    var result_types: [max_concat_group]kernel_root.Type = undefined;
    for (members, 0..) |member, index| {
        init_args[index] = try reductionNeutral(inner, member.kind, guard_ctx.dtype);
        result_types[index] = init_args[index].valueType();
    }

    var scope = try inner.forScope(
        guard_ctx.lane,
        cols,
        step,
        init_args[0..members.len],
        result_types[0..members.len],
    );
    errdefer scope.abort();
    const reduce_index = scope.inductionVar();
    const input_index = try choirReductionInputIndex(
        inner,
        members[0].dims,
        guard_ctx.row,
        reduce_index,
    );

    var memo: ?generated_elementwise.ValueMemo = generated_elementwise.ValueMemo.init(
        guard_ctx.allocator,
    );
    defer if (memo) |*existing| existing.deinit();
    var updated: [max_concat_group]kernel_root.Value = undefined;
    for (members, 0..) |member, index| {
        const value = try emitPrologueValue(
            inner,
            &memo,
            input_index,
            member.input_value,
            guard_ctx.outline,
            guard_ctx.buffer_plan,
            guard_ctx.abi,
            max_prologue_depth,
        );
        const current = scope.iterArg(index) orelse return error.UnsupportedOperation;
        updated[index] = try emitReductionValue(inner, member.kind, current, value);
    }
    try scope.leave(updated[0..members.len]);

    for (members, 0..) |member, index| {
        const partial = scope.result(index) orelse return error.UnsupportedOperation;
        const total = try inner.warpReduce(warpKindForReduction(member.kind), partial);
        const zero = try inner.constantIndex(0);
        const lane_zero = try inner.compare(.eq, guard_ctx.lane, zero);
        try inner.guardDo(lane_zero, .{
            .member = member,
            .row = guard_ctx.row,
            .out = guard_ctx.out,
            .total = total,
        }, store_concat_warp_row);
    }
}

fn emitConcatWarpRowsBody(logical: anytype, ctx: anytype) !void {
    const rows: u64 = ctx.rows;
    const domain = try logical.index1D("lane", rows * 32);
    const global = domain.index;
    const warp_size_extent = try logical.constantIndex(32);
    const row = try logical.div(global, warp_size_extent);
    const lane = try logical.sub(global, try logical.mul(row, warp_size_extent));
    const rows_extent = try logical.constantIndex(@intCast(rows));
    const row_ok = try logical.compare(.lt, row, rows_extent);
    try logical.guardDo(row_ok, .{
        .abi = ctx.abi,
        .allocator = ctx.allocator,
        .dtype = ctx.dtype,
        .members = ctx.members,
        .outline = ctx.outline,
        .buffer_plan = ctx.buffer_plan,
        .row = row,
        .lane = lane,
        .out = ctx.abi.output(logical),
    }, emit_concat_warp_row);
}

fn lowerFused(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    desc: ReductionDescription,
    format: ?gpu.ArtifactFormat,
) common.LoweringError!LoweredKernel {
    if (desc.init != .constant) return error.UnsupportedOperation;
    const root = work.ops[work.ops.len - 1];
    if (isName(root.name.name, dialect_mod.AccyDialect.ConcatenateOp.operation_name)) {
        return lowerConcatWarpRows(
            allocator,
            ir_ctx,
            outline,
            work,
            buffer_plan,
            desc,
            format,
            root,
        );
    }
    const reduce = root;
    const input_value = reduce.getOperand(0) orelse return error.InvalidArtifact;

    const input_dtypes = allocator.alloc(
        gpu_abi.DType,
        outline.inputCount(),
    ) catch return error.OutOfMemory;
    defer allocator.free(input_dtypes);
    for (outline.input_slot_ids, 0..) |slot_id, index| {
        const slot = bufferSlotById(buffer_plan, slot_id) orelse return error.InvalidArtifact;
        input_dtypes[index] = slot.dtype;
    }

    var abi = try generated_abi.flatTyped(allocator, desc.output_dtype, input_dtypes);
    defer abi.deinit(allocator);

    if (format == .cuda_ptx) if (kernelization_model.reductionWarpRowsThreads(
        desc.dims,
    )) |threads| {
        const entry_name = try generated_name.reductionWarpRows(
            allocator,
            desc,
            work.ops.len - 1,
            work.id,
        );
        errdefer allocator.free(entry_name);
        var lowered = try generated_builder.withoutLaunch(
            allocator,
            ir_ctx,
            work.id,
            entry_name,
            abi.params(),
            generated_schedule.flatThreads(threads),
            .{
                .abi = abi,
                .allocator = allocator,
                .kind = desc.kind,
                .dtype = desc.input_dtype,
                .dims = desc.dims,
                .init = desc.init,
                .input_value = input_value,
                .outline = outline,
                .buffer_plan = buffer_plan,
            },
            emitWarpRowsReductionBody,
        );
        lowered.body = .{
            .reduction_warp_rows = .{ .threads = threads, .rows = desc.dims.output_element_count },
        };
        return lowered;
    };

    const entry_name = try generated_name.reductionFused(
        allocator,
        desc,
        work.ops.len - 1,
        work.id,
    );
    errdefer allocator.free(entry_name);

    return generated_builder.withoutLaunch(
        allocator,
        ir_ctx,
        work.id,
        entry_name,
        abi.params(),
        generated_schedule.flat(),
        .{
            .abi = abi,
            .allocator = allocator,
            .kind = desc.kind,
            .dtype = desc.input_dtype,
            .dims = desc.dims,
            .init = desc.init,
            .input_value = input_value,
            .outline = outline,
            .buffer_plan = buffer_plan,
        },
        emitFusedReductionBody,
    );
}

pub fn warpKindForReduction(kind: ReductionKind) kernel_root.WarpOpKind {
    return switch (kind) {
        .sum => .add,
        .max => .max,
        .min => .min,
    };
}

fn reduce_warp_row(
    fold_inner: anytype,
    reduce_index: kernel_root.Value,
    current: kernel_root.Value,
    fold_ctx: anytype,
) !kernel_root.Value {
    const input_index = try choirReductionInputIndex(
        fold_inner,
        fold_ctx.dims,
        fold_ctx.row,
        reduce_index,
    );
    var memo: ?generated_elementwise.ValueMemo = generated_elementwise.ValueMemo.init(
        fold_ctx.allocator,
    );
    defer if (memo) |*existing| existing.deinit();
    var value = try emitPrologueValue(
        fold_inner,
        &memo,
        input_index,
        fold_ctx.input_value,
        fold_ctx.outline,
        fold_ctx.buffer_plan,
        fold_ctx.abi,
        max_prologue_depth,
    );
    if (fold_ctx.widen) value = try fold_inner.cast(value, .f32);
    return emitReductionValue(fold_inner, fold_ctx.kind, current, value);
}

fn store_warp_reduction_row(store_inner: anytype, store_ctx: anytype) !void {
    var initial = try choirReductionInitial(store_inner, store_ctx.init, null);
    if (store_ctx.widen) initial = try store_inner.cast(initial, .f32);
    var combined = try emitReductionValue(
        store_inner,
        store_ctx.kind,
        initial,
        store_ctx.total,
    );
    if (store_ctx.widen) combined = try store_inner.cast(combined, .f16);
    try store_inner.storeIndex(combined, store_ctx.out, store_ctx.row);
}

fn emit_warp_reduction_row(inner: anytype, guard_ctx: anytype) !void {
    const cols = try inner.constantIndex(guard_ctx.dims.cols);
    const step = try inner.constantIndex(32);
    const widen = guard_ctx.dtype == .f16;
    const neutral = try reductionNeutral(inner, guard_ctx.kind, guard_ctx.dtype);
    const partial = try inner.fold(guard_ctx.lane, cols, step, neutral, .{
        .abi = guard_ctx.abi,
        .allocator = guard_ctx.allocator,
        .kind = guard_ctx.kind,
        .dims = guard_ctx.dims,
        .input_value = guard_ctx.input_value,
        .outline = guard_ctx.outline,
        .buffer_plan = guard_ctx.buffer_plan,
        .row = guard_ctx.row,
        .widen = widen,
    }, reduce_warp_row);
    const total = try inner.warpReduce(warpKindForReduction(guard_ctx.kind), partial);
    const zero = try inner.constantIndex(0);
    const lane_zero = try inner.compare(.eq, guard_ctx.lane, zero);
    try inner.guardDo(lane_zero, .{
        .kind = guard_ctx.kind,
        .init = guard_ctx.init,
        .row = guard_ctx.row,
        .out = guard_ctx.out,
        .total = total,
        .widen = widen,
    }, store_warp_reduction_row);
}

fn emitWarpRowsReductionBody(logical: anytype, ctx: anytype) !void {
    const rows: u64 = ctx.dims.output_element_count;
    const domain = try logical.index1D("lane", rows * 32);
    const global = domain.index;
    const warp_size_extent = try logical.constantIndex(32);
    const row = try logical.div(global, warp_size_extent);
    const lane = try logical.sub(global, try logical.mul(row, warp_size_extent));
    const rows_extent = try logical.constantIndex(@intCast(rows));
    const row_ok = try logical.compare(.lt, row, rows_extent);
    try logical.guardDo(row_ok, .{
        .abi = ctx.abi,
        .allocator = ctx.allocator,
        .kind = ctx.kind,
        .dtype = ctx.dtype,
        .dims = ctx.dims,
        .init = ctx.init,
        .input_value = ctx.input_value,
        .outline = ctx.outline,
        .buffer_plan = ctx.buffer_plan,
        .row = row,
        .lane = lane,
        .out = ctx.abi.output(logical),
    }, emit_warp_reduction_row);
}

fn reduce_fused_reduction(
    fold_inner: anytype,
    reduce_index: kernel_root.Value,
    current: kernel_root.Value,
    fold_ctx: anytype,
) !kernel_root.Value {
    const input_index = try choirReductionInputIndex(
        fold_inner,
        fold_ctx.dims,
        fold_ctx.output_index,
        reduce_index,
    );
    var memo: ?generated_elementwise.ValueMemo = generated_elementwise.ValueMemo.init(
        fold_ctx.allocator,
    );
    defer if (memo) |*existing| existing.deinit();
    var value = try emitPrologueValue(
        fold_inner,
        &memo,
        input_index,
        fold_ctx.input_value,
        fold_ctx.outline,
        fold_ctx.buffer_plan,
        fold_ctx.abi,
        max_prologue_depth,
    );
    if (fold_ctx.widen) value = try fold_inner.cast(value, .f32);
    return emitReductionValue(fold_inner, fold_ctx.kind, current, value);
}

fn emit_fused_reduction_index(
    guarded: anytype,
    index: kernel_root.Index1D,
    body_ctx: anytype,
) !void {
    const lower_bound = try guarded.constantIndex(0);
    const upper = try choirReductionUpperBound(guarded, body_ctx.dims);
    const step = try guarded.constantIndex(1);
    const widen = body_ctx.dtype == .f16;
    var initial = try choirReductionInitial(guarded, body_ctx.init, null);
    if (widen) initial = try guarded.cast(initial, .f32);
    const result = try guarded.fold(lower_bound, upper, step, initial, .{
        .abi = body_ctx.abi,
        .allocator = body_ctx.allocator,
        .kind = body_ctx.kind,
        .dims = body_ctx.dims,
        .input_value = body_ctx.input_value,
        .outline = body_ctx.outline,
        .buffer_plan = body_ctx.buffer_plan,
        .output_index = index.index,
        .widen = widen,
    }, reduce_fused_reduction);
    const stored = if (widen) try guarded.cast(result, .f16) else result;
    try guarded.storeIndex(stored, body_ctx.out, index);
}

fn emitFusedReductionBody(logical: anytype, ctx: anytype) !void {
    const output_index = try logical.index1D("out", ctx.dims.output_element_count);
    try generated_guard.countIndexDo(logical, output_index, ctx.abi.count(logical), .{
        .abi = ctx.abi,
        .allocator = ctx.allocator,
        .kind = ctx.kind,
        .dtype = ctx.dtype,
        .dims = ctx.dims,
        .init = ctx.init,
        .input_value = ctx.input_value,
        .outline = ctx.outline,
        .buffer_plan = ctx.buffer_plan,
        .out = ctx.abi.output(logical),
    }, emit_fused_reduction_index);
}

fn emitPrologueValue(
    builder: anytype,
    memo: *?generated_elementwise.ValueMemo,
    index: kernel_root.Value,
    value: *ir.Value,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    abi: anytype,
    depth: usize,
) common.LoweringError!kernel_root.Value {
    return generated_elementwise.evaluateValueAtIndex(
        builder,
        memo,
        index,
        value,
        outline,
        buffer_plan,
        abi,
        depth,
    );
}

fn reductionInitFillPattern(init: ReductionInit) ?u32 {
    return switch (init) {
        .constant => |value| switch (value) {
            .f32 => |scalar| @bitCast(scalar),
            .i32 => |scalar| @bitCast(scalar),
            .u32 => |scalar| scalar,
            .f16 => null,
        },
        .input_buffer => null,
    };
}

fn reduce_atomic_input(
    fold_inner: anytype,
    reduce_index: kernel_root.Value,
    current: kernel_root.Value,
    fold_ctx: anytype,
) !kernel_root.Value {
    const value = try fold_inner.loadIndex(fold_ctx.input, reduce_index);
    return emitReductionValue(fold_inner, fold_ctx.kind, current, value);
}

fn combine_atomic_shared_reduction(inner: anytype, guard_ctx: anytype) !void {
    const left = try inner.loadIndex(guard_ctx.shared, guard_ctx.tid);
    const right_index = try inner.add(guard_ctx.tid, guard_ctx.offset_extent);
    const right = try inner.loadIndex(guard_ctx.shared, right_index);
    const combined = try emitReductionValue(inner, guard_ctx.kind, left, right);
    try inner.storeIndex(combined, guard_ctx.shared, guard_ctx.tid);
}

fn finish_atomic_reduction(inner: anytype, guard_ctx: anytype) !void {
    const zero_index = try inner.constantIndex(0);
    const block_total = try inner.loadIndex(guard_ctx.shared, zero_index);
    _ = try inner.atomicRmw(.add, block_total, guard_ctx.out, zero_index);
}

fn emitAtomicReductionBody(logical: anytype, ctx: anytype) !void {
    const plan: kernelization_model.ReductionAtomicPlan = ctx.plan;

    const out = ctx.abi.output(logical);
    const input = ctx.abi.input(logical);

    const domain = try logical.index1D("t", plan.stride());
    const global = domain.index;
    const tid = try logical.threadId(.x);
    const stride = try logical.constantIndex(@intCast(plan.stride()));

    const neutral = try reductionNeutral(logical, ctx.kind, ctx.dtype);
    const partial = if (vectorizedReductionQuads(
        ctx.dtype,
        ctx.dims.input_element_count,
    )) |quads| blk: {
        const quad_extent = try logical.constantIndex(quads);
        break :blk try logical.fold(global, quad_extent, stride, neutral, .{
            .kind = ctx.kind,
            .input = input,
        }, emitQuadReductionStep);
    } else blk: {
        const extent = try logical.constantIndex(ctx.dims.input_element_count);
        break :blk try logical.fold(global, extent, stride, neutral, .{
            .kind = ctx.kind,
            .input = input,
        }, reduce_atomic_input);
    };

    const shared = try logical.sharedBuffer(ctx.dtype, plan.threads);
    try logical.storeIndex(partial, shared, tid);
    try logical.barrier(.block);

    var offset: u32 = plan.threads / 2;
    while (offset > 0) : (offset /= 2) {
        const offset_extent = try logical.constantIndex(offset);
        const in_half = try logical.compare(.lt, tid, offset_extent);
        try logical.guardDo(in_half, .{
            .kind = ctx.kind,
            .shared = shared,
            .tid = tid,
            .offset_extent = offset_extent,
        }, combine_atomic_shared_reduction);
        try logical.barrier(.block);
    }

    const zero = try logical.constantIndex(0);
    const is_leader = try logical.compare(.eq, tid, zero);
    try logical.guardDo(is_leader, .{
        .shared = shared,
        .out = out,
    }, finish_atomic_reduction);
}

fn vectorizedReductionQuads(dtype: gpu_abi.DType, element_count: u32) ?i64 {
    if (dtype != .f32) return null;
    if (element_count % 4 != 0) return null;
    return @intCast(element_count / 4);
}

fn emitQuadReductionStep(
    fold_inner: anytype,
    quad_index: kernel_root.Value,
    current: kernel_root.Value,
    fold_ctx: anytype,
) !kernel_root.Value {
    const four = try fold_inner.constantIndex(4);
    const loaded = try fold_inner.loadVector(
        fold_ctx.input,
        try fold_inner.mul(quad_index, four),
        4,
    );
    var lanes: [4]kernel_root.Value = undefined;
    for (0..4) |lane| {
        lanes[lane] = try fold_inner.extractLane(loaded, @intCast(lane), .f32);
    }
    const low = try emitReductionValue(fold_inner, fold_ctx.kind, lanes[0], lanes[1]);
    const high = try emitReductionValue(fold_inner, fold_ctx.kind, lanes[2], lanes[3]);
    const combined = try emitReductionValue(fold_inner, fold_ctx.kind, low, high);
    return emitReductionValue(fold_inner, fold_ctx.kind, current, combined);
}

pub fn reductionNeutral(
    builder: anytype,
    kind: ReductionKind,
    dtype: gpu_abi.DType,
) !kernel_root.Value {
    const wide = if (dtype == .f16) gpu_abi.DType.f32 else dtype;
    return switch (wide) {
        .f32 => switch (kind) {
            .sum => builder.constantFloat(.f32, 0.0),
            .max => builder.constantFloat(.f32, -std.math.inf(f64)),
            .min => builder.constantFloat(.f32, std.math.inf(f64)),
        },
        .i32 => switch (kind) {
            .sum => builder.constantInt(.i32, 0),
            .max => builder.constantInt(.i32, std.math.minInt(i32)),
            .min => builder.constantInt(.i32, std.math.maxInt(i32)),
        },
        .u32 => switch (kind) {
            .sum => builder.constantInt(.u32, 0),
            .max => builder.constantInt(.u32, 0),
            .min => builder.constantInt(.u32, std.math.maxInt(u32)),
        },
        else => error.CapabilityMismatch,
    };
}

fn reduce_single_block_input(
    fold_inner: anytype,
    reduce_index: kernel_root.Value,
    current: kernel_root.Value,
    fold_ctx: anytype,
) !kernel_root.Value {
    var value = try fold_inner.loadIndex(fold_ctx.input, reduce_index);
    if (fold_ctx.widen) value = try fold_inner.cast(value, .f32);
    return emitReductionValue(fold_inner, fold_ctx.kind, current, value);
}

fn combine_single_block_shared_reduction(inner: anytype, guard_ctx: anytype) !void {
    const left = try inner.loadIndex(guard_ctx.shared, guard_ctx.tid);
    const right_index = try inner.add(guard_ctx.tid, guard_ctx.offset_extent);
    const right = try inner.loadIndex(guard_ctx.shared, right_index);
    const combined = try emitReductionValue(inner, guard_ctx.kind, left, right);
    try inner.storeIndex(combined, guard_ctx.shared, guard_ctx.tid);
}

fn finish_single_block_reduction(inner: anytype, guard_ctx: anytype) !void {
    const zero_index = try inner.constantIndex(0);
    const total = try inner.loadIndex(guard_ctx.shared, zero_index);
    var initial = try choirReductionInitial(inner, guard_ctx.init, guard_ctx.init_buffer);
    if (guard_ctx.widen) initial = try inner.cast(initial, .f32);
    const combined = try emitReductionValue(inner, guard_ctx.kind, total, initial);
    const stored = if (guard_ctx.widen) try inner.cast(combined, .f16) else combined;
    try inner.storeIndex(stored, guard_ctx.out, zero_index);
}

fn emitSingleBlockReductionBody(logical: anytype, ctx: anytype) !void {
    const threads: u32 = ctx.threads;
    const widen = ctx.dtype == .f16;
    const shared_dtype: gpu_abi.DType = if (widen) .f32 else ctx.dtype;

    const out = ctx.abi.output(logical);
    const input = ctx.abi.input(logical);
    const init_buffer: ?kernel_root.Value = if (ctx.init == .input_buffer)
        ctx.abi.init(logical)
    else
        null;

    const domain = try logical.index1D("t", threads);
    const tid = domain.index;
    const stride = try logical.constantIndex(threads);

    const neutral = try reductionNeutral(logical, ctx.kind, ctx.dtype);
    const partial = if (vectorizedReductionQuads(
        ctx.dtype,
        ctx.dims.input_element_count,
    )) |quads| blk: {
        const quad_extent = try logical.constantIndex(quads);
        break :blk try logical.fold(tid, quad_extent, stride, neutral, .{
            .kind = ctx.kind,
            .input = input,
        }, emitQuadReductionStep);
    } else blk: {
        const extent = try logical.constantIndex(ctx.dims.input_element_count);
        break :blk try logical.fold(tid, extent, stride, neutral, .{
            .kind = ctx.kind,
            .input = input,
            .widen = widen,
        }, reduce_single_block_input);
    };

    const shared = try logical.sharedBuffer(shared_dtype, threads);
    try logical.storeIndex(partial, shared, tid);
    try logical.barrier(.block);

    var offset: u32 = threads / 2;
    while (offset > 0) : (offset /= 2) {
        const offset_extent = try logical.constantIndex(offset);
        const in_half = try logical.compare(.lt, tid, offset_extent);
        try logical.guardDo(in_half, .{
            .kind = ctx.kind,
            .shared = shared,
            .tid = tid,
            .offset_extent = offset_extent,
        }, combine_single_block_shared_reduction);
        try logical.barrier(.block);
    }

    const zero = try logical.constantIndex(0);
    const is_leader = try logical.compare(.eq, tid, zero);
    try logical.guardDo(is_leader, .{
        .kind = ctx.kind,
        .init = ctx.init,
        .init_buffer = init_buffer,
        .shared = shared,
        .out = out,
        .widen = widen,
    }, finish_single_block_reduction);
}

fn reduce_reduction_input(
    fold_inner: anytype,
    reduce_index: kernel_root.Value,
    current: kernel_root.Value,
    fold_ctx: anytype,
) !kernel_root.Value {
    const input_index = try choirReductionInputIndex(
        fold_inner,
        fold_ctx.dims,
        fold_ctx.output_index,
        reduce_index,
    );
    var value = try fold_inner.loadIndex(fold_ctx.input, input_index);
    if (fold_ctx.widen) value = try fold_inner.cast(value, .f32);
    return emitReductionValue(fold_inner, fold_ctx.kind, current, value);
}

fn emit_reduction_index(
    guarded: anytype,
    index: kernel_root.Index1D,
    body_ctx: anytype,
) !void {
    const lower_bound = try guarded.constantIndex(0);
    const upper = try choirReductionUpperBound(guarded, body_ctx.dims);
    const step = try guarded.constantIndex(1);
    const widen = body_ctx.dtype == .f16;
    var initial = try choirReductionInitial(guarded, body_ctx.init, body_ctx.init_buffer);
    if (widen) initial = try guarded.cast(initial, .f32);
    const result = try guarded.fold(lower_bound, upper, step, initial, .{
        .kind = body_ctx.kind,
        .dims = body_ctx.dims,
        .input = body_ctx.input,
        .output_index = index.index,
        .widen = widen,
    }, reduce_reduction_input);
    const stored = if (widen) try guarded.cast(result, .f16) else result;
    try guarded.storeIndex(stored, body_ctx.out, index);
}

fn emitReductionBody(logical: anytype, ctx: anytype) !void {
    const output_index = try logical.index1D("out", ctx.dims.output_element_count);
    try generated_guard.countIndexDo(logical, output_index, ctx.abi.count(logical), .{
        .kind = ctx.kind,
        .dtype = ctx.dtype,
        .dims = ctx.dims,
        .init = ctx.init,
        .out = ctx.abi.output(logical),
        .input = ctx.abi.input(logical),
        .init_buffer = if (ctx.init == .input_buffer) ctx.abi.init(logical) else null,
    }, emit_reduction_index);
}

fn choirReductionUpperBound(
    builder: anytype,
    dims: ReductionStaticDims,
) !kernel_root.Value {
    const bound: i64 = switch (dims.input_rank) {
        1 => dims.input_element_count,
        2 => if (dims.axis == 0) dims.rows else dims.cols,
        3 => dims.cols,
        else => return error.InvalidArtifact,
    };
    return builder.constantIndex(bound);
}

fn choirReductionInputIndex(
    builder: anytype,
    dims: ReductionStaticDims,
    output_index: kernel_root.Value,
    reduce_index: kernel_root.Value,
) !kernel_root.Value {
    switch (dims.input_rank) {
        1 => return reduce_index,
        2 => {
            const cols = try builder.constantIndex(dims.cols);
            if (dims.axis == 0) {
                const offset = try builder.mul(reduce_index, cols);
                return builder.add(offset, output_index);
            }
            const row_offset = try builder.mul(output_index, cols);
            return builder.add(row_offset, reduce_index);
        },
        3 => {
            const inner = try builder.constantIndex(dims.inner);
            const outer_coord = try builder.div(output_index, inner);
            const consumed = try builder.mul(outer_coord, inner);
            const within = try builder.sub(output_index, consumed);
            const block_stride = try builder.constantIndex(
                @as(i64, dims.cols) * @as(i64, dims.inner),
            );
            const outer_offset = try builder.mul(outer_coord, block_stride);
            const reduce_offset = try builder.mul(reduce_index, inner);
            const offset = try builder.add(outer_offset, reduce_offset);
            return builder.add(offset, within);
        },
        else => return error.InvalidArtifact,
    }
}

fn choirReductionInitial(
    builder: anytype,
    init: ReductionInit,
    init_buffer: ?kernel_root.Value,
) !kernel_root.Value {
    return switch (init) {
        .constant => |value| choirReductionConstantInitial(builder, value),
        .input_buffer => builder.loadIndex(
            init_buffer orelse return error.InvalidArtifact,
            try builder.constantIndex(0),
        ),
    };
}

fn choirReductionConstantInitial(builder: anytype, value: ReductionInitValue) !kernel_root.Value {
    return switch (value) {
        .f32 => |scalar| builder.constantFloat(.f32, scalar),
        .i32 => |scalar| builder.constantInt(.i32, scalar),
        .u32 => |scalar| builder.constantInt(.u32, scalar),
        .f16 => |scalar| builder.constantFloat(.f16, @floatCast(scalar)),
    };
}

pub fn emitReductionValue(
    builder: anytype,
    kind: ReductionKind,
    current: kernel_root.Value,
    value: kernel_root.Value,
) !kernel_root.Value {
    return switch (kind) {
        .sum => builder.add(current, value),
        .max => builder.max(current, value),
        .min => builder.min(current, value),
    };
}

fn reductionStaticDims(
    input_dims: []const i64,
    output_dims: []const i64,
    axes: []const i64,
) gpu.BackendError!ReductionStaticDims {
    if (input_dims.len == 0) return error.CapabilityMismatch;
    if (try axesCoverInputRank(input_dims.len, axes)) {
        if (output_dims.len != 0) return error.InvalidArtifact;
        var input_element_count: u64 = 1;
        for (input_dims) |dim| {
            input_element_count *= try staticPositiveDimU32(dim);
        }
        const bounded = std.math.cast(u32, input_element_count) orelse
            return error.CapabilityMismatch;
        return .{
            .input_rank = 1,
            .axis = 0,
            .input_element_count = bounded,
            .output_element_count = 1,
            .rows = bounded,
            .cols = 1,
        };
    }
    return boundaryReductionStaticDims(input_dims, output_dims, axes);
}

fn boundaryReductionStaticDims(
    input_dims: []const i64,
    output_dims: []const i64,
    axes: []const i64,
) gpu.BackendError!ReductionStaticDims {
    if (axes.len == 0) return error.CapabilityMismatch;
    if (input_dims.len > i64_attr_list_stack_capacity) return error.CapabilityMismatch;

    var reduced_buffer = @as([i64_attr_list_stack_capacity]bool, @splat(false));
    const reduced = reduced_buffer[0..input_dims.len];
    try markReductionAxes(input_dims.len, axes, reduced);

    if (output_dims.len + axes.len != input_dims.len) return error.InvalidArtifact;

    if (axesCoverSuffix(reduced, output_dims.len)) {
        if (!std.mem.eql(i64, input_dims[0..output_dims.len], output_dims)) {
            return error.InvalidArtifact;
        }
        return flattenedBoundaryReductionDims(input_dims, output_dims, 1);
    }

    if (axesCoverPrefix(reduced, axes.len)) {
        if (!std.mem.eql(i64, input_dims[axes.len..], output_dims)) return error.InvalidArtifact;
        return flattenedBoundaryReductionDims(input_dims, output_dims, 0);
    }

    return interiorReductionStaticDims(input_dims, output_dims, reduced);
}

fn interiorReductionStaticDims(
    input_dims: []const i64,
    output_dims: []const i64,
    reduced: []const bool,
) gpu.BackendError!ReductionStaticDims {
    const block = contiguousReducedBlock(reduced) orelse return error.CapabilityMismatch;
    const trailing_start = block.last + 1;
    if (!std.mem.eql(i64, input_dims[0..block.first], output_dims[0..block.first])) {
        return error.InvalidArtifact;
    }
    if (!std.mem.eql(i64, input_dims[trailing_start..], output_dims[block.first..])) {
        return error.InvalidArtifact;
    }

    const input_element_count = try staticDimProductU32(input_dims);
    const output_element_count = try staticDimProductU32(output_dims);
    const extent = try staticDimProductU32(input_dims[block.first..trailing_start]);
    const inner = try staticDimProductU32(input_dims[trailing_start..]);
    const outer = output_element_count / inner;
    if (outer * inner != output_element_count) return error.InvalidArtifact;
    if (outer * extent * inner != input_element_count) return error.InvalidArtifact;

    return .{
        .input_rank = 3,
        .axis = 1,
        .input_element_count = input_element_count,
        .output_element_count = output_element_count,
        .rows = outer,
        .cols = extent,
        .inner = inner,
    };
}

fn contiguousReducedBlock(reduced: []const bool) ?struct { first: usize, last: usize } {
    var first: ?usize = null;
    var last: usize = 0;
    for (reduced, 0..) |flag, index| {
        if (!flag) continue;
        if (first == null) first = index;
        last = index;
    }
    const start = first orelse return null;
    for (reduced[start .. last + 1]) |flag| {
        if (!flag) return null;
    }
    return .{ .first = start, .last = last };
}

fn staticDimProductU32(dims: []const i64) gpu.BackendError!u32 {
    var product: u32 = 1;
    for (dims) |dim| {
        const value = try staticPositiveDimU32(dim);
        product = std.math.mul(u32, product, value) catch return error.CapabilityMismatch;
    }
    return product;
}

fn flattenedBoundaryReductionDims(
    input_dims: []const i64,
    output_dims: []const i64,
    axis: u8,
) gpu.BackendError!ReductionStaticDims {
    for (input_dims) |dim| _ = try staticPositiveDimU32(dim);
    const input_element_count = try staticDimProductU32(input_dims);
    const output_element_count = try staticDimProductU32(output_dims);
    if (input_element_count % output_element_count != 0) return error.InvalidArtifact;
    const reduction_extent = input_element_count / output_element_count;
    return .{
        .input_rank = 2,
        .axis = axis,
        .input_element_count = input_element_count,
        .output_element_count = output_element_count,
        .rows = if (axis == 0) reduction_extent else output_element_count,
        .cols = if (axis == 0) output_element_count else reduction_extent,
    };
}

fn markReductionAxes(rank: usize, axes: []const i64, reduced: []bool) gpu.BackendError!void {
    if (rank != reduced.len) return error.InvalidArtifact;
    for (axes) |axis| {
        if (axis < 0) return error.CapabilityMismatch;
        const index = std.math.cast(usize, axis) orelse return error.CapabilityMismatch;
        if (index >= rank) return error.CapabilityMismatch;
        if (reduced[index]) return error.CapabilityMismatch;
        reduced[index] = true;
    }
}

fn axesCoverSuffix(reduced: []const bool, output_rank: usize) bool {
    for (reduced, 0..) |is_reduced, index| {
        if (is_reduced != (index >= output_rank)) return false;
    }
    return true;
}

fn axesCoverPrefix(reduced: []const bool, axes_len: usize) bool {
    for (reduced, 0..) |is_reduced, index| {
        if (is_reduced != (index < axes_len)) return false;
    }
    return true;
}

fn axesCoverInputRank(rank: usize, axes: []const i64) gpu.BackendError!bool {
    if (axes.len != rank) return false;
    if (rank > i64_attr_list_stack_capacity) return error.CapabilityMismatch;
    var seen = @as([i64_attr_list_stack_capacity]bool, @splat(false));
    for (axes) |axis| {
        if (axis < 0) return error.CapabilityMismatch;
        const index = std.math.cast(usize, axis) orelse return error.CapabilityMismatch;
        if (index >= rank) return error.CapabilityMismatch;
        if (seen[index]) return error.CapabilityMismatch;
        seen[index] = true;
    }
    return true;
}

fn validateReductionDTypes(
    input_dtype: gpu_abi.DType,
    output_dtype: gpu_abi.DType,
    work: schedule_planning.ScheduleWorkItem,
) gpu.BackendError!void {
    if (input_dtype != output_dtype) return error.CapabilityMismatch;
    if (work.dtype != output_dtype) return error.InvalidArtifact;
    switch (input_dtype) {
        .f32, .i32, .u32, .f16 => {},
        else => return error.CapabilityMismatch,
    }
}

pub fn reductionKindForOp(op: *ir.Operation) gpu.BackendError!ReductionKind {
    const payload = try dialectAttrPayload(
        op,
        "reducer_kind",
        dialect_mod.AccyDialect.ReduceOp.dialectAttrName("reducer_kind"),
    );
    if (std.mem.eql(u8, payload, "sum")) return .sum;
    if (std.mem.eql(u8, payload, "max")) return .max;
    if (std.mem.eql(u8, payload, "min")) return .min;
    return error.UnsupportedOperation;
}

pub fn reductionInitValue(
    init_slot: bufferization.BufferSlot,
    dtype: gpu_abi.DType,
    outline: kernelization_model.KernelOutline,
) gpu.BackendError!ReductionInit {
    if (init_slot.dtype != dtype) return error.InvalidArtifact;
    if (!init_slot.role.constant) {
        if (externalInputIndex(outline, init_slot.id) != 1) return error.UnsupportedOperation;
        return .input_buffer;
    }
    const value = try reductionConstantInitValue(init_slot, dtype);
    return .{ .constant = value };
}

fn reductionConstantInitValue(
    init_slot: bufferization.BufferSlot,
    dtype: gpu_abi.DType,
) gpu.BackendError!ReductionInitValue {
    const payload = try constantPayloadForSlot(init_slot);
    switch (dtype) {
        .f32 => {
            if (payload.len != @sizeOf(f32)) return error.CapabilityMismatch;
            return .{ .f32 = std.mem.bytesToValue(f32, payload[0..@sizeOf(f32)]) };
        },
        .i32 => {
            if (payload.len != @sizeOf(i32)) return error.CapabilityMismatch;
            return .{ .i32 = std.mem.bytesToValue(i32, payload[0..@sizeOf(i32)]) };
        },
        .u32 => {
            if (payload.len != @sizeOf(u32)) return error.CapabilityMismatch;
            return .{ .u32 = std.mem.bytesToValue(u32, payload[0..@sizeOf(u32)]) };
        },
        .f16 => {
            if (payload.len != @sizeOf(f16)) return error.CapabilityMismatch;
            return .{ .f16 = std.mem.bytesToValue(f16, payload[0..@sizeOf(f16)]) };
        },
        else => return error.CapabilityMismatch,
    }
}
