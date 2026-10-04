const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const accy_choir = @import("../../choir/root.zig");
const kernel_library = @import("../../kernel/library/root.zig");
const dialect_mod = accy_choir.dialect;
const fusion = @import("../fusion/root.zig");
const shape_analysis = @import("../shape/root.zig");

const semantics = accy_choir.semantics;
const ir = choir.ir;
const passes = choir.passes;
const accounting = passes.pass.work;

pub const schedule_plan_analysis_name = "accy-choir-schedule-plan";
pub const schedule_planning_pass_name = "accy-choir-plan-schedule";
pub const schedule_planning_pass_description =
    "Plan static Accy Choir tensor work items before kernel outlining";

pub const ScheduleWorkKind = accy_choir.record.dispatch.ScheduleWorkKind;

pub const ScheduleResourceEstimate = accy_choir.record.dispatch.ScheduleResourceEstimate;

pub const ScheduleWorkItem = struct {
    id: usize,
    kind: ScheduleWorkKind,
    root: *ir.Operation,
    ops: []*ir.Operation,
    output_value: *ir.Value,
    dtype: gpu_abi.DType,
    rank: usize,
    element_count: u64,
    resources: ScheduleResourceEstimate,

    pub fn opCount(self: ScheduleWorkItem) usize {
        return self.ops.len;
    }

    fn deinit(self: *ScheduleWorkItem, allocator: std.mem.Allocator) void {
        allocator.free(self.ops);
        self.* = undefined;
    }
};

pub const SchedulePlanAnalysis = struct {
    allocator: std.mem.Allocator,
    work_items: std.ArrayListUnmanaged(ScheduleWorkItem),
    root_to_item: std.AutoHashMap(*ir.Operation, usize),
    single_work_count: usize = 0,
    fusion_work_count: usize = 0,
    kernel_call_work_count: usize = 0,
    scheduled_op_count: usize = 0,
    total_static_elements: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) SchedulePlanAnalysis {
        return .{
            .allocator = allocator,
            .work_items = .empty,
            .root_to_item = std.AutoHashMap(*ir.Operation, usize).init(allocator),
        };
    }

    pub fn deinit(self: *SchedulePlanAnalysis) void {
        for (self.work_items.items) |*item| {
            item.deinit(self.allocator);
        }
        self.work_items.deinit(self.allocator);
        self.root_to_item.deinit();
        self.* = undefined;
    }

    pub fn workItemCount(self: SchedulePlanAnalysis) usize {
        return self.work_items.items.len;
    }

    pub fn getWorkForRoot(
        self: *const SchedulePlanAnalysis,
        root: *ir.Operation,
    ) ?*const ScheduleWorkItem {
        const index = self.root_to_item.get(root) orelse return null;
        return &self.work_items.items[index];
    }

    fn addWorkItem(
        self: *SchedulePlanAnalysis,
        kind: ScheduleWorkKind,
        root: *ir.Operation,
        ops: []const *ir.Operation,
        output_value: *ir.Value,
        info: shape_analysis.TensorInfo,
        shapes: *const shape_analysis.ShapeLayoutAnalysis,
    ) !void {
        if (ops.len == 0) return;
        if (self.root_to_item.contains(root)) return;
        const element_count = info.element_count orelse return;
        const total_elements = try accounting.add(self.total_static_elements, element_count);

        const owned_ops = try self.allocator.alloc(*ir.Operation, ops.len);
        errdefer self.allocator.free(owned_ops);
        @memcpy(owned_ops, ops);

        const id = self.work_items.items.len;
        const resources = try resourceEstimateForWork(
            self.allocator,
            ops,
            info,
            shapes,
        );
        try self.root_to_item.put(root, id);
        errdefer _ = self.root_to_item.remove(root);
        try self.work_items.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .root = root,
            .ops = owned_ops,
            .output_value = output_value,
            .dtype = info.dtype,
            .rank = info.rank(),
            .element_count = element_count,
            .resources = resources,
        });

        switch (kind) {
            .elementwise_single => self.single_work_count += 1,
            .elementwise_fusion => self.fusion_work_count += 1,
            .shape => self.single_work_count += 1,
            .dot_general => self.single_work_count += 1,
            .reduction => self.single_work_count += 1,
            .kernel_call => self.kernel_call_work_count += 1,
            .row_pipeline => self.fusion_work_count += 1,
            .iterate => self.single_work_count += 1,
            .flash_attention => self.fusion_work_count += 1,
            .scan => self.single_work_count += 1,
        }
        self.scheduled_op_count += ops.len;
        self.total_static_elements = total_elements;
    }
};

const ScheduleWork = struct {
    input: accounting.Census,
    catalog: u64,

    fn inspect(op: *ir.Operation) !ScheduleWork {
        var calls: u64 = 0;
        _ = try op.walk(.{ .order = .pre_order }, &calls, countCatalogCalls);
        return .{
            .input = try accounting.Census.inspect(op),
            .catalog = if (calls == 0) 0 else try accounting.multiply(calls, try catalogUnits()),
        };
    }

    fn countCatalogCalls(count: *u64, op: *ir.Operation) !ir.Operation.WalkResult {
        if (isKernelCallOp(op)) count.* = try accounting.add(count.*, 1);
        return .advance;
    }

    fn catalogUnits() !u64 {
        var units: u64 = 1;
        for (kernel_library.catalog.descriptors) |descriptor| {
            units = try accounting.add(
                units,
                try accounting.add(1, descriptor.metadata.target.len),
            );
            const specialization = descriptor.metadata.specialization;
            for (specialization.outputs) |shape| {
                units = try accounting.add(units, try accounting.add(1, shape.axes.len));
            }
            var reuses: u64 = 1;
            for (specialization.reduction_reuse) |reuse| {
                reuses = try accounting.add(
                    reuses,
                    try accounting.add(reuse.reduction.len, reuse.shape.axes.len),
                );
            }
            for (specialization.reductions) |reduction| {
                const own = try accounting.add(reduction.name.len, reduction.shape.axes.len);
                units = try accounting.add(
                    units,
                    try accounting.add(try accounting.add(1, own), reuses),
                );
            }
        }
        return units;
    }

    fn storage(self: ScheduleWork) !u64 {
        const count = self.input.operations;
        const pairs = try accounting.multiply(count, count);
        const external = try accounting.add(self.input.values, self.input.operands);
        var bytes: u64 = @sizeOf(SchedulePlanAnalysis) + @alignOf(SchedulePlanAnalysis);
        bytes = try accounting.add(bytes, try accounting.arrayListGrowth(ScheduleWorkItem, count));
        const indexes = try accounting.hashMapGrowth(*ir.Operation, usize, count);
        bytes = try accounting.add(bytes, try accounting.multiply(2, indexes));
        bytes = try accounting.add(bytes, try accounting.hashMapGrowth(*ir.Operation, void, count));
        bytes = try accounting.add(bytes, try accounting.hashMapGrowth(*ir.Value, usize, count));
        const unique = try accounting.hashMapGrowth(*ir.Value, void, external);
        bytes = try accounting.add(bytes, try accounting.multiply(count, unique));
        bytes = try accounting.add(bytes, try accounting.multiply(pairs, @sizeOf(*ir.Operation)));
        bytes = try accounting.add(bytes, try accounting.multiply(count, @alignOf(*ir.Operation)));
        const sort_element = @sizeOf(usize) + 2 * @sizeOf(ScheduleWorkItem) + @sizeOf(bool);
        bytes = try accounting.add(bytes, try accounting.multiply(count, sort_element));
        bytes = try accounting.add(bytes, 4 * @alignOf(ScheduleWorkItem));
        bytes = try accounting.add(
            bytes,
            try accounting.arrayListGrowth(ScheduleDependency, pairs),
        );
        if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
        return bytes;
    }

    fn bounds(self: ScheduleWork) !accounting.Bounds {
        const count = self.input.operations;
        const pairs = try accounting.multiply(count, count);
        const storage_bytes = try self.storage();
        const bytes = try accounting.add(self.input.input_bytes, self.catalog);
        const units = try accounting.add(try accounting.add(self.input.atoms, bytes), 1);
        const entries = try accounting.add(
            count,
            try accounting.add(self.input.values, self.input.operands),
        );
        const probes = try accounting.hashMapCapacity(entries);
        const inner = try accounting.add(
            try accounting.add(pairs, count),
            try accounting.add(probes, units),
        );
        const visits = try accounting.multiply(
            try accounting.multiply(units, try accounting.add(count, 1)),
            inner,
        );
        return .{
            .work = .{
                .input_bytes = bytes,
                .structural_visits = try accounting.multiply(64, visits),
                .analysis_computations = 1,
                .allocation_capacity = storage_bytes,
            },
            .workspace = storage_bytes,
            .retained_storage = storage_bytes,
        };
    }
};

