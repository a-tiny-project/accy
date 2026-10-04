const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const generated_abi = @import("abi.zig");
const generated_builder = @import("builder.zig");
const common = @import("common.zig");
const generated_elementwise = @import("elementwise.zig");
const generated_name = @import("name.zig");
const generated_schedule = @import("schedule.zig");

const fusion = common.fusion;

const ir = common.ir;
const dialect_mod = common.dialect_mod;
const kernel_root = common.kernel_root;
const bufferization = common.bufferization;
const kernelization_model = @import("../model/root.zig");
const schedule_planning = common.schedule_planning;
const bufferSlotById = common.bufferSlotById;
const staticPositiveDimU32 = common.staticPositiveDimU32;
const isName = common.isName;

const DotGeneralStaticDims = kernelization_model.DotGeneralStaticDims;
const DotGeneralDescription = kernelization_model.DotGeneralDescription;
const LoweredKernel = kernelization_model.LoweredKernel;

fn dotInitialValue(builder: anytype, dtype: gpu_abi.DType) !kernel_root.Value {
    return switch (dtype) {
        .f32 => builder.constantFloat(.f32, 0.0),
        .f16 => builder.constantFloat(.f32, 0.0),
        .i32 => builder.constantInt(.i32, 0),
        .u32 => builder.constantInt(.u32, 0),
        else => error.CapabilityMismatch,
    };
}

fn hostLoopFormat(format: ?gpu.ArtifactFormat) bool {
    const artifact_format = format orelse return false;
    return gpu.artifactFormatUsesHostLoopLaunch(artifact_format);
}

pub fn dotGeneralDescriptionForWork(
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) gpu.BackendError!DotGeneralDescription {
    if (work.kind != .dot_general) return error.UnsupportedOperation;
    if (work.ops.len == 0) return error.UnsupportedOperation;
    if (!isName(work.ops[0].name.name, dialect_mod.AccyDialect.DotGeneralOp.operation_name)) {
        return error.UnsupportedOperation;
    }
    if (work.ops.len == 1 and outline.inputCount() != 2) return error.UnsupportedOperation;
    if (outline.inputCount() < 2) return error.UnsupportedOperation;

    const lhs_slot = bufferSlotById(buffer_plan, outline.input_slot_ids[0]) orelse
        return error.InvalidArtifact;
    const rhs_slot = bufferSlotById(buffer_plan, outline.input_slot_ids[1]) orelse
        return error.InvalidArtifact;
    const output_slot = bufferSlotById(buffer_plan, outline.output_slot_id) orelse
        return error.InvalidArtifact;
    try validateCanonicalDotLayout(work.ops[0], lhs_slot.dims.len);
    const dims = try dotGeneralStaticDims(lhs_slot.*, rhs_slot.*, output_slot.*);
    try validateDotGeneralDTypes(lhs_slot.*, rhs_slot.*, output_slot.*, work);

    return .{
        .input_dtype = lhs_slot.dtype,
        .output_dtype = output_slot.dtype,
        .dims = dims,
    };
}

pub const max_epilogue_inputs = 8;

const EpilogueBroadcastOperand = struct {
    param: usize,
    op: *ir.Operation,
    slot: *const bufferization.BufferSlot,
};

const EpilogueOperand = union(enum) {
    chain,
    full: usize,
    broadcast: EpilogueBroadcastOperand,
};

const EpilogueOp = struct {
    kind: kernelization_model.ElementwiseKernel,
    op: *ir.Operation,
    operands: [3]EpilogueOperand,
    operand_count: u8,
};

const EpiloguePlan = struct {
    ops: [fusion.max_dot_epilogue_ops]EpilogueOp = undefined,
    count: usize = 0,
    param_dtypes: [max_epilogue_inputs]gpu_abi.DType = undefined,
    param_count: usize = 0,

    fn chain(self: *const EpiloguePlan) []const EpilogueOp {
        return self.ops[0..self.count];
    }
};

fn buildEpiloguePlan(
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) common.LoweringError!EpiloguePlan {
    var plan = EpiloguePlan{};
    if (work.ops.len <= 1) return plan;
    if (work.ops.len - 1 > plan.ops.len) return error.UnsupportedOperation;

    var param_values: [max_epilogue_inputs]*ir.Value = undefined;

    const dot = work.ops[0];
    for (dot.getOperandValues()) |operand| {
        _ = try epilogueParamIndex(&plan, &param_values, buffer_plan, operand);
    }

    var previous = dot.getResult(0) orelse return error.InvalidArtifact;
    for (work.ops[1..]) |op| {
        const kind = generated_elementwise.kernelForOperation(op) orelse
            return error.UnsupportedOperation;
        const operands = op.getOperandValues();
        if (operands.len > 3) return error.UnsupportedOperation;
        var entry = EpilogueOp{
            .kind = kind,
            .op = op,
            .operands = undefined,
            .operand_count = @intCast(operands.len),
        };
        for (operands, 0..) |operand, operand_index| {
            if (operand == previous) {
                entry.operands[operand_index] = .chain;
                continue;
            }
            if (fusion.broadcastLeafSource(operand)) |source| {
                const def_any = operand.getDefiningOp() orelse return error.InvalidArtifact;
                const broadcast_op: *ir.Operation = @ptrCast(@alignCast(def_any));
                const param = try epilogueParamIndex(&plan, &param_values, buffer_plan, source);
                const slot = buffer_plan.getSlot(source) orelse return error.InvalidArtifact;
                entry.operands[operand_index] = .{
                    .broadcast = .{ .param = param, .op = broadcast_op, .slot = slot },
                };
                continue;
            }
            const param = try epilogueParamIndex(&plan, &param_values, buffer_plan, operand);
            entry.operands[operand_index] = .{ .full = param };
        }
        plan.ops[plan.count] = entry;
        plan.count += 1;
        previous = op.getResult(0) orelse return error.InvalidArtifact;
    }
    return plan;
}

fn epilogueParamIndex(
    plan: *EpiloguePlan,
    param_values: *[max_epilogue_inputs]*ir.Value,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    value: *ir.Value,
) common.LoweringError!usize {
    for (param_values[0..plan.param_count], 0..) |existing, index| {
        if (existing == value) return index;
    }
    if (plan.param_count >= max_epilogue_inputs) return error.UnsupportedOperation;
    const slot = buffer_plan.getSlot(value) orelse return error.UnsupportedOperation;
    param_values[plan.param_count] = value;
    plan.param_dtypes[plan.param_count] = slot.dtype;
    plan.param_count += 1;
    return plan.param_count - 1;
}

fn applyEpilogueChain(
    logical: anytype,
    epilogue: []const EpilogueOp,
    abi: anytype,
    initial: kernel_root.Value,
    flat_index: kernel_root.Value,
) !kernel_root.Value {
    var current = initial;
    for (epilogue) |entry| {
        var inputs: [3]kernel_root.Value = undefined;
        for (entry.operands[0..entry.operand_count], 0..) |operand, index| {
            inputs[index] = switch (operand) {
                .chain => current,
                .full => |param| try logical.loadIndex(abi.input(logical, param), flat_index),
                .broadcast => |broadcast| blk: {
                    const source_index = try generated_elementwise.broadcastInDimSourceIndex(
                        logical,
                        flat_index,
                        broadcast.op,
                        broadcast.slot,
                    );
                    break :blk try logical.loadIndex(
                        abi.input(logical, broadcast.param),
                        source_index,
                    );
                },
            };
        }
        current = try generated_elementwise.emitElementwiseValue(
            logical,
            entry.kind,
            inputs[0..entry.operand_count],
            .f32,
            entry.op,
        );
    }
    return current;
}

pub fn lower(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    format: ?gpu.ArtifactFormat,
    math_tier: gpu.BackendMathTier,
) common.LoweringError!LoweredKernel {
    const desc = try dotGeneralDescriptionForWork(outline, work, buffer_plan);
    if (!dotLoweringSupported(desc.input_dtype, desc.output_dtype)) return error.CapabilityMismatch;
    var mma_tile: ?kernelization_model.DotGeneralMmaTile = null;
    if (math_tier != .exact) {
        if (math_tier != .tf32_tensor or format != .cuda_ptx) return error.UnsupportedOperation;
        mma_tile = kernelization_model.dotGeneralMmaTileFor(desc) orelse
            return error.UnsupportedOperation;
    }

    const epilogue_plan = try buildEpiloguePlan(work, buffer_plan);
    if (epilogue_plan.count != 0) {
        if (desc.output_dtype != .f32) return error.CapabilityMismatch;
        if (epilogue_plan.param_count != outline.inputCount()) return error.InvalidArtifact;
        var abi = try generated_abi.dotFused(
            allocator,
            desc.output_dtype,
            epilogue_plan.param_dtypes[0..epilogue_plan.param_count],
        );
        defer abi.deinit(allocator);

        if (mma_tile) |picked_mma| {
            var tile_value = picked_mma;
            tile_value.splits = 1;
            const entry_name = try generated_name.dotGeneralFusedMma(
                allocator,
                desc,
                work,
                tile_value,
                work.id,
            );
            errdefer allocator.free(entry_name);
            var lowered = try generated_builder.withoutLaunch(
                allocator,
                ir_ctx,
                work.id,
                entry_name,
                abi.params(),
                generated_schedule.matrixThreads(32, tile_value.warps()),
                .{
                    .abi = abi,
                    .dims = desc.dims,
                    .tile = tile_value,
                    .epilogue = epilogue_plan.chain(),
                },
                emitMmaDotBody,
            );
            lowered.body = .{ .dot_mma_tile = tile_value };
            return lowered;
        }

        if (format ==
            .cuda_ptx) if (kernelization_model.dotGeneralBlockTileFor(desc)) |picked_tile|
        {
            var tile = picked_tile;
            tile.splits = 1;
            const entry_name = try generated_name.dotGeneralFused(
                allocator,
                desc,
                work,
                tile,
                work.id,
            );
            errdefer allocator.free(entry_name);
            var lowered = try generated_builder.withoutLaunch(
                allocator,
                ir_ctx,
                work.id,
                entry_name,
                abi.params(),
                generated_schedule.matrix(),
                .{
                    .abi = abi,
                    .dims = desc.dims,
                    .tile = tile,
                    .epilogue = epilogue_plan.chain(),
                },
                emitTiledDotBody,
            );
            lowered.body = .{ .dot_block_tile = tile };
            return lowered;
        };

        const entry_name = try generated_name.dotGeneralFused(allocator, desc, work, null, work.id);
        errdefer allocator.free(entry_name);
        if (hostLoopFormat(format)) {
            return generated_builder.withoutLaunch(
                allocator,
                ir_ctx,
                work.id,
                entry_name,
                abi.params(),
                generated_schedule.flat(),
                .{
                    .abi = abi,
                    .dims = desc.dims,
                    .dtype = desc.output_dtype,
                    .epilogue = epilogue_plan.chain(),
                },
                emitFlatDotBody,
            );
        }
        return generated_builder.withoutLaunch(
            allocator,
            ir_ctx,
            work.id,
            entry_name,
            abi.params(),
            generated_schedule.matrix(),
            .{
                .abi = abi,
                .dims = desc.dims,
                .dtype = desc.output_dtype,
                .epilogue = epilogue_plan.chain(),
            },
            emitDotBody,
        );
    }

    const abi = generated_abi.dot(desc.input_dtype, desc.output_dtype);
    const empty_epilogue: []const EpilogueOp = &.{};

    if (mma_tile) |tile_value| {
        const entry_name = try generated_name.dotGeneralMma(allocator, desc, tile_value, work.id);
        errdefer allocator.free(entry_name);
        var lowered = try generated_builder.withoutLaunch(
            allocator,
            ir_ctx,
            work.id,
            entry_name,
            abi.params(),
            generated_schedule.matrixThreads(32, tile_value.warps()),
            .{
                .abi = abi,
                .dims = desc.dims,
                .tile = tile_value,
                .epilogue = empty_epilogue,
            },
            emitMmaDotBody,
        );
        lowered.body = .{ .dot_mma_tile = tile_value };
        if (tile_value.splits > 1) lowered.output_fill_pattern = 0;
        return lowered;
    }

    if (format == .cuda_ptx) if (kernelization_model.dotGeneralBlockTileFor(desc)) |tile| {
        const entry_name = try generated_name.dotGeneralTiled(allocator, desc, tile, work.id);
        errdefer allocator.free(entry_name);
        var lowered = try generated_builder.withoutLaunch(
            allocator,
            ir_ctx,
            work.id,
            entry_name,
            abi.params(),
            generated_schedule.matrix(),
            .{
                .abi = abi,
                .dims = desc.dims,
                .tile = tile,
                .epilogue = empty_epilogue,
            },
            emitTiledDotBody,
        );
        lowered.body = .{ .dot_block_tile = tile };
        if (tile.splits > 1) lowered.output_fill_pattern = 0;
        return lowered;
    };

    if (hostLoopFormat(format)) {
        const entry_name = try generated_name.dotGeneral(allocator, desc, work.id);
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
                .dims = desc.dims,
                .dtype = desc.output_dtype,
                .epilogue = empty_epilogue,
            },
            emitFlatDotBody,
        );
    }

    const entry_name = try generated_name.dotGeneral(allocator, desc, work.id);
    errdefer allocator.free(entry_name);

    return generated_builder.withoutLaunch(
        allocator,
        ir_ctx,
        work.id,
        entry_name,
        abi.params(),
        generated_schedule.matrix(),
        .{
            .abi = abi,
            .dims = desc.dims,
            .dtype = desc.output_dtype,
            .epilogue = empty_epilogue,
        },
        emitDotBody,
    );
}

