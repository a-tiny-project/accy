const std = @import("std");
const alloc_fixed = @import("alloc_fixed");
const choir = @import("choir");
const accy_choir = @import("../../choir/root.zig");
const dialect_mod = accy_choir.dialect;
const shape_analysis = @import("../shape/root.zig");

const ir = choir.ir;
const passes = choir.passes;
const work = passes.pass.work;

pub const fusion_plan_analysis_name = "accy-choir-fusion-plan";
pub const fusion_planning_pass_name = "accy-choir-plan-fusion";
pub const fusion_planning_pass_description =
    "Plan block-local Accy Choir elementwise fusion clusters";

pub const ClaimKind = enum {
    recompute,
    slot,
};

pub const ClaimMap = std.AutoHashMap(*ir.Operation, ClaimKind);

pub const FusionClusterKind = accy_choir.record.dispatch.FusionClusterKind;

pub const FusionCluster = struct {
    ops: []*ir.Operation,
    kind: FusionClusterKind = .elementwise,

    pub fn len(self: FusionCluster) usize {
        return self.ops.len;
    }

    pub fn root(self: FusionCluster) ?*ir.Operation {
        if (self.ops.len == 0) return null;
        return self.ops[self.ops.len - 1];
    }

    fn deinit(self: *FusionCluster, allocator: std.mem.Allocator) void {
        allocator.free(self.ops);
        self.* = undefined;
    }
};

pub const FusionPlanAnalysis = struct {
    allocator: std.mem.Allocator,
    clusters: std.ArrayListUnmanaged(FusionCluster),
    elided: std.ArrayListUnmanaged(*ir.Operation),
    fused_op_count: usize = 0,
    max_cluster_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FusionPlanAnalysis {
        return .{
            .allocator = allocator,
            .clusters = .empty,
            .elided = .empty,
        };
    }

    pub fn deinit(self: *FusionPlanAnalysis) void {
        for (self.clusters.items) |*cluster| {
            cluster.deinit(self.allocator);
        }
        self.clusters.deinit(self.allocator);
        self.elided.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clusterCount(self: FusionPlanAnalysis) usize {
        return self.clusters.items.len;
    }

    fn addCluster(self: *FusionPlanAnalysis, ops: []const *ir.Operation) !void {
        try self.addClusterOfKind(ops, .elementwise);
    }

    fn addClusterOfKind(
        self: *FusionPlanAnalysis,
        ops: []const *ir.Operation,
        kind: FusionClusterKind,
    ) !void {
        if (ops.len < 2) return;
        try self.addOwnedCluster(ops, kind);
    }

    fn addReductionCluster(self: *FusionPlanAnalysis, ops: []const *ir.Operation) !void {
        if (ops.len == 0) return;
        try self.addOwnedCluster(ops, .reduction_input);
    }

    fn addOwnedCluster(
        self: *FusionPlanAnalysis,
        ops: []const *ir.Operation,
        kind: FusionClusterKind,
    ) !void {
        const owned = try self.allocator.alloc(*ir.Operation, ops.len);
        @memcpy(owned, ops);
        errdefer self.allocator.free(owned);
        try self.clusters.append(self.allocator, .{ .ops = owned, .kind = kind });
        self.fused_op_count += owned.len;
        self.max_cluster_len = @max(self.max_cluster_len, owned.len);
    }
};

const FusionWork = struct {
    input: work.Census = .{},
    scratch: u64 = 0,
    copies: u64 = 0,
    rounds: u64 = 1,

    fn inspect(op: *ir.Operation) !FusionWork {
        var counts = FusionWork{ .input = try work.Census.inspect(op) };
        _ = try op.walk(.{ .order = .pre_order }, &counts, visit);
        return counts;
    }

    fn visit(self: *FusionWork, op: *ir.Operation) !ir.Operation.WalkResult {
        for (op.regions.items) |*region| {
            var blocks = region.getBlocks();
            while (blocks.next()) |block| {
                var count: u64 = 0;
                var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
                while (current) |child| : (current = child.next_op) {
                    count = try work.add(count, 1);
                }
                try self.includeBlock(count);
            }
        }
        return .advance;
    }

    fn includeBlock(self: *FusionWork, count: u64) !void {
        if (count == 0) return;
        const maps = try work.add(try work.multiply(6, count), 4);
        const lists = try work.add(try work.multiply(4, count), 4);
        const map_bytes = try work.multiply(
            maps,
            try work.hashMapGrowth(*ir.Operation, void, count),
        );
        const list_bytes = try work.multiply(lists, try work.arrayListGrowth(*ir.Operation, count));
        self.scratch = try work.add(self.scratch, try work.add(map_bytes, list_bytes));
        const output_count = try work.multiply(7, count);
        const output_bytes = try work.add(try work.multiply(count, @sizeOf(*ir.Operation)), 8);
        self.copies = try work.add(self.copies, try work.multiply(output_count, output_bytes));
        const rounds = try work.multiply(try work.multiply(7, count), try work.add(count, 1));
        self.rounds = try work.add(self.rounds, rounds);
    }

    fn bounds(self: FusionWork) !work.Bounds {
        var retained: u64 = @sizeOf(FusionPlanAnalysis) + @alignOf(FusionPlanAnalysis);
        retained = try work.add(retained, self.copies);
        const clusters = try work.arrayListGrowth(
            FusionCluster,
            try work.multiply(7, self.input.operations),
        );
        retained = try work.add(retained, clusters);
        retained = try work.add(
            retained,
            try work.arrayListGrowth(*ir.Operation, self.input.operations),
        );
        const temporary = try work.add(
            self.scratch,
            try work.hashMapGrowth(*ir.Operation, ClaimKind, self.input.operations),
        );
        const bytes = try work.add(retained, temporary);
        if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
        const units = try work.add(try work.add(self.input.atoms, self.input.input_bytes), 1);
        const slots = try work.hashMapCapacity(
            try work.add(self.input.operations, self.input.values),
        );
        const probes = try work.add(slots, units);
        const visits = try work.multiply(try work.multiply(self.rounds, units), probes);
        return .{
            .work = .{
                .input_bytes = self.input.input_bytes,
                .structural_visits = try work.multiply(64, visits),
                .analysis_computations = 1,
                .allocation_capacity = bytes,
            },
            .workspace = bytes,
            .retained_storage = bytes,
        };
    }
};

fn fusionAnalysisWork(input: work.Input) !work.Bounds {
    return (try FusionWork.inspect(input.operation)).bounds();
}

fn fusionPassWork(_: work.Input) !work.Bounds {
    return .{ .work = .{ .structural_visits = 1 } };
}

pub const fusion_plan_analysis_descriptor = passes.AnalysisDescriptor{
    .id = passes.analysisId(fusion_plan_analysis_name),
    .name = fusion_plan_analysis_name,
    .work_contract = .{
        .identity = .{ .name = fusion_plan_analysis_name, .version = 1 },
        .estimate = fusionAnalysisWork,
    },
};

pub fn getFusionPlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) !*FusionPlanAnalysis {
    const ptr = try pass_ctx.getAnalysis(
        op,
        &fusion_plan_analysis_descriptor,
        computeFusionPlanAnalysis,
        cleanupFusionPlanAnalysis,
    );
    return @ptrCast(@alignCast(ptr));
}

pub fn fusionPlanningPass() passes.Pass {
    return .{
        .name = fusion_planning_pass_name,
        .description = fusion_planning_pass_description,
        .run_fn = runFusionPlanningPass,
        .work_contract = .{
            .identity = .{ .name = fusion_planning_pass_name, .version = 1 },
            .estimate = fusionPassWork,
        },
    };
}

fn runFusionPlanningPass(pass_ctx: *passes.PassContext) passes.PassResult {
    _ = getFusionPlanAnalysis(pass_ctx, pass_ctx.op) catch return .failure;
    pass_ctx.preserveAllAnalyses();
    return .success;
}

fn computeFusionPlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) anyerror!*anyopaque {
    const shapes = try shape_analysis.getShapeLayoutAnalysis(pass_ctx, op);
    const analysis = try pass_ctx.allocator.create(FusionPlanAnalysis);
    analysis.* = FusionPlanAnalysis.init(pass_ctx.allocator);
    errdefer {
        analysis.deinit();
        pass_ctx.allocator.destroy(analysis);
    }

    var claimed = ClaimMap.init(pass_ctx.allocator);
    defer claimed.deinit();

    try collectFlashAttentionPlansInRegions(
        pass_ctx.allocator,
        op.regions.items,
        shapes,
        analysis,
        &claimed,
    );
    try collectRowPipelinePlansInRegions(
        pass_ctx.allocator,
        op.regions.items,
        shapes,
        analysis,
        &claimed,
    );
    try collectDotEpiloguePlansInRegions(
        pass_ctx.allocator,
        op.regions.items,
        shapes,
        analysis,
        &claimed,
    );
    try collectReductionInputPlansInRegions(
        pass_ctx.allocator,
        op.regions.items,
        shapes,
        analysis,
        &claimed,
    );
    try collectIterateElisionsInRegions(
        pass_ctx.allocator,
        op.regions.items,
        shapes,
        analysis,
        &claimed,
    );
    try collectFusionPlansInRegions(
        pass_ctx.allocator,
        op.regions.items,
        shapes,
        analysis,
        &claimed,
    );
    return @ptrCast(analysis);
}