fn scheduleAnalysisWork(input: accounting.Input) !accounting.Bounds {
    return (try ScheduleWork.inspect(input.operation)).bounds();
}

fn schedulePassWork(_: accounting.Input) !accounting.Bounds {
    return .{ .work = .{ .structural_visits = 1 } };
}

pub const schedule_plan_analysis_descriptor = passes.AnalysisDescriptor{
    .id = passes.analysisId(schedule_plan_analysis_name),
    .name = schedule_plan_analysis_name,
    .work_contract = .{
        .identity = .{ .name = schedule_plan_analysis_name, .version = 1 },
        .estimate = scheduleAnalysisWork,
    },
};

pub fn getSchedulePlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) !*SchedulePlanAnalysis {
    const ptr = try pass_ctx.getAnalysis(
        op,
        &schedule_plan_analysis_descriptor,
        computeSchedulePlanAnalysis,
        cleanupSchedulePlanAnalysis,
    );
    return @ptrCast(@alignCast(ptr));
}

pub fn schedulePlanningPass() passes.Pass {
    return .{
        .name = schedule_planning_pass_name,
        .description = schedule_planning_pass_description,
        .run_fn = runSchedulePlanningPass,
        .work_contract = .{
            .identity = .{ .name = schedule_planning_pass_name, .version = 1 },
            .estimate = schedulePassWork,
        },
    };
}

fn runSchedulePlanningPass(pass_ctx: *passes.PassContext) passes.PassResult {
    _ = getSchedulePlanAnalysis(pass_ctx, pass_ctx.op) catch return .failure;
    pass_ctx.preserveAllAnalyses();
    return .success;
}

fn computeSchedulePlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) anyerror!*anyopaque {
    const shapes = try shape_analysis.getShapeLayoutAnalysis(pass_ctx, op);
    const fusion_plan = try fusion.getFusionPlanAnalysis(pass_ctx, op);

    const analysis = try pass_ctx.allocator.create(SchedulePlanAnalysis);
    analysis.* = SchedulePlanAnalysis.init(pass_ctx.allocator);
    errdefer {
        analysis.deinit();
        pass_ctx.allocator.destroy(analysis);
    }

    var claimed = std.AutoHashMap(*ir.Operation, void).init(pass_ctx.allocator);
    defer claimed.deinit();

    try addFusionWorkItems(fusion_plan, shapes, analysis, &claimed);
    try addStandaloneWorkItems(op, shapes, analysis, &claimed);
    try addBroadcastWorkItems(op, shapes, analysis, &claimed);
    try orderWorkItemsByDependencies(pass_ctx.allocator, analysis);

    return @ptrCast(analysis);
}

fn cleanupSchedulePlanAnalysis(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const analysis: *SchedulePlanAnalysis = @ptrCast(@alignCast(ptr));
    analysis.deinit();
    allocator.destroy(analysis);
}

fn addFusionWorkItems(
    fusion_plan: *const fusion.FusionPlanAnalysis,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *SchedulePlanAnalysis,
    claimed: *std.AutoHashMap(*ir.Operation, void),
) !void {
    for (fusion_plan.clusters.items) |cluster| {
        const root = cluster.root() orelse continue;
        const info = staticResultInfo(root, shapes) orelse continue;
        const result = root.getResult(0) orelse continue;

        try analysis.addWorkItem(
            switch (cluster.kind) {
                .elementwise => .elementwise_fusion,
                .dot_epilogue => .dot_general,
                .reduction_input => .reduction,
                .row_pipeline => .row_pipeline,
                .flash_attention => .flash_attention,
            },
            root,
            cluster.ops,
            result,
            info,
            shapes,
        );

        for (cluster.ops) |op| {
            try claimed.put(op, {});
        }
    }

    for (fusion_plan.elided.items) |op| {
        try claimed.put(op, {});
    }
}

fn addStandaloneWorkItems(
    op: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *SchedulePlanAnalysis,
    claimed: *std.AutoHashMap(*ir.Operation, void),
) !void {
    if (fusion.isFusableElementwiseOp(op) and !claimed.contains(op)) {
        if (staticResultInfo(op, shapes)) |info| {
            if (op.getResult(0)) |result| {
                try analysis.addWorkItem(
                    .elementwise_single,
                    op,
                    &.{op},
                    result,
                    info,
                    shapes,
                );
                try claimed.put(op, {});
            }
        }
    }

    if (isDotGeneralOp(op) and !claimed.contains(op)) {
        if (staticResultInfo(op, shapes)) |info| {
            if (op.getResult(0)) |result| {
                try analysis.addWorkItem(
                    .dot_general,
                    op,
                    &.{op},
                    result,
                    info,
                    shapes,
                );
                try claimed.put(op, {});
            }
        }
    }

    if (isShapeKernelOp(op) and !claimed.contains(op)) {
        if (staticResultInfo(op, shapes)) |info| {
            if (op.getResult(0)) |result| {
                try analysis.addWorkItem(
                    .shape,
                    op,
                    &.{op},
                    result,
                    info,
                    shapes,
                );
                try claimed.put(op, {});
            }
        }
    }

    if (isReduceOp(op) and !claimed.contains(op)) {
        if (staticResultInfo(op, shapes)) |info| {
            if (op.getResult(0)) |result| {
                try analysis.addWorkItem(
                    .reduction,
                    op,
                    &.{op},
                    result,
                    info,
                    shapes,
                );
                try claimed.put(op, {});
            }
        }
    }

    if (isCumsumOp(op) and !claimed.contains(op)) {
        if (staticResultInfo(op, shapes)) |info| {
            if (op.getResult(0)) |result| {
                try analysis.addWorkItem(
                    .scan,
                    op,
                    &.{op},
                    result,
                    info,
                    shapes,
                );
                try claimed.put(op, {});
            }
        }
    }

    if (isIterateOp(op) and !claimed.contains(op)) {
        if (staticResultInfo(op, shapes)) |info| {
            if (iterateOutputResult(op)) |result| {
                try analysis.addWorkItem(
                    .iterate,
                    op,
                    &.{op},
                    result,
                    info,
                    shapes,
                );
                try claimed.put(op, {});
            }
        }
    }

    if (isKernelCallOp(op) and !claimed.contains(op)) {
        if (op.getNumResults() == 1) {
            if (staticResultInfo(op, shapes)) |info| {
                if (op.getResult(0)) |result| {
                    try analysis.addWorkItem(
                        .kernel_call,
                        op,
                        &.{op},
                        result,
                        info,
                        shapes,
                    );
                    try claimed.put(op, {});
                }
            }
        }
    }

    if (fusion.regionsAreOpaque(op)) return;

    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                try addStandaloneWorkItems(
                    current_op,
                    shapes,
                    analysis,
                    claimed,
                );
                current = current_op.next_op;
            }
        }
    }
}

