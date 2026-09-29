const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const alloc_fixed = @import("alloc_fixed");
const generated_abi = @import("abi.zig");
const generated_builder = @import("builder.zig");
const common = @import("common.zig");
const generated_guard = @import("guard.zig");
const generated_name = @import("name.zig");
const generated_schedule = @import("schedule.zig");

const ir = common.ir;
const dialect_mod = common.dialect_mod;
const kernel_root = common.kernel_root;
const bufferization = common.bufferization;
const kernelization_model = @import("../model/root.zig");
const schedule_planning = common.schedule_planning;
const bufferSlotById = common.bufferSlotById;
const externalInputIndex = common.externalInputIndex;
const isName = common.isName;

const LoweredKernel = kernelization_model.LoweredKernel;

const block_rows = 32;
const block_cols = 32;
const dim = 64;
const threads_x = 16;
const threads_y = 8;
const rows_per_thread = block_rows / threads_y;
const score_cols_per_thread = block_cols / threads_x;
const acc_cols_per_thread = dim / threads_x;

const FlashDescription = struct {
    seq: u32,
    scale: f32,
    q: *ir.Value,
    kt: *ir.Value,
    v: *ir.Value,
};

pub fn lower(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    format: ?gpu.ArtifactFormat,
) common.LoweringError!LoweredKernel {
    const desc = try flashDescriptionForWork(work);

    const input_dtypes = allocator.alloc(gpu_abi.DType, outline.inputCount()) catch return error.OutOfMemory;
    defer allocator.free(input_dtypes);
    for (outline.input_slot_ids, 0..) |slot_id, index| {
        const slot = bufferSlotById(buffer_plan, slot_id) orelse return error.InvalidArtifact;
        input_dtypes[index] = slot.dtype;
    }

    var abi = try generated_abi.flatTyped(allocator, .f32, input_dtypes);
    defer abi.deinit(allocator);

    if (format == .cuda_ptx and desc.seq % block_rows == 0 and desc.seq % block_cols == 0) {
        const entry_name = try generated_name.flashAttention(allocator, desc.seq, dim, work.id);
        errdefer allocator.free(entry_name);
        var lowered = try generated_builder.withoutLaunch(allocator, ir_ctx, work.id, entry_name, abi.params(), generated_schedule.matrixThreads(threads_x, threads_y), .{
            .abi = abi,
            .allocator = allocator,
            .desc = desc,
            .outline = outline,
            .buffer_plan = buffer_plan,
        }, emitBlockFlashBody);
        lowered.body = .{ .flash_attention = .{
            .seq = desc.seq,
            .dim = dim,
            .br = block_rows,
            .bc = block_cols,
            .threads_x = threads_x,
            .threads_y = threads_y,
        } };
        return lowered;
    }

    const entry_name = try generated_name.flashAttentionSerial(allocator, desc.seq, dim, work.id);
    errdefer allocator.free(entry_name);
    return generated_builder.withoutLaunch(allocator, ir_ctx, work.id, entry_name, abi.params(), generated_schedule.flat(), .{
        .abi = abi,
        .allocator = allocator,
        .desc = desc,
        .outline = outline,
        .buffer_plan = buffer_plan,
    }, emitSerialFlashBody);
}

fn flashDescriptionForWork(
    work: schedule_planning.ScheduleWorkItem,
) common.LoweringError!FlashDescription {
    if (work.kind != .flash_attention) return error.UnsupportedOperation;
    if (work.ops.len < 7) return error.UnsupportedOperation;
    const dot1 = work.ops[0];
    const dot2 = work.ops[work.ops.len - 1];
    if (!isName(dot1.name.name, dialect_mod.AccyDialect.DotGeneralOp.operation_name)) return error.UnsupportedOperation;
    if (!isName(dot2.name.name, dialect_mod.AccyDialect.DotGeneralOp.operation_name)) return error.UnsupportedOperation;

    const q = dot1.getOperand(0) orelse return error.InvalidArtifact;
    const kt = dot1.getOperand(1) orelse return error.InvalidArtifact;
    const v = dot2.getOperand(1) orelse return error.InvalidArtifact;

    var dims_arena_buffer: [256]u8 = undefined;
    var dims_arena = alloc_fixed.FixedBuffer.init(dims_arena_buffer[0..]);
    const q_type = dialect_mod.decodeTensorType(dims_arena.allocator(), q.type) catch return error.InvalidArtifact;
    if (q_type.dtype != .f32 or q_type.dims.len != 2) return error.UnsupportedOperation;
    if (q_type.dims[1] != dim) return error.UnsupportedOperation;
    const seq = std.math.cast(u32, q_type.dims[0]) orelse return error.UnsupportedOperation;

    const scores = dot1.getResult(0) orelse return error.InvalidArtifact;
    const chain = try softmaxChain(scores, dot2);

    return .{
        .seq = seq,
        .scale = chain.scale,
        .q = q,
        .kt = kt,
        .v = v,
    };
}