fn cleanupFusionPlanAnalysis(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const analysis: *FusionPlanAnalysis = @ptrCast(@alignCast(ptr));
    analysis.deinit();
    allocator.destroy(analysis);
}

fn collectFusionPlansInRegions(
    allocator: std.mem.Allocator,
    regions: []ir.Region,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    for (regions) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |op| {
                const next = op.next_op;

                if (op.regions.items.len > 0 and !regionsAreOpaque(op)) {
                    try collectFusionPlansInRegions(
                        allocator,
                        op.regions.items,
                        shapes,
                        analysis,
                        claimed,
                    );
                }

                if (isFusableElementwiseOp(op) and
                    !claimed.contains(op) and !hasFusableOutputUser(op, shapes, claimed))
                {
                    try claimClusterRootedAt(allocator, op, shapes, analysis, claimed);
                }

                current = next;
            }
            var leftover: ?*ir.Operation = @ptrCast(@alignCast(block.operations.tail));
            while (leftover) |op| {
                const previous = op.prev_op;
                if (isFusableElementwiseOp(op) and !claimed.contains(op)) {
                    try claimClusterRootedAt(allocator, op, shapes, analysis, claimed);
                }
                leftover = previous;
            }
        }
    }
}

fn claimClusterRootedAt(
    allocator: std.mem.Allocator,
    root: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    var cluster: std.ArrayListUnmanaged(*ir.Operation) = .empty;
    defer cluster.deinit(allocator);
    var visiting = std.AutoHashMap(*ir.Operation, void).init(allocator);
    defer visiting.deinit();

    try collectProducerDAG(allocator, root, shapes, claimed, &visiting, &cluster);
    try retainClosedProducers(allocator, root, &cluster, shapes, claimed);
    if (cluster.items.len >= 2) {
        try analysis.addCluster(cluster.items);
        for (cluster.items) |node| {
            try claimed.put(node, .recompute);
        }
    }
}

fn hasFusableOutputUser(
    op: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *ClaimMap,
) bool {
    const result = op.getResult(0) orelse return false;
    var use = result.first_use;
    while (use) |current_use| : (use = current_use.next_use) {
        const user: *ir.Operation = @ptrCast(@alignCast(current_use.owner));
        if (user.getBlock() != op.getBlock()) continue;
        if (claimed.contains(user)) continue;
        if (!isFusableElementwiseOp(user)) continue;
        if (!compatibleProducerConsumer(op, user, shapes)) continue;
        return true;
    }
    return false;
}

fn collectProducerDAG(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *ClaimMap,
    visiting: *std.AutoHashMap(*ir.Operation, void),
    cluster: *std.ArrayListUnmanaged(*ir.Operation),
) anyerror!void {
    if (claimed.contains(op)) return;
    if (visiting.contains(op)) return;
    try visiting.put(op, {});

    if (isSeeThroughShapeOp(op)) {
        const source = op.getOperand(0) orelse return;
        if (source.getDefiningOp()) |source_def_any| {
            const source_def: *ir.Operation = @ptrCast(@alignCast(source_def_any));
            if (isSeeThroughShapeOp(source_def) and
                !claimed.contains(source_def) and source_def.getBlock() == op.getBlock())
            {
                try collectProducerDAG(allocator, source_def, shapes, claimed, visiting, cluster);
            }
        }
        try cluster.append(allocator, op);
        return;
    }

    for (op.getOperandValues()) |operand| {
        const producer = fusableProducerForOperand(operand, op, shapes, claimed) orelse continue;
        try collectProducerDAG(allocator, producer, shapes, claimed, visiting, cluster);
    }

    try cluster.append(allocator, op);
}

fn retainClosedProducers(
    allocator: std.mem.Allocator,
    root: *ir.Operation,
    cluster: *std.ArrayListUnmanaged(*ir.Operation),
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *const ClaimMap,
) anyerror!void {
    var members = std.AutoHashMap(*ir.Operation, void).init(allocator);
    defer members.deinit();
    for (cluster.items) |op| try members.put(op, {});

    var changed = true;
    while (changed) {
        changed = false;
        var index: usize = 0;
        while (index < cluster.items.len) {
            const op = cluster.items[index];
            if (op != root and !allUsesRecomputableOrInside(op, &members, shapes, claimed)) {
                _ = members.remove(op);
                _ = cluster.orderedRemove(index);
                changed = true;
                continue;
            }
            index += 1;
        }
    }
}

fn allUsesRecomputableOrInside(
    op: *ir.Operation,
    members: *const std.AutoHashMap(*ir.Operation, void),
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *const ClaimMap,
) bool {
    const result = op.getResult(0) orelse return false;
    var use = result.first_use;
    while (use) |current_use| : (use = current_use.next_use) {
        const user: *ir.Operation = @ptrCast(@alignCast(current_use.owner));
        if (members.contains(user)) continue;
        if (userCanRecompute(op, user, shapes, claimed)) continue;
        return false;
    }
    return true;
}

fn userCanRecompute(
    op: *ir.Operation,
    user: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *const ClaimMap,
) bool {
    if (claimed.get(user)) |kind| {
        if (kind == .slot) return false;
    }
    if (user.getBlock() != op.getBlock()) {
        return iterateRegionCanRecompute(op, user, shapes, claimed);
    }
    if (isName(user.name.name, dialect_mod.AccyDialect.IterateOp.operation_name)) {
        const op_result = op.getResult(0) orelse return false;
        const user_result = user.getResult(0) orelse return false;
        const op_info = shapes.get(op_result) orelse return false;
        const user_info = shapes.get(user_result) orelse return false;
        if (!op_info.hasStaticLayout() or !user_info.hasStaticLayout()) return false;
        return op_info.element_count.? == user_info.element_count.?;
    }
    if (isFlatGatherOp(user)) {
        const op_result = op.getResult(0) orelse return false;
        const user_operands = user.getOperandValues();
        if (user_operands[0] == op_result) return false;
        return resultShapesMatch(op, user, shapes);
    }
    if (!isFusableElementwiseOp(user)) return false;
    const op_result = op.getResult(0) orelse return false;
    const user_result = user.getResult(0) orelse return false;
    const op_info = shapes.get(op_result) orelse return false;
    const user_info = shapes.get(user_result) orelse return false;
    return sameStaticShape(op_info, user_info);
}

fn iterateRegionCanRecompute(
    op: *ir.Operation,
    user: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *const ClaimMap,
) bool {
    const user_block = user.getBlock() orelse return false;
    const parent = user_block.getParentOperation() orelse return false;
    if (!isName(parent.name.name, dialect_mod.AccyDialect.IterateOp.operation_name)) return false;
    if (parent.getBlock() != op.getBlock()) return false;
    if (claimed.contains(parent)) return false;
    const op_result = op.getResult(0) orelse return false;
    const parent_result = parent.getResult(0) orelse return false;
    const op_info = shapes.get(op_result) orelse return false;
    const parent_info = shapes.get(parent_result) orelse return false;
    if (!op_info.hasStaticLayout() or !parent_info.hasStaticLayout()) return false;
    return op_info.element_count.? == parent_info.element_count.?;
}

fn fusableProducerForOperand(
    operand: *ir.Value,
    consumer: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *ClaimMap,
) ?*ir.Operation {
    const def_any = operand.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (claimed.contains(def_op)) return null;
    if (def_op.getBlock() != consumer.getBlock()) return null;
    if (isFlatGatherOp(consumer)) {
        const consumer_operands = consumer.getOperandValues();
        if (consumer_operands[0] == operand) return null;
        if (!isFusableElementwiseOp(def_op) and !isFlatGatherOp(def_op)) return null;
        if (!resultShapesMatch(def_op, consumer, shapes)) return null;
        return def_op;
    }
    if (isSeeThroughShapeOp(def_op)) {
        if (!compatibleProducerConsumerShapes(def_op, consumer, shapes)) return null;
        return def_op;
    }
    if (isFlatGatherOp(def_op)) {
        if (!compatibleProducerConsumer(def_op, consumer, shapes)) return null;
        return def_op;
    }
    if (!isFusableElementwiseOp(def_op)) return null;
    if (!compatibleProducerConsumer(def_op, consumer, shapes)) return null;
    return def_op;
}

pub fn isFlatGatherOp(op: *ir.Operation) bool {
    if (!isName(op.name.name, dialect_mod.AccyDialect.GatherOp.operation_name)) return false;
    if (op.getNumResults() != 1) return false;
    const operands = op.getOperandValues();
    if (operands.len != 2) return false;
    const attr = op.getAttr("axis") orelse return false;
    const int_attr = attr.cast(ir.Attribute.IntegerAttr) orelse return false;
    if (int_attr.getValue() != 0) return false;
    var arena_buffer: [256]u8 = undefined;
    var arena = alloc_fixed.FixedBuffer.init(arena_buffer[0..]);
    const src_type = dialect_mod.decodeTensorType(
        arena.allocator(),
        operands[0].type,
    ) catch return false;
    return src_type.dims.len == 1;
}