fn isDotGeneralOp(op: *ir.Operation) bool {
    return std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.DotGeneralOp.operation_name);
}

fn isReduceOp(op: *ir.Operation) bool {
    return std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ReduceOp.operation_name);
}

fn iterateOutputResult(op: *ir.Operation) ?*ir.Value {
    var result_index: usize = 0;
    while (op.getResult(result_index)) |result| : (result_index += 1) {
        if (result.first_use != null) return result;
    }
    return op.getResult(0);
}

fn isCumsumOp(op: *ir.Operation) bool {
    return std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.CumsumOp.operation_name);
}

fn isIterateOp(op: *ir.Operation) bool {
    return std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.IterateOp.operation_name);
}

fn isKernelCallOp(op: *ir.Operation) bool {
    return std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.KernelCallOp.operation_name);
}

fn isShapeKernelOp(op: *ir.Operation) bool {
    return std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.IotaOp.operation_name) or
        std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ReshapeOp.operation_name) or
        std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.TransposeOp.operation_name) or
        std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.SliceOp.operation_name) or
        std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.PadOp.operation_name) or
        std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ConcatenateOp.operation_name) or
        std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.GatherOp.operation_name) or
        std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ScatterOp.operation_name);
}

fn addBroadcastWorkItems(
    op: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *SchedulePlanAnalysis,
    claimed: *std.AutoHashMap(*ir.Operation, void),
) !void {
    const initial_work_count = analysis.workItemCount();
    for (0..initial_work_count) |index| {
        const work = analysis.work_items.items[index];
        for (work.ops) |member| {
            for (member.getOperandValues()) |operand| {
                const input = kernelInputValueForOperand(work, operand);
                try materializeBroadcast(input, shapes, analysis, claimed);
            }
        }
    }
    var state = ReturnedBroadcastState{
        .shapes = shapes,
        .analysis = analysis,
        .claimed = claimed,
    };
    _ = try op.walk(.{ .order = .pre_order }, &state, ReturnedBroadcastState.visit);
}

const ReturnedBroadcastState = struct {
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *SchedulePlanAnalysis,
    claimed: *std.AutoHashMap(*ir.Operation, void),

    fn visit(self: *ReturnedBroadcastState, op: *ir.Operation) !ir.WalkResult {
        if (fusion.regionsAreOpaque(op)) return .skip;
        if (std.mem.eql(u8, op.name.name, "func.return") or
            std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ReturnOp.operation_name))
        {
            for (op.getOperandValues()) |result| {
                try materializeBroadcast(result, self.shapes, self.analysis, self.claimed);
            }
        }
        return .advance;
    }
};

fn materializeBroadcast(
    value: *ir.Value,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *SchedulePlanAnalysis,
    claimed: *std.AutoHashMap(*ir.Operation, void),
) !void {
    var current = value;
    while (current.getDefiningOp()) |defining| {
        const op: *ir.Operation = @ptrCast(@alignCast(defining));
        const broadcast_name = dialect_mod.AccyDialect.BroadcastInDimOp.operation_name;
        if (!std.mem.eql(u8, op.name.name, broadcast_name)) {
            return;
        }
        if (claimed.contains(op)) return;
        const info = staticResultInfo(op, shapes) orelse return;
        try analysis.addWorkItem(.shape, op, &.{op}, current, info, shapes);
        try claimed.put(op, {});
        current = op.getOperand(0) orelse return error.InvalidBroadcast;
    }
}

fn staticResultInfo(
    op: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
) ?shape_analysis.TensorInfo {
    const result = op.getResult(0) orelse return null;
    const info = shapes.get(result) orelse return null;
    if (!info.hasStaticLayout()) return null;
    return info;
}

fn resourceEstimateForWork(
    allocator: std.mem.Allocator,
    ops: []const *ir.Operation,
    info: shape_analysis.TensorInfo,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
) !ScheduleResourceEstimate {
    const element_count = info.element_count orelse return error.UnsupportedOperation;
    const resource_element_count = reductionInputElementCount(ops, shapes) orelse element_count;
    const element_size: u64 = @intCast(info.dtype.sizeOf());
    var resources = ScheduleResourceEstimate{
        .element_count = resource_element_count,
        .element_size = element_size,
        .op_count = ops.len,
        .estimated_element_ops = estimatedElementOpsForWork(ops, element_count, shapes),
    };

    var unique_external_values = std.AutoHashMap(*ir.Value, void).init(allocator);
    defer unique_external_values.deinit();

    if (tensorByteSize(info)) |bytes| {
        resources.static_write_bytes = saturatedAdd(resources.static_write_bytes, bytes);
    } else {
        resources.static_bytes_complete = false;
    }

    for (ops) |op| {
        for (op.getOperandValues(), 0..) |operand, operand_index| {
            if (isConstantReduceInitOperand(op, operand, operand_index)) continue;
            if (valueProducedByWork(operand, ops)) {
                resources.chain_operand_count += 1;
                continue;
            }
            resources.external_operand_count += 1;
            try putUniqueExternalValue(&unique_external_values, operand, &resources);
            if (!operandReads(op, operand_index)) continue;
            const operand_info = shapes.get(operand) orelse {
                resources.static_bytes_complete = false;
                continue;
            };
            if (tensorByteSize(operand_info)) |bytes| {
                resources.static_read_bytes = saturatedAdd(resources.static_read_bytes, bytes);
            } else {
                resources.static_bytes_complete = false;
            }
        }
    }

    resources.static_total_bytes = saturatedAdd(
        resources.static_read_bytes,
        resources.static_write_bytes,
    );
    return resources;
}

fn operandReads(op: *ir.Operation, operand_index: usize) bool {
    if (!isKernelCallOp(op)) return true;
    const attr = op.getAttr("operand_effects") orelse return true;
    if (!std.mem.eql(
        u8,
        attr.abstract.name,
        dialect_mod.AccyDialect.KernelCallOp.operand_effects_attr_name,
    )) return true;
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return true;
    if (operand_index >= dialect_attr.payload.len) return true;
    const effect = semantics.KernelOperandEffect.fromByte(
        dialect_attr.payload[operand_index],
    ) orelse return true;
    return switch (effect) {
        .read, .read_write, .unknown => true,
        .none, .write => false,
    };
}

fn isReduceInitOperand(op: *ir.Operation, operand_index: usize) bool {
    return isReduceOp(op) and operand_index == 1;
}

fn isConstantReduceInitOperand(
    op: *ir.Operation,
    operand: *ir.Value,
    operand_index: usize,
) bool {
    if (!isReduceInitOperand(op, operand_index)) return false;
    const def_any = operand.getDefiningOp() orelse return false;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    return std.mem.eql(u8, def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name);
}

