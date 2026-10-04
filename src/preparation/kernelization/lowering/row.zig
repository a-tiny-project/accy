const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const alloc_fixed = @import("alloc_fixed");
const generated_abi = @import("abi.zig");
const generated_builder = @import("builder.zig");
const common = @import("common.zig");
const generated_elementwise = @import("elementwise.zig");
const generated_name = @import("name.zig");
const generated_schedule = @import("schedule.zig");
const preparation = @import("../../root.zig");
const reduction = @import("reduction.zig");

const ir = common.ir;
const dialect_mod = common.dialect_mod;
const kernel_root = common.kernel_root;
const bufferization = common.bufferization;
const kernelization_model = @import("../model/root.zig");
const schedule_planning = common.schedule_planning;
const target_facts = preparation.target;
const bufferSlotById = common.bufferSlotById;
const externalInputIndex = common.externalInputIndex;
const mapKernelBuildError = common.mapKernelBuildError;
const isName = common.isName;

const LoweredKernel = kernelization_model.LoweredKernel;
const ReductionKind = kernelization_model.ReductionKind;
const Schedule = target_facts.GeneratedRowPipelineSchedule;

const warp_size: u32 = 32;
const max_reduces = 4;
const max_leaves = 6;
const max_quads = 8;

/// A pass declares its own costs before it runs as its work bound so compilation can refuse a pass
/// that would exceed the caller's limits, and the kernel stage calls this once per try at emitting
/// a kernel under one candidate schedule to charge row-kernel scratch. Block-wide generation keeps
/// one memo table for each reduction and output lane and one for shared statistics, and one-thread
/// generation adds one more table: each is a map from a source value to the kernel value already
/// emitted for it. Each table is sized for `value_count` source values. The parameter list and
/// input arrays belong to the caller and are charged separately.
pub fn scratchStorageBound(value_count: u64) !u64 {
    const accounting = @import("choir").passes.pass.work;
    const memos = (max_reduces + 1) * max_quads * 4 + 2;
    const table = try accounting.hashMapGrowth(*ir.Value, kernel_root.Value, value_count);
    const bytes = try accounting.multiply(memos, table);
    if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
    return bytes;
}

const block_schedules = [_]u32{ 256, 512, 128 };

pub const schedule_version: u32 = 1;
pub const max_schedule_candidates = block_schedules.len;

pub fn scheduleCandidates(
    cols: u64,
    format: ?gpu.ArtifactFormat,
    buffer: *[max_schedule_candidates]Schedule,
) []const Schedule {
    if (format != .cuda_ptx) return buffer[0..0];
    var count: usize = 0;
    for (block_schedules) |candidate_threads| {
        if (!scheduleViable(candidate_threads, cols)) continue;
        buffer[count] = .{ .threads = candidate_threads };
        count += 1;
    }
    return buffer[0..count];
}

fn scheduleViable(candidate_threads: u32, cols: u64) bool {
    const quad_width = @as(u64, candidate_threads) * 4;
    if (cols % quad_width != 0) return false;
    return cols / quad_width <= max_quads;
}

const PipelineReduce = struct {
    op: *ir.Operation,
    kind: ReductionKind,
    init: f32,
    input: *ir.Value,
};

const PipelineLeafKind = enum {
    full,
    column,
};

const PipelineLeaf = struct {
    value: *ir.Value,
    input_index: usize,
    kind: PipelineLeafKind,
};

const PipelineDescription = struct {
    rows: u32,
    cols: u32,
    root: *ir.Operation,
    reduces: [max_reduces]PipelineReduce,
    reduce_count: usize,
    leaves: [max_leaves]PipelineLeaf,
    leaf_count: usize,
};

fn BlockRowPipelineBodyType(comptime pipeline_threads: u32) type {
    return struct {
        fn emit(logical: anytype, ctx: anytype) !void {
            try emitBlockRowPipelineBodyScheduled(pipeline_threads, logical, ctx);
        }
    };
}