const max_block_tile_accumulators = 64;
const max_block_tile_fragments = 8;

const mma_shape = kernel_root.MmaShape{ .m = 16, .n = 8, .k = 8 };
const mma_lane_acc_count = 4;
const max_mma_fragments = 8;

fn emitMmaDotBody(logical: anytype, ctx: anytype) !void {
    const tile: kernelization_model.DotGeneralMmaTile = ctx.tile;
    const dims: DotGeneralStaticDims = ctx.dims;
    const m_frags = tile.warpTileM() / mma_shape.m;
    const n_frags = tile.warpTileN() / mma_shape.n;
    const k_steps = tile.bk / mma_shape.k;
    const threads = tile.threads();
    const accumulator_count: usize = @intCast(m_frags * n_frags * mma_lane_acc_count);
    if (accumulator_count > max_block_tile_accumulators) return error.UnsupportedOperation;
    if (m_frags > max_mma_fragments or n_frags > max_mma_fragments) {
        return error.UnsupportedOperation;
    }
    if ((tile.bm * tile.bk) % (threads * 4) != 0) return error.UnsupportedOperation;
    if ((tile.bk * tile.bn) % (threads * 4) != 0) return error.UnsupportedOperation;

    if (tile.splits > 1 and dims.batch != 1) return error.UnsupportedOperation;
    if (tile.splits > 1 and dims.k % tile.splits != 0) return error.UnsupportedOperation;
    const split_chunk: u64 = dims.k / tile.splits;

    const tiles_m = dims.m / tile.bm;
    const tiles_n = dims.n / tile.bn;
    _ = try logical.index3D(.{
        .x = kernel_root.logical.axis("lane", @as(u64, tiles_n) * 32),
        .y = kernel_root.logical.axis("row", @as(u64, tiles_m) * tile.warps()),
        .z = kernel_root.logical.axis("batch", dims.batch * tile.splits),
    });

    const out = ctx.abi.output(logical);
    const lhs = ctx.abi.lhs(logical);
    const rhs = ctx.abi.rhs(logical);

    const a_pitch: i64 = @as(i64, tile.bk) + 4;
    const b_pitch: i64 = @as(i64, tile.bn) + 4;
    const tile_a = try logical.sharedBuffer(.f32, @as(u64, tile.bm) * @as(u64, @intCast(a_pitch)));
    const tile_b = try logical.sharedBuffer(.f32, @as(u64, tile.bk) * @as(u64, @intCast(b_pitch)));

    const lane = try logical.threadId(.x);
    const warp = try logical.threadId(.y);
    const bx = try logical.blockId(.x);
    const by = try logical.blockId(.y);
    const bz = try logical.blockId(.z);

    const k_extent = try logical.constantIndex(dims.k);
    const n_extent = try logical.constantIndex(dims.n);
    const a_pitch_extent = try logical.constantIndex(a_pitch);
    const b_pitch_extent = try logical.constantIndex(b_pitch);
    const four = try logical.constantIndex(4);
    const eight = try logical.constantIndex(8);

    const zero_base = try logical.constantIndex(0);
    const lhs_base = if (tile.splits > 1)
        zero_base
    else
        try logical.mul(bz, try logical.constantIndex(@as(i64, dims.m) * dims.k));
    const rhs_base = if (tile.splits > 1)
        zero_base
    else
        try logical.mul(bz, try logical.constantIndex(@as(i64, dims.k) * dims.n));
    const out_base = if (tile.splits > 1)
        zero_base
    else
        try logical.mul(bz, try logical.constantIndex(@as(i64, dims.m) * dims.n));
    const split_lower = if (tile.splits > 1)
        try logical.mul(bz, try logical.constantIndex(@as(i64, @intCast(split_chunk))))
    else
        zero_base;
    const split_upper = if (tile.splits > 1)
        try logical.add(split_lower, try logical.constantIndex(@as(i64, @intCast(split_chunk))))
    else
        k_extent;

    const row_block = try logical.mul(by, try logical.constantIndex(tile.bm));
    const col_block = try logical.mul(bx, try logical.constantIndex(tile.bn));

    const group = try logical.div(lane, four);
    const tid = try logical.sub(lane, try logical.mul(group, four));
    const group_hi = try logical.add(group, eight);
    const tid_hi = try logical.add(tid, four);
    const warps_n_extent = try logical.constantIndex(tile.warps_n);
    const warp_m = try logical.div(warp, warps_n_extent);
    const warp_n = try logical.sub(warp, try logical.mul(warp_m, warps_n_extent));
    const thread_id = try logical.add(try logical.mul(warp, try logical.constantIndex(32)), lane);

    const warp_row = try logical.mul(warp_m, try logical.constantIndex(tile.warpTileM()));
    const warp_col = try logical.mul(warp_n, try logical.constantIndex(tile.warpTileN()));

    const zero_scalar = try logical.constantFloat(.f32, 0.0);
    var init_args: [max_block_tile_accumulators]kernel_root.Value = undefined;
    var result_types: [max_block_tile_accumulators]kernel_root.Type = undefined;
    for (init_args[0..accumulator_count], result_types[0..accumulator_count]) |*arg, *ty_slot| {
        arg.* = zero_scalar;
        ty_slot.* = zero_scalar.valueType();
    }

    const stage_ctx = MmaStageContext{
        .tile = tile,
        .threads = threads,
        .thread_id = thread_id,
        .row_block = row_block,
        .col_block = col_block,
        .lhs = lhs,
        .rhs = rhs,
        .a_pitch_extent = a_pitch_extent,
        .b_pitch_extent = b_pitch_extent,
        .n_extent = n_extent,
        .k_extent = k_extent,
        .lhs_base = lhs_base,
        .rhs_base = rhs_base,
        .four = four,
    };
    var slice_ctx = MmaSliceContext{
        .m_frags = m_frags,
        .n_frags = n_frags,
        .k_steps = k_steps,
        .a_pitch_extent = a_pitch_extent,
        .b_pitch_extent = b_pitch_extent,
        .warp_row = warp_row,
        .warp_col = warp_col,
        .group = group,
        .group_hi = group_hi,
        .tid = tid,
        .tid_hi = tid_hi,
        .round_frags = false,
    };

    const multistage = tile.splits == 1 and tile.stages > 2 and
        tile.stages <= max_pipeline_stages and
        split_chunk % (@as(u64, tile.stages) * tile.bk) == 0 and
        split_chunk >= 3 * @as(u64, tile.stages) * tile.bk;
    const double_buffered = !multistage and tile.stages >= 2 and
        split_chunk % (2 * @as(u64, tile.bk)) == 0 and split_chunk >= 4 * @as(u64, tile.bk);
    const loop_lower = split_lower;

    if (multistage) {
        slice_ctx.round_frags = true;
        const stage_count = tile.stages;
        var slots_a: [max_pipeline_stages]kernel_root.Value = undefined;
        var slots_b: [max_pipeline_stages]kernel_root.Value = undefined;
        slots_a[0] = tile_a;
        slots_b[0] = tile_b;
        var slot: u32 = 1;
        while (slot < stage_count) : (slot += 1) {
            slots_a[slot] = try logical.sharedBuffer(
                .f32,
                @as(u64, tile.bm) * @as(u64, @intCast(a_pitch)),
            );
            slots_b[slot] = try logical.sharedBuffer(
                .f32,
                @as(u64, tile.bk) * @as(u64, @intCast(b_pitch)),
            );
        }
        slot = 0;
        while (slot + 1 < stage_count) : (slot += 1) {
            const k_stage = try logical.constantIndex(@as(i64, slot) * tile.bk);
            try stageMmaTilesAsync(
                logical,
                stage_ctx,
                k_stage,
                slots_a[slot],
                slots_b[slot],
                false,
            );
            try logical.asyncCopyCommit();
        }

        const loop_step = try logical.constantIndex(@as(i64, stage_count) * tile.bk);
        var scope = try logical.forScope(
            loop_lower,
            split_upper,
            loop_step,
            init_args[0..accumulator_count],
            result_types[0..accumulator_count],
        );
        errdefer scope.abort();
        const k0 = scope.inductionVar();

        var accumulators: [max_block_tile_accumulators]kernel_root.Value = undefined;
        for (accumulators[0..accumulator_count], 0..) |*accumulator, index| {
            accumulator.* = scope.iterArg(index) orelse return error.UnsupportedOperation;
        }

        var sub: u32 = 0;
        while (sub < stage_count) : (sub += 1) {
            try logical.asyncCopyWait(stage_count - 2);
            try logical.barrier(.block);
            const k_ahead = try logical.add(k0, try logical.constantIndex(
                (@as(i64, sub) + @as(i64, stage_count) - 1) * tile.bk,
            ));
            const write_slot = (sub + stage_count - 1) % stage_count;
            try stageMmaTilesAsync(
                logical,
                stage_ctx,
                k_ahead,
                slots_a[write_slot],
                slots_b[write_slot],
                true,
            );
            try logical.asyncCopyCommit();
            try emitMmaComputeSlice(
                logical,
                slice_ctx,
                slots_a[sub],
                slots_b[sub],
                accumulators[0..accumulator_count],
            );
        }
        try scope.leave(accumulators[0..accumulator_count]);
        try emitMmaEpilogue(logical, ctx, &scope, accumulator_count, .{
            .m_frags = m_frags,
            .n_frags = n_frags,
            .splits = tile.splits,
            .out = out,
            .out_base = out_base,
            .row_block = row_block,
            .col_block = col_block,
            .warp_row = warp_row,
            .warp_col = warp_col,
            .group = group,
            .group_hi = group_hi,
            .tid = tid,
            .n_extent = n_extent,
        });
        return;
    }

    if (double_buffered) {
        slice_ctx.round_frags = true;
        const tile_a_next = try logical.sharedBuffer(
            .f32,
            @as(u64, tile.bm) * @as(u64, @intCast(a_pitch)),
        );
        const tile_b_next = try logical.sharedBuffer(
            .f32,
            @as(u64, tile.bk) * @as(u64, @intCast(b_pitch)),
        );
        const bk_extent = try logical.constantIndex(tile.bk);

        try stageMmaTilesAsync(logical, stage_ctx, loop_lower, tile_a, tile_b, false);
        try logical.asyncCopyCommit();

        const loop_step = try logical.constantIndex(2 * @as(i64, tile.bk));
        var scope = try logical.forScope(
            loop_lower,
            split_upper,
            loop_step,
            init_args[0..accumulator_count],
            result_types[0..accumulator_count],
        );
        errdefer scope.abort();
        const k0 = scope.inductionVar();

        var accumulators: [max_block_tile_accumulators]kernel_root.Value = undefined;
        for (accumulators[0..accumulator_count], 0..) |*accumulator, index| {
            accumulator.* = scope.iterArg(index) orelse return error.UnsupportedOperation;
        }

        try logical.barrier(.block);
        const k_ahead = try logical.add(k0, bk_extent);
        try stageMmaTilesAsync(logical, stage_ctx, k_ahead, tile_a_next, tile_b_next, false);
        try logical.asyncCopyCommit();
        try logical.asyncCopyWait(1);
        try logical.barrier(.block);
        try emitMmaComputeSlice(
            logical,
            slice_ctx,
            tile_a,
            tile_b,
            accumulators[0..accumulator_count],
        );
        try logical.barrier(.block);
        const k_wrap = try logical.add(k0, try logical.constantIndex(2 * @as(i64, tile.bk)));
        try stageMmaTilesAsync(logical, stage_ctx, k_wrap, tile_a, tile_b, true);
        try logical.asyncCopyCommit();
        try logical.asyncCopyWait(1);
        try logical.barrier(.block);
        try emitMmaComputeSlice(
            logical,
            slice_ctx,
            tile_a_next,
            tile_b_next,
            accumulators[0..accumulator_count],
        );
        try scope.leave(accumulators[0..accumulator_count]);
        try emitMmaEpilogue(logical, ctx, &scope, accumulator_count, .{
            .m_frags = m_frags,
            .n_frags = n_frags,
            .splits = tile.splits,
            .out = out,
            .out_base = out_base,
            .row_block = row_block,
            .col_block = col_block,
            .warp_row = warp_row,
            .warp_col = warp_col,
            .group = group,
            .group_hi = group_hi,
            .tid = tid,
            .n_extent = n_extent,
        });
        return;
    }

    const loop_step = try logical.constantIndex(tile.bk);
    var scope = try logical.forScope(
        loop_lower,
        split_upper,
        loop_step,
        init_args[0..accumulator_count],
        result_types[0..accumulator_count],
    );
    errdefer scope.abort();
    const k0 = scope.inductionVar();

    try logical.barrier(.block);
    try stageMmaTiles(logical, stage_ctx, k0, tile_a, tile_b, false);
    try logical.barrier(.block);

    var accumulators: [max_block_tile_accumulators]kernel_root.Value = undefined;
    for (accumulators[0..accumulator_count], 0..) |*accumulator, index| {
        accumulator.* = scope.iterArg(index) orelse return error.UnsupportedOperation;
    }

    try emitMmaComputeSlice(logical, slice_ctx, tile_a, tile_b, accumulators[0..accumulator_count]);

    try scope.leave(accumulators[0..accumulator_count]);

    try emitMmaEpilogue(logical, ctx, &scope, accumulator_count, .{
        .m_frags = m_frags,
        .n_frags = n_frags,
        .splits = tile.splits,
        .out = out,
        .out_base = out_base,
        .row_block = row_block,
        .col_block = col_block,
        .warp_row = warp_row,
        .warp_col = warp_col,
        .group = group,
        .group_hi = group_hi,
        .tid = tid,
        .n_extent = n_extent,
    });
}