const SoftmaxChain = struct {
    scale: f32,
};

fn softmaxChain(scores: *ir.Value, dot2: *ir.Operation) common.LoweringError!SoftmaxChain {
    var scale: f32 = 1.0;
    var scaled: *ir.Value = scores;

    var use = scores.first_use orelse return error.UnsupportedOperation;
    var user: *ir.Operation = @ptrCast(@alignCast(use.owner));
    if (isName(user.name.name, dialect_mod.AccyDialect.MulOp.operation_name)) {
        scale = splatOperandScalar(user) orelse return error.UnsupportedOperation;
        scaled = user.getResult(0) orelse return error.InvalidArtifact;
    } else if (!isName(user.name.name, dialect_mod.AccyDialect.ReduceOp.operation_name) and
        !isName(user.name.name, dialect_mod.AccyDialect.SubOp.operation_name))
    {
        return error.UnsupportedOperation;
    }

    var max_reduce: ?*ir.Operation = null;
    var sub_op: ?*ir.Operation = null;
    use = scaled.first_use orelse return error.UnsupportedOperation;
    while (true) {
        user = @ptrCast(@alignCast(use.owner));
        if (isName(user.name.name, dialect_mod.AccyDialect.ReduceOp.operation_name)) {
            max_reduce = user;
        } else if (isName(user.name.name, dialect_mod.AccyDialect.SubOp.operation_name)) {
            sub_op = user;
        } else {
            return error.UnsupportedOperation;
        }
        use = use.next_use orelse break;
    }
    const max_op = max_reduce orelse return error.UnsupportedOperation;
    const shifted_op = sub_op orelse return error.UnsupportedOperation;
    if (!reduceHasKind(max_op, "max")) return error.UnsupportedOperation;

    const shifted = shifted_op.getResult(0) orelse return error.InvalidArtifact;
    const exp_use = shifted.first_use orelse return error.UnsupportedOperation;
    const exp_op: *ir.Operation = @ptrCast(@alignCast(exp_use.owner));
    if (!isName(exp_op.name.name, dialect_mod.AccyDialect.ExpOp.operation_name)) return error.UnsupportedOperation;
    const exps = exp_op.getResult(0) orelse return error.InvalidArtifact;

    var sum_reduce: ?*ir.Operation = null;
    var normalization_op: ?*ir.Operation = null;
    var exp_walk = exps.first_use orelse return error.UnsupportedOperation;
    while (true) {
        user = @ptrCast(@alignCast(exp_walk.owner));
        if (isName(user.name.name, dialect_mod.AccyDialect.ReduceOp.operation_name)) {
            sum_reduce = user;
        } else if (isName(user.name.name, dialect_mod.AccyDialect.DivOp.operation_name) or
            isName(user.name.name, dialect_mod.AccyDialect.MulOp.operation_name))
        {
            normalization_op = user;
        } else {
            return error.UnsupportedOperation;
        }
        exp_walk = exp_walk.next_use orelse break;
    }
    const sum_op = sum_reduce orelse return error.UnsupportedOperation;
    const terminal = normalization_op orelse return error.UnsupportedOperation;
    if (!reduceHasKind(sum_op, "sum")) return error.UnsupportedOperation;
    if (isName(terminal.name.name, dialect_mod.AccyDialect.MulOp.operation_name) and
        !isReciprocalNormalization(exps, sum_op, terminal))
    {
        return error.UnsupportedOperation;
    }

    const probs = terminal.getResult(0) orelse return error.InvalidArtifact;
    const probs_use = probs.first_use orelse return error.UnsupportedOperation;
    if (probs_use.next_use != null) return error.UnsupportedOperation;
    const consumer: *ir.Operation = @ptrCast(@alignCast(probs_use.owner));
    if (consumer != dot2) return error.UnsupportedOperation;

    return .{ .scale = scale };
}