fn estimatedElementOpsForWork(
    ops: []const *ir.Operation,
    fallback_element_count: u64,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
) u64 {
    if (ops.len == 1 and isDotGeneralOp(ops[0])) {
        return dotGeneralElementOps(ops[0], shapes) orelse fallback_element_count;
    }
    if (ops.len == 1 and isReduceOp(ops[0])) {
        return reductionInputElementCount(ops, shapes) orelse fallback_element_count;
    }
    if (ops.len == 1 and isKernelCallOp(ops[0])) {
        return kernelCallElementOps(ops[0]) orelse fallback_element_count;
    }
    return saturatedMul(fallback_element_count, @intCast(ops.len));
}

fn kernelCallElementOps(op: *ir.Operation) ?u64 {
    const descriptor = kernelCallLibraryDescriptor(op) orelse return null;
    return descriptor.metadata.specialization.estimatedElementOps();
}

fn kernelCallLibraryDescriptor(op: *ir.Operation) ?kernel_library.CatalogDescriptor {
    const target = kernelCallTarget(op) orelse return null;
    const version = kernelCallVersion(op) orelse return null;
    return kernel_library.findEntry(target, version);
}

fn kernelCallTarget(op: *ir.Operation) ?[]const u8 {
    const attr = op.getAttr("target") orelse return null;
    if (!std.mem.eql(
        u8,
        attr.abstract.name,
        dialect_mod.AccyDialect.KernelCallOp.target_attr_name,
    )) return null;
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
    return dialect_attr.payload;
}

fn kernelCallVersion(op: *ir.Operation) ?u32 {
    const attr = op.getAttrAs(ir.Attribute.IntegerAttr, "version") orelse return null;
    const value = attr.getValue();
    if (value < 0 or value > std.math.maxInt(u32)) return null;
    return @intCast(value);
}

fn reductionInputElementCount(
    ops: []const *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
) ?u64 {
    if (ops.len != 1 or !isReduceOp(ops[0])) return null;
    const operands = ops[0].getOperandValues();
    if (operands.len < 1) return null;
    const input_info = shapes.get(operands[0]) orelse return null;
    return input_info.element_count;
}

fn dotGeneralElementOps(
    op: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
) ?u64 {
    if (op.getNumOperands() != 2) return null;
    const operands = op.getOperandValues();
    if (operands.len != 2) return null;
    const lhs = shapes.get(operands[0]) orelse return null;
    const rhs = shapes.get(operands[1]) orelse return null;
    const output = op.getResult(0) orelse return null;
    const output_info = shapes.get(output) orelse return null;
    if (lhs.dims.len != 2 or rhs.dims.len != 2 or output_info.dims.len != 2) return null;
    if (lhs.dims[0] < 0 or
        lhs.dims[1] < 0 or
        rhs.dims[0] < 0 or
        rhs.dims[1] < 0 or
        output_info.dims[0] < 0 or
        output_info.dims[1] < 0)
    {
        return null;
    }
    const m: u64 = @intCast(lhs.dims[0]);
    const k: u64 = @intCast(lhs.dims[1]);
    const n: u64 = @intCast(rhs.dims[1]);
    return saturatedMul(saturatedMul(saturatedMul(m, n), k), 2);
}

fn valueProducedByWork(
    value: *ir.Value,
    ops: []const *ir.Operation,
) bool {
    const def_any = value.getDefiningOp() orelse return false;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    for (ops) |op| {
        if (op == def_op) return true;
    }
    return false;
}

fn tensorByteSize(info: shape_analysis.TensorInfo) ?u64 {
    const element_count = info.element_count orelse return null;
    const element_size: u64 = @intCast(info.dtype.sizeOf());
    return std.math.mul(u64, element_count, element_size) catch null;
}

fn putUniqueExternalValue(
    unique_external_values: *std.AutoHashMap(*ir.Value, void),
    value: *ir.Value,
    resources: *ScheduleResourceEstimate,
) !void {
    if (unique_external_values.contains(value)) return;
    try unique_external_values.put(value, {});
    resources.external_input_value_count += 1;
}

fn saturatedAdd(lhs: u64, rhs: u64) u64 {
    return std.math.add(u64, lhs, rhs) catch std.math.maxInt(u64);
}

fn saturatedMul(lhs: u64, rhs: u64) u64 {
    return std.math.mul(u64, lhs, rhs) catch std.math.maxInt(u64);
}

const ScheduleDependency = struct {
    from: usize,
    to: usize,
};

fn orderWorkItemsByDependencies(
    allocator: std.mem.Allocator,
    analysis: *SchedulePlanAnalysis,
) !void {
    const work_items = analysis.work_items.items;
    if (work_items.len < 2) return;

    var output_to_item = std.AutoHashMap(*ir.Value, usize).init(allocator);
    defer output_to_item.deinit();
    for (work_items, 0..) |work, index| {
        try output_to_item.put(work.output_value, index);
    }

    const indegree = try allocator.alloc(usize, work_items.len);
    defer allocator.free(indegree);
    @memset(indegree, 0);

    var edges: std.ArrayListUnmanaged(ScheduleDependency) = .empty;
    defer edges.deinit(allocator);

    for (work_items, 0..) |work, consumer_index| {
        for (work.ops) |op| {
            for (op.getOperandValues()) |operand| {
                const producer_value = kernelInputValueForOperand(work, operand);
                const producer_index = output_to_item.get(producer_value) orelse continue;
                if (producer_index == consumer_index) continue;
                try appendScheduleDependency(
                    allocator,
                    &edges,
                    indegree,
                    producer_index,
                    consumer_index,
                );
            }
        }
    }

    if (edges.items.len == 0) return;

    const original = try allocator.alloc(ScheduleWorkItem, work_items.len);
    defer allocator.free(original);
    @memcpy(original, work_items);

    const ordered = try allocator.alloc(ScheduleWorkItem, work_items.len);
    defer allocator.free(ordered);

    const emitted = try allocator.alloc(bool, work_items.len);
    defer allocator.free(emitted);
    @memset(emitted, false);

    var ordered_count: usize = 0;
    while (ordered_count < work_items.len) {
        const next_index = nextReadyWorkItem(indegree, emitted) orelse {
            return error.CyclicScheduleDependency;
        };
        ordered[ordered_count] = original[next_index];
        ordered_count += 1;
        emitted[next_index] = true;

        for (edges.items) |edge| {
            if (edge.from != next_index) continue;
            std.debug.assert(indegree[edge.to] > 0);
            indegree[edge.to] -= 1;
        }
    }

    @memcpy(work_items, ordered);
    try rebuildWorkIndexMap(analysis);
}

pub fn kernelInputValueForOperand(
    work: ScheduleWorkItem,
    operand: *ir.Value,
) *ir.Value {
    switch (work.kind) {
        .elementwise_single,
        .elementwise_fusion,
        .dot_general,
        .reduction,
        .row_pipeline,
        .iterate,
        .flash_attention,
        => {
            const def_any = operand.getDefiningOp() orelse return operand;
            const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
            const broadcast_name = dialect_mod.AccyDialect.BroadcastInDimOp.operation_name;
            if (!std.mem.eql(u8, def_op.name.name, broadcast_name)) {
                return operand;
            }
            const operands = def_op.getOperandValues();
            if (operands.len != 1) return operand;
            return operands[0];
        },
        else => return operand,
    }
}