fn resultShapesMatch(
    producer: *ir.Operation,
    consumer: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
) bool {
    const producer_result = producer.getResult(0) orelse return false;
    const consumer_result = consumer.getResult(0) orelse return false;
    const producer_info = shapes.get(producer_result) orelse return false;
    const consumer_info = shapes.get(consumer_result) orelse return false;
    return sameStaticShape(producer_info, consumer_info);
}

fn collectIterateElisionsInRegions(
    allocator: std.mem.Allocator,
    regions: []ir.Region,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    for (regions) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |op| {
                const next = op.next_op;
                if (op.regions.items.len > 0 and !regionsAreOpaque(op)) {
                    try collectIterateElisionsInRegions(
                        allocator,
                        op.regions.items,
                        shapes,
                        analysis,
                        claimed,
                    );
                }
                current = next;
            }
            try collectBlockIterateElisions(allocator, block, shapes, analysis, claimed);
        }
    }
}

fn collectBlockIterateElisions(
    allocator: std.mem.Allocator,
    block: *ir.Block,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    var has_recompute_sink = false;
    var scan: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
    while (scan) |op| : (scan = op.next_op) {
        if (claimed.contains(op)) continue;
        if (isName(
            op.name.name,
            dialect_mod.AccyDialect.IterateOp.operation_name,
        ) or isFlatGatherOp(op)) {
            has_recompute_sink = true;
            break;
        }
    }
    if (!has_recompute_sink) return;

    var candidates = std.AutoHashMap(*ir.Operation, void).init(allocator);
    defer candidates.deinit();
    var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
    while (current) |op| : (current = op.next_op) {
        if (claimed.contains(op)) continue;
        if (!isFusableElementwiseOp(op) and
            !isName(op.name.name, dialect_mod.AccyDialect.IotaOp.operation_name) and
            !isFlatGatherOp(op)) continue;
        if (op.getNumResults() != 1) continue;
        try candidates.put(op, {});
    }
    if (candidates.count() == 0) return;

    var removals: std.ArrayListUnmanaged(*ir.Operation) = .empty;
    defer removals.deinit(allocator);
    var changed = true;
    while (changed) {
        changed = false;
        removals.clearRetainingCapacity();
        var candidate_iter = candidates.keyIterator();
        while (candidate_iter.next()) |candidate| {
            if (!iterateElisionUsesOk(candidate.*, &candidates, shapes, claimed)) {
                try removals.append(allocator, candidate.*);
            }
        }
        for (removals.items) |candidate| {
            _ = candidates.remove(candidate);
            changed = true;
        }
    }

    var claim_iter = candidates.keyIterator();
    while (claim_iter.next()) |candidate| {
        try claimed.put(candidate.*, .recompute);
        try analysis.elided.append(analysis.allocator, candidate.*);
    }
}

fn iterateElisionUsesOk(
    op: *ir.Operation,
    candidates: *const std.AutoHashMap(*ir.Operation, void),
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *const ClaimMap,
) bool {
    const result = op.getResult(0) orelse return false;
    var use = result.first_use;
    while (use) |current_use| : (use = current_use.next_use) {
        const user: *ir.Operation = @ptrCast(@alignCast(current_use.owner));
        if (candidates.contains(user)) continue;
        if (userCanRecompute(op, user, shapes, claimed)) continue;
        return false;
    }
    return true;
}

pub fn regionsAreOpaque(op: *ir.Operation) bool {
    return isName(op.name.name, dialect_mod.AccyDialect.IterateOp.operation_name);
}

pub fn isSeeThroughShapeOp(op: *ir.Operation) bool {
    if (op.getNumResults() != 1) return false;
    if (isName(op.name.name, dialect_mod.AccyDialect.SliceOp.operation_name)) return true;
    if (isName(op.name.name, dialect_mod.AccyDialect.PadOp.operation_name)) {
        return padHasZeroInterior(op);
    }
    return false;
}

fn padHasZeroInterior(op: *ir.Operation) bool {
    const attr = op.getAttrAs(ir.Attribute.DialectAttr, "interior") orelse return false;
    if (attr.payload.len % @sizeOf(i64) != 0) return false;
    var index: usize = 0;
    while (index < attr.payload.len) : (index += @sizeOf(i64)) {
        var dilation: i64 = undefined;
        @memcpy(std.mem.asBytes(&dilation), attr.payload[index..][0..@sizeOf(i64)]);
        if (dilation != 0) return false;
    }
    return true;
}

fn compatibleProducerConsumer(
    producer: *ir.Operation,
    consumer: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
) bool {
    const producer_result = producer.getResult(0) orelse return false;
    const consumer_result = consumer.getResult(0) orelse return false;
    const producer_info = shapes.get(producer_result) orelse return false;
    const consumer_info = shapes.get(consumer_result) orelse return false;
    if (!sameStaticShape(producer_info, consumer_info)) return false;

    for (consumer.getOperandValues()) |operand| {
        const operand_info = shapes.get(operand) orelse return false;
        if (!sameStaticShape(producer_info, operand_info)) return false;
    }
    return true;
}

fn sameStaticShape(lhs: shape_analysis.TensorInfo, rhs: shape_analysis.TensorInfo) bool {
    if (!lhs.hasStaticLayout() or !rhs.hasStaticLayout()) return false;
    if (lhs.element_count.? != rhs.element_count.?) return false;
    return std.mem.eql(i64, lhs.dims, rhs.dims);
}

pub const flash_attention_dim = 64;
pub const flash_attention_min_seq = 128;

fn collectFlashAttentionPlansInRegions(
    allocator: std.mem.Allocator,
    regions: []ir.Region,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    for (regions) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |op| {
                const next = op.next_op;
                if (op.regions.items.len > 0 and !regionsAreOpaque(op)) {
                    try collectFlashAttentionPlansInRegions(
                        allocator,
                        op.regions.items,
                        shapes,
                        analysis,
                        claimed,
                    );
                }
                current = next;
            }
            try collectBlockFlashAttentionPlans(allocator, block, shapes, analysis, claimed);
        }
    }
}

fn collectBlockFlashAttentionPlans(
    allocator: std.mem.Allocator,
    block: *ir.Block,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
    while (current) |dot2| : (current = dot2.next_op) {
        if (!isName(dot2.name.name, dialect_mod.AccyDialect.DotGeneralOp.operation_name)) continue;
        if (claimed.contains(dot2)) continue;
        if (!dotIsCanonicalRank2(dot2)) continue;

        const probs = dot2.getOperand(0) orelse continue;
        const probs_any = probs.getDefiningOp() orelse continue;
        const terminal: *ir.Operation = @ptrCast(@alignCast(probs_any));
        if (terminal.getBlock() != block or claimed.contains(terminal)) continue;
        if (!isFusableElementwiseOp(terminal)) continue;
        if (!probs.hasOneUse()) continue;

        const dot2_result = dot2.getResult(0) orelse continue;
        const out_info = shapes.get(dot2_result) orelse continue;
        if (!out_info.hasStaticLayout() or out_info.dims.len != 2) continue;
        if (out_info.dims[1] != flash_attention_dim) continue;
        const seq = out_info.dims[0];
        if (seq < flash_attention_min_seq or @rem(seq, 64) != 0) continue;
        if (out_info.dtype != .f32) continue;

        var probe = RowPipelineProbe{
            .members = std.AutoHashMap(*ir.Operation, void).init(allocator),
        };
        defer probe.deinit();
        probe.rows = seq;
        probe.cols = seq;
        if (!try collectRowPipelineMembers(terminal, block, shapes, claimed, &probe)) continue;
        if (probe.reduce_count != 2) continue;
        if (probe.members.count() > max_row_pipeline_ops) continue;
        if (!flashPipeClosed(terminal, dot2, &probe)) continue;

        const dot1 = flashScoresDot(block, shapes, claimed, &probe, seq) orelse continue;

        var ops: std.ArrayListUnmanaged(*ir.Operation) = .empty;
        defer ops.deinit(allocator);
        try ops.append(allocator, dot1);
        var walk: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
        while (walk) |member| : (walk = member.next_op) {
            if (member == dot1 or member == dot2) continue;
            if (probe.members.contains(member)) try ops.append(allocator, member);
        }
        try ops.append(allocator, dot2);

        try analysis.addClusterOfKind(ops.items, .flash_attention);
        for (ops.items) |member| try claimed.put(member, .slot);
    }
}

fn dotIsCanonicalRank2(op: *ir.Operation) bool {
    const lhs_contract = op.getAttrAs(
        ir.Attribute.DialectAttr,
        dialect_mod.AccyDialect.DotGeneralOp.dialectAttrName("lhs_contract"),
    ) orelse
        op.getAttrAs(ir.Attribute.DialectAttr, "lhs_contract") orelse return false;
    const rhs_contract = op.getAttrAs(
        ir.Attribute.DialectAttr,
        dialect_mod.AccyDialect.DotGeneralOp.dialectAttrName("rhs_contract"),
    ) orelse
        op.getAttrAs(ir.Attribute.DialectAttr, "rhs_contract") orelse return false;
    const lhs_batch = op.getAttrAs(
        ir.Attribute.DialectAttr,
        dialect_mod.AccyDialect.DotGeneralOp.dialectAttrName("lhs_batch"),
    ) orelse
        op.getAttrAs(ir.Attribute.DialectAttr, "lhs_batch") orelse return false;
    if (lhs_batch.payload.len != 0) return false;
    if (lhs_contract.payload.len != @sizeOf(i64) or rhs_contract.payload.len != @sizeOf(i64)) {
        return false;
    }
    var lhs_dim: i64 = undefined;
    var rhs_dim: i64 = undefined;
    @memcpy(std.mem.asBytes(&lhs_dim), lhs_contract.payload[0..@sizeOf(i64)]);
    @memcpy(std.mem.asBytes(&rhs_dim), rhs_contract.payload[0..@sizeOf(i64)]);
    return lhs_dim == 1 and rhs_dim == 0;
}