fn reduceHasKind(op: *ir.Operation, kind: []const u8) bool {
    const attr = op.getAttrAs(ir.Attribute.DialectAttr, "reducer_kind") orelse
        op.getAttrAs(ir.Attribute.DialectAttr, dialect_mod.AccyDialect.ReduceOp.dialectAttrName("reducer_kind")) orelse return false;
    return std.mem.eql(u8, attr.payload, kind);
}

fn splatOperandScalar(mul: *ir.Operation) ?f32 {
    for (mul.getOperandValues()) |operand| {
        if (splatValueScalar(operand)) |scalar| return scalar;
    }
    return null;
}

fn isReciprocalNormalization(exps: *ir.Value, sum_op: *ir.Operation, mul: *ir.Operation) bool {
    const lhs = mul.getOperand(0) orelse return false;
    const rhs = mul.getOperand(1) orelse return false;
    const normalization = if (lhs == exps)
        rhs
    else if (rhs == exps)
        lhs
    else
        return false;

    const broadcast_any = normalization.getDefiningOp() orelse return false;
    const broadcast: *ir.Operation = @ptrCast(@alignCast(broadcast_any));
    if (!isName(broadcast.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name) and
        !isName(broadcast.name.name, dialect_mod.AccyDialect.BroadcastOp.operation_name))
    {
        return false;
    }
    const reciprocal = broadcast.getOperand(0) orelse return false;
    const div_any = reciprocal.getDefiningOp() orelse return false;
    const div: *ir.Operation = @ptrCast(@alignCast(div_any));
    if (!isName(div.name.name, dialect_mod.AccyDialect.DivOp.operation_name)) return false;
    const numerator = div.getOperand(0) orelse return false;
    const denominator = div.getOperand(1) orelse return false;
    const sum = sum_op.getResult(0) orelse return false;
    if (denominator != sum) return false;
    const scalar = splatValueScalar(numerator) orelse return false;
    return scalar == 1.0;
}