pub fn lower(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    format: ?gpu.ArtifactFormat,
    row_pipeline_schedules: ?[]const u8,
) common.LoweringError!LoweredKernel {
    const desc = try pipelineDescriptionForWork(outline, work, buffer_plan);

    const input_dtypes = allocator.alloc(
        gpu_abi.DType,
        outline.inputCount(),
    ) catch return error.OutOfMemory;
    defer allocator.free(input_dtypes);
    for (outline.input_slot_ids, 0..) |slot_id, index| {
        const slot = bufferSlotById(buffer_plan, slot_id) orelse return error.InvalidArtifact;
        input_dtypes[index] = slot.dtype;
    }

    var abi = try generated_abi.flatTyped(allocator, .f32, input_dtypes);
    defer abi.deinit(allocator);

    if (format == .cuda_ptx) {
        if (row_pipeline_schedules) |encoded| {
            if (try target_facts.resolveGeneratedRowPipelineSchedule(
                encoded,
                desc.rows,
                desc.cols,
            )) |schedule| {
                if (scheduleViable(schedule.threads, desc.cols)) {
                    if (try lowerBlockRowPipeline(
                        schedule,
                        allocator,
                        ir_ctx,
                        outline,
                        work,
                        buffer_plan,
                        desc,
                        abi,
                    )) |lowered| {
                        return lowered;
                    }
                }
            }
        }
        var candidate_buffer: [max_schedule_candidates]Schedule = undefined;
        for (scheduleCandidates(desc.cols, format, &candidate_buffer)) |schedule| {
            if (try lowerBlockRowPipeline(
                schedule,
                allocator,
                ir_ctx,
                outline,
                work,
                buffer_plan,
                desc,
                abi,
            )) |lowered| {
                return lowered;
            }
        }
    }

    const entry_name = try generated_name.rowPipelineSerial(
        allocator,
        desc.reduce_count,
        work.ops.len,
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
            .desc = desc,
            .work = work,
            .outline = outline,
            .buffer_plan = buffer_plan,
        },
        emitSerialRowPipelineBody,
    );
}