fn flashPipeClosed(
    terminal: *ir.Operation,
    dot2: *ir.Operation,
    probe: *const RowPipelineProbe,
) bool {
    var member_iter = probe.members.keyIterator();
    while (member_iter.next()) |member| {
        const result = member.*.getResult(0) orelse return false;
        var use = result.first_use;
        while (use) |current_use| : (use = current_use.next_use) {
            const user: *ir.Operation = @ptrCast(@alignCast(current_use.owner));
            if (probe.members.contains(user)) continue;
            if (member.* == terminal and user == dot2) continue;
            return false;
        }
    }
    return true;
}

fn flashScoresDot(
    block: *ir.Block,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *const ClaimMap,
    probe: *const RowPipelineProbe,
    seq: i64,
) ?*ir.Operation {
    var scores_dot: ?*ir.Operation = null;
    var member_iter = probe.members.keyIterator();
    while (member_iter.next()) |member| {
        for (member.*.getOperandValues()) |operand| {
            const def_any = operand.getDefiningOp() orelse continue;
            const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
            if (probe.members.contains(def_op)) continue;
            if (!isName(def_op.name.name, dialect_mod.AccyDialect.DotGeneralOp.operation_name)) {
                continue;
            }
            if (def_op.getBlock() != block or claimed.contains(def_op)) continue;
            if (!dotIsCanonicalRank2(def_op)) continue;
            const result = def_op.getResult(0) orelse continue;
            const info = shapes.get(result) orelse continue;
            if (!info.hasStaticLayout() or info.dims.len != 2) continue;
            if (info.dims[0] != seq or info.dims[1] != seq) continue;
            var use = result.first_use;
            var all_inside = true;
            while (use) |current_use| : (use = current_use.next_use) {
                const user: *ir.Operation = @ptrCast(@alignCast(current_use.owner));
                if (!probe.members.contains(user)) {
                    all_inside = false;
                    break;
                }
            }
            if (!all_inside) continue;
            const lhs = def_op.getOperand(0) orelse continue;
            const lhs_info = shapes.get(lhs) orelse continue;
            if (!lhs_info.hasStaticLayout() or lhs_info.dims.len != 2) continue;
            if (lhs_info.dims[1] != flash_attention_dim) continue;
            if (scores_dot != null and scores_dot != def_op) return null;
            scores_dot = def_op;
        }
    }
    return scores_dot;
}

pub const row_pipeline_threads = 256;
pub const max_row_pipeline_ops = 24;
pub const max_row_pipeline_reduces = 4;
pub const max_row_pipeline_cols = 8192;

fn collectRowPipelinePlansInRegions(
    allocator: std.mem.Allocator,
    regions: []ir.Region,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    for (regions) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |op| {
                const next = op.next_op;
                if (op.regions.items.len > 0 and !regionsAreOpaque(op)) {
                    try collectRowPipelinePlansInRegions(
                        allocator,
                        op.regions.items,
                        shapes,
                        analysis,
                        claimed,
                    );
                }
                current = next;
            }
            try collectBlockRowPipelinePlans(allocator, block, shapes, analysis, claimed);
        }
    }
}

const RowPipelineProbe = struct {
    members: std.AutoHashMap(*ir.Operation, void),
    reduce_count: usize = 0,
    rows: i64 = 0,
    cols: i64 = 0,

    fn deinit(self: *RowPipelineProbe) void {
        self.members.deinit();
    }
};

fn collectBlockRowPipelinePlans(
    allocator: std.mem.Allocator,
    block: *ir.Block,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
    while (current) |op| : (current = op.next_op) {
        if (!rowPipelineTerminalCandidate(op, shapes, claimed)) continue;

        var probe = RowPipelineProbe{
            .members = std.AutoHashMap(*ir.Operation, void).init(allocator),
        };
        defer probe.deinit();
        const info = rowPipelineRowInfo(op, shapes) orelse continue;
        probe.rows = info.rows;
        probe.cols = info.cols;

        if (!try collectRowPipelineMembers(op, block, shapes, claimed, &probe)) continue;
        if (probe.reduce_count == 0) continue;
        if (probe.members.count() > max_row_pipeline_ops) continue;
        if (!rowPipelineIsClosed(op, &probe)) continue;

        var ops: std.ArrayListUnmanaged(*ir.Operation) = .empty;
        defer ops.deinit(allocator);
        var walk: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
        while (walk) |member| : (walk = member.next_op) {
            if (member == op) continue;
            if (probe.members.contains(member)) try ops.append(allocator, member);
        }
        try ops.append(allocator, op);

        try analysis.addClusterOfKind(ops.items, .row_pipeline);
        for (ops.items) |member| try claimed.put(member, .slot);
    }
}

const RowPipelineRowInfo = struct {
    rows: i64,
    cols: i64,
};

const RowPipelineQuery = union(enum) {
    member: *ir.Operation,
    operand: *ir.Value,
    broadcast: *ir.Operation,
    stat: *ir.Value,
    reduce: *ir.Operation,
};

fn rowPipelineRowInfo(
    op: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
) ?RowPipelineRowInfo {
    const result = op.getResult(0) orelse return null;
    const info = shapes.get(result) orelse return null;
    if (!info.hasStaticLayout()) return null;
    if (info.dims.len != 2) return null;
    const rows = info.dims[0];
    const cols = info.dims[1];
    if (rows < 1 or cols < 1) return null;
    if (cols > max_row_pipeline_cols) return null;
    if (@rem(cols, @as(i64, row_pipeline_threads) * 4) != 0) return null;
    return .{ .rows = rows, .cols = cols };
}

fn rowPipelineTerminalCandidate(
    op: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *ClaimMap,
) bool {
    if (claimed.contains(op)) return false;
    if (!isFusableElementwiseOp(op)) return false;
    const result = op.getResult(0) orelse return false;
    const info = shapes.get(result) orelse return false;
    if (!info.hasStaticLayout() or info.dims.len != 2) return false;
    var use = result.first_use;
    while (use) |current_use| : (use = current_use.next_use) {
        const user: *ir.Operation = @ptrCast(@alignCast(current_use.owner));
        if (isFusableElementwiseOp(user) and user.getBlock() == op.getBlock()) return false;
        if (isName(user.name.name, dialect_mod.AccyDialect.ReduceOp.operation_name)) return false;
    }
    return true;
}

fn rowPipelineValueIsF32Rows(
    value: *ir.Value,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    probe: *const RowPipelineProbe,
) bool {
    const info = shapes.get(value) orelse return false;
    if (!info.hasStaticLayout() or info.dims.len != 2) return false;
    if (info.dims[0] != probe.rows or info.dims[1] != probe.cols) return false;
    return info.dtype == .f32;
}

fn collectRowPipelineMembers(
    op: *ir.Operation,
    block: *ir.Block,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *ClaimMap,
    probe: *RowPipelineProbe,
) anyerror!bool {
    return rowPipelineQueryOk(.{ .member = op }, block, shapes, claimed, probe);
}