const MmaStageContext = struct {
    tile: kernelization_model.DotGeneralMmaTile,
    threads: u32,
    thread_id: kernel_root.Value,
    row_block: kernel_root.Value,
    col_block: kernel_root.Value,
    lhs: kernel_root.Value,
    rhs: kernel_root.Value,
    a_pitch_extent: kernel_root.Value,
    b_pitch_extent: kernel_root.Value,
    n_extent: kernel_root.Value,
    k_extent: kernel_root.Value,
    lhs_base: kernel_root.Value,
    rhs_base: kernel_root.Value,
    four: kernel_root.Value,
};

fn stageMmaTiles(
    logical: anytype,
    ctx: MmaStageContext,
    k_slice: kernel_root.Value,
    tile_a: kernel_root.Value,
    tile_b: kernel_root.Value,
    clamp: bool,
) !void {
    const tile = ctx.tile;
    const threads = ctx.threads;
    const k_quad_limit = try logical.sub(ctx.k_extent, ctx.four);
    const k_row_limit = try logical.sub(ctx.k_extent, try logical.constantIndex(1));

    const a_quads_per_thread = (tile.bm * tile.bk) / (threads * 4);
    const a_quads_per_row = tile.bk / 4;
    var quad: u32 = 0;
    while (quad < a_quads_per_thread) : (quad += 1) {
        const flat = try logical.add(
            ctx.thread_id,
            try logical.constantIndex(@as(i64, quad) * threads),
        );
        const quads_per_row_extent = try logical.constantIndex(a_quads_per_row);
        const local_row = try logical.div(flat, quads_per_row_extent);
        const quad_in_row = try logical.sub(flat, try logical.mul(local_row, quads_per_row_extent));
        const local_k = try logical.mul(quad_in_row, ctx.four);
        const global_row = try logical.add(ctx.row_block, local_row);
        var global_k = try logical.add(k_slice, local_k);
        if (clamp) global_k = try logical.min(global_k, k_quad_limit);
        const global_index = try logical.add(
            try logical.add(ctx.lhs_base, try logical.mul(global_row, ctx.k_extent)),
            global_k,
        );
        const quad_value = try logical.loadVector(ctx.lhs, global_index, 4);
        const shared_base = try logical.add(
            try logical.mul(local_row, ctx.a_pitch_extent),
            local_k,
        );
        var lane_index: u32 = 0;
        while (lane_index < 4) : (lane_index += 1) {
            const scalar = try logical.extractLane(quad_value, lane_index, .f32);
            const rounded = try logical.tf32Round(scalar);
            const shared_index = try logical.add(
                shared_base,
                try logical.constantIndex(lane_index),
            );
            try logical.storeIndex(rounded, tile_a, shared_index);
        }
    }

    const b_quads_per_thread = (tile.bk * tile.bn) / (threads * 4);
    const b_quads_per_row = tile.bn / 4;
    quad = 0;
    while (quad < b_quads_per_thread) : (quad += 1) {
        const flat = try logical.add(
            ctx.thread_id,
            try logical.constantIndex(@as(i64, quad) * threads),
        );
        const quads_per_row_extent = try logical.constantIndex(b_quads_per_row);
        const local_k = try logical.div(flat, quads_per_row_extent);
        const quad_in_row = try logical.sub(flat, try logical.mul(local_k, quads_per_row_extent));
        const local_col = try logical.mul(quad_in_row, ctx.four);
        var global_k = try logical.add(k_slice, local_k);
        if (clamp) global_k = try logical.min(global_k, k_row_limit);
        const global_col = try logical.add(ctx.col_block, local_col);
        const global_index = try logical.add(
            try logical.add(ctx.rhs_base, try logical.mul(global_k, ctx.n_extent)),
            global_col,
        );
        const quad_value = try logical.loadVector(ctx.rhs, global_index, 4);
        const shared_base = try logical.add(
            try logical.mul(local_k, ctx.b_pitch_extent),
            local_col,
        );
        var lane_index: u32 = 0;
        while (lane_index < 4) : (lane_index += 1) {
            const scalar = try logical.extractLane(quad_value, lane_index, .f32);
            const rounded = try logical.tf32Round(scalar);
            const shared_index = try logical.add(
                shared_base,
                try logical.constantIndex(lane_index),
            );
            try logical.storeIndex(rounded, tile_b, shared_index);
        }
    }
}

fn stageMmaTilesAsync(
    logical: anytype,
    ctx: MmaStageContext,
    k_slice: kernel_root.Value,
    tile_a: kernel_root.Value,
    tile_b: kernel_root.Value,
    clamp: bool,
) !void {
    const tile = ctx.tile;
    const threads = ctx.threads;
    const k_quad_limit = try logical.sub(ctx.k_extent, ctx.four);
    const k_row_limit = try logical.sub(ctx.k_extent, try logical.constantIndex(1));

    const a_quads_per_thread = (tile.bm * tile.bk) / (threads * 4);
    const a_quads_per_row = tile.bk / 4;
    var quad: u32 = 0;
    while (quad < a_quads_per_thread) : (quad += 1) {
        const flat = try logical.add(
            ctx.thread_id,
            try logical.constantIndex(@as(i64, quad) * threads),
        );
        const quads_per_row_extent = try logical.constantIndex(a_quads_per_row);
        const local_row = try logical.div(flat, quads_per_row_extent);
        const quad_in_row = try logical.sub(flat, try logical.mul(local_row, quads_per_row_extent));
        const local_k = try logical.mul(quad_in_row, ctx.four);
        const global_row = try logical.add(ctx.row_block, local_row);
        var global_k = try logical.add(k_slice, local_k);
        if (clamp) global_k = try logical.min(global_k, k_quad_limit);
        const global_index = try logical.add(
            try logical.add(ctx.lhs_base, try logical.mul(global_row, ctx.k_extent)),
            global_k,
        );
        const shared_base = try logical.add(
            try logical.mul(local_row, ctx.a_pitch_extent),
            local_k,
        );
        try logical.asyncCopyShared(tile_a, shared_base, ctx.lhs, global_index, 16);
    }

    const b_quads_per_thread = (tile.bk * tile.bn) / (threads * 4);
    const b_quads_per_row = tile.bn / 4;
    quad = 0;
    while (quad < b_quads_per_thread) : (quad += 1) {
        const flat = try logical.add(
            ctx.thread_id,
            try logical.constantIndex(@as(i64, quad) * threads),
        );
        const quads_per_row_extent = try logical.constantIndex(b_quads_per_row);
        const local_k = try logical.div(flat, quads_per_row_extent);
        const quad_in_row = try logical.sub(flat, try logical.mul(local_k, quads_per_row_extent));
        const local_col = try logical.mul(quad_in_row, ctx.four);
        var global_k = try logical.add(k_slice, local_k);
        if (clamp) global_k = try logical.min(global_k, k_row_limit);
        const global_col = try logical.add(ctx.col_block, local_col);
        const global_index = try logical.add(
            try logical.add(ctx.rhs_base, try logical.mul(global_k, ctx.n_extent)),
            global_col,
        );
        const shared_base = try logical.add(
            try logical.mul(local_k, ctx.b_pitch_extent),
            local_col,
        );
        try logical.asyncCopyShared(tile_b, shared_base, ctx.rhs, global_index, 16);
    }
}