fn pipelineDescriptionForWork(
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) common.LoweringError!PipelineDescription {
    if (work.kind != .row_pipeline) return error.UnsupportedOperation;
    if (work.ops.len == 0) return error.UnsupportedOperation;
    const root = work.ops[work.ops.len - 1];
    const root_result = root.getResult(0) orelse return error.InvalidArtifact;

    var dims_arena_buffer: [256]u8 = undefined;
    var dims_arena = alloc_fixed.FixedBuffer.init(dims_arena_buffer[0..]);
    const root_type = dialect_mod.decodeTensorType(
        dims_arena.allocator(),
        root_result.type,
    ) catch return error.InvalidArtifact;
    if (root_type.dtype != .f32 or root_type.dims.len != 2) return error.UnsupportedOperation;
    const rows = std.math.cast(u32, root_type.dims[0]) orelse return error.UnsupportedOperation;
    const cols = std.math.cast(u32, root_type.dims[1]) orelse return error.UnsupportedOperation;
    if (rows == 0 or cols == 0) return error.UnsupportedOperation;

    var desc = PipelineDescription{
        .rows = rows,
        .cols = cols,
        .root = root,
        .reduces = undefined,
        .reduce_count = 0,
        .leaves = undefined,
        .leaf_count = 0,
    };

    for (work.ops) |op| {
        if (!isName(op.name.name, dialect_mod.AccyDialect.ReduceOp.operation_name)) continue;
        if (desc.reduce_count >= max_reduces) return error.UnsupportedOperation;
        const kind = try reduction.reductionKindForOp(op);
        const init_operand = op.getOperand(1) orelse return error.InvalidArtifact;
        const init_slot = buffer_plan.getSlot(init_operand) orelse return error.InvalidArtifact;
        const init = switch (try reduction.reductionInitValue(init_slot.*, .f32, outline)) {
            .constant => |value| switch (value) {
                .f32 => |scalar| scalar,
                else => return error.UnsupportedOperation,
            },
            .input_buffer => return error.UnsupportedOperation,
        };
        const input = op.getOperand(0) orelse return error.InvalidArtifact;
        desc.reduces[desc.reduce_count] = .{ .op = op, .kind = kind, .init = init, .input = input };
        desc.reduce_count += 1;
    }
    if (desc.reduce_count == 0) return error.UnsupportedOperation;

    var member_set = MemberSet{};
    for (work.ops) |op| member_set.put(op);

    for (work.ops) |op| {
        if (isName(op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name)) {
            var dims_buffer: [8]i64 = undefined;
            const dims = readBroadcastDimsBounded(op, dims_buffer[0..]) orelse
                return error.InvalidArtifact;
            if (dims.len != 1) return error.UnsupportedOperation;
            if (dims[0] != 1) continue;
            const source = op.getOperand(0) orelse return error.InvalidArtifact;
            if (leafIndexFor(&desc, source) != null) continue;
            if (desc.leaf_count >= max_leaves) return error.UnsupportedOperation;
            const slot = buffer_plan.getSlot(source) orelse return error.UnsupportedOperation;
            const input_index = externalInputIndex(outline, slot.id) orelse
                return error.UnsupportedOperation;
            desc.leaves[desc.leaf_count] = .{
                .value = source,
                .input_index = input_index,
                .kind = .column,
            };
            desc.leaf_count += 1;
            continue;
        }
        const operand_limit: usize = if (isName(
            op.name.name,
            dialect_mod.AccyDialect.ReduceOp.operation_name,
        )) 1 else op.getOperandValues().len;
        for (op.getOperandValues()[0..operand_limit]) |operand| {
            if (operand.getDefiningOp()) |def_any| {
                const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
                if (member_set.contains(def_op)) continue;
                if (isName(def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
                    continue;
                }
                if (broadcastOfConstant(def_op)) continue;
            }
            if (leafIndexFor(&desc, operand) != null) continue;
            var operand_arena_buffer: [256]u8 = undefined;
            var operand_arena = alloc_fixed.FixedBuffer.init(operand_arena_buffer[0..]);
            const operand_type = dialect_mod.decodeTensorType(
                operand_arena.allocator(),
                operand.type,
            ) catch return error.InvalidArtifact;
            if (operand_type.dims.len != 2) return error.UnsupportedOperation;
            if (desc.leaf_count >= max_leaves) return error.UnsupportedOperation;
            const slot = buffer_plan.getSlot(operand) orelse return error.UnsupportedOperation;
            const input_index = externalInputIndex(outline, slot.id) orelse
                return error.UnsupportedOperation;
            desc.leaves[desc.leaf_count] = .{
                .value = operand,
                .input_index = input_index,
                .kind = .full,
            };
            desc.leaf_count += 1;
        }
    }

    return desc;
}

fn broadcastOfConstant(op: *ir.Operation) bool {
    if (!isName(op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name)) {
        return false;
    }
    const operands = op.getOperandValues();
    if (operands.len != 1) return false;
    const source_any = operands[0].getDefiningOp() orelse return false;
    const source: *ir.Operation = @ptrCast(@alignCast(source_any));
    return isName(source.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name);
}

fn readBroadcastDimsBounded(op: *ir.Operation, buffer: []i64) ?[]const i64 {
    const payload = payloadFor(op, "broadcast_dims") orelse return null;
    if (payload.len % @sizeOf(i64) != 0) return null;
    const count = payload.len / @sizeOf(i64);
    if (count > buffer.len) return null;
    for (buffer[0..count], 0..) |*slot, index| {
        @memcpy(std.mem.asBytes(slot), payload[index * @sizeOf(i64) ..][0..@sizeOf(i64)]);
    }
    return buffer[0..count];
}

fn payloadFor(op: *ir.Operation, name: []const u8) ?[]const u8 {
    if (op.getAttrAs(ir.Attribute.DialectAttr, name)) |attr| return attr.payload;
    if (op.getAttrAs(
        ir.Attribute.DialectAttr,
        dialect_mod.AccyDialect.BroadcastInDimOp.dialectAttrName("broadcast_dims"),
    )) |attr| return attr.payload;
    return null;
}

const MemberSet = struct {
    ops: [fusionMaxOps()]*ir.Operation = undefined,
    count: usize = 0,

    fn put(self: *MemberSet, op: *ir.Operation) void {
        if (self.count < self.ops.len) {
            self.ops[self.count] = op;
            self.count += 1;
        }
    }

    fn contains(self: *const MemberSet, op: *ir.Operation) bool {
        for (self.ops[0..self.count]) |member| {
            if (member == op) return true;
        }
        return false;
    }
};

fn fusionMaxOps() usize {
    return 32;
}

fn leafIndexFor(desc: *const PipelineDescription, value: *ir.Value) ?usize {
    for (desc.leaves[0..desc.leaf_count], 0..) |leaf, index| {
        if (leaf.value == value) return index;
    }
    return null;
}

fn reduceIndexFor(desc: *const PipelineDescription, op: *ir.Operation) ?usize {
    for (desc.reduces[0..desc.reduce_count], 0..) |entry, index| {
        if (entry.op == op) return index;
    }
    return null;
}

const ResolveContext = struct {
    desc: *const PipelineDescription,
    scalars: [max_reduces]?kernel_root.Value,
    leaf_values: [max_leaves]kernel_root.Value,
    memo: std.AutoHashMap(*ir.Value, kernel_root.Value),
    stats: ?*std.AutoHashMap(*ir.Value, kernel_root.Value) = null,

    fn init(allocator: std.mem.Allocator, desc: *const PipelineDescription) ResolveContext {
        return .{
            .desc = desc,
            .scalars = @splat(null),
            .leaf_values = undefined,
            .memo = std.AutoHashMap(*ir.Value, kernel_root.Value).init(allocator),
        };
    }

    fn deinit(self: *ResolveContext) void {
        self.memo.deinit();
    }
};

fn resolveValue(
    builder: anytype,
    ctx: *ResolveContext,
    value: *ir.Value,
) common.LoweringError!kernel_root.Value {
    if (leafIndexFor(ctx.desc, value)) |leaf_index| return ctx.leaf_values[leaf_index];
    if (ctx.memo.get(value)) |cached| return cached;

    const def_any = value.getDefiningOp() orelse return error.UnsupportedOperation;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));

    if (reduceIndexFor(ctx.desc, def_op)) |reduce_index| {
        return ctx.scalars[reduce_index] orelse error.UnsupportedOperation;
    }

    if (isName(def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
        return common.splatConstantValue(builder, def_op) catch |err|
            return common.mapGeneratedKernelError(err);
    }

    if (isName(def_op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name)) {
        var dims_buffer: [8]i64 = undefined;
        const dims = readBroadcastDimsBounded(def_op, dims_buffer[0..]) orelse
            return error.InvalidArtifact;
        const source = def_op.getOperand(0) orelse return error.InvalidArtifact;
        if (dims.len == 0) {
            return resolveValue(builder, ctx, source);
        }
        if (dims.len != 1) return error.UnsupportedOperation;
        if (dims[0] == 1) {
            return resolveValue(builder, ctx, source);
        }
        if (ctx.stats) |stats| {
            if (stats.get(value)) |cached| return cached;
        }
        const resolved = try resolveStatValue(builder, ctx, source);
        if (ctx.stats) |stats| {
            stats.put(value, resolved) catch return error.OutOfMemory;
        }
        return resolved;
    }

    const kind = generated_elementwise.kernelForOperation(def_op) orelse
        return error.UnsupportedOperation;
    const operands = def_op.getOperandValues();
    if (operands.len > 3) return error.UnsupportedOperation;
    var inputs: [3]kernel_root.Value = undefined;
    for (operands, 0..) |operand, operand_index| {
        inputs[operand_index] = try resolveValue(builder, ctx, operand);
    }
    const resolved = generated_elementwise.emitElementwiseValue(
        builder,
        kind,
        inputs[0..operands.len],
        .f32,
        def_op,
    ) catch |err| return common.mapGeneratedKernelError(err);
    ctx.memo.put(value, resolved) catch return error.OutOfMemory;
    return resolved;
}