fn rowPipelineQueryOk(
    query: RowPipelineQuery,
    block: *ir.Block,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *ClaimMap,
    probe: *RowPipelineProbe,
) anyerror!bool {
    switch (query) {
        .member => |op| {
            if (probe.members.contains(op)) return true;
            if (claimed.contains(op)) return false;
            if (op.getBlock() != block) return false;
            if (!isFusableElementwiseOp(op)) return false;
            const result = op.getResult(0) orelse return false;
            if (!rowPipelineValueIsF32Rows(result, shapes, probe)) return false;
            try probe.members.put(op, {});

            for (op.getOperandValues()) |operand| {
                if (try rowPipelineQueryOk(
                    .{ .operand = operand },
                    block,
                    shapes,
                    claimed,
                    probe,
                )) continue;
                return false;
            }
            return true;
        },
        .operand => |operand| {
            const def_any = operand.getDefiningOp() orelse {
                return rowPipelineValueIsF32Rows(operand, shapes, probe);
            };
            const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
            if (probe.members.contains(def_op)) return true;
            if (isName(def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
                return rowPipelineValueIsF32Rows(operand, shapes, probe) and
                    constantIsSplat(def_op);
            }

            if (isName(
                def_op.name.name,
                dialect_mod.AccyDialect.BroadcastInDimOp.operation_name,
            ) and
                def_op.getBlock() == block and !claimed.contains(def_op))
            {
                if (try rowPipelineQueryOk(
                    .{ .broadcast = def_op },
                    block,
                    shapes,
                    claimed,
                    probe,
                )) return true;
            }

            if (def_op.getBlock() == block and !claimed.contains(def_op) and
                isFusableElementwiseOp(def_op))
            {
                return rowPipelineQueryOk(.{ .member = def_op }, block, shapes, claimed, probe);
            }

            return rowPipelineValueIsF32Rows(operand, shapes, probe);
        },
        .broadcast => |broadcast| {
            const broadcast_result = broadcast.getResult(0) orelse return false;
            if (!rowPipelineValueIsF32Rows(broadcast_result, shapes, probe)) return false;
            var dims_buffer: [8]i64 = undefined;
            const dims = readBroadcastDims(broadcast, dims_buffer[0..]) orelse return false;
            if (dims.len != 1) return false;

            const operands = broadcast.getOperandValues();
            if (operands.len != 1) return false;

            if (dims[0] == 1) {
                const source_info = shapes.get(operands[0]) orelse return false;
                if (!source_info.hasStaticLayout() or source_info.dims.len != 1) return false;
                if (source_info.dims[0] != probe.cols) return false;
                if (source_info.dtype != .f32) return false;
                if (operands[0].getDefiningOp()) |source_any| {
                    const source: *ir.Operation = @ptrCast(@alignCast(source_any));
                    if (probe.members.contains(source)) return false;
                }
                try probe.members.put(broadcast, {});
                return true;
            }

            if (dims[0] != 0) return false;
            if (!try rowPipelineQueryOk(.{ .stat = operands[0] }, block, shapes, claimed, probe)) {
                return false;
            }
            try probe.members.put(broadcast, {});
            return true;
        },
        .stat => |value| {
            const info = shapes.get(value) orelse return false;
            if (!info.hasStaticLayout() or info.dims.len != 1) return false;
            if (info.dims[0] != probe.rows) return false;
            if (info.dtype != .f32) return false;

            const def_any = value.getDefiningOp() orelse return false;
            const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
            if (probe.members.contains(def_op)) return true;
            if (def_op.getBlock() != block or claimed.contains(def_op)) return false;

            if (isName(def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
                return constantIsSplat(def_op);
            }

            if (isName(def_op.name.name, dialect_mod.AccyDialect.ReduceOp.operation_name)) {
                return rowPipelineQueryOk(.{ .reduce = def_op }, block, shapes, claimed, probe);
            }

            if (!isFusableElementwiseOp(def_op)) return false;
            try probe.members.put(def_op, {});
            for (def_op.getOperandValues()) |operand| {
                if (!try rowPipelineQueryOk(.{ .stat = operand }, block, shapes, claimed, probe)) {
                    return false;
                }
            }
            return true;
        },
        .reduce => |reduce| {
            if (probe.members.contains(reduce)) return true;
            if (probe.reduce_count >= max_row_pipeline_reduces) return false;
            if (!reduceHasConstantInit(reduce)) return false;

            var axes_buffer: [8]i64 = undefined;
            const axes = readReduceDimensions(reduce, axes_buffer[0..]) orelse return false;
            if (axes.len != 1 or axes[0] != 1) return false;

            const reduce_result = reduce.getResult(0) orelse return false;
            const reduce_info = shapes.get(reduce_result) orelse return false;
            if (!reduce_info.hasStaticLayout() or reduce_info.dims.len != 1) return false;
            if (reduce_info.dims[0] != probe.rows) return false;

            const input = reduce.getOperand(0) orelse return false;
            try probe.members.put(reduce, {});
            probe.reduce_count += 1;
            if (!try rowPipelineQueryOk(.{ .operand = input }, block, shapes, claimed, probe)) {
                return false;
            }
            return true;
        },
    }
}

fn constantIsSplat(op: *ir.Operation) bool {
    const constant = dialect_mod.AccyDialect.ConstantOp{ .op = op };
    const payload = constant.getPayload() orelse return false;
    if (payload.len < 4 or payload.len % 4 != 0) return false;
    const first = payload[0..4];
    var offset: usize = 4;
    while (offset < payload.len) : (offset += 4) {
        if (!std.mem.eql(u8, payload[offset..][0..4], first)) return false;
    }
    return true;
}

fn readBroadcastDims(op: *ir.Operation, buffer: []i64) ?[]const i64 {
    if (readI64Payload(op.getAttrAs(ir.Attribute.DialectAttr, "broadcast_dims"), buffer)) |dims| {
        return dims;
    }
    return readI64Payload(op.getAttrAs(
        ir.Attribute.DialectAttr,
        dialect_mod.AccyDialect.BroadcastInDimOp.dialectAttrName("broadcast_dims"),
    ), buffer);
}

fn readReduceDimensions(op: *ir.Operation, buffer: []i64) ?[]const i64 {
    if (readI64Payload(op.getAttrAs(ir.Attribute.DialectAttr, "dimensions"), buffer)) |dims| {
        return dims;
    }
    return readI64Payload(op.getAttrAs(
        ir.Attribute.DialectAttr,
        dialect_mod.AccyDialect.ReduceOp.dialectAttrName("dimensions"),
    ), buffer);
}

fn readI64Payload(attr: ?*const ir.Attribute.DialectAttr, buffer: []i64) ?[]const i64 {
    const dialect_attr = attr orelse return null;
    if (dialect_attr.payload.len % @sizeOf(i64) != 0) return null;
    const count = dialect_attr.payload.len / @sizeOf(i64);
    if (count > buffer.len) return null;
    for (buffer[0..count], 0..) |*slot, index| {
        var value: i64 = undefined;
        @memcpy(
            std.mem.asBytes(&value),
            dialect_attr.payload[index * @sizeOf(i64) ..][0..@sizeOf(i64)],
        );
        slot.* = value;
    }
    return buffer[0..count];
}

fn rowPipelineIsClosed(root: *ir.Operation, probe: *const RowPipelineProbe) bool {
    var member_iter = probe.members.keyIterator();
    while (member_iter.next()) |member| {
        if (member.* == root) continue;
        const result = member.*.getResult(0) orelse return false;
        var use = result.first_use;
        while (use) |current_use| : (use = current_use.next_use) {
            const user: *ir.Operation = @ptrCast(@alignCast(current_use.owner));
            if (!probe.members.contains(user) and user != root) return false;
        }
    }
    return true;
}

pub const max_dot_epilogue_ops = 6;
pub const max_reduction_prologue_ops = 48;
const max_reduction_prologue_depth = 24;

fn collectReductionInputPlansInRegions(
    allocator: std.mem.Allocator,
    regions: []ir.Region,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    for (regions) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |op| {
                const next = op.next_op;
                if (op.regions.items.len > 0 and !regionsAreOpaque(op)) {
                    try collectReductionInputPlansInRegions(
                        allocator,
                        op.regions.items,
                        shapes,
                        analysis,
                        claimed,
                    );
                }
                current = next;
            }
            try collectBlockReductionInputPlans(allocator, block, shapes, analysis, claimed);
        }
    }
}

fn collectBlockReductionInputPlans(
    allocator: std.mem.Allocator,
    block: *ir.Block,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    var reduces: std.ArrayListUnmanaged(*ir.Operation) = .empty;
    defer reduces.deinit(allocator);

    var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
    while (current) |op| : (current = op.next_op) {
        if (!isName(op.name.name, dialect_mod.AccyDialect.ReduceOp.operation_name)) continue;
        if (claimed.contains(op)) continue;
        if (!reduceHasConstantInit(op)) continue;
        try reduces.append(allocator, op);
    }
    if (reduces.items.len == 0) return;

    var members = std.AutoHashMap(*ir.Operation, void).init(allocator);
    defer members.deinit();

    for (reduces.items) |reduce| {
        const input = reduce.getOperand(0) orelse continue;
        const baseline = shapes.get(input) orelse continue;
        try collectReductionProducerDAG(
            input,
            baseline,
            block,
            shapes,
            claimed,
            &members,
            max_reduction_prologue_depth,
        );
    }
    if (members.count() == 0) return;
    if (members.count() > max_reduction_prologue_ops) return;

    var removals: std.ArrayListUnmanaged(*ir.Operation) = .empty;
    defer removals.deinit(allocator);
    var changed = true;
    while (changed) {
        changed = false;
        removals.clearRetainingCapacity();
        var member_iter = members.keyIterator();
        while (member_iter.next()) |member| {
            if (!reductionUsesInside(member.*, &members, reduces.items, shapes, claimed)) {
                try removals.append(allocator, member.*);
            }
        }
        for (removals.items) |member| {
            _ = members.remove(member);
            changed = true;
        }
    }
    if (members.count() == 0) return;

    var owned = std.AutoHashMap(*ir.Operation, void).init(allocator);
    defer owned.deinit();
    var cluster: std.ArrayListUnmanaged(*ir.Operation) = .empty;
    defer cluster.deinit(allocator);

    var grouped = std.AutoHashMap(*ir.Operation, void).init(allocator);
    defer grouped.deinit();
    try collectConcatReductionClusters(
        allocator,
        block,
        shapes,
        reduces.items,
        &members,
        &owned,
        &cluster,
        &grouped,
        analysis,
        claimed,
    );

    for (reduces.items) |reduce| {
        if (grouped.contains(reduce)) continue;
        const input = reduce.getOperand(0) orelse continue;
        cluster.clearRetainingCapacity();
        try collectOwnedPrologue(allocator, input, &members, &owned, &cluster);
        const input_inlined = inputIsMember(input, &members);
        if (cluster.items.len == 0 and !input_inlined) continue;
        try cluster.append(allocator, reduce);
        try analysis.addReductionCluster(cluster.items);
        for (cluster.items) |cluster_op| try claimed.put(cluster_op, .recompute);
    }
}