const MmaSliceContext = struct {
    m_frags: u32,
    n_frags: u32,
    k_steps: u32,
    a_pitch_extent: kernel_root.Value,
    b_pitch_extent: kernel_root.Value,
    warp_row: kernel_root.Value,
    warp_col: kernel_root.Value,
    group: kernel_root.Value,
    group_hi: kernel_root.Value,
    tid: kernel_root.Value,
    tid_hi: kernel_root.Value,
    round_frags: bool,
};

fn mmaFragValue(
    logical: anytype,
    ctx: MmaSliceContext,
    buffer: kernel_root.Value,
    index: kernel_root.Value,
) !kernel_root.Value {
    const loaded = try logical.loadIndex(buffer, index);
    if (!ctx.round_frags) return loaded;
    return logical.tf32Round(loaded);
}

fn emitMmaComputeSlice(
    logical: anytype,
    ctx: MmaSliceContext,
    tile_a: kernel_root.Value,
    tile_b: kernel_root.Value,
    accumulators: []kernel_root.Value,
) !void {
    const m_frags = ctx.m_frags;
    const n_frags = ctx.n_frags;
    var step: u32 = 0;
    while (step < ctx.k_steps) : (step += 1) {
        const kk = try logical.constantIndex(@as(i64, step) * mma_shape.k);
        const col_lo = try logical.add(kk, ctx.tid);
        const col_hi = try logical.add(kk, ctx.tid_hi);

        var a_frags: [max_mma_fragments][4]kernel_root.Value = undefined;
        var mf: u32 = 0;
        while (mf < m_frags) : (mf += 1) {
            const frag_row = try logical.add(
                ctx.warp_row,
                try logical.constantIndex(@as(i64, mf) * mma_shape.m),
            );
            const row_lo = try logical.mul(
                try logical.add(frag_row, ctx.group),
                ctx.a_pitch_extent,
            );
            const row_hi = try logical.mul(
                try logical.add(frag_row, ctx.group_hi),
                ctx.a_pitch_extent,
            );
            a_frags[mf] = .{
                try mmaFragValue(logical, ctx, tile_a, try logical.add(row_lo, col_lo)),
                try mmaFragValue(logical, ctx, tile_a, try logical.add(row_hi, col_lo)),
                try mmaFragValue(logical, ctx, tile_a, try logical.add(row_lo, col_hi)),
                try mmaFragValue(logical, ctx, tile_a, try logical.add(row_hi, col_hi)),
            };
        }

        const k_row_lo = try logical.mul(col_lo, ctx.b_pitch_extent);
        const k_row_hi = try logical.mul(col_hi, ctx.b_pitch_extent);
        var b_frags: [max_mma_fragments][2]kernel_root.Value = undefined;
        var nf: u32 = 0;
        while (nf < n_frags) : (nf += 1) {
            const frag_col = try logical.add(
                ctx.warp_col,
                try logical.constantIndex(@as(i64, nf) * mma_shape.n),
            );
            const col_offset = try logical.add(frag_col, ctx.group);
            b_frags[nf] = .{
                try mmaFragValue(logical, ctx, tile_b, try logical.add(k_row_lo, col_offset)),
                try mmaFragValue(logical, ctx, tile_b, try logical.add(k_row_hi, col_offset)),
            };
        }

        mf = 0;
        while (mf < m_frags) : (mf += 1) {
            nf = 0;
            while (nf < n_frags) : (nf += 1) {
                const slot = (@as(usize, mf) * n_frags + nf) * mma_lane_acc_count;
                const updated = try logical.mmaSync(mma_shape, a_frags[mf], b_frags[nf], .{
                    accumulators[slot],
                    accumulators[slot + 1],
                    accumulators[slot + 2],
                    accumulators[slot + 3],
                });
                accumulators[slot] = updated[0];
                accumulators[slot + 1] = updated[1];
                accumulators[slot + 2] = updated[2];
                accumulators[slot + 3] = updated[3];
            }
        }
    }
}

const MmaEpilogueContext = struct {
    m_frags: u32,
    n_frags: u32,
    splits: u32 = 1,
    out: kernel_root.Value,
    out_base: kernel_root.Value,
    row_block: kernel_root.Value,
    col_block: kernel_root.Value,
    warp_row: kernel_root.Value,
    warp_col: kernel_root.Value,
    group: kernel_root.Value,
    group_hi: kernel_root.Value,
    tid: kernel_root.Value,
    n_extent: kernel_root.Value,
};

fn emitMmaEpilogue(
    logical: anytype,
    ctx: anytype,
    scope: anytype,
    accumulator_count: usize,
    epi: MmaEpilogueContext,
) !void {
    var results: [max_block_tile_accumulators]kernel_root.Value = undefined;
    for (results[0..accumulator_count], 0..) |*result, index| {
        result.* = scope.result(index) orelse return error.UnsupportedOperation;
    }

    const two = try logical.constantIndex(2);
    const one = try logical.constantIndex(1);
    const tid2 = try logical.mul(epi.tid, two);
    var mf: u32 = 0;
    while (mf < epi.m_frags) : (mf += 1) {
        const frag_row = try logical.add(
            epi.row_block,
            try logical.add(epi.warp_row, try logical.constantIndex(@as(i64, mf) * mma_shape.m)),
        );
        const row_lo = try logical.add(frag_row, epi.group);
        const row_hi = try logical.add(frag_row, epi.group_hi);
        const row_lo_offset = try logical.add(epi.out_base, try logical.mul(row_lo, epi.n_extent));
        const row_hi_offset = try logical.add(epi.out_base, try logical.mul(row_hi, epi.n_extent));
        var nf: u32 = 0;
        while (nf < epi.n_frags) : (nf += 1) {
            const frag_col = try logical.add(epi.col_block, try logical.add(
                epi.warp_col,
                try logical.constantIndex(@as(i64, nf) * mma_shape.n),
            ));
            const col_lo = try logical.add(frag_col, tid2);
            const col_hi = try logical.add(col_lo, one);
            const slot = (@as(usize, mf) * epi.n_frags + nf) * mma_lane_acc_count;
            const addresses = [mma_lane_acc_count]kernel_root.Value{
                try logical.add(row_lo_offset, col_lo),
                try logical.add(row_lo_offset, col_hi),
                try logical.add(row_hi_offset, col_lo),
                try logical.add(row_hi_offset, col_hi),
            };
            for (addresses, 0..) |address, acc_index| {
                const value = try applyEpilogueChain(
                    logical,
                    ctx.epilogue,
                    ctx.abi,
                    results[slot + acc_index],
                    address,
                );
                if (epi.splits > 1) {
                    _ = try logical.atomicRmw(.add, value, epi.out, address);
                } else {
                    try logical.storeIndex(value, epi.out, address);
                }
            }
        }
    }
}

fn tiledDotVectorizable(
    tile: kernelization_model.DotGeneralBlockTile,
    dims: DotGeneralStaticDims,
) bool {
    if (!tile.exact(dims)) return false;
    if (dims.k % 4 != 0 or dims.n % 4 != 0) return false;
    if (tile.bk % 4 != 0 or tile.bn % 4 != 0) return false;
    if (tile.tm % 4 != 0 or tile.tn % 4 != 0) return false;
    const threads = tile.threadsX() * tile.threadsY();
    if ((tile.bm * tile.bk) % (threads * 4) != 0) return false;
    if ((tile.bk * tile.bn) % 4 != 0) return false;
    return true;
}