fn resolveStatValue(
    builder: anytype,
    ctx: *ResolveContext,
    value: *ir.Value,
) common.LoweringError!kernel_root.Value {
    if (ctx.stats) |stats| {
        if (stats.get(value)) |cached| return cached;
    }
    const def_any = value.getDefiningOp() orelse return error.UnsupportedOperation;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));

    if (reduceIndexFor(ctx.desc, def_op)) |reduce_index| {
        return ctx.scalars[reduce_index] orelse error.UnsupportedOperation;
    }
    if (isName(def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
        return common.splatConstantValue(builder, def_op) catch |err|
            return common.mapGeneratedKernelError(err);
    }
    const kind = generated_elementwise.kernelForOperation(def_op) orelse
        return error.UnsupportedOperation;
    const operands = def_op.getOperandValues();
    if (operands.len > 3) return error.UnsupportedOperation;
    var inputs: [3]kernel_root.Value = undefined;
    for (operands, 0..) |operand, operand_index| {
        inputs[operand_index] = try resolveStatValue(builder, ctx, operand);
    }
    const resolved = generated_elementwise.emitElementwiseValue(
        builder,
        kind,
        inputs[0..operands.len],
        .f32,
        def_op,
    ) catch |err| return common.mapGeneratedKernelError(err);
    if (ctx.stats) |stats| {
        stats.put(value, resolved) catch return error.OutOfMemory;
    }
    return resolved;
}