fn appendScheduleDependency(
    allocator: std.mem.Allocator,
    edges: *std.ArrayListUnmanaged(ScheduleDependency),
    indegree: []usize,
    from: usize,
    to: usize,
) !void {
    for (edges.items) |edge| {
        if (edge.from == from and edge.to == to) return;
    }
    try edges.append(allocator, .{
        .from = from,
        .to = to,
    });
    indegree[to] += 1;
}

fn nextReadyWorkItem(indegree: []const usize, emitted: []const bool) ?usize {
    for (indegree, 0..) |incoming, index| {
        if (!emitted[index] and incoming == 0) return index;
    }
    return null;
}

fn rebuildWorkIndexMap(analysis: *SchedulePlanAnalysis) !void {
    var rebuilt = std.AutoHashMap(*ir.Operation, usize).init(analysis.allocator);
    errdefer rebuilt.deinit();
    for (analysis.work_items.items, 0..) |work, index| {
        try rebuilt.put(work.root, index);
    }
    analysis.root_to_item.deinit();
    analysis.root_to_item = rebuilt;
}

const testing = std.testing;
const semantic = accy_choir.semantic;

fn findOpNamedInBlock(block: *ir.Block, name: []const u8) ?*ir.Operation {
    return findNthOpNamedInBlock(block, name, 0);
}

fn findNthOpNamedInBlock(block: *ir.Block, name: []const u8, needle_index: usize) ?*ir.Operation {
    var seen: usize = 0;
    var iter = block.operations.head;
    while (iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (std.mem.eql(u8, op.name.name, name)) {
            if (seen == needle_index) return op;
            seen += 1;
        }
        iter = op.next_op;
    }
    return null;
}

test "schedule planning emits one work item for an elementwise fusion cluster" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction(
        "schedule_fused_add_mul",
        &.{ f32_4, f32_4, f32_4 },
        &.{f32_4},
    );
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(sum, fb.parameter(2));
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_fused_add_mul") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const mul = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.MulOp.operation_name,
    ) orelse return error.TestExpectedMul;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 0), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 1), analysis.fusion_work_count);
    try testing.expectEqual(@as(usize, 2), analysis.scheduled_op_count);
    try testing.expectEqual(@as(u64, 4), analysis.total_static_elements);

    const item = analysis.getWorkForRoot(mul) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.elementwise_fusion, item.kind);
    try testing.expectEqual(@as(usize, 2), item.opCount());
    try testing.expectEqual(gpu_abi.DType.f32, item.dtype);
    try testing.expectEqual(@as(usize, 1), item.rank);
    try testing.expectEqual(@as(u64, 4), item.element_count);
    try testing.expectEqual(@as(u64, 4), item.resources.element_count);
    try testing.expectEqual(@as(u64, 4), item.resources.element_size);
    try testing.expectEqual(@as(usize, 2), item.resources.op_count);
    try testing.expectEqual(@as(usize, 3), item.resources.external_input_value_count);
    try testing.expectEqual(@as(usize, 3), item.resources.external_operand_count);
    try testing.expectEqual(@as(usize, 1), item.resources.chain_operand_count);
    try testing.expectEqual(@as(u64, 48), item.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 16), item.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 64), item.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 8), item.resources.estimated_element_ops);
    try testing.expectEqual(@as(u64, 128), item.resources.elementOpsPerKiB());
    try testing.expect(item.resources.static_bytes_complete);

    try testing.expectEqual(mul.getResult(0).?, item.output_value);
}

test "schedule planning emits standalone work when fusion is rejected" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction(
        "schedule_escape",
        &.{ f32_4, f32_4, f32_4 },
        &.{ f32_4, f32_4 },
    );
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(sum, fb.parameter(2));
    try fb.return_(&.{ sum, product });
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_escape") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const add = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.AddOp.operation_name,
    ) orelse return error.TestExpectedAdd;
    const mul = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.MulOp.operation_name,
    ) orelse return error.TestExpectedMul;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 2), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 2), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 0), analysis.fusion_work_count);
    try testing.expectEqual(@as(usize, 2), analysis.scheduled_op_count);
    try testing.expectEqual(@as(u64, 8), analysis.total_static_elements);
    const add_work = analysis.getWorkForRoot(add) orelse return error.TestExpectedWorkItem;
    const mul_work = analysis.getWorkForRoot(mul) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.elementwise_single, add_work.kind);
    try testing.expectEqual(ScheduleWorkKind.elementwise_single, mul_work.kind);
    try testing.expectEqual(@as(usize, 2), add_work.resources.external_input_value_count);
    try testing.expectEqual(@as(usize, 2), add_work.resources.external_operand_count);
    try testing.expectEqual(@as(u64, 32), add_work.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 16), add_work.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 48), add_work.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 4), add_work.resources.estimated_element_ops);
    try testing.expectEqual(@as(usize, 2), mul_work.resources.external_input_value_count);
    try testing.expectEqual(@as(usize, 2), mul_work.resources.external_operand_count);
    try testing.expectEqual(@as(usize, 0), mul_work.resources.chain_operand_count);
    try testing.expectEqual(@as(u64, 48), mul_work.resources.static_total_bytes);
}

test "schedule planning emits dot_general work for static rank-2 matmul" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_16x16 = try builder.tensor(.f32, &.{ 16, 16 });
    var fb = try builder.beginFunction(
        "schedule_dot_general_matmul",
        &.{ f32_16x16, f32_16x16 },
        &.{f32_16x16},
    );
    const dot = try fb.dotGeneral(
        fb.parameter(0),
        fb.parameter(1),
        f32_16x16,
        &.{1},
        &.{0},
        &.{},
        &.{},
    );
    try fb.return_(&.{dot});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_dot_general_matmul") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const dot_op = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.DotGeneralOp.operation_name,
    ) orelse return error.TestExpectedDotGeneral;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 1), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 0), analysis.fusion_work_count);
    try testing.expectEqual(@as(usize, 1), analysis.scheduled_op_count);
    try testing.expectEqual(@as(u64, 256), analysis.total_static_elements);

    const item = analysis.getWorkForRoot(dot_op) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.dot_general, item.kind);
    try testing.expectEqual(@as(usize, 1), item.opCount());
    try testing.expectEqual(gpu_abi.DType.f32, item.dtype);
    try testing.expectEqual(@as(usize, 2), item.rank);
    try testing.expectEqual(@as(u64, 256), item.element_count);
    try testing.expectEqual(@as(u64, 256), item.resources.element_count);
    try testing.expectEqual(@as(u64, 4), item.resources.element_size);
    try testing.expectEqual(@as(usize, 1), item.resources.op_count);
    try testing.expectEqual(@as(usize, 2), item.resources.external_input_value_count);
    try testing.expectEqual(@as(usize, 2), item.resources.external_operand_count);
    try testing.expectEqual(@as(usize, 0), item.resources.chain_operand_count);
    try testing.expectEqual(@as(u64, 2048), item.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 1024), item.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 3072), item.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 8192), item.resources.estimated_element_ops);
    try testing.expectEqual(@as(u64, 2730), item.resources.elementOpsPerKiB());
    try testing.expect(item.resources.static_bytes_complete);
}