pub const max_concat_reduction_group = 8;

fn collectConcatReductionClusters(
    allocator: std.mem.Allocator,
    block: *ir.Block,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    reduces: []const *ir.Operation,
    members: *const std.AutoHashMap(*ir.Operation, void),
    owned: *std.AutoHashMap(*ir.Operation, void),
    cluster: *std.ArrayListUnmanaged(*ir.Operation),
    grouped: *std.AutoHashMap(*ir.Operation, void),
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
    while (current) |op| : (current = op.next_op) {
        if (!isName(op.name.name, dialect_mod.AccyDialect.ConcatenateOp.operation_name)) continue;
        if (claimed.contains(op)) continue;
        const operands = op.getOperandValues();
        if (operands.len < 2 or operands.len > max_concat_reduction_group) continue;
        if (!concatIsAxisZeroRankOne(op, shapes)) continue;

        var group_buffer: [max_concat_reduction_group]*ir.Operation = undefined;
        const group = concatReduceGroup(
            operands,
            reduces,
            shapes,
            group_buffer[0..],
        ) orelse continue;

        cluster.clearRetainingCapacity();
        var any_inlined = false;
        for (group) |reduce| {
            const input = reduce.getOperand(0) orelse break;
            try collectOwnedPrologue(allocator, input, members, owned, cluster);
            if (inputIsMember(input, members)) any_inlined = true;
        }
        if (cluster.items.len == 0 and !any_inlined) continue;
        for (group) |reduce| try cluster.append(allocator, reduce);
        try cluster.append(allocator, op);
        try analysis.addReductionCluster(cluster.items);
        for (cluster.items) |cluster_op| try claimed.put(cluster_op, .recompute);
        for (group) |reduce| try grouped.put(reduce, {});
    }
}

fn concatIsAxisZeroRankOne(
    op: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
) bool {
    const attr = op.getAttrAs(ir.Attribute.IntegerAttr, "dimension") orelse return false;
    if (attr.getValue() != 0) return false;
    const result = op.getResult(0) orelse return false;
    const info = shapes.get(result) orelse return false;
    return info.dims.len == 1;
}

fn concatReduceGroup(
    operands: []const *ir.Value,
    reduces: []const *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    buffer: []*ir.Operation,
) ?[]*ir.Operation {
    var group_shape: ?shape_analysis.TensorInfo = null;
    var input_shape: ?shape_analysis.TensorInfo = null;
    for (operands, 0..) |operand, index| {
        if (!operand.hasOneUse()) return null;
        const def_any = operand.getDefiningOp() orelse return null;
        const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
        var collected = false;
        for (reduces) |reduce| {
            if (reduce == def_op) {
                collected = true;
                break;
            }
        }
        if (!collected) return null;
        const operand_info = shapes.get(operand) orelse return null;
        if (group_shape) |existing| {
            if (!sameStaticShape(existing, operand_info)) return null;
        } else {
            group_shape = operand_info;
        }
        const reduce_input = def_op.getOperand(0) orelse return null;
        const reduce_input_info = shapes.get(reduce_input) orelse return null;
        if (input_shape) |existing| {
            if (!sameStaticShape(existing, reduce_input_info)) return null;
        } else {
            input_shape = reduce_input_info;
        }
        buffer[index] = def_op;
    }
    return buffer[0..operands.len];
}

fn inputIsMember(input: *ir.Value, members: *const std.AutoHashMap(*ir.Operation, void)) bool {
    const def_any = input.getDefiningOp() orelse return false;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    return members.contains(def_op);
}

fn reduceHasConstantInit(reduce: *ir.Operation) bool {
    const init = reduce.getOperand(1) orelse return false;
    const def_any = init.getDefiningOp() orelse return false;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    return isName(def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name);
}

fn collectReductionProducerDAG(
    value: *ir.Value,
    baseline: shape_analysis.TensorInfo,
    block: *ir.Block,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *ClaimMap,
    members: *std.AutoHashMap(*ir.Operation, void),
    depth: usize,
) anyerror!void {
    if (depth == 0) return;
    const def_any = value.getDefiningOp() orelse return;
    const op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (members.contains(op)) return;
    if (claimed.contains(op)) return;
    if (op.getBlock() != block) return;
    if (!isFusableElementwiseOp(op)) return;

    const result = op.getResult(0) orelse return;
    const result_info = shapes.get(result) orelse return;
    if (!sameStaticShape(result_info, baseline)) return;

    for (op.getOperandValues()) |operand| {
        if (broadcastLeafSource(operand) != null) continue;
        const operand_info = shapes.get(operand) orelse return;
        if (!sameStaticShape(operand_info, baseline)) return;
    }

    try members.put(op, {});
    for (op.getOperandValues()) |operand| {
        if (broadcastLeafSource(operand) != null) continue;
        try collectReductionProducerDAG(
            operand,
            baseline,
            block,
            shapes,
            claimed,
            members,
            depth - 1,
        );
    }
}

fn reductionUsesInside(
    op: *ir.Operation,
    members: *const std.AutoHashMap(*ir.Operation, void),
    reduces: []const *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *const ClaimMap,
) bool {
    const result = op.getResult(0) orelse return false;
    var use = result.first_use;
    while (use) |current_use| : (use = current_use.next_use) {
        const user: *ir.Operation = @ptrCast(@alignCast(current_use.owner));
        if (members.contains(user)) continue;
        var is_fused_reduce = false;
        for (reduces) |reduce| {
            if (user == reduce) {
                is_fused_reduce = true;
                break;
            }
        }
        if (is_fused_reduce) continue;
        if (userCanRecompute(op, user, shapes, claimed)) continue;
        return false;
    }
    return true;
}

fn collectOwnedPrologue(
    allocator: std.mem.Allocator,
    value: *ir.Value,
    members: *const std.AutoHashMap(*ir.Operation, void),
    owned: *std.AutoHashMap(*ir.Operation, void),
    cluster: *std.ArrayListUnmanaged(*ir.Operation),
) anyerror!void {
    const def_any = value.getDefiningOp() orelse return;
    const op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!members.contains(op)) return;
    if (owned.contains(op)) return;
    try owned.put(op, {});
    for (op.getOperandValues()) |operand| {
        if (broadcastLeafSource(operand) != null) continue;
        try collectOwnedPrologue(allocator, operand, members, owned, cluster);
    }
    try cluster.append(allocator, op);
}

fn collectDotEpiloguePlansInRegions(
    allocator: std.mem.Allocator,
    regions: []ir.Region,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    analysis: *FusionPlanAnalysis,
    claimed: *ClaimMap,
) anyerror!void {
    for (regions) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |op| {
                const next = op.next_op;
                if (op.regions.items.len > 0 and !regionsAreOpaque(op)) {
                    try collectDotEpiloguePlansInRegions(
                        allocator,
                        op.regions.items,
                        shapes,
                        analysis,
                        claimed,
                    );
                }
                if (isName(
                    op.name.name,
                    dialect_mod.AccyDialect.DotGeneralOp.operation_name,
                ) and !claimed.contains(op)) {
                    var chain_buffer: [1 + max_dot_epilogue_ops]*ir.Operation = undefined;
                    const chain = collectDotEpilogueChain(op, shapes, claimed, chain_buffer[0..]);
                    if (chain.len >= 2) {
                        try analysis.addClusterOfKind(chain, .dot_epilogue);
                        for (chain) |chain_op| try claimed.put(chain_op, .slot);
                    }
                }
                current = next;
            }
        }
    }
}

fn collectDotEpilogueChain(
    dot: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *ClaimMap,
    buffer: []*ir.Operation,
) []*ir.Operation {
    buffer[0] = dot;
    var count: usize = 1;
    var producer = dot;
    while (count < buffer.len) {
        const consumer = soleFusableConsumer(producer, shapes, claimed) orelse break;
        if (!dotEpilogueOperandsSupported(consumer, producer, shapes)) break;
        buffer[count] = consumer;
        count += 1;
        producer = consumer;
    }
    return buffer[0..count];
}

fn soleFusableConsumer(
    producer: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    claimed: *ClaimMap,
) ?*ir.Operation {
    const result = producer.getResult(0) orelse return null;
    if (!result.hasOneUse()) return null;
    const use = result.first_use orelse return null;
    const user: *ir.Operation = @ptrCast(@alignCast(use.owner));
    if (user.getBlock() != producer.getBlock()) return null;
    if (claimed.contains(user)) return null;
    if (!isDotEpilogueOp(user)) return null;
    if (!compatibleProducerConsumerShapes(producer, user, shapes)) return null;
    const user_result = user.getResult(0) orelse return null;
    const user_info = shapes.get(user_result) orelse return null;
    if (user_info.dtype != .f32) return null;
    return user;
}

fn isDotEpilogueOp(op: *ir.Operation) bool {
    if (!isFusableElementwiseOp(op)) return false;
    const name = op.name.name;
    if (std.mem.eql(u8, name, dialect_mod.AccyDialect.CompareOp.operation_name)) return false;
    if (std.mem.eql(u8, name, dialect_mod.AccyDialect.ConvertOp.operation_name)) return false;
    if (std.mem.eql(u8, name, dialect_mod.AccyDialect.SelectOp.operation_name)) return false;
    return true;
}