fn emitTiledDotBody(logical: anytype, ctx: anytype) !void {
    const tile: kernelization_model.DotGeneralBlockTile = ctx.tile;
    const dims: DotGeneralStaticDims = ctx.dims;
    const exact = tile.exact(dims);
    if (tile.tm * tile.tn > max_block_tile_accumulators) return error.UnsupportedOperation;
    if (tile.tm > max_block_tile_fragments or tile.tn > max_block_tile_fragments) {
        return error.UnsupportedOperation;
    }
    const staging_threads = tile.threadsX() * tile.threadsY();
    if ((tile.bm * tile.bk) % staging_threads != 0) return error.UnsupportedOperation;
    if ((tile.bk * tile.bn) % staging_threads != 0) return error.UnsupportedOperation;
    if (tile.splits > 1 and dims.batch != 1) return error.UnsupportedOperation;
    if (tile.splits > 1 and dims.k % tile.splits != 0) return error.UnsupportedOperation;
    const split_chunk: u64 = dims.k / tile.splits;
    const vectorized = tiledDotVectorizable(tile, dims);
    const multistage = vectorized and tile.stages > 2 and tile.stages <= max_pipeline_stages and
        split_chunk % (@as(u64, tile.stages) * tile.bk) == 0 and
        split_chunk >= 3 * @as(u64, tile.stages) * tile.bk;
    const double_buffered = !multistage and vectorized and
        split_chunk % (2 * tile.bk) == 0 and split_chunk >= 4 * tile.bk;

    const tiles_m = (dims.m + tile.bm - 1) / tile.bm;
    const tiles_n = (dims.n + tile.bn - 1) / tile.bn;
    _ = try logical.index3D(.{
        .x = kernel_root.logical.axis("lane", @as(u64, tiles_n) * tile.threadsX()),
        .y = kernel_root.logical.axis("row", @as(u64, tiles_m) * tile.threadsY()),
        .z = kernel_root.logical.axis("batch", dims.batch * tile.splits),
    });

    const out = ctx.abi.output(logical);
    const lhs = ctx.abi.lhs(logical);
    const rhs = ctx.abi.rhs(logical);

    const a_pitch: i64 = @as(i64, tile.bm) + if (vectorized) @as(i64, 4) else @as(i64, 1);
    const tile_a = try logical.sharedBuffer(.f32, @as(u64, tile.bk) * @as(u64, @intCast(a_pitch)));
    const tile_b = try logical.sharedBuffer(.f32, @as(u64, tile.bk) * tile.bn);
    const tile_a_next = if (double_buffered)
        try logical.sharedBuffer(.f32, @as(u64, tile.bk) * @as(u64, @intCast(a_pitch)))
    else
        tile_a;
    const tile_b_next = if (double_buffered)
        try logical.sharedBuffer(.f32, @as(u64, tile.bk) * tile.bn)
    else
        tile_b;

    const tx = try logical.threadId(.x);
    const ty = try logical.threadId(.y);
    const bx = try logical.blockId(.x);
    const by = try logical.blockId(.y);
    const bz = try logical.blockId(.z);

    const m_edge = try logical.constantIndex(@as(i64, dims.m) - 1);
    const n_edge = try logical.constantIndex(@as(i64, dims.n) - 1);
    const k_edge = try logical.constantIndex(@as(i64, dims.k) - 1);
    const m_extent = try logical.constantIndex(dims.m);
    const n_extent = try logical.constantIndex(dims.n);
    const k_extent = try logical.constantIndex(dims.k);

    const zero_index = try logical.constantIndex(0);
    const lhs_base = if (tile.splits > 1)
        zero_index
    else
        try logical.mul(bz, try logical.constantIndex(@as(i64, dims.m) * dims.k));
    const rhs_base = if (tile.splits > 1)
        zero_index
    else
        try logical.mul(bz, try logical.constantIndex(@as(i64, dims.k) * dims.n));
    const out_base = if (tile.splits > 1)
        zero_index
    else
        try logical.mul(bz, try logical.constantIndex(@as(i64, dims.m) * dims.n));
    const split_lower = if (tile.splits > 1)
        try logical.mul(bz, try logical.constantIndex(@as(i64, @intCast(split_chunk))))
    else
        zero_index;
    const split_upper = if (tile.splits > 1)
        try logical.add(split_lower, try logical.constantIndex(@as(i64, @intCast(split_chunk))))
    else
        k_extent;

    const row_block = try logical.mul(by, try logical.constantIndex(tile.bm));
    const col_block = try logical.mul(bx, try logical.constantIndex(tile.bn));
    const row_local = try logical.mul(ty, try logical.constantIndex(if (vectorized)
        4
    else
        @as(i64, tile.tm)));
    const col_local = try logical.mul(tx, try logical.constantIndex(if (vectorized)
        4
    else
        @as(i64, tile.tn)));
    const row_base = try logical.add(row_block, row_local);
    const col_base = try logical.add(col_block, col_local);

    const threads = staging_threads;
    const thread_id = try logical.add(
        try logical.mul(ty, try logical.constantIndex(tile.threadsX())),
        tx,
    );
    const a_pitch_extent = try logical.constantIndex(a_pitch);
    const bk_extent = try logical.constantIndex(tile.bk);
    const bn_extent = try logical.constantIndex(tile.bn);

    const stage_ctx = StageContext{
        .tile = tile,
        .threads = threads,
        .thread_id = thread_id,
        .row_block = row_block,
        .col_block = col_block,
        .lhs = lhs,
        .rhs = rhs,
        .a_pitch_extent = a_pitch_extent,
        .bn_extent = bn_extent,
        .n_extent = n_extent,
        .k_extent = k_extent,
        .lhs_base = lhs_base,
        .rhs_base = rhs_base,
    };
    const slice_ctx = SliceContext{
        .tile = tile,
        .a_pitch = a_pitch,
        .row_local = row_local,
        .col_local = col_local,
    };

    const zero_scalar = try logical.constantFloat(.f32, 0.0);
    var init_args: [max_block_tile_accumulators]kernel_root.Value = undefined;
    var result_types: [max_block_tile_accumulators]kernel_root.Type = undefined;
    const accumulator_count: usize = @intCast(tile.tm * tile.tn);
    for (init_args[0..accumulator_count], result_types[0..accumulator_count]) |*arg, *ty_slot| {
        arg.* = zero_scalar;
        ty_slot.* = zero_scalar.valueType();
    }

    if (multistage) {
        const stage_count = tile.stages;
        var slots_a: [max_pipeline_stages]kernel_root.Value = undefined;
        var slots_b: [max_pipeline_stages]kernel_root.Value = undefined;
        slots_a[0] = tile_a;
        slots_b[0] = tile_b;
        var slot: u32 = 1;
        while (slot < stage_count) : (slot += 1) {
            slots_a[slot] = try logical.sharedBuffer(
                .f32,
                @as(u64, tile.bk) * @as(u64, @intCast(a_pitch)),
            );
            slots_b[slot] = try logical.sharedBuffer(.f32, @as(u64, tile.bk) * tile.bn);
        }
        slot = 0;
        while (slot + 1 < stage_count) : (slot += 1) {
            const k_stage = try logical.add(
                split_lower,
                try logical.constantIndex(@as(i64, slot) * tile.bk),
            );
            try stageBTileAsync(logical, stage_ctx, k_stage, slots_b[slot], false);
            try logical.asyncCopyCommit();
            const staged = try loadATileQuads(logical, stage_ctx, k_stage, false);
            try storeATileQuads(logical, stage_ctx, staged, slots_a[slot]);
        }

        const loop_step = try logical.constantIndex(@as(i64, stage_count) * tile.bk);
        var scope = try logical.forScope(
            split_lower,
            split_upper,
            loop_step,
            init_args[0..accumulator_count],
            result_types[0..accumulator_count],
        );
        errdefer scope.abort();
        const k0 = scope.inductionVar();

        var accumulators: [max_block_tile_accumulators]kernel_root.Value = undefined;
        for (accumulators[0..accumulator_count], 0..) |*accumulator, index| {
            accumulator.* = scope.iterArg(index) orelse return error.UnsupportedOperation;
        }

        var sub: u32 = 0;
        while (sub < stage_count) : (sub += 1) {
            try logical.asyncCopyWait(stage_count - 2);
            try logical.barrier(.block);
            const k_ahead = try logical.add(k0, try logical.constantIndex(
                (@as(i64, sub) + @as(i64, stage_count) - 1) * tile.bk,
            ));
            const write_slot = (sub + stage_count - 1) % stage_count;
            try stageBTileAsync(logical, stage_ctx, k_ahead, slots_b[write_slot], true);
            try logical.asyncCopyCommit();
            const staged = try loadATileQuads(logical, stage_ctx, k_ahead, true);
            try emitComputeSlice(
                logical,
                slice_ctx,
                slots_a[sub],
                slots_b[sub],
                accumulators[0..accumulator_count],
                true,
            );
            try storeATileQuads(logical, stage_ctx, staged, slots_a[write_slot]);
        }
        try scope.leave(accumulators[0..accumulator_count]);
        try emitTiledEpilogue(
            logical,
            ctx,
            &scope,
            accumulator_count,
            out,
            out_base,
            row_base,
            col_base,
            m_extent,
            n_extent,
            exact,
            true,
        );
        return;
    }

    if (double_buffered) {
        try stageBTileAsync(logical, stage_ctx, split_lower, tile_b, false);
        try logical.asyncCopyCommit();
        const prologue_quads = try loadATileQuads(logical, stage_ctx, split_lower, false);
        try storeATileQuads(logical, stage_ctx, prologue_quads, tile_a);

        const loop_step = try logical.constantIndex(2 * @as(i64, tile.bk));
        var scope = try logical.forScope(
            split_lower,
            split_upper,
            loop_step,
            init_args[0..accumulator_count],
            result_types[0..accumulator_count],
        );
        errdefer scope.abort();
        const k0 = scope.inductionVar();

        var accumulators: [max_block_tile_accumulators]kernel_root.Value = undefined;
        for (accumulators[0..accumulator_count], 0..) |*accumulator, index| {
            accumulator.* = scope.iterArg(index) orelse return error.UnsupportedOperation;
        }

        try logical.barrier(.block);
        const k_ahead = try logical.add(k0, bk_extent);
        try stageBTileAsync(logical, stage_ctx, k_ahead, tile_b_next, false);
        try logical.asyncCopyCommit();
        const quads_ahead = try loadATileQuads(logical, stage_ctx, k_ahead, false);
        try logical.asyncCopyWait(1);
        try logical.barrier(.block);
        try emitComputeSlice(
            logical,
            slice_ctx,
            tile_a,
            tile_b,
            accumulators[0..accumulator_count],
            true,
        );
        try logical.barrier(.block);
        const k_wrap = try logical.add(k0, try logical.constantIndex(2 * @as(i64, tile.bk)));
        try stageBTileAsync(logical, stage_ctx, k_wrap, tile_b, true);
        try logical.asyncCopyCommit();
        const quads_wrap = try loadATileQuads(logical, stage_ctx, k_wrap, true);
        try storeATileQuads(logical, stage_ctx, quads_ahead, tile_a_next);
        try logical.asyncCopyWait(1);
        try logical.barrier(.block);
        try emitComputeSlice(
            logical,
            slice_ctx,
            tile_a_next,
            tile_b_next,
            accumulators[0..accumulator_count],
            true,
        );
        try storeATileQuads(logical, stage_ctx, quads_wrap, tile_a);
        try scope.leave(accumulators[0..accumulator_count]);
        try emitTiledEpilogue(
            logical,
            ctx,
            &scope,
            accumulator_count,
            out,
            out_base,
            row_base,
            col_base,
            m_extent,
            n_extent,
            exact,
            true,
        );
        return;
    }

    const loop_step = try logical.constantIndex(tile.bk);
    var scope = try logical.forScope(
        split_lower,
        split_upper,
        loop_step,
        init_args[0..accumulator_count],
        result_types[0..accumulator_count],
    );
    errdefer scope.abort();
    const k0 = scope.inductionVar();

    if (vectorized) {
        try stageVectorized(logical, stage_ctx, k0, tile_a, tile_b, false);
    } else {
        try emitScalarStaging(logical, .{
            .tile = tile,
            .threads = threads,
            .thread_id = thread_id,
            .k0 = k0,
            .row_block = row_block,
            .col_block = col_block,
            .lhs = lhs,
            .rhs = rhs,
            .tile_a = tile_a,
            .tile_b = tile_b,
            .a_pitch_extent = a_pitch_extent,
            .bk_extent = bk_extent,
            .bn_extent = bn_extent,
            .m_edge = m_edge,
            .n_edge = n_edge,
            .k_edge = k_edge,
            .m_extent = m_extent,
            .n_extent = n_extent,
            .k_extent = k_extent,
            .lhs_base = lhs_base,
            .rhs_base = rhs_base,
            .zero_scalar = zero_scalar,
            .exact = exact,
        });
    }
    try logical.barrier(.block);

    var accumulators: [max_block_tile_accumulators]kernel_root.Value = undefined;
    for (accumulators[0..accumulator_count], 0..) |*accumulator, index| {
        accumulator.* = scope.iterArg(index) orelse return error.UnsupportedOperation;
    }

    try emitComputeSlice(
        logical,
        slice_ctx,
        tile_a,
        tile_b,
        accumulators[0..accumulator_count],
        vectorized,
    );
    try logical.barrier(.block);
    try scope.leave(accumulators[0..accumulator_count]);
    try emitTiledEpilogue(
        logical,
        ctx,
        &scope,
        accumulator_count,
        out,
        out_base,
        row_base,
        col_base,
        m_extent,
        n_extent,
        exact,
        vectorized,
    );
}

const StageContext = struct {
    tile: kernelization_model.DotGeneralBlockTile,
    threads: u32,
    thread_id: kernel_root.Value,
    row_block: kernel_root.Value,
    col_block: kernel_root.Value,
    lhs: kernel_root.Value,
    rhs: kernel_root.Value,
    a_pitch_extent: kernel_root.Value,
    bn_extent: kernel_root.Value,
    n_extent: kernel_root.Value,
    k_extent: kernel_root.Value,
    lhs_base: kernel_root.Value,
    rhs_base: kernel_root.Value,
};

