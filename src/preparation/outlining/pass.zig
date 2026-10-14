const std = @import("std");
const alloc_fixed = @import("alloc_fixed");
const choir = @import("choir");
const bufferization = @import("../bufferization/root.zig");
const accy_choir = @import("../../choir/root.zig");
const dialect_mod = accy_choir.dialect;
const kernelization_model = @import("../kernelization/model/root.zig");
const schedule_planning = @import("../schedule/root.zig");

const ir = choir.ir;
const passes = choir.passes;
const accounting = passes.pass.work;

pub const kernel_outlining_planning_pass_name = "accy-choir-plan-kernel-outlines";
pub const kernel_outlining_planning_pass_description =
    "Plan Accy Choir kernel outline candidates";

const KernelOutlineKind = kernelization_model.KernelOutlineKind;
const KernelOutline = kernelization_model.KernelOutline;
const KernelOutlinePlanAnalysis = kernelization_model.KernelOutlinePlanAnalysis;

const OutlineWork = struct {
    input: accounting.Census,

    fn inspect(input: accounting.Input) !OutlineWork {
        if (input.options.max_threads != 1 or input.options.worker_allocator != null) {
            return error.MissingWorkContract;
        }
        var scope = input.operation;
        _ = try scope.walk(.{ .order = .pre_order }, &scope, checkScope);
        return .{ .input = try accounting.Census.inspect(scope) };
    }

    fn checkScope(root: **ir.Operation, op: *ir.Operation) !ir.Operation.WalkResult {
        ir.traits.verifyOperandsWithin(root.*, op) catch return error.UnboundProductInput;
        return .advance;
    }

    fn storage(self: OutlineWork) !u64 {
        const count = self.input.operations;
        const values = self.input.values;
        var per_work = try accounting.hashMapGrowth(*ir.Operation, void, count);
        per_work = try accounting.add(per_work, try accounting.hashMapGrowth(usize, void, values));
        const memo = try accounting.hashMapGrowth(*ir.Value, u64, values);
        per_work = try accounting.add(per_work, memo);
        per_work = try accounting.add(per_work, try accounting.arrayListGrowth(usize, values));
        const owned_inputs = try accounting.add(
            try accounting.multiply(values, @sizeOf(usize)),
            @alignOf(usize),
        );
        per_work = try accounting.add(per_work, owned_inputs);
        const name_bytes = "accy_choir_kernel_".len + 3 * @sizeOf(usize);
        per_work = try accounting.add(per_work, name_bytes);
        var bytes: u64 = @sizeOf(KernelOutlinePlanAnalysis) + @alignOf(KernelOutlinePlanAnalysis);
        bytes = try accounting.add(bytes, try accounting.multiply(count, per_work));
        bytes = try accounting.add(bytes, try accounting.arrayListGrowth(KernelOutline, count));
        bytes = try accounting.add(bytes, try accounting.hashMapGrowth(usize, usize, count));
        bytes = try accounting.add(bytes, try accounting.hashMapGrowth(usize, void, values));
        if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
        return bytes;
    }

    fn bounds(self: OutlineWork) !accounting.Bounds {
        const bytes = try self.storage();
        const input_units = try accounting.add(self.input.atoms, self.input.input_bytes);
        const units = try accounting.add(input_units, 1);
        const entries = try accounting.add(self.input.operations, self.input.values);
        const probes = try accounting.hashMapCapacity(entries);
        const leaf_states = try accounting.multiply(
            elided_leaf_walk_depth,
            try accounting.add(self.input.values, 1),
        );
        const edges = try accounting.multiply(
            leaf_states,
            try accounting.add(self.input.operands, 1),
        );
        const work_visits = try accounting.multiply(
            try accounting.add(edges, units),
            try accounting.add(try accounting.add(units, probes), 1),
        );
        const visits = try accounting.multiply(
            try accounting.add(self.input.operations, 1),
            work_visits,
        );
        return .{
            .work = .{
                .input_bytes = self.input.input_bytes,
                .structural_visits = try accounting.multiply(64, visits),
                .analysis_computations = 1,
                .allocation_capacity = bytes,
            },
            .workspace = bytes,
            .retained_storage = bytes,
        };
    }
};

fn outlineAnalysisWork(input: accounting.Input) !accounting.Bounds {
    return (try OutlineWork.inspect(input)).bounds();
}

fn outlinePassWork(_: accounting.Input) !accounting.Bounds {
    return .{ .work = .{ .structural_visits = 1 } };
}