fn splatValueScalar(value: *ir.Value) ?f32 {
    const def_any = value.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    var source = def_op;
    if (isName(def_op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name) or
        isName(def_op.name.name, dialect_mod.AccyDialect.BroadcastOp.operation_name))
    {
        const inner = def_op.getOperand(0) orelse return null;
        const inner_any = inner.getDefiningOp() orelse return null;
        source = @ptrCast(@alignCast(inner_any));
    }
    if (!isName(source.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) return null;
    const constant = dialect_mod.AccyDialect.ConstantOp{ .op = source };
    const payload = constant.getPayload() orelse return null;
    if (payload.len < @sizeOf(f32) or payload.len % @sizeOf(f32) != 0) return null;
    var first: f32 = undefined;
    @memcpy(std.mem.asBytes(&first), payload[0..@sizeOf(f32)]);
    var offset: usize = @sizeOf(f32);
    while (offset < payload.len) : (offset += @sizeOf(f32)) {
        if (!std.mem.eql(u8, payload[offset..][0..@sizeOf(f32)], payload[0..@sizeOf(f32)])) return null;
    }
    return first;
}

const FlashInputs = struct {
    q: kernel_root.Value,
    kt: kernel_root.Value,
    v: kernel_root.Value,
    out: kernel_root.Value,
};

fn flashInputs(builder: anytype, ctx: anytype) !FlashInputs {
    const desc: FlashDescription = ctx.desc;
    const q_slot = ctx.buffer_plan.getSlot(desc.q) orelse return error.UnsupportedOperation;
    const kt_slot = ctx.buffer_plan.getSlot(desc.kt) orelse return error.UnsupportedOperation;
    const v_slot = ctx.buffer_plan.getSlot(desc.v) orelse return error.UnsupportedOperation;
    const q_index = externalInputIndex(ctx.outline, q_slot.id) orelse return error.UnsupportedOperation;
    const kt_index = externalInputIndex(ctx.outline, kt_slot.id) orelse return error.UnsupportedOperation;
    const v_index = externalInputIndex(ctx.outline, v_slot.id) orelse return error.UnsupportedOperation;
    return .{
        .q = ctx.abi.input(builder, q_index),
        .kt = ctx.abi.input(builder, kt_index),
        .v = ctx.abi.input(builder, v_index),
        .out = ctx.abi.output(builder),
    };
}

fn emitBlockFlashBody(logical: anytype, ctx: anytype) !void {
    const desc: FlashDescription = ctx.desc;
    const seq: i64 = @intCast(desc.seq);
    const q_tiles: u64 = desc.seq / block_rows;

    _ = try logical.index3D(.{
        .x = kernel_root.logical.axis("lane", q_tiles * threads_x),
        .y = kernel_root.logical.axis("row", threads_y),
        .z = kernel_root.logical.axis("batch", 1),
    });

    const inputs = try flashInputs(logical, ctx);
    const tx = try logical.threadId(.x);
    const ty = try logical.threadId(.y);
    const bx = try logical.blockId(.x);

    const seq_extent = try logical.constantIndex(seq);
    const dim_extent = try logical.constantIndex(dim);
    const q_pitch = try logical.constantIndex(dim + 4);
    const k_pitch = try logical.constantIndex(block_cols + 4);
    const v_pitch = try logical.constantIndex(dim + 4);
    const p_pitch = try logical.constantIndex(block_cols + 4);

    const q_s = try logical.sharedBuffer(.f32, block_rows * (dim + 4));
    const k_s = try logical.sharedBuffer(.f32, dim * (block_cols + 4));
    const v_s = try logical.sharedBuffer(.f32, block_cols * (dim + 4));
    const p_s = try logical.sharedBuffer(.f32, block_rows * (block_cols + 4));

    const flat = try logical.add(try logical.mul(ty, try logical.constantIndex(threads_x)), tx);
    const row_block = try logical.mul(bx, try logical.constantIndex(block_rows));

    {
        var chunk: u32 = 0;
        while (chunk < (block_rows * dim) / (threads_x * threads_y)) : (chunk += 1) {
            const idx = try logical.add(flat, try logical.constantIndex(@as(i64, chunk) * threads_x * threads_y));
            const row = try logical.div(idx, dim_extent);
            const col = try logical.sub(idx, try logical.mul(row, dim_extent));
            const global_row = try logical.add(row_block, row);
            const value = try logical.loadIndex(inputs.q, try logical.add(try logical.mul(global_row, dim_extent), col));
            try logical.storeIndex(value, q_s, try logical.add(try logical.mul(row, q_pitch), col));
        }
    }

    const scale_value = try logical.constantFloat(.f32, desc.scale);
    const neg_inf = try logical.constantFloat(.f32, -std.math.floatMax(f32));
    const zero_f = try logical.constantFloat(.f32, 0.0);

    var init_args: [2 * rows_per_thread + rows_per_thread * acc_cols_per_thread]kernel_root.Value = undefined;
    var init_types: [2 * rows_per_thread + rows_per_thread * acc_cols_per_thread]kernel_root.Type = undefined;
    for (0..rows_per_thread) |i| {
        init_args[i] = neg_inf;
        init_args[rows_per_thread + i] = zero_f;
    }
    for (0..rows_per_thread * acc_cols_per_thread) |i| {
        init_args[2 * rows_per_thread + i] = zero_f;
    }
    for (init_args, 0..) |arg, i| init_types[i] = arg.valueType();

    const loop_lower = try logical.constantIndex(0);
    const loop_step = try logical.constantIndex(block_cols);
    var scope = try logical.forScope(loop_lower, seq_extent, loop_step, init_args[0..], init_types[0..]);
    errdefer scope.abort();
    const j0 = scope.inductionVar();

    var m_state: [rows_per_thread]kernel_root.Value = undefined;
    var l_state: [rows_per_thread]kernel_root.Value = undefined;
    var acc_state: [rows_per_thread][acc_cols_per_thread]kernel_root.Value = undefined;
    for (0..rows_per_thread) |i| {
        m_state[i] = scope.iterArg(i) orelse return error.UnsupportedOperation;
        l_state[i] = scope.iterArg(rows_per_thread + i) orelse return error.UnsupportedOperation;
    }
    for (0..rows_per_thread) |i| {
        for (0..acc_cols_per_thread) |j| {
            acc_state[i][j] = scope.iterArg(2 * rows_per_thread + i * acc_cols_per_thread + j) orelse return error.UnsupportedOperation;
        }
    }

    try logical.barrier(.block);

    {
        var chunk: u32 = 0;
        while (chunk < (dim * block_cols) / (threads_x * threads_y)) : (chunk += 1) {
            const idx = try logical.add(flat, try logical.constantIndex(@as(i64, chunk) * threads_x * threads_y));
            const bc_extent = try logical.constantIndex(block_cols);
            const d = try logical.div(idx, bc_extent);
            const c = try logical.sub(idx, try logical.mul(d, bc_extent));
            const global_col = try logical.add(j0, c);
            const value = try logical.loadIndex(inputs.kt, try logical.add(try logical.mul(d, seq_extent), global_col));
            try logical.storeIndex(value, k_s, try logical.add(try logical.mul(d, k_pitch), c));
        }
        chunk = 0;
        while (chunk < (block_cols * dim) / (threads_x * threads_y)) : (chunk += 1) {
            const idx = try logical.add(flat, try logical.constantIndex(@as(i64, chunk) * threads_x * threads_y));
            const c = try logical.div(idx, dim_extent);
            const dc = try logical.sub(idx, try logical.mul(c, dim_extent));
            const global_row = try logical.add(j0, c);
            const value = try logical.loadIndex(inputs.v, try logical.add(try logical.mul(global_row, dim_extent), dc));
            try logical.storeIndex(value, v_s, try logical.add(try logical.mul(c, v_pitch), dc));
        }
    }

    try logical.barrier(.block);

    var scores: [rows_per_thread][score_cols_per_thread]kernel_root.Value = undefined;
    for (0..rows_per_thread) |i| {
        const local_row = try logical.add(try logical.mul(ty, try logical.constantIndex(rows_per_thread)), try logical.constantIndex(@as(i64, @intCast(i))));
        const q_row_base = try logical.mul(local_row, q_pitch);
        for (0..score_cols_per_thread) |jj| {
            const local_col = try logical.add(try logical.mul(tx, try logical.constantIndex(score_cols_per_thread)), try logical.constantIndex(@as(i64, @intCast(jj))));
            var acc = zero_f;
            var d: u32 = 0;
            while (d < dim) : (d += 1) {
                const d_extent = try logical.constantIndex(@as(i64, d));
                const q_val = try logical.loadIndex(q_s, try logical.add(q_row_base, d_extent));
                const k_val = try logical.loadIndex(k_s, try logical.add(try logical.mul(d_extent, k_pitch), local_col));
                acc = try logical.add(acc, try logical.mul(q_val, k_val));
            }
            scores[i][jj] = try logical.mul(acc, scale_value);
        }
    }

    var new_m: [rows_per_thread]kernel_root.Value = undefined;
    var corr: [rows_per_thread]kernel_root.Value = undefined;
    var probs: [rows_per_thread][score_cols_per_thread]kernel_root.Value = undefined;
    for (0..rows_per_thread) |i| {
        var tile_max = scores[i][0];
        for (1..score_cols_per_thread) |jj| {
            tile_max = try logical.max(tile_max, scores[i][jj]);
        }
        inline for ([_]u32{ 8, 4, 2, 1 }) |offset| {
            const other = try logical.shuffleSync(.xor, tile_max, try logical.constantInt(.i32, @as(i32, @intCast(offset))));
            tile_max = try logical.max(tile_max, other);
        }
        new_m[i] = try logical.max(m_state[i], tile_max);
        corr[i] = try logical.exp(try logical.sub(m_state[i], new_m[i]));
        var tile_sum = zero_f;
        for (0..score_cols_per_thread) |jj| {
            probs[i][jj] = try logical.exp(try logical.sub(scores[i][jj], new_m[i]));
            tile_sum = try logical.add(tile_sum, probs[i][jj]);
        }
        inline for ([_]u32{ 8, 4, 2, 1 }) |offset| {
            const other = try logical.shuffleSync(.xor, tile_sum, try logical.constantInt(.i32, @as(i32, @intCast(offset))));
            tile_sum = try logical.add(tile_sum, other);
        }
        l_state[i] = try logical.add(try logical.mul(l_state[i], corr[i]), tile_sum);
        m_state[i] = new_m[i];
    }

    try logical.barrier(.block);

    for (0..rows_per_thread) |i| {
        const local_row = try logical.add(try logical.mul(ty, try logical.constantIndex(rows_per_thread)), try logical.constantIndex(@as(i64, @intCast(i))));
        const p_row_base = try logical.mul(local_row, p_pitch);
        for (0..score_cols_per_thread) |jj| {
            const local_col = try logical.add(try logical.mul(tx, try logical.constantIndex(score_cols_per_thread)), try logical.constantIndex(@as(i64, @intCast(jj))));
            try logical.storeIndex(probs[i][jj], p_s, try logical.add(p_row_base, local_col));
        }
    }

    try logical.barrier(.block);

    for (0..rows_per_thread) |i| {
        const local_row = try logical.add(try logical.mul(ty, try logical.constantIndex(rows_per_thread)), try logical.constantIndex(@as(i64, @intCast(i))));
        const p_row_base = try logical.mul(local_row, p_pitch);
        for (0..acc_cols_per_thread) |j| {
            const local_dc = try logical.add(try logical.mul(tx, try logical.constantIndex(acc_cols_per_thread)), try logical.constantIndex(@as(i64, @intCast(j))));
            var acc = try logical.mul(acc_state[i][j], corr[i]);
            var c: u32 = 0;
            while (c < block_cols) : (c += 1) {
                const c_extent = try logical.constantIndex(@as(i64, c));
                const p_val = try logical.loadIndex(p_s, try logical.add(p_row_base, c_extent));
                const v_val = try logical.loadIndex(v_s, try logical.add(try logical.mul(c_extent, v_pitch), local_dc));
                acc = try logical.add(acc, try logical.mul(p_val, v_val));
            }
            acc_state[i][j] = acc;
        }
    }

    var leave_args: [2 * rows_per_thread + rows_per_thread * acc_cols_per_thread]kernel_root.Value = undefined;
    for (0..rows_per_thread) |i| {
        leave_args[i] = m_state[i];
        leave_args[rows_per_thread + i] = l_state[i];
    }
    for (0..rows_per_thread) |i| {
        for (0..acc_cols_per_thread) |j| {
            leave_args[2 * rows_per_thread + i * acc_cols_per_thread + j] = acc_state[i][j];
        }
    }
    try scope.leave(leave_args[0..]);

    for (0..rows_per_thread) |i| {
        const final_l = scope.result(rows_per_thread + i) orelse return error.UnsupportedOperation;
        const local_row = try logical.add(try logical.mul(ty, try logical.constantIndex(rows_per_thread)), try logical.constantIndex(@as(i64, @intCast(i))));
        const global_row = try logical.add(row_block, local_row);
        const out_row_base = try logical.mul(global_row, dim_extent);
        for (0..acc_cols_per_thread) |j| {
            const final_acc = scope.result(2 * rows_per_thread + i * acc_cols_per_thread + j) orelse return error.UnsupportedOperation;
            const local_dc = try logical.add(try logical.mul(tx, try logical.constantIndex(acc_cols_per_thread)), try logical.constantIndex(@as(i64, @intCast(j))));
            const value = try logical.div(final_acc, final_l);
            try logical.storeIndex(value, inputs.out, try logical.add(out_row_base, local_dc));
        }
    }
}

fn emitSerialFlashBody(logical: anytype, ctx: anytype) !void {
    const desc: FlashDescription = ctx.desc;
    const seq: i64 = @intCast(desc.seq);

    const domain = try logical.index1D("row", desc.seq);
    try generated_guard.countIndexDo(logical, domain, ctx.abi.count(logical), .{
        .abi = ctx.abi,
        .allocator = ctx.allocator,
        .desc = desc,
        .outline = ctx.outline,
        .buffer_plan = ctx.buffer_plan,
        .seq = seq,
    }, struct {
        fn run(inner: anytype, domain_index: kernel_root.Index1D, guard_ctx: anytype) !void {
            const desc_inner: FlashDescription = guard_ctx.desc;
            const row = domain_index.index;
            const inputs = try flashInputs(inner, guard_ctx);
            const seq_extent = try inner.constantIndex(guard_ctx.seq);
            const dim_extent = try inner.constantIndex(dim);
            const row_base = try inner.mul(row, dim_extent);
            const scale_value = try inner.constantFloat(.f32, desc_inner.scale);

            var q_row: [dim]kernel_root.Value = undefined;
            for (0..dim) |d| {
                q_row[d] = try inner.loadIndex(inputs.q, try inner.add(row_base, try inner.constantIndex(@as(i64, @intCast(d)))));
            }

            const neg_inf = try inner.constantFloat(.f32, -std.math.floatMax(f32));
            const zero_f = try inner.constantFloat(.f32, 0.0);
            var init_args: [2 + dim]kernel_root.Value = undefined;
            var init_types: [2 + dim]kernel_root.Type = undefined;
            init_args[0] = neg_inf;
            init_args[1] = zero_f;
            for (0..dim) |d| init_args[2 + d] = zero_f;
            for (init_args, 0..) |arg, i| init_types[i] = arg.valueType();

            const one = try inner.constantIndex(1);
            const zero_index = try inner.constantIndex(0);
            var scope = try inner.forScope(zero_index, seq_extent, one, init_args[0..], init_types[0..]);
            errdefer scope.abort();
            const j = scope.inductionVar();

            const m_old = scope.iterArg(0) orelse return error.UnsupportedOperation;
            const l_old = scope.iterArg(1) orelse return error.UnsupportedOperation;

            var s = zero_f;
            for (0..dim) |d| {
                const kt_val = try inner.loadIndex(inputs.kt, try inner.add(try inner.mul(try inner.constantIndex(@as(i64, @intCast(d))), seq_extent), j));
                s = try inner.add(s, try inner.mul(q_row[d], kt_val));
            }
            s = try inner.mul(s, scale_value);

            const m_new = try inner.max(m_old, s);
            const corr = try inner.exp(try inner.sub(m_old, m_new));
            const p = try inner.exp(try inner.sub(s, m_new));
            const l_new = try inner.add(try inner.mul(l_old, corr), p);

            const v_row_base = try inner.mul(j, dim_extent);
            var leave_args: [2 + dim]kernel_root.Value = undefined;
            leave_args[0] = m_new;
            leave_args[1] = l_new;
            for (0..dim) |d| {
                const acc_old = scope.iterArg(2 + d) orelse return error.UnsupportedOperation;
                const v_val = try inner.loadIndex(inputs.v, try inner.add(v_row_base, try inner.constantIndex(@as(i64, @intCast(d)))));
                leave_args[2 + d] = try inner.add(try inner.mul(acc_old, corr), try inner.mul(p, v_val));
            }
            try scope.leave(leave_args[0..]);

            const final_l = scope.result(1) orelse return error.UnsupportedOperation;
            for (0..dim) |d| {
                const final_acc = scope.result(2 + d) orelse return error.UnsupportedOperation;
                const value = try inner.div(final_acc, final_l);
                try inner.storeIndex(value, inputs.out, try inner.add(row_base, try inner.constantIndex(@as(i64, @intCast(d)))));
            }
        }
    }.run);
}