fn compatibleProducerConsumerShapes(
    producer: *ir.Operation,
    consumer: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
) bool {
    const producer_result = producer.getResult(0) orelse return false;
    const consumer_result = consumer.getResult(0) orelse return false;
    const producer_info = shapes.get(producer_result) orelse return false;
    const consumer_info = shapes.get(consumer_result) orelse return false;
    return sameStaticShape(producer_info, consumer_info);
}

fn dotEpilogueOperandsSupported(
    consumer: *ir.Operation,
    producer: *ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
) bool {
    const producer_result = producer.getResult(0) orelse return false;
    const consumer_result = consumer.getResult(0) orelse return false;
    const consumer_info = shapes.get(consumer_result) orelse return false;
    for (consumer.getOperandValues()) |operand| {
        if (operand == producer_result) continue;
        if (broadcastLeafSource(operand) != null) continue;
        const operand_info = shapes.get(operand) orelse return false;
        if (!sameStaticShape(consumer_info, operand_info)) return false;
        if (operand.getDefiningOp() != null) return false;
    }
    return true;
}

pub fn broadcastLeafSource(operand: *ir.Value) ?*ir.Value {
    const def_any = operand.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!isName(def_op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name)) {
        return null;
    }
    const operands = def_op.getOperandValues();
    if (operands.len != 1) return null;
    if (operands[0].getDefiningOp() != null) return null;
    return operands[0];
}

fn isName(name: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, name, expected);
}

pub fn isFusableElementwiseOp(op: *ir.Operation) bool {
    if (op.regions.items.len > 0) return false;
    if (op.getNumResults() != 1) return false;
    const name = op.name.name;
    return std.mem.eql(u8, name, dialect_mod.AccyDialect.AddOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.SubOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.MulOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.DivOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.MaxOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.MinOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.PowOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.Atan2Op.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.NegOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.ExpOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.LogOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.TanhOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.SqrtOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.AbsOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.SinOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.CosOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.TanOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.FloorOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.RoundOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.TruncOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.CompareOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.ConvertOp.operation_name) or
        std.mem.eql(u8, name, dialect_mod.AccyDialect.SelectOp.operation_name);
}

const testing = std.testing;
const semantic = accy_choir.semantic;

const FusionProbe = struct {
    var cluster_count: usize = 0;
    var fused_op_count: usize = 0;
    var max_cluster_len: usize = 0;
    var first_root_name: []const u8 = "";

    fn reset() void {
        cluster_count = 0;
        fused_op_count = 0;
        max_cluster_len = 0;
        first_root_name = "";
    }

    fn pass() passes.Pass {
        return .{
            .name = "accy-choir-fusion-test-probe",
            .description = "Inspect Accy Choir fusion plans in tests",
            .run_fn = run,
            .work_contract = .{
                .identity = .{ .name = "accy-choir-fusion-test-probe", .version = 1 },
                .estimate = probeWork,
            },
        };
    }

    fn probeWork(_: passes.pass.work.Input) !passes.pass.work.Bounds {
        return .{ .work = .{ .structural_visits = 16 } };
    }

    fn run(pass_ctx: *passes.PassContext) passes.PassResult {
        const analysis = getFusionPlanAnalysis(pass_ctx, pass_ctx.op) catch return .failure;
        cluster_count = analysis.clusterCount();
        fused_op_count = analysis.fused_op_count;
        max_cluster_len = analysis.max_cluster_len;
        if (analysis.clusters.items.len > 0) {
            first_root_name = analysis.clusters.items[0].root().?.name.name;
        }
        pass_ctx.preserveAllAnalyses();
        return .success;
    }
};