pub const kernel_outline_plan_analysis_descriptor = passes.AnalysisDescriptor{
    .id = passes.analysisId(kernelization_model.kernel_outline_plan_analysis_name),
    .name = kernelization_model.kernel_outline_plan_analysis_name,
    .work_contract = .{
        .identity = .{
            .name = kernelization_model.kernel_outline_plan_analysis_name,
            .version = 1,
        },
        .estimate = outlineAnalysisWork,
    },
};

pub fn getKernelOutlinePlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) !*KernelOutlinePlanAnalysis {
    const ptr = try pass_ctx.getAnalysis(
        op,
        &kernel_outline_plan_analysis_descriptor,
        computeKernelOutlinePlanAnalysis,
        cleanupKernelOutlinePlanAnalysis,
    );
    return @ptrCast(@alignCast(ptr));
}

pub fn kernelOutliningPlanningPass() passes.Pass {
    return .{
        .name = kernel_outlining_planning_pass_name,
        .description = kernel_outlining_planning_pass_description,
        .run_fn = runKernelOutliningPlanningPass,
        .work_contract = .{
            .identity = .{ .name = kernel_outlining_planning_pass_name, .version = 1 },
            .estimate = outlinePassWork,
        },
    };
}

fn runKernelOutliningPlanningPass(pass_ctx: *passes.PassContext) passes.PassResult {
    _ = getKernelOutlinePlanAnalysis(pass_ctx, pass_ctx.op) catch return .failure;
    pass_ctx.preserveAllAnalyses();
    return .success;
}

fn computeKernelOutlinePlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) anyerror!*anyopaque {
    const schedule_plan = try schedule_planning.getSchedulePlanAnalysis(pass_ctx, op);
    const buffer_plan = try bufferization.getBufferPlanAnalysis(pass_ctx, op);

    const analysis = try pass_ctx.allocator.create(KernelOutlinePlanAnalysis);
    analysis.* = KernelOutlinePlanAnalysis.init(pass_ctx.allocator);
    errdefer {
        analysis.deinit();
        pass_ctx.allocator.destroy(analysis);
    }

    try addKernelOutlines(pass_ctx, analysis, schedule_plan, buffer_plan);
    try validateOutlineSlotDataflow(pass_ctx.allocator, analysis, buffer_plan);

    return @ptrCast(analysis);
}

fn validateOutlineSlotDataflow(
    allocator: std.mem.Allocator,
    analysis: *const KernelOutlinePlanAnalysis,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) !void {
    var written = std.AutoHashMap(usize, void).init(allocator);
    defer written.deinit();
    for (analysis.kernels.items) |outline| {
        try written.put(outline.output_slot_id, {});
        if (outline.kind == .kernel_call) {
            for (outline.input_slot_ids) |slot_id| {
                try written.put(slot_id, {});
            }
        }
        if (outline.kind == .iterate) {
            var result_index: usize = 0;
            while (outline.root.getResult(result_index)) |result| : (result_index += 1) {
                const slot = buffer_plan.getSlot(result) orelse continue;
                try written.put(slot.id, {});
            }
        }
        if (outline.kind == .scan) {
            if (outline.root.getOperand(1)) |scratch| {
                if (buffer_plan.getSlot(scratch)) |slot| {
                    try written.put(slot.id, {});
                }
            }
        }
    }

    for (analysis.kernels.items) |outline| {
        if (outline.kind == .kernel_call) continue;
        for (outline.input_slot_ids) |slot_id| {
            if (written.contains(slot_id)) continue;
            const slot = bufferSlotById(buffer_plan, slot_id) orelse
                return error.UnwrittenKernelInput;
            if (slot.role.input or slot.role.constant) continue;
            return error.UnwrittenKernelInput;
        }
    }
}

fn bufferSlotById(
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    slot_id: usize,
) ?*const bufferization.BufferSlot {
    for (buffer_plan.slots.items) |*slot| {
        if (slot.id == slot_id) return slot;
    }
    return null;
}

fn cleanupKernelOutlinePlanAnalysis(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const analysis: *KernelOutlinePlanAnalysis = @ptrCast(@alignCast(ptr));
    analysis.deinit();
    allocator.destroy(analysis);
}