fn lowerBlockRowPipeline(
    schedule: Schedule,
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    desc: PipelineDescription,
    abi: generated_abi.Flat,
) common.LoweringError!?LoweredKernel {
    inline for (block_schedules) |candidate_threads| {
        if (candidate_threads == schedule.threads) {
            const entry_name = try generated_name.rowPipeline(
                allocator,
                desc.reduce_count,
                candidate_threads,
                work.ops.len,
                work.id,
            );
            errdefer allocator.free(entry_name);
            var lowered = try generated_builder.withoutLaunch(
                allocator,
                ir_ctx,
                work.id,
                entry_name,
                abi.params(),
                generated_schedule.flatThreads(candidate_threads),
                .{
                    .abi = abi,
                    .allocator = allocator,
                    .desc = desc,
                    .work = work,
                    .outline = outline,
                    .buffer_plan = buffer_plan,
                },
                BlockRowPipelineBodyType(candidate_threads).emit,
            );
            lowered.body = .{ .row_pipeline = .{
                .threads = candidate_threads,
                .rows = desc.rows,
                .cols = desc.cols,
                .warps = candidate_threads / warp_size,
            } };
            return lowered;
        }
    }
    return null;
}

fn store_row_pipeline_partial(inner: anytype, store_ctx: anytype) !void {
    try inner.storeIndex(store_ctx.acc, store_ctx.partials, store_ctx.warp);
}