const SliceContext = struct {
    tile: kernelization_model.DotGeneralBlockTile,
    a_pitch: i64,
    row_local: kernel_root.Value,
    col_local: kernel_root.Value,
};

fn load_partial_b_tile_quad(inner: anytype, guard_ctx: anytype) !void {
    const quad_value = try inner.loadVector(guard_ctx.rhs, guard_ctx.global_index, 4);
    try inner.storeIndex(quad_value, guard_ctx.tile_b, guard_ctx.shared_index);
}

fn stageVectorized(
    logical: anytype,
    ctx: StageContext,
    k_slice: kernel_root.Value,
    tile_a: kernel_root.Value,
    tile_b: kernel_root.Value,
    clamp: bool,
) !void {
    const tile = ctx.tile;
    const k_quad_limit = try logical.sub(ctx.k_extent, try logical.constantIndex(4));

    const a_quads_per_thread = (tile.bm * tile.bk) / (ctx.threads * 4);
    const a_quads_per_row = tile.bk / 4;
    var quad: u32 = 0;
    while (quad < a_quads_per_thread) : (quad += 1) {
        const flat = try logical.add(
            ctx.thread_id,
            try logical.constantIndex(@as(i64, quad) * ctx.threads),
        );
        const quads_per_row_extent = try logical.constantIndex(a_quads_per_row);
        const local_row = try logical.div(flat, quads_per_row_extent);
        const quad_in_row = try logical.sub(flat, try logical.mul(local_row, quads_per_row_extent));
        const local_k = try logical.mul(quad_in_row, try logical.constantIndex(4));
        const global_row = try logical.add(ctx.row_block, local_row);
        var global_k = try logical.add(k_slice, local_k);
        if (clamp) global_k = try logical.min(global_k, k_quad_limit);
        const global_index = try logical.add(
            try logical.add(ctx.lhs_base, try logical.mul(global_row, ctx.k_extent)),
            global_k,
        );
        const quad_value = try logical.loadVector(ctx.lhs, global_index, 4);
        var lane: u32 = 0;
        while (lane < 4) : (lane += 1) {
            const scalar = try logical.extractLane(quad_value, lane, .f32);
            const shared_row = try logical.add(local_k, try logical.constantIndex(lane));
            const shared_index = try logical.add(
                try logical.mul(shared_row, ctx.a_pitch_extent),
                local_row,
            );
            try logical.storeIndex(scalar, tile_a, shared_index);
        }
    }

    const total_b_quads = (tile.bk * tile.bn) / 4;
    const b_quads_per_row = tile.bn / 4;
    var issued: u32 = 0;
    quad = 0;
    while (issued < total_b_quads) : (quad += 1) {
        const pass_quads = @min(ctx.threads, total_b_quads - issued);
        const flat = try logical.add(
            ctx.thread_id,
            try logical.constantIndex(@as(i64, quad) * ctx.threads),
        );
        const quads_per_row_extent = try logical.constantIndex(b_quads_per_row);
        const local_k = try logical.div(flat, quads_per_row_extent);
        const quad_in_row = try logical.sub(flat, try logical.mul(local_k, quads_per_row_extent));
        const local_col = try logical.mul(quad_in_row, try logical.constantIndex(4));
        var global_k = try logical.add(k_slice, local_k);
        if (clamp) global_k = try logical.min(global_k, k_quad_limit);
        const global_col = try logical.add(ctx.col_block, local_col);
        const global_index = try logical.add(
            try logical.add(ctx.rhs_base, try logical.mul(global_k, ctx.n_extent)),
            global_col,
        );
        if (pass_quads == ctx.threads) {
            const quad_value = try logical.loadVector(ctx.rhs, global_index, 4);
            const shared_index = try logical.add(
                try logical.mul(local_k, ctx.bn_extent),
                local_col,
            );
            try logical.storeIndex(quad_value, tile_b, shared_index);
        } else {
            const shared_index = try logical.add(
                try logical.mul(local_k, ctx.bn_extent),
                local_col,
            );
            const in_pass = try logical.compare(
                .lt,
                flat,
                try logical.constantIndex(total_b_quads),
            );
            try logical.guardDo(in_pass, .{
                .tile_b = tile_b,
                .shared_index = shared_index,
                .rhs = ctx.rhs,
                .global_index = global_index,
            }, load_partial_b_tile_quad);
        }
        issued += pass_quads;
    }
}

const max_stage_quads = 4;
const max_pipeline_stages = 5;

const StagedQuads = struct {
    values: [max_stage_quads]kernel_root.Value,
    count: u32,
};

fn loadATileQuads(
    logical: anytype,
    ctx: StageContext,
    k_slice: kernel_root.Value,
    clamp: bool,
) !StagedQuads {
    const tile = ctx.tile;
    const k_quad_limit = try logical.sub(ctx.k_extent, try logical.constantIndex(4));
    const a_quads_per_thread = (tile.bm * tile.bk) / (ctx.threads * 4);
    const a_quads_per_row = tile.bk / 4;
    if (a_quads_per_thread > max_stage_quads) return error.UnsupportedOperation;
    var staged = StagedQuads{ .values = undefined, .count = a_quads_per_thread };
    var quad: u32 = 0;
    while (quad < a_quads_per_thread) : (quad += 1) {
        const flat = try logical.add(
            ctx.thread_id,
            try logical.constantIndex(@as(i64, quad) * ctx.threads),
        );
        const quads_per_row_extent = try logical.constantIndex(a_quads_per_row);
        const local_row = try logical.div(flat, quads_per_row_extent);
        const quad_in_row = try logical.sub(flat, try logical.mul(local_row, quads_per_row_extent));
        const local_k = try logical.mul(quad_in_row, try logical.constantIndex(4));
        const global_row = try logical.add(ctx.row_block, local_row);
        var global_k = try logical.add(k_slice, local_k);
        if (clamp) global_k = try logical.min(global_k, k_quad_limit);
        const global_index = try logical.add(
            try logical.add(ctx.lhs_base, try logical.mul(global_row, ctx.k_extent)),
            global_k,
        );
        staged.values[quad] = try logical.loadVector(ctx.lhs, global_index, 4);
    }
    return staged;
}

fn storeATileQuads(
    logical: anytype,
    ctx: StageContext,
    staged: StagedQuads,
    tile_a: kernel_root.Value,
) !void {
    const tile = ctx.tile;
    const a_quads_per_row = tile.bk / 4;
    var quad: u32 = 0;
    while (quad < staged.count) : (quad += 1) {
        const flat = try logical.add(
            ctx.thread_id,
            try logical.constantIndex(@as(i64, quad) * ctx.threads),
        );
        const quads_per_row_extent = try logical.constantIndex(a_quads_per_row);
        const local_row = try logical.div(flat, quads_per_row_extent);
        const quad_in_row = try logical.sub(flat, try logical.mul(local_row, quads_per_row_extent));
        const local_k = try logical.mul(quad_in_row, try logical.constantIndex(4));
        var lane: u32 = 0;
        while (lane < 4) : (lane += 1) {
            const scalar = try logical.extractLane(staged.values[quad], lane, .f32);
            const shared_row = try logical.add(local_k, try logical.constantIndex(lane));
            const shared_index = try logical.add(
                try logical.mul(shared_row, ctx.a_pitch_extent),
                local_row,
            );
            try logical.storeIndex(scalar, tile_a, shared_index);
        }
    }
}

fn copy_partial_b_tile_quad(inner: anytype, guard_ctx: anytype) !void {
    try inner.asyncCopyShared(
        guard_ctx.tile_b,
        guard_ctx.shared_index,
        guard_ctx.rhs,
        guard_ctx.global_index,
        16,
    );
}

fn stageBTileAsync(
    logical: anytype,
    ctx: StageContext,
    k_slice: kernel_root.Value,
    tile_b: kernel_root.Value,
    clamp: bool,
) !void {
    const tile = ctx.tile;
    const k_row_limit = try logical.sub(ctx.k_extent, try logical.constantIndex(1));
    const total_quads = (tile.bk * tile.bn) / 4;
    const b_quads_per_row = tile.bn / 4;
    var issued: u32 = 0;
    var quad: u32 = 0;
    while (issued < total_quads) : (quad += 1) {
        const pass_quads = @min(ctx.threads, total_quads - issued);
        const flat = try logical.add(
            ctx.thread_id,
            try logical.constantIndex(@as(i64, quad) * ctx.threads),
        );
        const quads_per_row_extent = try logical.constantIndex(b_quads_per_row);
        const local_k = try logical.div(flat, quads_per_row_extent);
        const quad_in_row = try logical.sub(flat, try logical.mul(local_k, quads_per_row_extent));
        const local_col = try logical.mul(quad_in_row, try logical.constantIndex(4));
        var global_k = try logical.add(k_slice, local_k);
        if (clamp) global_k = try logical.min(global_k, k_row_limit);
        const global_col = try logical.add(ctx.col_block, local_col);
        const global_index = try logical.add(
            try logical.add(ctx.rhs_base, try logical.mul(global_k, ctx.n_extent)),
            global_col,
        );
        const shared_index = try logical.add(try logical.mul(local_k, ctx.bn_extent), local_col);
        if (pass_quads == ctx.threads) {
            try logical.asyncCopyShared(tile_b, shared_index, ctx.rhs, global_index, 16);
        } else {
            const in_pass = try logical.compare(.lt, flat, try logical.constantIndex(total_quads));
            try logical.guardDo(in_pass, .{
                .tile_b = tile_b,
                .shared_index = shared_index,
                .rhs = ctx.rhs,
                .global_index = global_index,
            }, copy_partial_b_tile_quad);
        }
        issued += pass_quads;
    }
}