fn collectInputSlots(
    allocator: std.mem.Allocator,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) ![]usize {
    var inputs: std.ArrayListUnmanaged(usize) = .empty;
    errdefer inputs.deinit(allocator);
    var seen = std.AutoHashMap(usize, void).init(allocator);
    defer seen.deinit();
    var leaves = LeafWalk.init(allocator, buffer_plan, &seen, &inputs);
    defer leaves.deinit();
    var op_set = std.AutoHashMap(*ir.Operation, void).init(allocator);
    defer op_set.deinit();
    for (work.ops) |op| try op_set.put(op, {});

    for (work.ops) |op| {
        for (op.getOperandValues(), 0..) |operand, operand_index| {
            if ((work.kind == .reduction or work.kind == .row_pipeline) and
                isConstantReduceInitOperand(buffer_plan, op, operand, operand_index)) continue;
            if ((work.kind == .row_pipeline or
                work.kind == .flash_attention) and operandIsConstant(operand)) continue;
            if (work.kind == .flash_attention and operandIsBroadcastOfConstant(operand)) continue;
            if (operand.getDefiningOp()) |def_any| {
                const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
                if (op_set.contains(def_op)) continue;
            }
            const slot_value = schedule_planning.kernelInputValueForOperand(work, operand);
            if (buffer_plan.getSlot(slot_value)) |slot| {
                if (seen.contains(slot.id)) continue;
                try seen.put(slot.id, {});
                try inputs.append(allocator, slot.id);
                continue;
            }
            switch (work.kind) {
                .elementwise_single, .elementwise_fusion, .reduction, .row_pipeline, .iterate, .flash_attention => {
                    try leaves.collect(operand, elided_leaf_walk_depth);
                },
                else => {},
            }
        }
    }

    if (work.kind == .iterate and work.ops.len == 1) {
        try collectIterateCaptureSlots(&leaves, work.ops[0]);
        var result_index: usize = 0;
        while (work.ops[0].getResult(result_index)) |result| : (result_index += 1) {
            if (result.first_use == null) continue;
            const slot = buffer_plan.getSlot(result) orelse return error.MissingOutputSlot;
            if (slot.id == buffer_plan.getSlot(work.output_value).?.id) continue;
            if (seen.contains(slot.id)) continue;
            try seen.put(slot.id, {});
            try inputs.append(allocator, slot.id);
        }
    }

    return try inputs.toOwnedSlice(allocator);
}

fn collectIterateCaptureSlots(leaves: *LeafWalk, iterate: *ir.Operation) anyerror!void {
    if (iterate.regions.items.len != 1) return;
    const region = &iterate.regions.items[0];
    var block_iter = region.getBlocks();
    while (block_iter.next()) |block| {
        var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
        while (current) |op| : (current = op.next_op) {
            for (op.getOperandValues()) |operand| {
                if (operandIsInsideRegion(operand, region)) continue;
                if (operandIsSplatMaterial(operand)) continue;
                const slot = leaves.buffer_plan.getSlot(operand) orelse {
                    try leaves.collect(operand, elided_leaf_walk_depth);
                    continue;
                };
                if (leaves.seen.contains(slot.id)) continue;
                try leaves.seen.put(slot.id, {});
                try leaves.inputs.append(leaves.allocator, slot.id);
            }
        }
    }
}

fn operandIsSplatMaterial(operand: *ir.Value) bool {
    const def_any = operand.getDefiningOp() orelse return false;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (constantOpIsSplat(def_op)) return true;
    if (!std.mem.eql(u8, def_op.name.name, dialect_mod.AccyDialect.BroadcastOp.operation_name) and
        !std.mem.eql(u8, def_op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name))
    {
        return false;
    }
    const operands = def_op.getOperandValues();
    if (operands.len != 1) return false;
    const source_any = operands[0].getDefiningOp() orelse return false;
    const source_op: *ir.Operation = @ptrCast(@alignCast(source_any));
    return constantOpIsSplat(source_op);
}