fn emitBlockRowPipelineBodyScheduled(
    comptime pipeline_threads: u32,
    logical: anytype,
    ctx: anytype,
) !void {
    const desc: PipelineDescription = ctx.desc;
    const quads: u32 = desc.cols / (pipeline_threads * 4);
    const warps: u32 = pipeline_threads / warp_size;

    const domain = try logical.index1D("lane", @as(u64, desc.rows) * pipeline_threads);
    const global = domain.index;
    const threads_extent = try logical.constantIndex(pipeline_threads);
    const row = try logical.div(global, threads_extent);
    const tid = try logical.sub(global, try logical.mul(row, threads_extent));
    const cols_extent = try logical.constantIndex(desc.cols);
    const row_base = try logical.mul(row, cols_extent);

    const warp_extent = try logical.constantIndex(warp_size);
    const warp = try logical.div(tid, warp_extent);
    const lane = try logical.sub(tid, try logical.mul(warp, warp_extent));

    const partials = try logical.sharedBuffer(.f32, warps);

    var leaf_quads: [max_leaves][max_quads]kernel_root.Value = undefined;
    for (desc.leaves[0..desc.leaf_count], 0..) |leaf, leaf_index| {
        const input = ctx.abi.input(logical, leaf.input_index);
        var quad: u32 = 0;
        while (quad < quads) : (quad += 1) {
            const offset = try logical.constantIndex(@as(i64, quad) * pipeline_threads);
            const element = try logical.mul(
                try logical.add(offset, tid),
                try logical.constantIndex(4),
            );
            const index = switch (leaf.kind) {
                .full => try logical.add(row_base, element),
                .column => element,
            };
            leaf_quads[leaf_index][quad] = try logical.loadVector(input, index, 4);
        }
    }

    var stat_values = std.AutoHashMap(*ir.Value, kernel_root.Value).init(ctx.allocator);
    defer stat_values.deinit();

    var scalars: [max_reduces]?kernel_root.Value = @splat(null);
    for (desc.reduces[0..desc.reduce_count], 0..) |entry, reduce_index| {
        var acc = try reduction.reductionNeutral(logical, entry.kind, .f32);
        var quad: u32 = 0;
        while (quad < quads) : (quad += 1) {
            var lane_index: u32 = 0;
            while (lane_index < 4) : (lane_index += 1) {
                var resolve_ctx = ResolveContext.init(ctx.allocator, &desc);
                defer resolve_ctx.deinit();
                resolve_ctx.scalars = scalars;
                resolve_ctx.stats = &stat_values;
                for (0..desc.leaf_count) |leaf_index| {
                    resolve_ctx.leaf_values[leaf_index] = try logical.extractLane(
                        leaf_quads[leaf_index][quad],
                        lane_index,
                        .f32,
                    );
                }
                const value = try resolveValue(logical, &resolve_ctx, entry.input);
                acc = try reduction.emitReductionValue(logical, entry.kind, acc, value);
            }
        }
        acc = try logical.warpReduce(reduction.warpKindForReduction(entry.kind), acc);

        if (reduce_index > 0) try logical.barrier(.block);
        const zero = try logical.constantIndex(0);
        const lane_zero = try logical.compare(.eq, lane, zero);
        try logical.guardDo(
            lane_zero,
            .{ .partials = partials, .warp = warp, .acc = acc },
            store_row_pipeline_partial,
        );
        try logical.barrier(.block);

        var total = try logical.constantFloat(.f32, entry.init);
        var warp_index: u32 = 0;
        while (warp_index < warps) : (warp_index += 1) {
            const loaded = try logical.loadIndex(partials, try logical.constantIndex(warp_index));
            total = try reduction.emitReductionValue(logical, entry.kind, total, loaded);
        }
        scalars[reduce_index] = total;
    }

    const out = ctx.abi.output(logical);
    const root_result = desc.root.getResult(0) orelse return error.InvalidArtifact;
    var quad: u32 = 0;
    while (quad < quads) : (quad += 1) {
        const offset = try logical.constantIndex(@as(i64, quad) * pipeline_threads);
        const element = try logical.mul(try logical.add(offset, tid), try logical.constantIndex(4));
        const base = try logical.add(row_base, element);
        var lane_index: u32 = 0;
        while (lane_index < 4) : (lane_index += 1) {
            var resolve_ctx = ResolveContext.init(ctx.allocator, &desc);
            defer resolve_ctx.deinit();
            resolve_ctx.scalars = scalars;
            resolve_ctx.stats = &stat_values;
            for (0..desc.leaf_count) |leaf_index| {
                resolve_ctx.leaf_values[leaf_index] = try logical.extractLane(
                    leaf_quads[leaf_index][quad],
                    lane_index,
                    .f32,
                );
            }
            const value = try resolveValue(logical, &resolve_ctx, root_result);
            const index = try logical.add(base, try logical.constantIndex(lane_index));
            try logical.storeIndex(value, out, index);
        }
    }
}