test "schedule planning emits reduction work for static rank-1 reduce" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_256 = try builder.tensor(.f32, &.{256});
    const f32_scalar = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("schedule_reduce_sum_rank1", &.{f32_256}, &.{f32_scalar});
    const zero_value: f32 = 0.0;
    const zero = try fb.constant(f32_scalar, std.mem.asBytes(&zero_value));
    const reduced = try fb.reduce(fb.parameter(0), zero, f32_scalar, "sum", &.{0});
    try fb.return_(&.{reduced});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_reduce_sum_rank1") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const reduce_op = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.ReduceOp.operation_name,
    ) orelse return error.TestExpectedReduce;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 1), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 0), analysis.fusion_work_count);
    try testing.expectEqual(@as(usize, 1), analysis.scheduled_op_count);
    try testing.expectEqual(@as(u64, 1), analysis.total_static_elements);

    const item = analysis.getWorkForRoot(reduce_op) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.reduction, item.kind);
    try testing.expectEqual(@as(usize, 1), item.opCount());
    try testing.expectEqual(gpu_abi.DType.f32, item.dtype);
    try testing.expectEqual(@as(usize, 0), item.rank);
    try testing.expectEqual(@as(u64, 1), item.element_count);
    try testing.expectEqual(@as(u64, 256), item.resources.element_count);
    try testing.expectEqual(@as(u64, 4), item.resources.element_size);
    try testing.expectEqual(@as(usize, 1), item.resources.op_count);
    try testing.expectEqual(@as(usize, 1), item.resources.external_input_value_count);
    try testing.expectEqual(@as(usize, 1), item.resources.external_operand_count);
    try testing.expectEqual(@as(usize, 0), item.resources.chain_operand_count);
    try testing.expectEqual(@as(u64, 1024), item.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 4), item.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 1028), item.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 256), item.resources.estimated_element_ops);
    try testing.expectEqual(@as(u64, 255), item.resources.elementOpsPerKiB());
    try testing.expect(item.resources.static_bytes_complete);
}

test "schedule planning emits kernel_call work with operand effects" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("schedule_kernel_call", &.{ f32_4, f32_4 }, &.{f32_4});
    const call = try fb.kernelCall(
        &.{ fb.parameter(0), fb.parameter(1) },
        &.{f32_4},
        .{
            .target = "accy.custom.scale",
            .operand_effects = &.{ .read, .write },
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_kernel_call") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const call_op = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.KernelCallOp.operation_name,
    ) orelse return error.TestExpectedKernelCall;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 0), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 0), analysis.fusion_work_count);
    try testing.expectEqual(@as(usize, 1), analysis.kernel_call_work_count);
    try testing.expectEqual(@as(usize, 1), analysis.scheduled_op_count);
    try testing.expectEqual(@as(u64, 4), analysis.total_static_elements);

    const item = analysis.getWorkForRoot(call_op) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.kernel_call, item.kind);
    try testing.expectEqual(@as(usize, 1), item.opCount());
    try testing.expectEqual(gpu_abi.DType.f32, item.dtype);
    try testing.expectEqual(@as(usize, 1), item.rank);
    try testing.expectEqual(@as(u64, 4), item.element_count);
    try testing.expectEqual(@as(u64, 4), item.resources.element_count);
    try testing.expectEqual(@as(u64, 4), item.resources.element_size);
    try testing.expectEqual(@as(usize, 1), item.resources.op_count);
    try testing.expectEqual(@as(usize, 2), item.resources.external_input_value_count);
    try testing.expectEqual(@as(usize, 2), item.resources.external_operand_count);
    try testing.expectEqual(@as(usize, 0), item.resources.chain_operand_count);
    try testing.expectEqual(@as(u64, 16), item.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 16), item.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 32), item.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 4), item.resources.estimated_element_ops);
    try testing.expectEqual(call.getFirstResult(), item.output_value);
}

test "schedule planning estimates catalog kernel_call reductions" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 4, 8 });
    const rhs_ty = try builder.tensor(.f32, &.{ 8, 16 });
    const out_ty = try builder.tensor(.f32, &.{ 4, 16 });
    var fb = try builder.beginFunction(
        "schedule_catalog_kernel_call_matmul",
        &.{ lhs_ty, rhs_ty },
        &.{out_ty},
    );
    const call = try fb.kernelCall(
        &.{ fb.parameter(0), fb.parameter(1) },
        &.{out_ty},
        .{
            .target = kernel_library.linalg.MatrixProduct4x16x8F32.target,
            .operand_effects = &.{ .read, .read },
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(
        body,
        "schedule_catalog_kernel_call_matmul",
    ) orelse return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const call_op = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.KernelCallOp.operation_name,
    ) orelse return error.TestExpectedKernelCall;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    const declared = try ScheduleWork.inspect(choir_mod);
    try testing.expect(declared.catalog >= kernel_library.catalog.descriptors.len);
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 1), analysis.kernel_call_work_count);

    const item = analysis.getWorkForRoot(call_op) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.kernel_call, item.kind);
    try testing.expectEqual(@as(u64, 64), item.element_count);
    try testing.expectEqual(@as(u64, 64), item.resources.element_count);
    try testing.expectEqual(@as(u64, 640), item.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 256), item.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 896), item.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 1024), item.resources.estimated_element_ops);
    try testing.expectEqual(@as(u64, 1170), item.resources.elementOpsPerKiB());
}

test "schedule planning emits shape work for static transpose" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_16x32 = try builder.tensor(.f32, &.{ 16, 32 });
    const f32_32x16 = try builder.tensor(.f32, &.{ 32, 16 });
    var fb = try builder.beginFunction("schedule_transpose", &.{f32_16x32}, &.{f32_32x16});
    const transposed = try fb.transpose(fb.parameter(0), f32_32x16, &.{ 1, 0 });
    try fb.return_(&.{transposed});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_transpose") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const transpose_op = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.TransposeOp.operation_name,
    ) orelse return error.TestExpectedTranspose;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 1), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 0), analysis.fusion_work_count);

    const item = analysis.getWorkForRoot(transpose_op) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.shape, item.kind);
    try testing.expectEqual(@as(usize, 1), item.opCount());
    try testing.expectEqual(gpu_abi.DType.f32, item.dtype);
    try testing.expectEqual(@as(usize, 2), item.rank);
    try testing.expectEqual(@as(u64, 512), item.element_count);
    try testing.expectEqual(@as(u64, 2048), item.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 2048), item.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 4096), item.resources.static_total_bytes);
}

test "schedule planning emits shape work for static slice" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_18x18 = try builder.tensor(.f32, &.{ 18, 18 });
    const f32_16x16 = try builder.tensor(.f32, &.{ 16, 16 });
    var fb = try builder.beginFunction("schedule_slice", &.{f32_18x18}, &.{f32_16x16});
    const sliced = try fb.slice(fb.parameter(0), f32_16x16, &.{ 1, 1 }, &.{ 17, 17 }, &.{ 1, 1 });
    try fb.return_(&.{sliced});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_slice") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const slice_op = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.SliceOp.operation_name,
    ) orelse return error.TestExpectedSlice;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 1), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 0), analysis.fusion_work_count);

    const item = analysis.getWorkForRoot(slice_op) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.shape, item.kind);
    try testing.expectEqual(@as(usize, 1), item.opCount());
    try testing.expectEqual(gpu_abi.DType.f32, item.dtype);
    try testing.expectEqual(@as(usize, 2), item.rank);
    try testing.expectEqual(@as(u64, 256), item.element_count);
    try testing.expectEqual(@as(u64, 1296), item.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 1024), item.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 2320), item.resources.static_total_bytes);
}