fn emitComputeSlice(
    logical: anytype,
    ctx: SliceContext,
    tile_a: kernel_root.Value,
    tile_b: kernel_root.Value,
    accumulators: []kernel_root.Value,
    vectorized: bool,
) !void {
    const tile = ctx.tile;
    var kk: u32 = 0;
    while (kk < tile.bk) : (kk += 1) {
        var fragment_a: [max_block_tile_fragments]kernel_root.Value = undefined;
        var fragment_b: [max_block_tile_fragments]kernel_root.Value = undefined;
        const a_row_offset = try logical.constantIndex(@as(i64, kk) * ctx.a_pitch);
        const b_row_offset = try logical.constantIndex(@as(i64, kk) * tile.bn);
        if (vectorized) {
            const m_quad_stride = @divExact(@as(i64, tile.bm) * 4, tile.tm);
            const n_quad_stride = @divExact(@as(i64, tile.bn) * 4, tile.tn);
            var quad: u32 = 0;
            while (quad < tile.tm / 4) : (quad += 1) {
                const local = try logical.add(
                    ctx.row_local,
                    try logical.constantIndex(@as(i64, quad) * m_quad_stride),
                );
                const quad_value = try logical.loadVector(
                    tile_a,
                    try logical.add(a_row_offset, local),
                    4,
                );
                var lane: u32 = 0;
                while (lane < 4) : (lane += 1) {
                    fragment_a[quad * 4 + lane] = try logical.extractLane(quad_value, lane, .f32);
                }
            }
            quad = 0;
            while (quad < tile.tn / 4) : (quad += 1) {
                const local = try logical.add(
                    ctx.col_local,
                    try logical.constantIndex(@as(i64, quad) * n_quad_stride),
                );
                const quad_value = try logical.loadVector(
                    tile_b,
                    try logical.add(b_row_offset, local),
                    4,
                );
                var lane: u32 = 0;
                while (lane < 4) : (lane += 1) {
                    fragment_b[quad * 4 + lane] = try logical.extractLane(quad_value, lane, .f32);
                }
            }
        } else {
            var i_frag: u32 = 0;
            while (i_frag < tile.tm) : (i_frag += 1) {
                const local = try logical.add(ctx.row_local, try logical.constantIndex(i_frag));
                fragment_a[i_frag] = try logical.loadIndex(
                    tile_a,
                    try logical.add(a_row_offset, local),
                );
            }
            var j_frag: u32 = 0;
            while (j_frag < tile.tn) : (j_frag += 1) {
                const local = try logical.add(ctx.col_local, try logical.constantIndex(j_frag));
                fragment_b[j_frag] = try logical.loadIndex(
                    tile_b,
                    try logical.add(b_row_offset, local),
                );
            }
        }
        var i: u32 = 0;
        while (i < tile.tm) : (i += 1) {
            var jj: u32 = 0;
            while (jj < tile.tn) : (jj += 1) {
                const slot = i * tile.tn + jj;
                const product = try logical.mul(fragment_a[i], fragment_b[jj]);
                accumulators[slot] = try logical.add(accumulators[slot], product);
            }
        }
    }
}

fn store_block_tile_result(inner: anytype, nested_ctx: anytype) !void {
    try inner.storeIndex(nested_ctx.value, nested_ctx.out, nested_ctx.address);
}

fn guard_block_tile_store_column(inner: anytype, outer_ctx: anytype) !void {
    try inner.guardDo(outer_ctx.col_ok, outer_ctx, store_block_tile_result);
}

fn emitTiledEpilogue(
    logical: anytype,
    ctx: anytype,
    scope: anytype,
    accumulator_count: usize,
    out: kernel_root.Value,
    out_base: kernel_root.Value,
    row_base: kernel_root.Value,
    col_base: kernel_root.Value,
    m_extent: kernel_root.Value,
    n_extent: kernel_root.Value,
    exact: bool,
    vectorized: bool,
) !void {
    const tile: kernelization_model.DotGeneralBlockTile = ctx.tile;
    const m_quad_stride = @divExact(@as(i64, tile.bm) * 4, tile.tm);
    const n_quad_stride = @divExact(@as(i64, tile.bn) * 4, tile.tn);
    var results: [max_block_tile_accumulators]kernel_root.Value = undefined;
    for (results[0..accumulator_count], 0..) |*result, index| {
        result.* = scope.result(index) orelse return error.UnsupportedOperation;
    }

    var i: u32 = 0;
    while (i < tile.tm) : (i += 1) {
        const row_step: i64 = if (vectorized)
            @as(i64, i / 4) * m_quad_stride + i % 4
        else
            @as(i64, i);
        const row = try logical.add(row_base, try logical.constantIndex(row_step));
        const row_offset = try logical.add(out_base, try logical.mul(row, n_extent));
        var j: u32 = 0;
        while (j < tile.tn) : (j += 1) {
            const col_step: i64 = if (vectorized)
                @as(i64, j / 4) * n_quad_stride + j % 4
            else
                @as(i64, j);
            const col = try logical.add(col_base, try logical.constantIndex(col_step));
            const address = try logical.add(row_offset, col);
            const value = try applyEpilogueChain(
                logical,
                ctx.epilogue,
                ctx.abi,
                results[i * tile.tn + j],
                address,
            );
            if (exact) {
                if (tile.splits > 1) {
                    _ = try logical.atomicRmw(.add, value, out, address);
                } else {
                    try logical.storeIndex(value, out, address);
                }
            } else {
                const row_ok = try logical.compare(.lt, row, m_extent);
                const col_ok = try logical.compare(.lt, col, n_extent);
                try logical.guardDo(row_ok, .{
                    .col_ok = col_ok,
                    .value = value,
                    .out = out,
                    .address = address,
                }, guard_block_tile_store_column);
            }
        }
    }
}

fn emitScalarStaging(logical: anytype, ctx: anytype) !void {
    const tile: kernelization_model.DotGeneralBlockTile = ctx.tile;
    const a_loads_per_thread = (tile.bm * tile.bk) / ctx.threads;
    var stage: u32 = 0;
    while (stage < a_loads_per_thread) : (stage += 1) {
        const flat = try logical.add(
            ctx.thread_id,
            try logical.constantIndex(@as(i64, stage) * ctx.threads),
        );
        const local_row = try logical.div(flat, ctx.bk_extent);
        const local_k = try logical.sub(flat, try logical.mul(local_row, ctx.bk_extent));
        const global_row = try logical.add(ctx.row_block, local_row);
        const global_k = try logical.add(ctx.k0, local_k);
        const value = try stagedLoad(logical, ctx.lhs, .{
            .base = ctx.lhs_base,
            .major = global_row,
            .major_edge = ctx.m_edge,
            .major_extent = ctx.m_extent,
            .pitch = ctx.k_extent,
            .minor = global_k,
            .minor_edge = ctx.k_edge,
            .minor_extent = ctx.k_extent,
            .zero = ctx.zero_scalar,
            .exact = ctx.exact,
        });
        const shared_index = try logical.add(
            try logical.mul(local_k, ctx.a_pitch_extent),
            local_row,
        );
        try logical.storeIndex(value, ctx.tile_a, shared_index);
    }

    const b_loads_per_thread = (tile.bk * tile.bn) / ctx.threads;
    stage = 0;
    while (stage < b_loads_per_thread) : (stage += 1) {
        const flat = try logical.add(
            ctx.thread_id,
            try logical.constantIndex(@as(i64, stage) * ctx.threads),
        );
        const local_k = try logical.div(flat, ctx.bn_extent);
        const local_col = try logical.sub(flat, try logical.mul(local_k, ctx.bn_extent));
        const global_k = try logical.add(ctx.k0, local_k);
        const global_col = try logical.add(ctx.col_block, local_col);
        const value = try stagedLoad(logical, ctx.rhs, .{
            .base = ctx.rhs_base,
            .major = global_k,
            .major_edge = ctx.k_edge,
            .major_extent = ctx.k_extent,
            .pitch = ctx.n_extent,
            .minor = global_col,
            .minor_edge = ctx.n_edge,
            .minor_extent = ctx.n_extent,
            .zero = ctx.zero_scalar,
            .exact = ctx.exact,
        });
        const shared_index = try logical.add(try logical.mul(local_k, ctx.bn_extent), local_col);
        try logical.storeIndex(value, ctx.tile_b, shared_index);
    }
}

fn stagedLoad(logical: anytype, buffer: kernel_root.Value, spec: anytype) !kernel_root.Value {
    if (spec.exact) {
        const offset = try logical.mul(spec.major, spec.pitch);
        const address = try logical.add(try logical.add(spec.base, offset), spec.minor);
        return logical.loadIndex(buffer, address);
    }
    const major_ok = try logical.compare(.lt, spec.major, spec.major_extent);
    const minor_ok = try logical.compare(.lt, spec.minor, spec.minor_extent);
    const major_clamped = try logical.min(spec.major, spec.major_edge);
    const minor_clamped = try logical.min(spec.minor, spec.minor_edge);
    const offset = try logical.mul(major_clamped, spec.pitch);
    const address = try logical.add(try logical.add(spec.base, offset), minor_clamped);
    const loaded = try logical.loadIndex(buffer, address);
    const minor_masked = try logical.select(minor_ok, loaded, spec.zero);
    return logical.select(major_ok, minor_masked, spec.zero);
}

fn accumulate_dot_product(
    fold_inner: anytype,
    k_index: kernel_root.Value,
    current: kernel_root.Value,
    fold_ctx: anytype,
) !kernel_root.Value {
    const m_stride = try fold_inner.constantIndex(fold_ctx.dims.m);
    const k_stride = try fold_inner.constantIndex(fold_ctx.dims.k);
    const n_stride = try fold_inner.constantIndex(fold_ctx.dims.n);
    const lhs_batch_rows = try fold_inner.mul(fold_ctx.batch, m_stride);
    const lhs_row = try fold_inner.add(lhs_batch_rows, fold_ctx.row);
    const lhs_row_offset = try fold_inner.mul(lhs_row, k_stride);
    const lhs_index = try fold_inner.add(lhs_row_offset, k_index);
    const rhs_batch_rows = try fold_inner.mul(fold_ctx.batch, k_stride);
    const rhs_row = try fold_inner.add(rhs_batch_rows, k_index);
    const rhs_row_offset = try fold_inner.mul(rhs_row, n_stride);
    const rhs_index = try fold_inner.add(rhs_row_offset, fold_ctx.col);
    var lhs_value = try fold_inner.loadIndex(fold_ctx.lhs, lhs_index);
    var rhs_value = try fold_inner.loadIndex(fold_ctx.rhs, rhs_index);
    if (fold_ctx.widen) {
        lhs_value = try fold_inner.cast(lhs_value, .f32);
        rhs_value = try fold_inner.cast(rhs_value, .f32);
    }
    const product = try fold_inner.mul(lhs_value, rhs_value);
    return fold_inner.add(current, product);
}

fn emit_dot_index(inner: anytype, index: kernel_root.Index3D, each_ctx: anytype) !void {
    const lower_bound = try inner.constantIndex(0);
    const upper = try inner.constantIndex(each_ctx.dims.k);
    const step = try inner.constantIndex(1);
    const widen = each_ctx.dtype == .f16;
    const initial = try dotInitialValue(inner, each_ctx.dtype);
    const result = try inner.fold(lower_bound, upper, step, initial, .{
        .dims = each_ctx.dims,
        .lhs = each_ctx.lhs,
        .rhs = each_ctx.rhs,
        .row = index.y.index,
        .col = index.x.index,
        .batch = index.z.index,
        .widen = widen,
    }, accumulate_dot_product);
    const stored = if (widen) try inner.cast(result, .f16) else result;
    const m_stride = try inner.constantIndex(each_ctx.dims.m);
    const n_stride = try inner.constantIndex(each_ctx.dims.n);
    const out_batch_rows = try inner.mul(index.z.index, m_stride);
    const out_row = try inner.add(out_batch_rows, index.y.index);
    const out_row_offset = try inner.mul(out_row, n_stride);
    const out_index = try inner.add(out_row_offset, index.x.index);
    const finished = try applyEpilogueChain(
        inner,
        each_ctx.epilogue,
        each_ctx.abi,
        stored,
        out_index,
    );
    try inner.storeIndex(finished, each_ctx.out, out_index);
}