fn constantOpIsSplat(op: *ir.Operation) bool {
    if (!std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
        return false;
    }
    const constant = dialect_mod.AccyDialect.ConstantOp{ .op = op };
    const payload = constant.getPayload() orelse return false;
    const result = op.getResult(0) orelse return false;
    var dtype_arena_buffer: [160]u8 = undefined;
    var dtype_arena = alloc_fixed.FixedBuffer.init(dtype_arena_buffer[0..]);
    const result_type = dialect_mod.decodeTensorType(
        dtype_arena.allocator(),
        result.type,
    ) catch return false;
    switch (result_type.dtype) {
        .f32, .i32 => {
            if (payload.len < 4 or payload.len % 4 != 0) return false;
            var first: u32 = undefined;
            @memcpy(std.mem.asBytes(&first), payload[0..4]);
            var offset: usize = 4;
            while (offset < payload.len) : (offset += 4) {
                var value: u32 = undefined;
                @memcpy(std.mem.asBytes(&value), payload[offset..][0..4]);
                if (value != first) return false;
            }
            return true;
        },
        .i1 => {
            if (payload.len == 0) return false;
            const first = payload[0];
            for (payload[1..]) |value| {
                if (value != first) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn operandIsInsideRegion(operand: *ir.Value, region: *const ir.Region) bool {
    if (operand.getDefiningOp()) |def_any| {
        const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
        const block = def_op.getBlock() orelse return false;
        return blockInRegion(block, region);
    }
    const owner_any = operand.getOwnerBlock() orelse return false;
    const block: *ir.Block = @ptrCast(@alignCast(owner_any));
    return blockInRegion(block, region);
}

fn blockInRegion(block: *ir.Block, region: *const ir.Region) bool {
    var block_iter = @constCast(region).getBlocks();
    while (block_iter.next()) |candidate| {
        if (candidate == block) return true;
    }
    return false;
}

const elided_leaf_walk_depth = 48;

const LeafWalk = struct {
    allocator: std.mem.Allocator,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    seen: *std.AutoHashMap(usize, void),
    inputs: *std.ArrayListUnmanaged(usize),
    completed: std.AutoHashMap(*ir.Value, u64),
    expansions: u64 = 0,

    fn init(
        allocator: std.mem.Allocator,
        buffer_plan: *const bufferization.BufferPlanAnalysis,
        seen: *std.AutoHashMap(usize, void),
        inputs: *std.ArrayListUnmanaged(usize),
    ) LeafWalk {
        return .{
            .allocator = allocator,
            .buffer_plan = buffer_plan,
            .seen = seen,
            .inputs = inputs,
            .completed = std.AutoHashMap(*ir.Value, u64).init(allocator),
        };
    }

    fn deinit(self: *LeafWalk) void {
        self.completed.deinit();
        self.* = undefined;
    }

    fn collect(self: *LeafWalk, value: *ir.Value, depth: usize) anyerror!void {
        if (depth == 0) return error.WorkExhausted;
        std.debug.assert(depth <= elided_leaf_walk_depth);
        const bit = @as(u64, 1) << @intCast(depth - 1);
        if (self.completed.get(value)) |mask| {
            if (mask & bit != 0) return;
        }
        self.expansions = try passes.pass.work.add(self.expansions, 1);
        try self.expand(value, depth);
        const entry = try self.completed.getOrPut(value);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* |= bit;
    }

    fn expand(self: *LeafWalk, value: *ir.Value, depth: usize) anyerror!void {
        if (value.getDefiningOp()) |def_any| {
            const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
            if (constantOpIsSplat(def_op)) return;
            const broadcast_name = dialect_mod.AccyDialect.BroadcastInDimOp.operation_name;
            if (std.mem.eql(u8, def_op.name.name, broadcast_name)) {
                const operands = def_op.getOperandValues();
                if (operands.len != 1) return error.UnsupportedOperation;
                if (operands[0].getDefiningOp()) |source_any| {
                    const source_op: *ir.Operation = @ptrCast(@alignCast(source_any));
                    if (constantOpIsSplat(source_op)) return;
                }
                const source_slot = self.buffer_plan.getSlot(operands[0]) orelse
                    return error.UnsupportedOperation;
                if (!self.seen.contains(source_slot.id)) {
                    try self.seen.put(source_slot.id, {});
                    try self.inputs.append(self.allocator, source_slot.id);
                }
                return;
            }
        }
        if (self.buffer_plan.getSlot(value)) |slot| {
            if (!self.seen.contains(slot.id)) {
                try self.seen.put(slot.id, {});
                try self.inputs.append(self.allocator, slot.id);
            }
            return;
        }
        const def_any = value.getDefiningOp() orelse return error.UnsupportedOperation;
        const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
        for (def_op.getOperandValues()) |operand| {
            try self.collect(operand, depth - 1);
        }
    }
};

const KernelOutlineSlots = struct {
    input_slot_ids: []usize,
    output_slot_id: usize,

    fn deinit(self: KernelOutlineSlots, allocator: std.mem.Allocator) void {
        allocator.free(self.input_slot_ids);
    }
};

fn collectKernelOutlineSlots(
    allocator: std.mem.Allocator,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) !KernelOutlineSlots {
    const input_slots = try collectInputSlots(allocator, work, buffer_plan);
    errdefer allocator.free(input_slots);
    const output_slot = buffer_plan.getSlot(work.output_value) orelse
        return error.MissingOutputSlot;
    return .{
        .input_slot_ids = input_slots,
        .output_slot_id = output_slot.id,
    };
}

fn addKernelOutlines(
    pass_ctx: *passes.PassContext,
    analysis: *KernelOutlinePlanAnalysis,
    schedule_plan: *const schedule_planning.SchedulePlanAnalysis,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) !void {
    const work_items = schedule_plan.work_items.items;
    if (pass_ctx.workerCount(work_items.len) > 1) {
        return try addKernelOutlinesParallel(pass_ctx, analysis, work_items, buffer_plan);
    }
    for (work_items) |work| {
        const slots = try collectKernelOutlineSlots(pass_ctx.allocator, work, buffer_plan);
        try addKernelWithOwnedSlots(pass_ctx.allocator, analysis, work, slots);
    }
}

const KernelOutlineInputResult = union(enum) {
    pending,
    ok: KernelOutlineSlots,
    err: anyerror,
};

const KernelOutlineInputSlot = struct {
    result: KernelOutlineInputResult = .pending,
};

const KernelOutlineInputBatch = struct {
    allocator: std.mem.Allocator,
    work_items: []const schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    slots: []KernelOutlineInputSlot,
};

fn addKernelOutlinesParallel(
    pass_ctx: *passes.PassContext,
    analysis: *KernelOutlinePlanAnalysis,
    work_items: []const schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) !void {
    const slots = try pass_ctx.allocator.alloc(KernelOutlineInputSlot, work_items.len);
    defer pass_ctx.allocator.free(slots);
    for (slots) |*slot| slot.* = .{};

    const worker_allocator = pass_ctx.workerAllocator();
    defer deinitKernelOutlineInputSlots(worker_allocator, slots);

    var batch = KernelOutlineInputBatch{
        .allocator = worker_allocator,
        .work_items = work_items,
        .buffer_plan = buffer_plan,
        .slots = slots,
    };

    try ir.threading.parallelForEachIndex(
        pass_ctx.run_options,
        work_items.len,
        &batch,
        collectKernelOutlineAt,
    );

    if (firstKernelOutlineInputError(slots)) |err| return err;

    for (work_items, slots) |work, slot| {
        const worker_input_slots = switch (slot.result) {
            .ok => |input_slots| input_slots,
            .pending => unreachable,
            .err => unreachable,
        };
        try addKernelWithClonedSlots(pass_ctx.allocator, analysis, work, worker_input_slots);
    }
}

fn collectKernelOutlineAt(batch: *KernelOutlineInputBatch, index: usize) void {
    batch.slots[index].result = if (collectKernelOutlineSlots(
        batch.allocator,
        batch.work_items[index],
        batch.buffer_plan,
    )) |input_slots|
        .{ .ok = input_slots }
    else |err|
        .{ .err = err };
}

fn firstKernelOutlineInputError(slots: []const KernelOutlineInputSlot) ?anyerror {
    for (slots) |slot| {
        switch (slot.result) {
            .err => |err| return err,
            else => {},
        }
    }
    return null;
}

fn deinitKernelOutlineInputSlots(
    allocator: std.mem.Allocator,
    slots: []KernelOutlineInputSlot,
) void {
    for (slots) |*slot| {
        switch (slot.result) {
            .ok => |kernel_slots| kernel_slots.deinit(allocator),
            else => {},
        }
    }
}

fn addKernelWithClonedSlots(
    allocator: std.mem.Allocator,
    analysis: *KernelOutlinePlanAnalysis,
    work: schedule_planning.ScheduleWorkItem,
    worker_slots: KernelOutlineSlots,
) !void {
    const input_slots = try allocator.dupe(usize, worker_slots.input_slot_ids);
    try addKernelWithOwnedSlots(allocator, analysis, work, .{
        .input_slot_ids = input_slots,
        .output_slot_id = worker_slots.output_slot_id,
    });
}

fn addKernelWithOwnedSlots(
    allocator: std.mem.Allocator,
    analysis: *KernelOutlinePlanAnalysis,
    work: schedule_planning.ScheduleWorkItem,
    slots: KernelOutlineSlots,
) !void {
    errdefer slots.deinit(allocator);
    try addKernel(analysis, work, slots.input_slot_ids, slots.output_slot_id);
}

fn addKernel(
    analysis: *KernelOutlinePlanAnalysis,
    work: schedule_planning.ScheduleWorkItem,
    input_slot_ids: []usize,
    output_slot_id: usize,
) !void {
    if (analysis.work_to_kernel.contains(work.id)) return;
    const id = analysis.kernels.items.len;
    const name = try std.fmt.allocPrint(analysis.allocator, "accy_choir_kernel_{d}", .{id});
    errdefer analysis.allocator.free(name);

    try analysis.work_to_kernel.put(work.id, id);
    errdefer _ = analysis.work_to_kernel.remove(work.id);
    try analysis.kernels.append(analysis.allocator, .{
        .id = id,
        .name = name,
        .kind = kernelKindForWork(work.kind),
        .work_item_id = work.id,
        .root = work.root,
        .input_slot_ids = input_slot_ids,
        .output_slot_id = output_slot_id,
        .element_count = work.element_count,
        .op_count = work.opCount(),
    });

    analysis.total_input_slots += input_slot_ids.len;
    analysis.total_scheduled_ops += work.opCount();
}

fn kernelKindForWork(kind: schedule_planning.ScheduleWorkKind) KernelOutlineKind {
    return switch (kind) {
        .elementwise_single, .elementwise_fusion => .elementwise,
        .shape => .shape,
        .dot_general => .dot_general,
        .reduction => .reduction,
        .kernel_call => .kernel_call,
        .row_pipeline => .row_pipeline,
        .iterate => .iterate,
        .flash_attention => .flash_attention,
        .scan => .scan,
    };
}

fn operandIsBroadcastOfConstant(operand: *ir.Value) bool {
    const def_any = operand.getDefiningOp() orelse return false;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!std.mem.eql(
        u8,
        def_op.name.name,
        dialect_mod.AccyDialect.BroadcastInDimOp.operation_name,
    ) and
        !std.mem.eql(u8, def_op.name.name, dialect_mod.AccyDialect.BroadcastOp.operation_name))
    {
        return false;
    }
    const operands = def_op.getOperandValues();
    if (operands.len != 1) return false;
    return operandIsConstant(operands[0]);
}

fn operandIsConstant(operand: *ir.Value) bool {
    const def_any = operand.getDefiningOp() orelse return false;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    return std.mem.eql(u8, def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name);
}

fn isReduceInitOperand(op: *ir.Operation, operand_index: usize) bool {
    return std.mem.eql(
        u8,
        op.name.name,
        dialect_mod.AccyDialect.ReduceOp.operation_name,
    ) and operand_index == 1;
}

fn isConstantReduceInitOperand(
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    op: *ir.Operation,
    operand: *ir.Value,
    operand_index: usize,
) bool {
    if (!isReduceInitOperand(op, operand_index)) return false;
    const slot = buffer_plan.getSlot(operand) orelse return false;
    return slot.role.constant;
}

const testing = std.testing;
const semantic = accy_choir.semantic;

fn findOpNamedInBlock(block: *ir.Block, name: []const u8) ?*ir.Operation {
    var iter = block.operations.head;
    while (iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (std.mem.eql(u8, op.name.name, name)) return op;
        iter = op.next_op;
    }
    return null;
}

fn checkLeafWalkBoundary(count: usize, exhausted: bool) !void {
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const typ = try builder.tensor(.f32, &.{4});
    var function = try builder.beginFunction("outline_leaf_depth", &.{ typ, typ }, &.{typ});
    const left = function.parameter(0);
    const right = function.parameter(1);
    var leaf = left;
    for (0..count) |_| leaf = try function.add(leaf, right);
    const result = try function.add(leaf, right);
    try function.return_(&.{result});
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    var cache = passes.AnalysisCache.init(testing.allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer pass_ctx.deinit();
    const buffers = try bufferization.getBufferPlanAnalysis(&pass_ctx, module.choir_module);
    try testing.expect(buffers.getElision(leaf) != null);
    var seen = std.AutoHashMap(usize, void).init(testing.allocator);
    defer seen.deinit();
    var inputs: std.ArrayListUnmanaged(usize) = .empty;
    defer inputs.deinit(testing.allocator);
    var leaves = LeafWalk.init(testing.allocator, buffers, &seen, &inputs);
    defer leaves.deinit();
    const collected = leaves.collect(leaf, elided_leaf_walk_depth);
    if (exhausted) {
        try testing.expectError(error.WorkExhausted, collected);
    } else {
        try collected;
        try testing.expectEqualSlices(
            usize,
            &.{ buffers.getSlot(left).?.id, buffers.getSlot(right).?.id },
            inputs.items,
        );
        try testing.expectError(
            error.WorkExhausted,
            leaves.collect(leaf, elided_leaf_walk_depth - 1),
        );
    }
    var empty = bufferization.BufferPlanAnalysis.init(testing.allocator);
    defer empty.deinit();
    var unsupported = LeafWalk.init(testing.allocator, &empty, &seen, &inputs);
    defer unsupported.deinit();
    try testing.expectError(
        error.UnsupportedOperation,
        unsupported.collect(left, elided_leaf_walk_depth),
    );
}

fn checkSharedLeafWalk(count: usize) !void {
    std.debug.assert(count < elided_leaf_walk_depth);
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const typ = try builder.tensor(.f32, &.{4});
    var function = try builder.beginFunction("shared_leaf_walk", &.{typ}, &.{typ});
    const input = function.parameter(0);
    var leaf = input;
    for (0..count) |_| leaf = try function.add(leaf, leaf);
    const result = try function.add(leaf, input);
    try function.return_(&.{result});
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    var cache = passes.AnalysisCache.init(testing.allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer pass_ctx.deinit();
    const buffers = try bufferization.getBufferPlanAnalysis(&pass_ctx, module.choir_module);
    try testing.expect(buffers.getElision(leaf) != null);
    var seen = std.AutoHashMap(usize, void).init(testing.allocator);
    defer seen.deinit();
    var inputs: std.ArrayListUnmanaged(usize) = .empty;
    defer inputs.deinit(testing.allocator);
    var leaves = LeafWalk.init(testing.allocator, buffers, &seen, &inputs);
    defer leaves.deinit();
    try leaves.collect(leaf, elided_leaf_walk_depth);
    const slot_id = buffers.getSlot(input).?.id;
    try testing.expectEqualSlices(usize, &.{slot_id}, inputs.items);
    try testing.expectEqual(count + 1, leaves.expansions);
    try testing.expectEqual(count + 1, leaves.completed.count());
    try leaves.collect(leaf, elided_leaf_walk_depth);
    try testing.expectEqual(count + 1, leaves.expansions);
    try testing.expectEqual(@as(usize, 1), inputs.items.len);
    try checkLeafWalkStorage(leaf, buffers, count + 1, slot_id);
}

fn checkLeafWalkStorage(
    value: *ir.Value,
    buffers: *const bufferization.BufferPlanAnalysis,
    reached_values: u64,
    slot_id: usize,
) !void {
    const memo = try accounting.hashMapGrowth(*ir.Value, u64, reached_values);
    const seen_bytes = try accounting.hashMapGrowth(usize, void, 1);
    const input_bytes = try accounting.arrayListGrowth(usize, 1);
    const allowance = try accounting.add(memo, try accounting.add(seen_bytes, input_bytes));
    const bytes = try testing.allocator.alignedAlloc(u8, .@"64", @intCast(allowance));
    defer testing.allocator.free(bytes);
    var backing = alloc_fixed.Tracked.init(bytes);
    var retained = alloc_fixed.Monotonic.init(backing.allocator(), bytes.len);
    const allocator = retained.allocator();
    var seen = std.AutoHashMap(usize, void).init(allocator);
    defer seen.deinit();
    var inputs: std.ArrayListUnmanaged(usize) = .empty;
    defer inputs.deinit(allocator);
    var leaves = LeafWalk.init(allocator, buffers, &seen, &inputs);
    defer leaves.deinit();
    try leaves.collect(value, elided_leaf_walk_depth);
    try testing.expectEqualSlices(usize, &.{slot_id}, inputs.items);
    try testing.expectEqual(reached_values, leaves.expansions);
    try testing.expectEqual(reached_values, leaves.completed.count());
    try testing.expect(!backing.exhausted);
    const used = if (retained.current) |*current| alloc_fixed.used(current) else 0;
    try testing.expect(used <= allowance);
    try testing.expect(used > 0);
}

fn outlineTestLedger() !*choir.product.revision.AccountingV1 {
    const revision = choir.product.revision;
    return revision.AccountingV1.create(testing.allocator, .{
        .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
        .workspace = std.math.maxInt(u64),
        .events = 32,
    }, &.{});
}

fn checkOutlineStorage(
    op: *ir.Operation,
    ctx: *ir.Context,
    cache: *passes.AnalysisCache,
    expected: *const KernelOutlinePlanAnalysis,
) !void {
    const bounds = try outlineAnalysisWork(.{ .operation = op });
    const bytes = try testing.allocator.alignedAlloc(u8, .@"64", @intCast(bounds.workspace));
    defer testing.allocator.free(bytes);
    var backing = alloc_fixed.Tracked.init(bytes);
    var retained = alloc_fixed.Monotonic.init(backing.allocator(), @max(1, bytes.len));
    const allocator = retained.allocator();
    var pass_ctx = passes.PassContext.init(op, ctx, allocator, cache);
    defer pass_ctx.deinit();
    const ptr = try computeKernelOutlinePlanAnalysis(&pass_ctx, op);
    defer cleanupKernelOutlinePlanAnalysis(ptr, allocator);
    const actual: *KernelOutlinePlanAnalysis = @ptrCast(@alignCast(ptr));
    try expectOutlinePlan(expected, actual);
    const used = if (retained.current) |*current| alloc_fixed.used(current) else 0;
    try testing.expect(!backing.exhausted);
    try testing.expect(used <= bounds.workspace);
    try testing.expect(used >= @sizeOf(KernelOutlinePlanAnalysis));
}

fn expectOutlinePlan(
    expected: *const KernelOutlinePlanAnalysis,
    actual: *const KernelOutlinePlanAnalysis,
) !void {
    try testing.expectEqual(expected.kernelCount(), actual.kernelCount());
    try testing.expectEqual(expected.total_input_slots, actual.total_input_slots);
    try testing.expectEqual(expected.total_scheduled_ops, actual.total_scheduled_ops);
    for (expected.kernels.items, actual.kernels.items) |left, right| {
        inline for (.{
            "id", "kind", "work_item_id", "root", "output_slot_id", "element_count", "op_count",
        }) |field| try testing.expectEqual(@field(left, field), @field(right, field));
        try testing.expectEqualStrings(left.name, right.name);
        try testing.expectEqualSlices(usize, left.input_slot_ids, right.input_slot_ids);
        try testing.expectEqual(right.id, actual.getKernelForWork(right.work_item_id).?.id);
    }
}

fn buildOutlineTestModule(builder: *semantic.Builder, count: usize) !*semantic.SemanticModule {
    const typ = try builder.tensor(.f32, &.{4});
    const types = try testing.allocator.alloc(ir.Type, count);
    defer testing.allocator.free(types);
    @memset(types, typ);
    const results = try testing.allocator.alloc(*ir.Value, count);
    defer testing.allocator.free(results);
    var function = try builder.beginFunction("outline_work", &.{ typ, typ }, types);
    for (results) |*result| {
        result.* = try function.add(function.parameter(0), function.parameter(1));
    }
    try function.return_(results);
    try function.finish();
    return builder.finish();
}

fn rejectOutlineRefresh(_: *passes.PassContext, _: *ir.Operation, _: *anyopaque) !void {
    return error.TestUnexpectedResult;
}

fn checkOutlineOptions(options: ir.ThreadingOptions, refresh: bool) !void {
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const module = try buildOutlineTestModule(&builder, 2);
    defer module.deinit();
    const ledger = try outlineTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(testing.allocator, null, ledger, .{}, 8);
    defer cache.deinit();
    var ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer ctx.deinit();
    const existing = if (refresh)
        try getKernelOutlinePlanAnalysis(&ctx, module.choir_module)
    else
        null;
    const before = ledger.view().charged;
    const entries = cache.entries.count();
    ctx.run_options = options;
    if (refresh) {
        try testing.expectError(error.MissingWorkContract, ctx.refreshAnalysis(
            module.choir_module,
            &kernel_outline_plan_analysis_descriptor,
            rejectOutlineRefresh,
        ));
        try testing.expectEqual(@as(usize, 2), existing.?.kernelCount());
    } else {
        try testing.expectError(
            error.MissingWorkContract,
            getKernelOutlinePlanAnalysis(&ctx, module.choir_module),
        );
    }
    try testing.expectEqualDeep(before, ledger.view().charged);
    try testing.expectEqual(entries, cache.entries.count());
    try testing.expectEqual(.rejected, ledger.view().outcome);
    ctx.run_options = .{};
    try testing.expectError(
        error.TerminalWorkOutcome,
        getKernelOutlinePlanAnalysis(&ctx, module.choir_module),
    );
}

fn outlinePassLedger(visits: u64) !*choir.product.revision.AccountingV1 {
    const revision = choir.product.revision;
    var allowance = revision.WorkVector.uniform(std.math.maxInt(u64));
    allowance.structural_visits = visits;
    return revision.AccountingV1.create(testing.allocator, .{
        .allowance = allowance,
        .workspace = std.math.maxInt(u64),
        .events = 32,
    }, &.{.{ .name = kernel_outlining_planning_pass_name, .version = 1 }});
}

fn checkOutlineAllowance(module: *semantic.SemanticModule, visits: u64, success: bool) !u64 {
    const ledger = try outlinePassLedger(visits);
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(testing.allocator, null, ledger, .{}, 8);
    defer cache.deinit();
    var manager = passes.PassManager.init(testing.allocator);
    defer manager.deinit();
    try manager.addPass(kernelOutliningPlanningPass());
    const result = manager.runWithAnalysisCache(module.choir_module, module.context(), &cache, .{});
    var ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer ctx.deinit();
    if (success) {
        try testing.expectEqual(passes.PassResult.success, result);
        try ledger.producersComplete();
        const before = ledger.view().charged;
        const outlines = try getKernelOutlinePlanAnalysis(&ctx, module.choir_module);
        try testing.expectEqual(@as(usize, 2), outlines.kernelCount());
        try testing.expectEqualDeep(before, ledger.view().charged);
        try testing.expect(ledger.view().executed.counters.analysis_hits > 0);
    } else {
        try testing.expectEqual(passes.PassResult.failure, result);
        try testing.expectEqual(.exhausted, ledger.view().outcome);
        try testing.expectError(
            error.TerminalWorkOutcome,
            getKernelOutlinePlanAnalysis(&ctx, module.choir_module),
        );
    }
    return ledger.view().charged.structural_visits;
}