fn store_serial_row_pipeline_value(
    store_inner: anytype,
    col: kernel_root.Value,
    store_ctx: anytype,
) !void {
    const value = try serialResolve(
        store_inner,
        store_ctx,
        store_ctx.scalars,
        store_ctx.row_base,
        col,
        store_ctx.root_result,
    );
    const index = try store_inner.add(store_ctx.row_base, col);
    try store_inner.storeIndex(value, store_ctx.out, index);
}

fn emit_serial_row_pipeline_row(inner: anytype, guard_ctx: anytype) !void {
    const desc_inner: PipelineDescription = guard_ctx.desc;
    const cols_extent = try inner.constantIndex(desc_inner.cols);
    const row_base = try inner.mul(guard_ctx.row, cols_extent);
    const one = try inner.constantIndex(1);
    const zero = try inner.constantIndex(0);

    var scalars: [max_reduces]?kernel_root.Value = @splat(null);
    for (desc_inner.reduces[0..desc_inner.reduce_count], 0..) |entry, reduce_index| {
        const init_value = try inner.constantFloat(.f32, entry.init);
        var scope = try inner.forScope(
            zero,
            cols_extent,
            one,
            &.{init_value},
            &.{init_value.valueType()},
        );
        errdefer scope.abort();
        const col = scope.inductionVar();
        const current = scope.iterArg(0) orelse return error.UnsupportedOperation;
        const value = try serialResolve(inner, guard_ctx, scalars, row_base, col, entry.input);
        const updated = try reduction.emitReductionValue(inner, entry.kind, current, value);
        try scope.leave(&.{updated});
        scalars[reduce_index] = scope.result(0) orelse return error.UnsupportedOperation;
    }

    const out = guard_ctx.abi.output(inner);
    const root_result = desc_inner.root.getResult(0) orelse return error.InvalidArtifact;
    _ = try inner.forDo(zero, cols_extent, one, .{
        .abi = guard_ctx.abi,
        .allocator = guard_ctx.allocator,
        .desc = desc_inner,
        .row_base = row_base,
        .scalars = scalars,
        .root_result = root_result,
        .out = out,
    }, store_serial_row_pipeline_value);
}

fn emitSerialRowPipelineBody(logical: anytype, ctx: anytype) !void {
    const desc: PipelineDescription = ctx.desc;

    const domain = try logical.index1D("row", desc.rows);
    const row = domain.index;
    const rows_extent = try logical.constantIndex(desc.rows);
    const row_ok = try logical.compare(.lt, row, rows_extent);
    try logical.guardDo(row_ok, .{
        .abi = ctx.abi,
        .allocator = ctx.allocator,
        .desc = desc,
        .row = row,
    }, emit_serial_row_pipeline_row);
}

fn serialResolve(
    inner: anytype,
    guard_ctx: anytype,
    scalars: [max_reduces]?kernel_root.Value,
    row_base: kernel_root.Value,
    col: kernel_root.Value,
    value: *ir.Value,
) common.LoweringError!kernel_root.Value {
    const desc: PipelineDescription = guard_ctx.desc;
    var resolve_ctx = ResolveContext.init(guard_ctx.allocator, &desc);
    defer resolve_ctx.deinit();
    resolve_ctx.scalars = scalars;
    for (desc.leaves[0..desc.leaf_count], 0..) |leaf, leaf_index| {
        const input = guard_ctx.abi.input(inner, leaf.input_index);
        const index = switch (leaf.kind) {
            .full => inner.add(row_base, col) catch |err| return mapKernelBuildError(err),
            .column => col,
        };
        resolve_ctx.leaf_values[leaf_index] = inner.loadIndex(
            input,
            index,
        ) catch |err| return mapKernelBuildError(err);
    }
    return resolveValue(inner, &resolve_ctx, value);
}