fn emitDotBody(logical: anytype, ctx: anytype) !void {
    const output_index = try logical.index3D(.{
        .x = kernel_root.logical.axis("col", ctx.dims.n),
        .y = kernel_root.logical.axis("row", ctx.dims.m),
        .z = kernel_root.logical.axis("batch", ctx.dims.batch),
    });
    try logical.guardIndex3DDo(output_index, .{
        .dims = ctx.dims,
        .dtype = ctx.dtype,
        .out = ctx.abi.output(logical),
        .lhs = ctx.abi.lhs(logical),
        .rhs = ctx.abi.rhs(logical),
        .abi = ctx.abi,
        .epilogue = ctx.epilogue,
    }, emit_dot_index);
}

fn emitFlatDotBody(logical: anytype, ctx: anytype) !void {
    const output_elements = @as(u64, ctx.dims.m) * @as(u64, ctx.dims.n) * @as(u64, ctx.dims.batch);
    const output_index = try logical.index1D("out", output_elements);
    const flat = output_index.index;
    const n_extent = try logical.constantIndex(ctx.dims.n);
    const mn_extent = try logical.constantIndex(@as(i64, ctx.dims.m) * @as(i64, ctx.dims.n));
    const batch = try logical.div(flat, mn_extent);
    const batch_base = try logical.mul(batch, mn_extent);
    const in_batch = try logical.sub(flat, batch_base);
    const row = try logical.div(in_batch, n_extent);
    const row_base = try logical.mul(row, n_extent);
    const col = try logical.sub(in_batch, row_base);

    const widen = ctx.dtype == .f16;
    var result = try dotInitialValue(logical, ctx.dtype);
    var k: u32 = 0;
    while (k < ctx.dims.k) : (k += 1) {
        result = try accumulateDotProduct(
            logical,
            ctx.dims,
            ctx.abi.lhs(logical),
            ctx.abi.rhs(logical),
            row,
            col,
            batch,
            result,
            try logical.constantIndex(k),
            widen,
        );
    }
    const stored = if (widen) try logical.cast(result, .f16) else result;
    const finished = try applyEpilogueChain(logical, ctx.epilogue, ctx.abi, stored, flat);
    try logical.storeIndex(finished, ctx.abi.output(logical), flat);
}

fn accumulateDotProduct(
    builder: anytype,
    dims: DotGeneralStaticDims,
    lhs: kernel_root.Value,
    rhs: kernel_root.Value,
    row: kernel_root.Value,
    col: kernel_root.Value,
    batch: kernel_root.Value,
    current: kernel_root.Value,
    k_index: kernel_root.Value,
    widen: bool,
) !kernel_root.Value {
    const m_stride = try builder.constantIndex(dims.m);
    const k_stride = try builder.constantIndex(dims.k);
    const n_stride = try builder.constantIndex(dims.n);
    const lhs_batch_rows = try builder.mul(batch, m_stride);
    const lhs_row = try builder.add(lhs_batch_rows, row);
    const lhs_row_offset = try builder.mul(lhs_row, k_stride);
    const lhs_index = try builder.add(lhs_row_offset, k_index);
    const rhs_batch_rows = try builder.mul(batch, k_stride);
    const rhs_row = try builder.add(rhs_batch_rows, k_index);
    const rhs_row_offset = try builder.mul(rhs_row, n_stride);
    const rhs_index = try builder.add(rhs_row_offset, col);
    var lhs_value = try builder.loadIndex(lhs, lhs_index);
    var rhs_value = try builder.loadIndex(rhs, rhs_index);
    if (widen) {
        lhs_value = try builder.cast(lhs_value, .f32);
        rhs_value = try builder.cast(rhs_value, .f32);
    }
    const product = try builder.mul(lhs_value, rhs_value);
    return builder.add(current, product);
}

fn validateCanonicalDotLayout(op: *ir.Operation, lhs_rank: usize) gpu.BackendError!void {
    var lhs_contract_buffer: [8]i64 = undefined;
    const lhs_contract = try common.readI64ListAttrBounded(
        op,
        "lhs_contract",
        dialect_mod.AccyDialect.DotGeneralOp.dialectAttrName("lhs_contract"),
        &lhs_contract_buffer,
    );
    var rhs_contract_buffer: [8]i64 = undefined;
    const rhs_contract = try common.readI64ListAttrBounded(
        op,
        "rhs_contract",
        dialect_mod.AccyDialect.DotGeneralOp.dialectAttrName("rhs_contract"),
        &rhs_contract_buffer,
    );
    var lhs_batch_buffer: [8]i64 = undefined;
    const lhs_batch = try common.readI64ListAttrBounded(
        op,
        "lhs_batch",
        dialect_mod.AccyDialect.DotGeneralOp.dialectAttrName("lhs_batch"),
        &lhs_batch_buffer,
    );
    var rhs_batch_buffer: [8]i64 = undefined;
    const rhs_batch = try common.readI64ListAttrBounded(
        op,
        "rhs_batch",
        dialect_mod.AccyDialect.DotGeneralOp.dialectAttrName("rhs_batch"),
        &rhs_batch_buffer,
    );

    switch (lhs_rank) {
        2 => {
            if (lhs_batch.len != 0 or rhs_batch.len != 0) return error.UnsupportedOperation;
            if (lhs_contract.len != 1 or rhs_contract.len != 1) return error.UnsupportedOperation;
            if (lhs_contract[0] != 1 or rhs_contract[0] != 0) return error.UnsupportedOperation;
        },
        3 => {
            if (lhs_batch.len != 1 or rhs_batch.len != 1) return error.UnsupportedOperation;
            if (lhs_batch[0] != 0 or rhs_batch[0] != 0) return error.UnsupportedOperation;
            if (lhs_contract.len != 1 or rhs_contract.len != 1) return error.UnsupportedOperation;
            if (lhs_contract[0] != 2 or rhs_contract[0] != 1) return error.UnsupportedOperation;
        },
        else => return error.UnsupportedOperation,
    }
}

fn dotGeneralStaticDims(
    lhs_slot: bufferization.BufferSlot,
    rhs_slot: bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
) gpu.BackendError!DotGeneralStaticDims {
    if (lhs_slot.dims.len == 2 and rhs_slot.dims.len == 2 and output_slot.dims.len == 2) {
        return dotGeneralRank2StaticDims(lhs_slot, rhs_slot, output_slot);
    }
    if (lhs_slot.dims.len == 3 and rhs_slot.dims.len == 3 and output_slot.dims.len == 3) {
        return dotGeneralRank3StaticDims(lhs_slot, rhs_slot, output_slot);
    }
    return error.UnsupportedOperation;
}

fn dotGeneralRank2StaticDims(
    lhs_slot: bufferization.BufferSlot,
    rhs_slot: bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
) gpu.BackendError!DotGeneralStaticDims {
    const m = try staticPositiveDimU32(lhs_slot.dims[0]);
    const k = try staticPositiveDimU32(lhs_slot.dims[1]);
    const rhs_k = try staticPositiveDimU32(rhs_slot.dims[0]);
    const n = try staticPositiveDimU32(rhs_slot.dims[1]);
    const output_m = try staticPositiveDimU32(output_slot.dims[0]);
    const output_n = try staticPositiveDimU32(output_slot.dims[1]);
    if (rhs_k != k or output_m != m or output_n != n) return error.InvalidArtifact;
    return .{ .m = m, .n = n, .k = k };
}

fn dotGeneralRank3StaticDims(
    lhs_slot: bufferization.BufferSlot,
    rhs_slot: bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
) gpu.BackendError!DotGeneralStaticDims {
    const batch = try staticPositiveDimU32(lhs_slot.dims[0]);
    const m = try staticPositiveDimU32(lhs_slot.dims[1]);
    const k = try staticPositiveDimU32(lhs_slot.dims[2]);
    const rhs_batch = try staticPositiveDimU32(rhs_slot.dims[0]);
    const rhs_k = try staticPositiveDimU32(rhs_slot.dims[1]);
    const n = try staticPositiveDimU32(rhs_slot.dims[2]);
    const output_batch = try staticPositiveDimU32(output_slot.dims[0]);
    const output_m = try staticPositiveDimU32(output_slot.dims[1]);
    const output_n = try staticPositiveDimU32(output_slot.dims[2]);
    if (rhs_batch != batch or output_batch != batch or rhs_k != k or
        output_m != m or output_n != n) return error.InvalidArtifact;
    return .{ .m = m, .n = n, .k = k, .batch = batch };
}

fn validateDotGeneralDTypes(
    lhs_slot: bufferization.BufferSlot,
    rhs_slot: bufferization.BufferSlot,
    output_slot: bufferization.BufferSlot,
    work: schedule_planning.ScheduleWorkItem,
) gpu.BackendError!void {
    if (lhs_slot.dtype != rhs_slot.dtype) return error.CapabilityMismatch;
    switch (lhs_slot.dtype) {
        .f32 => if (output_slot.dtype != .f32) return error.CapabilityMismatch,
        .f16 => if (output_slot.dtype != .f16) return error.CapabilityMismatch,
        .i32 => if (output_slot.dtype != .i32) return error.CapabilityMismatch,
        .u32 => if (output_slot.dtype != .u32) return error.CapabilityMismatch,
        else => return error.CapabilityMismatch,
    }
    if (work.dtype != output_slot.dtype) return error.InvalidArtifact;
}

fn dotLoweringSupported(input_dtype: gpu_abi.DType, output_dtype: gpu_abi.DType) bool {
    if (input_dtype == .f32 and output_dtype == .f32) return true;
    if (input_dtype == .f16 and output_dtype == .f16) return true;
    if (input_dtype == .u32 and output_dtype == .u32) return true;
    return input_dtype == .i32 and output_dtype == .i32;
}

fn testBufferSlot(dtype: gpu_abi.DType, dims: []i64) bufferization.BufferSlot {
    return .{
        .id = 0,
        .value = undefined,
        .producer = null,
        .function = null,
        .role = .{},
        .dtype = dtype,
        .dims = dims,
        .element_count = null,
        .row_major_strides = null,
        .byte_size = null,
    };
}

test "dot general static dims accept edge tile shapes" {
    var lhs_dims = [_]i64{ 1, 32 };
    var rhs_dims = [_]i64{ 32, 24 };
    var out_dims = [_]i64{ 1, 24 };

    const dims = try dotGeneralStaticDims(
        testBufferSlot(.f32, lhs_dims[0..]),
        testBufferSlot(.f32, rhs_dims[0..]),
        testBufferSlot(.f32, out_dims[0..]),
    );

    try std.testing.expectEqual(@as(u32, 1), dims.m);
    try std.testing.expectEqual(@as(u32, 24), dims.n);
    try std.testing.expectEqual(@as(u32, 32), dims.k);
}

test "dot general static dims accept batched matmul shapes" {
    var lhs_dims = [_]i64{ 8, 2, 4 };
    var rhs_dims = [_]i64{ 8, 4, 3 };
    var out_dims = [_]i64{ 8, 2, 3 };

    const dims = try dotGeneralStaticDims(
        testBufferSlot(.f32, lhs_dims[0..]),
        testBufferSlot(.f32, rhs_dims[0..]),
        testBufferSlot(.f32, out_dims[0..]),
    );

    try std.testing.expectEqual(@as(u32, 8), dims.batch);
    try std.testing.expectEqual(@as(u32, 2), dims.m);
    try std.testing.expectEqual(@as(u32, 3), dims.n);
    try std.testing.expectEqual(@as(u32, 4), dims.k);
}