test "fusion planning finds straight-line elementwise chain" {
    const allocator = testing.allocator;
    FusionProbe.reset();

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("fusion_add_mul", &.{ f32_4, f32_4, f32_4 }, &.{f32_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(sum, fb.parameter(2));
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(fusionPlanningPass());
    try pm.addPass(FusionProbe.pass());

    try runAccountedFusion(&pm, choir_mod, ctx);
    try testing.expectEqual(@as(u64, 2), pm.stats.pass_runs);
    try testing.expectEqual(@as(usize, 1), FusionProbe.cluster_count);
    try testing.expectEqual(@as(usize, 2), FusionProbe.fused_op_count);
    try testing.expectEqual(@as(usize, 2), FusionProbe.max_cluster_len);
    try testing.expectEqualStrings(
        dialect_mod.AccyDialect.MulOp.operation_name,
        FusionProbe.first_root_name,
    );
}

test "fusion planning finds single-use elementwise producer DAG" {
    const allocator = testing.allocator;
    FusionProbe.reset();

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction(
        "fusion_branch_sum",
        &.{ f32_4, f32_4, f32_4, f32_4 },
        &.{f32_4},
    );
    const left = try fb.mul(fb.parameter(0), fb.parameter(1));
    const right = try fb.mul(fb.parameter(2), fb.parameter(3));
    const sum = try fb.add(left, right);
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(fusionPlanningPass());
    try pm.addPass(FusionProbe.pass());

    try runAccountedFusion(&pm, choir_mod, ctx);
    try testing.expectEqual(@as(usize, 1), FusionProbe.cluster_count);
    try testing.expectEqual(@as(usize, 3), FusionProbe.fused_op_count);
    try testing.expectEqual(@as(usize, 3), FusionProbe.max_cluster_len);
    try testing.expectEqualStrings(
        dialect_mod.AccyDialect.AddOp.operation_name,
        FusionProbe.first_root_name,
    );
}

test "fusion planning claims slices and pads as see-through members" {
    const allocator = testing.allocator;
    FusionProbe.reset();

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4x4 = try builder.tensor(.f32, &.{ 4, 4 });
    const f32_6x6 = try builder.tensor(.f32, &.{ 6, 6 });
    const scalar = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("fusion_stencil", &.{f32_4x4}, &.{f32_4x4});
    const zero = try fb.constant(scalar, std.mem.asBytes(&@as(f32, 0.0)));
    const padded = try fb.pad(fb.parameter(0), zero, f32_6x6, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 0, 0 });
    const up = try fb.slice(padded, f32_4x4, &.{ 0, 1 }, &.{ 4, 5 }, &.{ 1, 1 });
    const down = try fb.slice(padded, f32_4x4, &.{ 2, 1 }, &.{ 6, 5 }, &.{ 1, 1 });
    const sum = try fb.add(up, down);
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(fusionPlanningPass());
    try pm.addPass(FusionProbe.pass());

    try runAccountedFusion(&pm, choir_mod, ctx);
    try testing.expectEqual(@as(usize, 1), FusionProbe.cluster_count);
    try testing.expectEqual(@as(usize, 4), FusionProbe.fused_op_count);
    try testing.expectEqualStrings(
        dialect_mod.AccyDialect.AddOp.operation_name,
        FusionProbe.first_root_name,
    );
}

test "fusion planning claims reduction prologues with shared recompute" {
    const allocator = testing.allocator;
    FusionProbe.reset();

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4x8 = try builder.tensor(.f32, &.{ 4, 8 });
    const f32_4 = try builder.tensor(.f32, &.{4});
    const scalar = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction(
        "fusion_reduce_pair",
        &.{ f32_4x8, f32_4x8 },
        &.{ f32_4, f32_4 },
    );
    const zero = try fb.constant(scalar, std.mem.asBytes(&@as(f32, 0.0)));
    const shared = try fb.mul(fb.parameter(0), fb.parameter(1));
    const left = try fb.add(shared, fb.parameter(0));
    const right = try fb.sub(shared, fb.parameter(1));
    const left_sum = try fb.reduce(left, zero, f32_4, "sum", &.{1});
    const right_sum = try fb.reduce(right, zero, f32_4, "sum", &.{1});
    try fb.return_(&.{ left_sum, right_sum });
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(fusionPlanningPass());
    try pm.addPass(FusionProbe.pass());

    try runAccountedFusion(&pm, choir_mod, ctx);
    try testing.expectEqual(@as(usize, 2), FusionProbe.cluster_count);
    try testing.expectEqual(@as(usize, 5), FusionProbe.fused_op_count);
}

test "fusion planning claims softmax as one row pipeline" {
    const allocator = testing.allocator;
    FusionProbe.reset();

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4x1024 = try builder.tensor(.f32, &.{ 4, 1024 });
    const f32_4 = try builder.tensor(.f32, &.{4});
    const scalar = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("fusion_softmax", &.{f32_4x1024}, &.{f32_4x1024});
    const neg_inf = try fb.constant(scalar, std.mem.asBytes(&@as(f32, -std.math.inf(f32))));
    const zero = try fb.constant(scalar, std.mem.asBytes(&@as(f32, 0.0)));
    const row_max = try fb.reduce(fb.parameter(0), neg_inf, f32_4, "max", &.{1});
    const max_full = try fb.broadcastInDim(row_max, f32_4x1024, &.{ 4, 1024 }, &.{0});
    const shifted = try fb.sub(fb.parameter(0), max_full);
    const exps = try fb.exp(shifted);
    const row_sum = try fb.reduce(exps, zero, f32_4, "sum", &.{1});
    const sum_full = try fb.broadcastInDim(row_sum, f32_4x1024, &.{ 4, 1024 }, &.{0});
    const out = try fb.div(exps, sum_full);
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(fusionPlanningPass());
    try pm.addPass(FusionProbe.pass());

    try runAccountedFusion(&pm, choir_mod, ctx);
    try testing.expectEqual(@as(usize, 1), FusionProbe.cluster_count);
    try testing.expectEqual(@as(usize, 7), FusionProbe.fused_op_count);
    try testing.expectEqual(@as(usize, 7), FusionProbe.max_cluster_len);
    try testing.expectEqualStrings(
        dialect_mod.AccyDialect.DivOp.operation_name,
        FusionProbe.first_root_name,
    );
}

test "fusion planning keeps narrow softmax on sibling recompute" {
    const allocator = testing.allocator;
    FusionProbe.reset();

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4x8 = try builder.tensor(.f32, &.{ 4, 8 });
    const f32_4 = try builder.tensor(.f32, &.{4});
    const scalar = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("fusion_softmax_narrow", &.{f32_4x8}, &.{f32_4x8});
    const neg_inf = try fb.constant(scalar, std.mem.asBytes(&@as(f32, -std.math.inf(f32))));
    const zero = try fb.constant(scalar, std.mem.asBytes(&@as(f32, 0.0)));
    const row_max = try fb.reduce(fb.parameter(0), neg_inf, f32_4, "max", &.{1});
    const max_full = try fb.broadcastInDim(row_max, f32_4x8, &.{ 4, 8 }, &.{0});
    const shifted = try fb.sub(fb.parameter(0), max_full);
    const exps = try fb.exp(shifted);
    const row_sum = try fb.reduce(exps, zero, f32_4, "sum", &.{1});
    const sum_full = try fb.broadcastInDim(row_sum, f32_4x8, &.{ 4, 8 }, &.{0});
    const out = try fb.div(exps, sum_full);
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(fusionPlanningPass());
    try pm.addPass(FusionProbe.pass());

    try runAccountedFusion(&pm, choir_mod, ctx);
    try testing.expectEqual(@as(usize, 1), FusionProbe.cluster_count);
    try testing.expectEqual(@as(usize, 3), FusionProbe.fused_op_count);
    try testing.expectEqual(@as(usize, 3), FusionProbe.max_cluster_len);
}

test "fusion planning elides producer shared by sibling roots" {
    const allocator = testing.allocator;
    FusionProbe.reset();

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction(
        "fusion_sibling_roots",
        &.{ f32_4, f32_4 },
        &.{ f32_4, f32_4 },
    );
    const shared = try fb.mul(fb.parameter(0), fb.parameter(1));
    const first = try fb.sin(shared);
    const second = try fb.cos(shared);
    try fb.return_(&.{ first, second });
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(fusionPlanningPass());
    try pm.addPass(FusionProbe.pass());

    try runAccountedFusion(&pm, choir_mod, ctx);
    try testing.expectEqual(@as(usize, 1), FusionProbe.cluster_count);
    try testing.expectEqual(@as(usize, 2), FusionProbe.fused_op_count);
    try testing.expectEqual(@as(usize, 2), FusionProbe.max_cluster_len);
}

test "fusion planning rejects producer with escaping use" {
    const allocator = testing.allocator;
    FusionProbe.reset();

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction(
        "fusion_escape",
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
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(fusionPlanningPass());
    try pm.addPass(FusionProbe.pass());

    try runAccountedFusion(&pm, choir_mod, ctx);
    try testing.expectEqual(@as(usize, 0), FusionProbe.cluster_count);
    try testing.expectEqual(@as(usize, 0), FusionProbe.fused_op_count);
}

fn runAccountedFusion(manager: *passes.PassManager, op: *ir.Operation, ctx: *ir.Context) !void {
    const revision = choir.product.revision;
    const ledger = try revision.AccountingV1.create(testing.allocator, .{
        .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
        .workspace = std.math.maxInt(u64),
        .events = 16,
    }, &.{
        .{ .name = fusion_planning_pass_name, .version = 1 },
        .{ .name = "accy-choir-fusion-test-probe", .version = 1 },
    });
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(testing.allocator, null, ledger, .{}, 2);
    defer cache.deinit();
    try testing.expectEqual(
        passes.PassResult.success,
        manager.runWithAnalysisCache(op, ctx, &cache, .{}),
    );
    try ledger.producersComplete();
    try checkFusionStorage(op, ctx, &cache);
}

fn checkFusionStorage(op: *ir.Operation, ctx: *ir.Context, cache: *passes.AnalysisCache) !void {
    const bounds = try fusionAnalysisWork(.{ .operation = op });
    const bytes = try testing.allocator.alloc(u8, @intCast(bounds.workspace));
    defer testing.allocator.free(bytes);
    var storage = alloc_fixed.Tracked.init(bytes);
    var pass_ctx = passes.PassContext.init(op, ctx, storage.allocator(), cache);
    defer pass_ctx.deinit();
    const ptr = try computeFusionPlanAnalysis(&pass_ctx, op);
    defer cleanupFusionPlanAnalysis(ptr, storage.allocator());
    const analysis: *FusionPlanAnalysis = @ptrCast(@alignCast(ptr));
    const reference = try getFusionPlanAnalysis(&pass_ctx, op);
    try testing.expectEqual(reference.fused_op_count, analysis.fused_op_count);
    try testing.expectEqual(reference.clusterCount(), analysis.clusterCount());
    for (reference.clusters.items, analysis.clusters.items) |expected, actual| {
        try testing.expectEqual(expected.kind, actual.kind);
        try testing.expectEqualSlices(*ir.Operation, expected.ops, actual.ops);
    }
    try testing.expectEqualSlices(*ir.Operation, reference.elided.items, analysis.elided.items);
    try testing.expect(!storage.exhausted);
    try testing.expect(storage.status().high_water_bytes <= bounds.workspace);
    try testing.expect(storage.status().high_water_bytes >= @sizeOf(FusionPlanAnalysis));
}

test "fusion planning contract scales through map growth and rejects overflow" {
    for ([_]usize{ 1, 2, 6, 7, 16, 64 }) |count| {
        try checkFusionChain(count);
    }
    try testing.expectError(error.WorkOverflow, work.hashMapCapacity(std.math.maxInt(u64)));
    try testing.expectError(
        error.WorkOverflow,
        work.arrayListGrowth(FusionCluster, std.math.maxInt(u64)),
    );
    try testing.expectError(
        error.WorkOverflow,
        (FusionWork{ .rounds = std.math.maxInt(u64) }).bounds(),
    );
}

fn checkFusionChain(count: usize) !void {
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const typ = try builder.tensor(.f32, &.{ 2, 3 });
    var function = try builder.beginFunction("fusion_chain", &.{ typ, typ }, &.{typ});
    var result = function.parameter(0);
    for (0..count) |_| result = try function.add(result, function.parameter(1));
    try function.return_(&.{result});
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    var manager = passes.PassManager.init(testing.allocator);
    defer manager.deinit();
    try manager.addPass(fusionPlanningPass());
    try manager.addPass(FusionProbe.pass());
    FusionProbe.reset();
    try runAccountedFusion(&manager, module.choir_module, module.context());
    try testing.expectEqual(@as(usize, if (count > 1) 1 else 0), FusionProbe.cluster_count);
    try testing.expectEqual(if (count > 1) count else 0, FusionProbe.fused_op_count);
    try checkFusionAdmission(module.choir_module, module.context());
}

fn checkFusionAdmission(op: *ir.Operation, ctx: *ir.Context) !void {
    const revision = choir.product.revision;
    const bounds = try fusionAnalysisWork(.{ .operation = op });
    const shape = shape_analysis.shape_layout_analysis_descriptor.work_contract.?;
    const shape_bounds = try shape.estimate(.{ .operation = op });
    const analysis_charge = try work.add(
        bounds.work.structural_visits,
        shape_bounds.work.structural_visits,
    );
    const charge = try work.add(analysis_charge, 1);
    for ([_]i8{ -1, 0, 1 }) |offset| {
        var allowance = revision.WorkVector.uniform(std.math.maxInt(u64));
        allowance.structural_visits = @intCast(@as(i128, charge) + offset);
        const ledger = try revision.AccountingV1.create(testing.allocator, .{
            .allowance = allowance,
            .workspace = std.math.maxInt(u64),
            .events = 8,
        }, &.{.{ .name = fusion_planning_pass_name, .version = 1 }});
        defer ledger.destroy();
        var cache = try passes.AnalysisCache.initAccounted(
            testing.allocator,
            null,
            ledger,
            .{},
            2,
        );
        defer cache.deinit();
        var manager = passes.PassManager.init(testing.allocator);
        defer manager.deinit();
        try manager.addPass(fusionPlanningPass());
        const result = manager.runWithAnalysisCache(op, ctx, &cache, .{});
        if (offset < 0) {
            try testing.expectEqual(passes.PassResult.failure, result);
            try testing.expectEqual(revision.receipt.Outcome.exhausted, ledger.view().outcome);
            try testing.expectEqual(@as(usize, 0), cache.entries.count());
        } else {
            try testing.expectEqual(passes.PassResult.success, result);
            try ledger.producersComplete();
            try testing.expectEqual(@as(usize, 2), cache.entries.count());
        }
    }
}