test "schedule planning emits shape work for static pad" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_scalar = try builder.tensor(.f32, &.{});
    const f32_4x4 = try builder.tensor(.f32, &.{ 4, 4 });
    const f32_6x6 = try builder.tensor(.f32, &.{ 6, 6 });
    var fb = try builder.beginFunction("schedule_pad", &.{ f32_4x4, f32_scalar }, &.{f32_6x6});
    const padded = try fb.pad(
        fb.parameter(0),
        fb.parameter(1),
        f32_6x6,
        &.{ 1, 1 },
        &.{ 1, 1 },
        &.{ 0, 0 },
    );
    try fb.return_(&.{padded});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_pad") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const pad_op = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.PadOp.operation_name,
    ) orelse return error.TestExpectedPad;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 1), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 0), analysis.fusion_work_count);

    const item = analysis.getWorkForRoot(pad_op) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.shape, item.kind);
    try testing.expectEqual(@as(usize, 1), item.opCount());
    try testing.expectEqual(gpu_abi.DType.f32, item.dtype);
    try testing.expectEqual(@as(usize, 2), item.rank);
    try testing.expectEqual(@as(u64, 36), item.element_count);
    try testing.expectEqual(@as(usize, 2), item.resources.external_input_value_count);
    try testing.expectEqual(@as(usize, 2), item.resources.external_operand_count);
    try testing.expectEqual(@as(usize, 0), item.resources.chain_operand_count);
    try testing.expectEqual(@as(u64, 68), item.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 144), item.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 212), item.resources.static_total_bytes);
}

test "schedule planning emits shape work for static iota" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4x8 = try builder.tensor(.f32, &.{ 4, 8 });
    var fb = try builder.beginFunction("schedule_iota", &.{}, &.{f32_4x8});
    const iota = try fb.iota(f32_4x8, 1);
    try fb.return_(&.{iota});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_iota") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const iota_op = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.IotaOp.operation_name,
    ) orelse return error.TestExpectedIota;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 1), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 0), analysis.fusion_work_count);

    const item = analysis.getWorkForRoot(iota_op) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.shape, item.kind);
    try testing.expectEqual(@as(usize, 1), item.opCount());
    try testing.expectEqual(gpu_abi.DType.f32, item.dtype);
    try testing.expectEqual(@as(usize, 2), item.rank);
    try testing.expectEqual(@as(u64, 32), item.element_count);
    try testing.expectEqual(@as(usize, 0), item.resources.external_input_value_count);
    try testing.expectEqual(@as(u64, 0), item.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 128), item.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 128), item.resources.static_total_bytes);
}

test "schedule planning emits shape work for static concatenate" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4x4 = try builder.tensor(.f32, &.{ 4, 4 });
    const f32_4x8 = try builder.tensor(.f32, &.{ 4, 8 });
    var fb = try builder.beginFunction("schedule_concatenate", &.{ f32_4x4, f32_4x4 }, &.{f32_4x8});
    const concatenated = try fb.concatenate(&.{ fb.parameter(0), fb.parameter(1) }, f32_4x8, 1);
    try fb.return_(&.{concatenated});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_concatenate") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const concat_op = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.ConcatenateOp.operation_name,
    ) orelse return error.TestExpectedConcatenate;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 1), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 0), analysis.fusion_work_count);

    const item = analysis.getWorkForRoot(concat_op) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.shape, item.kind);
    try testing.expectEqual(@as(usize, 1), item.opCount());
    try testing.expectEqual(gpu_abi.DType.f32, item.dtype);
    try testing.expectEqual(@as(usize, 2), item.rank);
    try testing.expectEqual(@as(u64, 32), item.element_count);
    try testing.expectEqual(@as(usize, 2), item.resources.external_input_value_count);
    try testing.expectEqual(@as(usize, 2), item.resources.external_operand_count);
    try testing.expectEqual(@as(u64, 128), item.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 128), item.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 256), item.resources.static_total_bytes);
}

test "schedule planning orders fusion after external producers" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction(
        "schedule_branch_fusion_order",
        &.{ f32_4, f32_4, f32_4, f32_4 },
        &.{f32_4},
    );
    const shared = try fb.add(fb.parameter(0), fb.parameter(1));
    const left = try fb.mul(shared, fb.parameter(2));
    const right = try fb.add(shared, fb.parameter(3));
    const product = try fb.mul(left, right);
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_branch_fusion_order") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const shared_op = findNthOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.AddOp.operation_name,
        0,
    ) orelse return error.TestExpectedAdd;
    const left_op = findNthOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.MulOp.operation_name,
        0,
    ) orelse return error.TestExpectedMul;
    const right_op = findNthOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.AddOp.operation_name,
        1,
    ) orelse return error.TestExpectedAdd;
    const product_op = findNthOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.MulOp.operation_name,
        1,
    ) orelse return error.TestExpectedMul;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 0), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 1), analysis.fusion_work_count);
    try testing.expectEqual(product_op, analysis.work_items.items[0].root);

    const fused = analysis.getWorkForRoot(product_op) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.elementwise_fusion, fused.kind);
    try testing.expectEqual(@as(usize, 4), fused.opCount());
    try testing.expectEqual(shared_op, fused.ops[0]);
    try testing.expectEqual(left_op, fused.ops[1]);
    try testing.expectEqual(right_op, fused.ops[2]);
    try testing.expectEqual(product_op, fused.ops[3]);
    try testing.expectEqual(@as(usize, 4), fused.resources.external_input_value_count);
    try testing.expectEqual(@as(usize, 4), fused.resources.external_operand_count);
    try testing.expectEqual(@as(usize, 4), fused.resources.chain_operand_count);
    try testing.expectEqual(@as(u64, 80), fused.resources.static_total_bytes);
}

test "schedule planning orders fusion after broadcast source producers" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    const f32_4x4 = try builder.tensor(.f32, &.{ 4, 4 });
    var fb = try builder.beginFunction(
        "schedule_broadcast_source_order",
        &.{ f32_4x4, f32_4 },
        &.{f32_4x4},
    );
    const row_product = try fb.mul(fb.parameter(1), fb.parameter(1));
    const row_broadcast = try fb.broadcastInDim(row_product, f32_4x4, &.{ 4, 4 }, &.{0});
    const sum = try fb.add(fb.parameter(0), row_broadcast);
    const product = try fb.mul(sum, fb.parameter(0));
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "schedule_broadcast_source_order") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const row_product_op = findNthOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.MulOp.operation_name,
        0,
    ) orelse return error.TestExpectedMul;
    const sum_op = findNthOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.AddOp.operation_name,
        0,
    ) orelse return error.TestExpectedAdd;
    const product_op = findNthOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.MulOp.operation_name,
        1,
    ) orelse return error.TestExpectedMul;

    const analysis = try getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkScheduleStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 2), analysis.workItemCount());
    try testing.expectEqual(@as(usize, 1), analysis.single_work_count);
    try testing.expectEqual(@as(usize, 1), analysis.fusion_work_count);
    try testing.expectEqual(row_product_op, analysis.work_items.items[0].root);
    try testing.expectEqual(product_op, analysis.work_items.items[1].root);

    const fused = analysis.getWorkForRoot(product_op) orelse return error.TestExpectedWorkItem;
    try testing.expectEqual(ScheduleWorkKind.elementwise_fusion, fused.kind);
    try testing.expectEqual(@as(usize, 2), fused.opCount());
    try testing.expectEqual(sum_op, fused.ops[0]);
    try testing.expectEqual(product_op, fused.ops[1]);
}

test "schedule planning pass preserves IR" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("schedule_pass_add4", &.{ f32_4, f32_4 }, &.{f32_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(schedulePlanningPass());

    const ledger = try choir.product.revision.AccountingV1.create(allocator, .{
        .allowance = choir.product.revision.WorkVector.uniform(std.math.maxInt(u64)),
        .workspace = std.math.maxInt(u64),
        .events = 8,
    }, &.{.{ .name = schedule_planning_pass_name, .version = 1 }});
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    try testing.expectEqual(
        passes.PassResult.success,
        pm.runWithAnalysisCache(choir_mod, ctx, &cache, .{}),
    );
    try ledger.producersComplete();
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

fn scheduleTestLedger() !*choir.product.revision.AccountingV1 {
    const revision = choir.product.revision;
    return revision.AccountingV1.create(testing.allocator, .{
        .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
        .workspace = std.math.maxInt(u64),
        .events = 8,
    }, &.{});
}

fn checkScheduleStorage(
    op: *ir.Operation,
    ctx: *ir.Context,
    cache: *passes.AnalysisCache,
    expected: *const SchedulePlanAnalysis,
) !void {
    const bounds = try scheduleAnalysisWork(.{ .operation = op });
    const bytes = try testing.allocator.alloc(u8, @intCast(bounds.workspace));
    defer testing.allocator.free(bytes);
    var storage = @import("alloc_fixed").Tracked.init(bytes);
    var pass_ctx = passes.PassContext.init(op, ctx, storage.allocator(), cache);
    defer pass_ctx.deinit();
    const ptr = try computeSchedulePlanAnalysis(&pass_ctx, op);
    defer cleanupSchedulePlanAnalysis(ptr, storage.allocator());
    const actual: *SchedulePlanAnalysis = @ptrCast(@alignCast(ptr));
    try testing.expectEqual(expected.workItemCount(), actual.workItemCount());
    try testing.expectEqual(expected.scheduled_op_count, actual.scheduled_op_count);
    try testing.expectEqual(expected.total_static_elements, actual.total_static_elements);
    for (expected.work_items.items, actual.work_items.items) |left, right| {
        try testing.expectEqual(left.id, right.id);
        try testing.expectEqual(left.kind, right.kind);
        try testing.expectEqual(left.root, right.root);
        try testing.expectEqual(left.output_value, right.output_value);
        try testing.expectEqualSlices(*ir.Operation, left.ops, right.ops);
        try testing.expectEqualDeep(left.resources, right.resources);
        try testing.expectEqual(right.id, actual.getWorkForRoot(right.root).?.id);
    }
    try testing.expect(!storage.exhausted);
    try testing.expect(storage.status().high_water_bytes <= bounds.workspace);
    try testing.expect(storage.status().high_water_bytes >= @sizeOf(SchedulePlanAnalysis));
}

test "schedule planning work contract covers growing dependency chains" {
    for ([_]usize{ 1, 2, 6, 7, 16, 64 }) |count| try checkScheduleChain(count);
    try testing.expectError(error.WorkOverflow, (ScheduleWork{
        .input = .{ .operations = std.math.maxInt(u64) },
        .catalog = 0,
    }).bounds());
    try testing.expectError(error.WorkOverflow, (ScheduleWork{
        .input = .{},
        .catalog = std.math.maxInt(u64),
    }).bounds());
}

fn checkScheduleChain(count: usize) !void {
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const typ = try builder.tensor(.f32, &.{ 2, 3 });
    var function = try builder.beginFunction("schedule_chain", &.{typ}, &.{typ});
    var result = function.parameter(0);
    for (0..count) |_| result = try function.reshape(result, typ, &.{ 2, 3 });
    try function.return_(&.{result});
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(testing.allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer pass_ctx.deinit();
    const analysis = try getSchedulePlanAnalysis(&pass_ctx, module.choir_module);
    try ledger.producersComplete();
    try testing.expectEqual(count, analysis.workItemCount());
    for (analysis.work_items.items, 0..) |item, index| {
        try testing.expectEqual(index, item.id);
        try testing.expectEqual(ScheduleWorkKind.shape, item.kind);
        if (index != 0) {
            const previous = analysis.work_items.items[index - 1];
            try testing.expectEqual(previous.output_value, item.root.getOperand(0).?);
        }
    }
    try checkScheduleStorage(module.choir_module, module.context(), &cache, analysis);
    try checkScheduleAdmission(module.choir_module, module.context());
}

fn checkScheduleAdmission(op: *ir.Operation, ctx: *ir.Context) !void {
    const revision = choir.product.revision;
    var charge: u64 = 1;
    for ([_]passes.AnalysisDescriptor{
        shape_analysis.shape_layout_analysis_descriptor,
        fusion.fusion_plan_analysis_descriptor,
        schedule_plan_analysis_descriptor,
    }) |descriptor| {
        const bounds = try descriptor.work_contract.?.estimate(.{ .operation = op });
        charge = try accounting.add(charge, bounds.work.structural_visits);
    }
    for ([_]i8{ -1, 0, 1 }) |offset| {
        var allowance = revision.WorkVector.uniform(std.math.maxInt(u64));
        allowance.structural_visits = @intCast(@as(i128, charge) + offset);
        const ledger = try revision.AccountingV1.create(testing.allocator, .{
            .allowance = allowance,
            .workspace = std.math.maxInt(u64),
            .events = 8,
        }, &.{.{ .name = schedule_planning_pass_name, .version = 1 }});
        defer ledger.destroy();
        var cache = try passes.AnalysisCache.initAccounted(
            testing.allocator,
            null,
            ledger,
            .{},
            3,
        );
        defer cache.deinit();
        var manager = passes.PassManager.init(testing.allocator);
        defer manager.deinit();
        try manager.addPass(schedulePlanningPass());
        const result = manager.runWithAnalysisCache(op, ctx, &cache, .{});
        if (offset < 0) {
            try testing.expectEqual(passes.PassResult.failure, result);
            try testing.expectEqual(revision.receipt.Outcome.exhausted, ledger.view().outcome);
            try testing.expectEqual(@as(usize, 1), cache.entries.count());
        } else {
            try testing.expectEqual(passes.PassResult.success, result);
            try ledger.producersComplete();
            try testing.expectEqual(@as(usize, 3), cache.entries.count());
        }
    }
}

test "schedule planning reports aggregate element overflow without caching a plan" {
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const extent = std.math.maxInt(i64);
    const typ = try builder.tensor(.f32, &.{extent});
    var function = try builder.beginFunction("schedule_overflow", &.{typ}, &.{typ});
    const first = try function.reshape(function.parameter(0), typ, &.{extent});
    const second = try function.reshape(first, typ, &.{extent});
    const third = try function.reshape(second, typ, &.{extent});
    try function.return_(&.{third});
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    const ledger = try scheduleTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(
        testing.allocator,
        null,
        ledger,
        .{},
        3,
    );
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer pass_ctx.deinit();
    try testing.expectError(
        error.WorkOverflow,
        getSchedulePlanAnalysis(&pass_ctx, module.choir_module),
    );
    try testing.expectEqual(
        choir.product.revision.receipt.Outcome.exhausted,
        ledger.view().outcome,
    );
    try testing.expectEqual(@as(usize, 2), cache.entries.count());
    try testing.expectError(
        error.TerminalWorkOutcome,
        getSchedulePlanAnalysis(&pass_ctx, module.choir_module),
    );
}
