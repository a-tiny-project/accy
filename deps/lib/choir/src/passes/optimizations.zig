const std = @import("std");
const ir = @import("../core/root.zig");
const rewrite = ir.rewrite;
const pass_mod = @import("pass/root.zig");
const registry_mod = @import("pipeline.zig");
const textual_pipeline = @import("textual.zig");
const canonicalization = @import("canonicalization.zig");
const control_flow = @import("control.zig");
const cse = @import("cse/root.zig");
const effects = @import("effects.zig");
const dialects = @import("../dialects/root.zig");

const PatternRewriter = rewrite.PatternRewriter;
const Pass = pass_mod.Pass;
const PassContext = pass_mod.PassContext;
const PassResult = pass_mod.PassResult;

const arith = dialects.ArithDialect;
const memref = dialects.MemrefDialect;
const scf = dialects.ScfDialect;

const maximum_sccp_operation_depth: usize = 256;

pub const dead_code_elimination_pass_name = "choir-dce";
pub const dead_code_elimination_pass_description =
    "Dead code elimination for trivially dead operations";
pub const common_subexpression_elimination_pass_name = cse.common_subexpression_elimination_pass_name;
pub const common_subexpression_elimination_pass_description = cse.common_subexpression_elimination_pass_description;
pub const constant_folding_pass_name = "choir-const-fold";
pub const constant_folding_pass_description =
    "Constant folding for scalar arith operations";
pub const sparse_conditional_constant_propagation_pass_name = "choir-sccp";
pub const sparse_conditional_constant_propagation_pass_description =
    "Sparse conditional constant propagation for scalar values";
pub const load_store_forwarding_pass_name = "choir-load-store-forward";
pub const load_store_forwarding_pass_description =
    "Load/store forwarding for simple memref patterns";
pub const dead_store_elimination_pass_name = "choir-dse";
pub const dead_store_elimination_pass_description =
    "Dead store elimination for simple block-local memref overwrites";
pub const loop_invariant_code_motion_pass_name = "choir-licm";
pub const loop_invariant_code_motion_pass_description =
    "Loop-invariant code motion for scf.for";
pub const equality_saturation_pass_name = "choir-eqsat-arith";
pub const equality_saturation_pass_description =
    "Equality saturation over pure scalar arith operations";
pub const default_optimization_pipeline_name = "choir-cleanup";
pub const default_optimization_pipeline_description =
    "Run the standard Choir canonicalization and cleanup optimization pipeline";

pub fn createDeadCodeEliminationPass() Pass {
    return .{
        .name = dead_code_elimination_pass_name,
        .description = dead_code_elimination_pass_description,
        .run_fn = runDeadCodeElimination,
        .mutation_scope = .isolated,
    };
}

pub const createCommonSubexpressionEliminationPass = cse.createCommonSubexpressionEliminationPass;

const promotion = @import("promotion.zig");
pub const createMemoryPromotionPass = promotion.createMemoryPromotionPass;
pub const memory_promotion_pass_name = promotion.memory_promotion_pass_name;

pub fn createConstantFoldingPass() Pass {
    return .{
        .name = constant_folding_pass_name,
        .description = constant_folding_pass_description,
        .run_fn = runConstantFolding,
        .mutation_scope = .isolated,
    };
}

pub fn createSparseConditionalConstantPropagationPass() Pass {
    return .{
        .name = sparse_conditional_constant_propagation_pass_name,
        .description = sparse_conditional_constant_propagation_pass_description,
        .run_fn = runSparseConditionalConstantPropagation,
        .mutation_scope = .isolated,
    };
}

pub fn createLoadStoreForwardingPass() Pass {
    return .{
        .name = load_store_forwarding_pass_name,
        .description = load_store_forwarding_pass_description,
        .run_fn = runLoadStoreForwarding,
        .mutation_scope = .isolated,
    };
}

pub fn createDeadStoreEliminationPass() Pass {
    return .{
        .name = dead_store_elimination_pass_name,
        .description = dead_store_elimination_pass_description,
        .run_fn = runDeadStoreElimination,
        .mutation_scope = .isolated,
    };
}

pub fn createLoopInvariantCodeMotionPass() Pass {
    return .{
        .name = loop_invariant_code_motion_pass_name,
        .description = loop_invariant_code_motion_pass_description,
        .run_fn = runLoopInvariantCodeMotion,
        .mutation_scope = .whole_module,
    };
}

pub const dead_code_elimination_pass_registration = registry_mod.PassRegistration{
    .name = dead_code_elimination_pass_name,
    .description = dead_code_elimination_pass_description,
    .pass = createDeadCodeEliminationPass(),
};

pub const common_subexpression_elimination_pass_registration = cse.common_subexpression_elimination_pass_registration;

pub const constant_folding_pass_registration = registry_mod.PassRegistration{
    .name = constant_folding_pass_name,
    .description = constant_folding_pass_description,
    .pass = createConstantFoldingPass(),
};

pub const sparse_conditional_constant_propagation_pass_registration = registry_mod.PassRegistration{
    .name = sparse_conditional_constant_propagation_pass_name,
    .description = sparse_conditional_constant_propagation_pass_description,
    .pass = createSparseConditionalConstantPropagationPass(),
};

pub const load_store_forwarding_pass_registration = registry_mod.PassRegistration{
    .name = load_store_forwarding_pass_name,
    .description = load_store_forwarding_pass_description,
    .pass = createLoadStoreForwardingPass(),
};

pub const dead_store_elimination_pass_registration = registry_mod.PassRegistration{
    .name = dead_store_elimination_pass_name,
    .description = dead_store_elimination_pass_description,
    .pass = createDeadStoreEliminationPass(),
};

pub const loop_invariant_code_motion_pass_registration = registry_mod.PassRegistration{
    .name = loop_invariant_code_motion_pass_name,
    .description = loop_invariant_code_motion_pass_description,
    .pass = createLoopInvariantCodeMotionPass(),
};

const ArithEqualitySaturationPass = @import("root.zig").EGraphPass(.{
    .name = equality_saturation_pass_name,
    .description = equality_saturation_pass_description,
    .populate_rules = dialects.arith.populateEGraphRules,
});

pub fn createEqualitySaturationPass() Pass {
    return ArithEqualitySaturationPass.create();
}

pub const equality_saturation_pass_registration = registry_mod.PassRegistration{
    .name = equality_saturation_pass_name,
    .description = equality_saturation_pass_description,
    .pass = createEqualitySaturationPass(),
};

pub const optimization_pass_registrations = [_]registry_mod.PassRegistration{
    canonicalization.canonicalization_pass_registration,
    constant_folding_pass_registration,
    sparse_conditional_constant_propagation_pass_registration,
    common_subexpression_elimination_pass_registration,
    load_store_forwarding_pass_registration,
    dead_store_elimination_pass_registration,
    loop_invariant_code_motion_pass_registration,
    promotion.memory_promotion_pass_registration,
    equality_saturation_pass_registration,
    dead_code_elimination_pass_registration,
};

pub const default_optimization_pipeline_registration = registry_mod.PipelineRegistration{
    .name = default_optimization_pipeline_name,
    .description = default_optimization_pipeline_description,
    .build = buildDefaultOptimizationPipeline,
};

pub const optimization_pipeline_registrations = [_]registry_mod.PipelineRegistration{
    default_optimization_pipeline_registration,
};

pub fn addDefaultOptimizationPipeline(pm: *pass_mod.PassManager) !void {
    try default_optimization_pipeline_registration.addTo(&pm.root);
}

pub fn buildDefaultOptimizationPipeline(pm: *pass_mod.OpPassManager) anyerror!void {
    try pm.addPass(promotion.createMemoryPromotionPass());
    try pm.addPass(canonicalization.createCanonicalizationPass());
    try pm.addPass(createConstantFoldingPass());
    try pm.addPass(createSparseConditionalConstantPropagationPass());
    try pm.addPass(canonicalization.createCanonicalizationPass());
    try pm.addPass(createCommonSubexpressionEliminationPass());
    try pm.addPass(createLoadStoreForwardingPass());
    try pm.addPass(createDeadStoreEliminationPass());
    try pm.addPass(createLoopInvariantCodeMotionPass());
    try pm.addPass(createCommonSubexpressionEliminationPass());
    try pm.addPass(createDeadCodeEliminationPass());
}

pub fn registerOptimizationPassEntries(registry: *registry_mod.PassRegistry) !void {
    for (optimization_pass_registrations) |registration| {
        try registry.registerPass(registration);
    }
    for (optimization_pipeline_registrations) |registration| {
        try registry.registerPipeline(registration);
    }
}

test "optimization pass mutation scopes classify cleanup locality" {
    try std.testing.expect(createDeadCodeEliminationPass().isolatedMutation());
    const cse_pass = createCommonSubexpressionEliminationPass();
    try std.testing.expect(cse_pass.isolatedMutation());
    try std.testing.expectEqual(pass_mod.PassRerunPolicy.skip_if_unchanged, cse_pass.rerun_policy);
    try std.testing.expect(cse_pass.validRerunContract());
    try std.testing.expect(createConstantFoldingPass().isolatedMutation());
    try std.testing.expect(createSparseConditionalConstantPropagationPass().isolatedMutation());
    try std.testing.expect(createLoadStoreForwardingPass().isolatedMutation());
    try std.testing.expect(createDeadStoreEliminationPass().isolatedMutation());
    try std.testing.expect(createLoopInvariantCodeMotionPass().wholeModuleMutation());
}

const CleanupRunFn = *const fn (*PassContext) PassResult;

fn expectUnmodifiedCleanupPreservesAll(run_fn: CleanupRunFn) !void {
    const allocator = std.testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var cache = pass_mod.AnalysisCache.init(allocator, null);
    defer cache.deinit();

    var pass_ctx = PassContext.init(module.op, &ctx, allocator, &cache);
    defer pass_ctx.deinit();

    try std.testing.expectEqual(PassResult.success, run_fn(&pass_ctx));
    try std.testing.expect(!pass_ctx.modified);
    try std.testing.expect(pass_ctx.preserved.preserve_all);
}

test "unmodified cleanup passes preserve all analyses" {
    try expectUnmodifiedCleanupPreservesAll(cse.run);
    try expectUnmodifiedCleanupPreservesAll(runConstantFolding);
    try expectUnmodifiedCleanupPreservesAll(runLoadStoreForwarding);
    try expectUnmodifiedCleanupPreservesAll(runDeadStoreElimination);
    try expectUnmodifiedCleanupPreservesAll(runLoopInvariantCodeMotion);
}

fn runDeadCodeElimination(ctx: *PassContext) PassResult {
    const modified = canonicalization.eliminateDeadOps(ctx);
    if (modified) {
        ctx.markModified();
    } else {
        ctx.preserveAllAnalyses();
    }
    return .success;
}

fn runConstantFolding(ctx: *PassContext) PassResult {
    var rewriter = PatternRewriter.init(ctx.allocator, ctx.ir_ctx);
    defer rewriter.deinit();

    var modified = false;
    constantFoldOnOp(ctx.op, ctx.ir_ctx, &rewriter, &modified);
    rewriter.finalize(ctx.op);

    if (modified) {
        ctx.markModified();
    } else {
        ctx.preserveAllAnalyses();
    }
    return .success;
}

fn constantFoldOnOp(
    op: *ir.Operation,
    ir_ctx: *ir.Context,
    rewriter: *PatternRewriter,
    modified: *bool,
) void {
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                const next = current_op.next_op;

                if (current_op.regions.items.len > 0) {
                    constantFoldOnOp(current_op, ir_ctx, rewriter, modified);
                }

                if (tryFoldEvaluatableOp(current_op, ir_ctx, rewriter)) {
                    modified.* = true;
                } else if (tryFoldRegisteredAttributeOp(current_op, ir_ctx, rewriter)) {
                    modified.* = true;
                }

                current = next;
            }
        }
    }
}

fn runSparseConditionalConstantPropagation(ctx: *PassContext) PassResult {
    var rewriter = PatternRewriter.init(ctx.allocator, ctx.ir_ctx);
    defer rewriter.deinit();

    var modified = false;
    sccpOnOp(ctx.op, ctx.ir_ctx, &rewriter, &modified) catch return .failure;
    rewriter.finalize(ctx.op);

    if (modified) {
        ctx.preserveAnalysisSet(control_flow.analysis_ids);
        ctx.markModified();
    } else {
        ctx.preserveAllAnalyses();
    }
    return .success;
}

const SccpOperationTarget = struct {
    op: *ir.Operation,
    visit: bool,
};

const SccpTarget = union(enum) {
    operation: SccpOperationTarget,
    region: *ir.Region,
    block: *ir.Block,
};

fn sccpOnOp(
    op: *ir.Operation,
    ir_ctx: *ir.Context,
    rewriter: *PatternRewriter,
    modified: *bool,
) anyerror!void {
    try sccpWalk(.{ .operation = .{ .op = op, .visit = false } }, 1, ir_ctx, rewriter, modified);
}

fn sccpWalk(
    target: SccpTarget,
    operation_depth: usize,
    ir_ctx: *ir.Context,
    rewriter: *PatternRewriter,
    modified: *bool,
) anyerror!void {
    std.debug.assert(operation_depth > 0);
    switch (target) {
        .operation => |operation| {
            if (operation_depth > maximum_sccp_operation_depth) return error.NestingLimitExceeded;
            const child_depth = operation_depth + 1;
            const op = operation.op;
            if (operation.visit and std.mem.eql(u8, op.name.name, scf.IfOp.operation_name)) {
                const if_op = scf.IfOp{ .op = op };
                const condition = constantFromValue(if_op.getCondition());
                if (condition) |constant| {
                    if (constBool(constant)) |known_condition| {
                        if (selectedSccpIfBlock(if_op, known_condition)) |selected| {
                            try sccpWalk(.{ .block = selected }, child_depth, ir_ctx, rewriter, modified);
                            try propagateSelectedIfConstants(if_op, selected, ir_ctx, rewriter, modified);
                        }
                        return;
                    }
                }

                try sccpWalk(.{ .block = if_op.getThenBlock() }, child_depth, ir_ctx, rewriter, modified);
                if (if_op.getElseBlock()) |else_block| {
                    try sccpWalk(.{ .block = else_block }, child_depth, ir_ctx, rewriter, modified);
                }
                return;
            }

            for (op.regions.items) |*region| {
                try sccpWalk(.{ .region = region }, child_depth, ir_ctx, rewriter, modified);
            }

            if (!operation.visit) return;
            if (!effects.permitsRepeatableExpression(op)) return;

            const folded = inferConstant(op) orelse return;
            const result = op.getResult(0) orelse return;
            try recordSccpConstant(ir_ctx, rewriter, op, result, folded, modified);
        },
        .region => |region| {
            var block_iter = region.getBlocks();
            while (block_iter.next()) |block| {
                try sccpWalk(.{ .block = block }, operation_depth, ir_ctx, rewriter, modified);
            }
        },
        .block => |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                const next = current_op.next_op;
                try sccpWalk(.{ .operation = .{ .op = current_op, .visit = true } }, operation_depth, ir_ctx, rewriter, modified);
                current = next;
            }
        },
    }
}

fn selectedSccpIfBlock(if_op: scf.IfOp, condition: bool) ?*ir.Block {
    if (condition) return if_op.getThenBlock();
    return if_op.getElseBlock();
}

fn propagateSelectedIfConstants(
    if_op: scf.IfOp,
    selected: *ir.Block,
    ir_ctx: *ir.Context,
    rewriter: *PatternRewriter,
    modified: *bool,
) anyerror!void {
    const yield = sccpYieldTerminator(selected) orelse return;
    if (yield.operands.items.len != if_op.op.getNumResults()) return;

    for (yield.operands.items, 0..) |operand, index| {
        const constant = constantFromValue(operand.value) orelse continue;
        const result = if_op.op.getResult(index) orelse continue;
        try recordSccpConstant(ir_ctx, rewriter, if_op.op, result, constant, modified);
    }
}

fn sccpYieldTerminator(block: *ir.Block) ?*ir.Operation {
    const tail = block.operations.tail orelse return null;
    const op: *ir.Operation = @ptrCast(@alignCast(tail));
    if (!std.mem.eql(u8, op.name.name, scf.YieldOp.operation_name)) return null;
    return op;
}

fn recordSccpConstant(
    ir_ctx: *ir.Context,
    rewriter: *PatternRewriter,
    before: *ir.Operation,
    value: *ir.Value,
    constant: ConstValue,
    modified: *bool,
) anyerror!void {
    if (value.hasNoUses()) return;
    if (try materializeSccpConstant(ir_ctx, rewriter, before, value, constant)) {
        modified.* = true;
    }
}

fn materializeSccpConstant(
    ir_ctx: *ir.Context,
    rewriter: *PatternRewriter,
    before: *ir.Operation,
    value: *ir.Value,
    constant: ConstValue,
) anyerror!bool {
    const attr = constantAttrForType(ir_ctx, value.type, constant) catch return false;
    rewriter.setInsertionPointBefore(before);
    var state = ir.Operation.State.init(arith.ConstantOp.operation_name, before.location);
    state.addTypes(&.{value.type});
    const uses_properties = try state.setPropertiesAttrIfRegistered(ir_ctx, attr);
    const const_op = try rewriter.create(state);
    if (!uses_properties) try const_op.setAttr("value", attr);
    const result = const_op.getResult(0) orelse return false;
    try rewriter.replaceAllUsesWith(value, result);
    return true;
}

fn runLoadStoreForwarding(ctx: *PassContext) PassResult {
    var rewriter = PatternRewriter.init(ctx.allocator, ctx.ir_ctx);
    defer rewriter.deinit();

    var modified = false;
    forwardOnOp(ctx.op, ctx.allocator, &rewriter, &modified);
    rewriter.finalize(ctx.op);

    if (modified) {
        ctx.markModified();
    } else {
        ctx.preserveAllAnalyses();
    }
    return .success;
}

const StoreInfo = struct {
    value: *ir.Value,
};

const MemoryLocation = struct {
    memref: *ir.Value,
    index: *ir.Value,
};

const MemoryLocationContext = struct {
    pub fn hash(_: MemoryLocationContext, key: MemoryLocation) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const memref_id = @intFromPtr(key.memref);
        const index_id = @intFromPtr(key.index);
        hasher.update(std.mem.asBytes(&memref_id));
        hasher.update(std.mem.asBytes(&index_id));
        return hasher.final();
    }

    pub fn eql(_: MemoryLocationContext, lhs: MemoryLocation, rhs: MemoryLocation) bool {
        return lhs.memref == rhs.memref and lhs.index == rhs.index;
    }
};

const StoreInfoMap = std.HashMap(MemoryLocation, StoreInfo, MemoryLocationContext, std.hash_map.default_max_load_percentage);
const StoreOpMap = std.HashMap(MemoryLocation, *ir.Operation, MemoryLocationContext, std.hash_map.default_max_load_percentage);

fn forwardOnOp(
    op: *ir.Operation,
    allocator: std.mem.Allocator,
    rewriter: *PatternRewriter,
    modified: *bool,
) void {
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var stores = StoreInfoMap.init(allocator);
            defer stores.deinit();

            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                const next = current_op.next_op;

                if (current_op.regions.items.len > 0) {
                    forwardOnOp(current_op, allocator, rewriter, modified);
                    stores.clearRetainingCapacity();
                    current = next;
                    continue;
                }

                forwardOperation(current_op, &stores, rewriter, modified);
                current = next;
            }
        }
    }
}

fn forwardOperation(
    current_op: *ir.Operation,
    stores: *StoreInfoMap,
    rewriter: *PatternRewriter,
    modified: *bool,
) void {
    if (isMemrefStore(current_op)) {
        if (!effects.permitsDiscard(current_op)) {
            stores.clearRetainingCapacity();
            return;
        }
        const location = memrefStoreLocation(current_op) orelse {
            stores.clearRetainingCapacity();
            return;
        };
        const stored_val = current_op.operands.items[0].value;
        _ = stores.put(location, .{ .value = stored_val }) catch {};
        return;
    }

    if (isMemrefLoad(current_op)) {
        if (!effects.permitsDiscard(current_op)) {
            stores.clearRetainingCapacity();
            return;
        }
        const location = memrefLoadLocation(current_op) orelse {
            stores.clearRetainingCapacity();
            return;
        };
        if (stores.get(location)) |info| {
            rewriter.replaceOpWithValue(current_op, info.value) catch {};
            modified.* = true;
        }
        return;
    }

    if (invalidatesStores(current_op)) {
        stores.clearRetainingCapacity();
    }
}

fn runDeadStoreElimination(ctx: *PassContext) PassResult {
    var rewriter = PatternRewriter.init(ctx.allocator, ctx.ir_ctx);
    defer rewriter.deinit();

    var modified = false;
    eliminateDeadStoresOnOp(ctx.op, ctx.allocator, &rewriter, &modified);
    rewriter.finalize(ctx.op);

    if (modified) {
        ctx.markModified();
    } else {
        ctx.preserveAllAnalyses();
    }
    return .success;
}

fn eliminateDeadStoresOnOp(
    op: *ir.Operation,
    allocator: std.mem.Allocator,
    rewriter: *PatternRewriter,
    modified: *bool,
) void {
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var stores = StoreOpMap.init(allocator);
            defer stores.deinit();

            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                const next = current_op.next_op;

                if (current_op.regions.items.len > 0) {
                    eliminateDeadStoresOnOp(current_op, allocator, rewriter, modified);
                    stores.clearRetainingCapacity();
                    current = next;
                    continue;
                }

                eliminateDeadStoreOperation(current_op, &stores, rewriter, modified);
                current = next;
            }
        }
    }
}

fn eliminateDeadStoreOperation(
    current_op: *ir.Operation,
    stores: *StoreOpMap,
    rewriter: *PatternRewriter,
    modified: *bool,
) void {
    if (isMemrefStore(current_op)) {
        if (!effects.permitsDiscard(current_op)) {
            stores.clearRetainingCapacity();
            return;
        }
        const location = memrefStoreLocation(current_op) orelse {
            stores.clearRetainingCapacity();
            return;
        };
        if (stores.get(location)) |previous| {
            rewriter.eraseOp(previous) catch {
                _ = stores.put(location, current_op) catch {};
                return;
            };
            modified.* = true;
        }
        _ = stores.put(location, current_op) catch {};
        return;
    }

    if (isMemrefLoad(current_op)) {
        if (!effects.permitsDiscard(current_op)) {
            stores.clearRetainingCapacity();
            return;
        }
        if (memrefLoadLocation(current_op)) |location| {
            _ = stores.remove(location);
        } else {
            stores.clearRetainingCapacity();
        }
        return;
    }

    if (observesOrInvalidatesStores(current_op)) {
        stores.clearRetainingCapacity();
    }
}

fn runLoopInvariantCodeMotion(ctx: *PassContext) PassResult {
    var modified = false;
    licmOnOp(ctx.op, &modified);
    if (modified) {
        ctx.markModified();
    } else {
        ctx.preserveAllAnalyses();
    }
    return .success;
}

fn licmOnOp(op: *ir.Operation, modified: *bool) void {
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                const next = current_op.next_op;
                licmOnOp(current_op, modified);
                current = next;
            }
        }
    }

    if (std.mem.eql(u8, op.name.name, scf.ForOp.operation_name)) {
        if (hoistLoopInvariants(op)) {
            modified.* = true;
        }
    }
}

fn hoistLoopInvariants(for_op: *ir.Operation) bool {
    const loop = scf.ForOp{ .op = for_op };
    const body_block = loop.getBodyBlock();
    if (for_op.getBlock() == null) return false;

    var modified = false;
    var progress = true;
    while (progress) {
        progress = false;
        var current: ?*ir.Operation = @ptrCast(@alignCast(body_block.operations.head));
        while (current) |current_op| {
            const next = current_op.next_op;

            if (std.mem.eql(u8, current_op.name.name, scf.YieldOp.operation_name)) {
                current = next;
                continue;
            }

            if (isLoopInvariantCandidate(current_op) and canMoveToLoopEntry(current_op, for_op)) {
                current_op.moveBefore(for_op) catch {
                    current = next;
                    continue;
                };

                modified = true;
                progress = true;
            }

            current = next;
        }
    }

    return modified;
}

fn canMoveToLoopEntry(op: *ir.Operation, loop_op: *ir.Operation) bool {
    if (!operandsInvariant(op, loop_op)) return false;
    var summary = effects.EffectSummary.init(op.allocator, op) catch return false;
    defer summary.deinit();
    if (!summary.speculate(true) or !summary.duplicate(.{})) return false;
    var previous = op.prev_op;
    while (previous) |crossed| : (previous = crossed.prev_op) {
        var crossing = effects.EffectSummary.init(op.allocator, crossed) catch return false;
        defer crossing.deinit();
        if (!summary.reorder(&crossing)) return false;
    }
    return true;
}

fn operandsInvariant(
    op: *ir.Operation,
    loop_op: *ir.Operation,
) bool {
    for (op.operands.items) |operand| {
        if (!valueInvariant(operand.value, loop_op)) return false;
        if (!valueAvailableBefore(operand.value, loop_op)) return false;
    }
    return true;
}

fn valueAvailableBefore(value: *ir.Value, destination: *ir.Operation) bool {
    var current: ?*ir.Operation = destination;
    while (current) |placement| : (current = placement.getParentOp()) {
        if (value.getDefiningOp()) |definition| {
            const op: *ir.Operation = @ptrCast(@alignCast(definition));
            if (op.getBlock() == placement.getBlock()) return op.isBeforeInBlock(placement);
        } else if (value.getOwnerBlock()) |owner| {
            if (owner == @as(?*anyopaque, @ptrCast(placement.getBlock()))) return true;
        }
    }
    return false;
}

fn valueInvariant(
    value: *ir.Value,
    loop_op: *ir.Operation,
) bool {
    if (value.getDefiningOp()) |def_any| {
        const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
        return !loop_op.isAncestor(def_op);
    }

    if (value.getOwnerBlock()) |block_any| {
        const block: *ir.Block = @ptrCast(@alignCast(block_any));
        const parent_op = block.getParentOperation() orelse return true;
        return !loop_op.isAncestor(parent_op);
    }

    return true;
}

fn isLoopInvariantCandidate(op: *ir.Operation) bool {
    if (op.regions.items.len > 0) return false;
    if (op.getNumResults() == 0) return false;
    if (op.getNumSuccessors() != 0) return false;
    if (op.hasTrait("is_terminator")) return false;
    return effects.permitsRepeatableExpression(op);
}

fn isMemrefLoad(op: *ir.Operation) bool {
    return std.mem.eql(u8, op.name.name, memref.LoadOp.operation_name);
}

fn isMemrefStore(op: *ir.Operation) bool {
    return std.mem.eql(u8, op.name.name, memref.StoreOp.operation_name);
}

fn memrefLoadLocation(op: *ir.Operation) ?MemoryLocation {
    if (!isMemrefLoad(op)) return null;
    if (op.operands.items.len != 2) return null;
    return .{
        .memref = op.operands.items[0].value,
        .index = op.operands.items[1].value,
    };
}

fn memrefStoreLocation(op: *ir.Operation) ?MemoryLocation {
    if (!isMemrefStore(op)) return null;
    if (op.operands.items.len != 3) return null;
    return .{
        .memref = op.operands.items[1].value,
        .index = op.operands.items[2].value,
    };
}

fn invalidatesStores(op: *ir.Operation) bool {
    if (op.hasTrait("is_terminator")) return true;
    var summary = effects.EffectSummary.init(op.allocator, op) catch return true;
    defer summary.deinit();
    return summary.invalidatesStores();
}

fn observesOrInvalidatesStores(op: *ir.Operation) bool {
    if (op.hasTrait("is_terminator")) return true;
    var summary = effects.EffectSummary.init(op.allocator, op) catch return true;
    defer summary.deinit();
    return summary.observesStores();
}

const ConstValue = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
};

const ScalarKind = enum {
    int,
    float,
    bool,
    other,
};

fn constInt(value: ConstValue) ?i64 {
    return switch (value) {
        .int => |v| v,
        else => null,
    };
}

fn constBool(value: ConstValue) ?bool {
    return switch (value) {
        .bool => |v| v,
        else => null,
    };
}

fn classifyType(ty: ir.Type) ScalarKind {
    const kind = dialects.arith.scalarKindFromType(ty) orelse return .other;
    return switch (kind) {
        .bool => .bool,
        .f16, .bf16, .f32, .f64 => .float,
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .index => .int,
    };
}

fn constantFromValue(value: *ir.Value) ?ConstValue {
    const def_any = value.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!std.mem.eql(u8, def_op.name.name, arith.ConstantOp.operation_name)) return null;

    if (def_op.getAttrAs(ir.Attribute.IntegerAttr, "value")) |int_attr| {
        return .{ .int = int_attr.getValue() };
    }
    if (def_op.getAttrAs(ir.Attribute.FloatAttr, "value")) |float_attr| {
        return .{ .float = float_attr.getValue() };
    }
    if (def_op.getAttrAs(ir.Attribute.BoolAttr, "value")) |bool_attr| {
        return .{ .bool = bool_attr.getValue() };
    }
    return null;
}

fn constantFromAttribute(attr: ir.Attribute) ?ConstValue {
    if (arith.getIntValue(attr)) |int_val| return .{ .int = int_val };
    if (arith.getFloatValue(attr)) |float_val| return .{ .float = float_val };
    if (arith.getBoolValue(attr)) |bool_val| return .{ .bool = bool_val };
    return null;
}

fn inferConstant(op: *ir.Operation) ?ConstValue {
    if (std.mem.eql(u8, op.name.name, arith.ConstantOp.operation_name)) return null;
    if (op.getNumResults() != 1) return null;
    if (!effects.permitsRepeatableExpression(op)) return null;
    const iface = op.interface(ir.interfaces.Evaluatable) orelse return null;
    if (!iface.call(.canEval, .{})) return null;
    var evaluator = @import("../eval/root.zig").Evaluator.init(op.allocator, op.getContext());
    defer evaluator.deinit();
    for (op.getOperandValues()) |operand| {
        const value = constantFromValue(operand) orelse return null;
        const attr = constantAttrForType(op.getContext(), operand.type, value) catch return null;
        evaluator.setValue(operand, attr) catch return null;
    }
    const result = evaluator.evaluate(op) catch return null;
    return constantFromAttribute(result);
}

fn tryFoldEvaluatableOp(op: *ir.Operation, ir_ctx: *ir.Context, rewriter: *PatternRewriter) bool {
    if (!effects.permitsRepeatableExpression(op)) return false;
    const folded = inferConstant(op) orelse return false;
    return replaceWithConstant(op, ir_ctx, rewriter, folded);
}

fn tryFoldRegisteredAttributeOp(op: *ir.Operation, ir_ctx: *ir.Context, rewriter: *PatternRewriter) bool {
    if (!effects.permitsRepeatableExpression(op)) return false;
    const iface = op.interface(ir.interfaces.FoldOpInterface) orelse return false;

    const result_count = op.getNumResults();
    var inline_results: [1]ir.interfaces.FoldResult = undefined;
    const result_storage = if (result_count <= inline_results.len)
        inline_results[0..result_count]
    else
        rewriter.allocator.alloc(ir.interfaces.FoldResult, result_count) catch return false;
    defer if (result_count > inline_results.len) rewriter.allocator.free(result_storage);

    var folded = ir.interfaces.FoldResults.init(result_storage);
    iface.call(.fold, .{&folded}) catch return false;
    const folded_results = folded.slice();

    if (folded_results.len == 0) return false;
    if (folded_results.len != result_count) return false;

    var inline_values: [1]*ir.Value = undefined;
    const values = if (result_count <= inline_values.len)
        inline_values[0..result_count]
    else
        rewriter.allocator.alloc(*ir.Value, result_count) catch return false;
    defer if (result_count > inline_values.len) rewriter.allocator.free(values);

    for (folded_results, 0..) |folded_result, index| {
        const op_result = op.getResult(index) orelse return false;
        const constant = switch (folded_result) {
            .attribute => |attr| constantFromAttribute(attr) orelse return false,
            .value => return false,
        };
        values[index] = createConstantValue(ir_ctx, rewriter, op, op_result.type, constant) orelse return false;
    }

    rewriter.replaceOp(op, values) catch return false;
    return true;
}

fn replaceWithConstant(
    op: *ir.Operation,
    ir_ctx: *ir.Context,
    rewriter: *PatternRewriter,
    value: ConstValue,
) bool {
    const result_type = op.getResultTypes()[0];
    const result = createConstantValue(ir_ctx, rewriter, op, result_type, value) orelse return false;
    rewriter.replaceOpWithValue(op, result) catch return false;
    return true;
}

fn createConstantValue(
    ir_ctx: *ir.Context,
    rewriter: *PatternRewriter,
    before: *ir.Operation,
    result_type: ir.Type,
    value: ConstValue,
) ?*ir.Value {
    const attr = constantAttrForType(ir_ctx, result_type, value) catch return null;

    rewriter.setInsertionPointBefore(before);
    var state = ir.Operation.State.init(arith.ConstantOp.operation_name, before.location);
    state.addTypes(&.{result_type});
    const uses_properties = state.setPropertiesAttrIfRegistered(ir_ctx, attr) catch return null;
    const const_op = rewriter.create(state) catch return null;
    if (!uses_properties) const_op.setAttr("value", attr) catch return null;
    return const_op.getResult(0);
}

fn constantAttrForType(
    ir_ctx: *ir.Context,
    ty: ir.Type,
    value: ConstValue,
) !ir.Attribute {
    return switch (classifyType(ty)) {
        .int => switch (value) {
            .int => |v| try arith.getIntAttr(ir_ctx, v),
            else => error.InvalidConstant,
        },
        .float => switch (value) {
            .float => |v| try arith.getFloatAttr(ir_ctx, v),
            else => error.InvalidConstant,
        },
        .bool => switch (value) {
            .bool => |v| try arith.getBoolAttr(ir_ctx, v),
            else => error.InvalidConstant,
        },
        else => error.InvalidConstant,
    };
}

const testing = std.testing;
const test_dialect = @import("../dialects/fixture/root.zig");

fn buildTestContext(allocator: std.mem.Allocator) !ir.Context {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    errdefer ctx.deinit(allocator);
    try test_dialect.registerTestDialect(&ctx);
    return ctx;
}

fn runDcePass(allocator: std.mem.Allocator, module: *ir.Operation, ctx: *ir.Context) !pass_mod.PassManager {
    var pm = pass_mod.PassManager.init(allocator);
    errdefer pm.deinit();
    try pm.addPass(createDeadCodeEliminationPass());
    try testing.expectEqual(PassResult.success, pm.run(module, ctx));
    return pm;
}

fn runConstantFoldingPass(allocator: std.mem.Allocator, module: *ir.Operation, ctx: *ir.Context) !pass_mod.PassManager {
    var pm = pass_mod.PassManager.init(allocator);
    errdefer pm.deinit();
    try pm.addPass(createConstantFoldingPass());
    try testing.expectEqual(PassResult.success, pm.run(module, ctx));
    return pm;
}

fn runSccpPass(allocator: std.mem.Allocator, module: *ir.Operation, ctx: *ir.Context) !pass_mod.PassManager {
    var pm = pass_mod.PassManager.init(allocator);
    errdefer pm.deinit();
    try pm.addPass(createSparseConditionalConstantPropagationPass());
    try testing.expectEqual(PassResult.success, pm.run(module, ctx));
    return pm;
}

fn runLicmPass(allocator: std.mem.Allocator, module: *ir.Operation, ctx: *ir.Context) !pass_mod.PassManager {
    var pm = pass_mod.PassManager.init(allocator);
    errdefer pm.deinit();
    try pm.addPass(createLoopInvariantCodeMotionPass());
    try testing.expectEqual(PassResult.success, pm.run(module, ctx));
    return pm;
}

fn runLoadStoreForwardingPass(allocator: std.mem.Allocator, module: *ir.Operation, ctx: *ir.Context) !pass_mod.PassManager {
    var pm = pass_mod.PassManager.init(allocator);
    errdefer pm.deinit();
    try pm.addPass(createLoadStoreForwardingPass());
    try testing.expectEqual(PassResult.success, pm.run(module, ctx));
    return pm;
}

fn runDeadStoreEliminationPass(allocator: std.mem.Allocator, module: *ir.Operation, ctx: *ir.Context) !pass_mod.PassManager {
    var pm = pass_mod.PassManager.init(allocator);
    errdefer pm.deinit();
    try pm.addPass(createDeadStoreEliminationPass());
    try testing.expectEqual(PassResult.success, pm.run(module, ctx));
    return pm;
}

fn createReturn(ctx: *ir.Context, block: *ir.Block, operands: []const *ir.Value) !test_dialect.TestDialect.ReturnOp {
    const op = try test_dialect.TestDialect.ReturnOp.create(ctx, ir.Location.getUnknown(), operands);
    try block.addOperation(op.op);
    return op;
}

fn createResultOp(ctx: *ir.Context, block: *ir.Block, name: []const u8, result_type: ir.Type) !*ir.Operation {
    var builder = ir.OperationBuilder.init(ctx);
    var state = ir.Operation.State.init(name, ir.Location.getUnknown());
    state.addTypes(&.{result_type});
    const op = try builder.create(state);
    try block.addOperation(op);
    return op;
}

fn createOperandResultOp(
    ctx: *ir.Context,
    block: *ir.Block,
    name: []const u8,
    operand: *ir.Value,
    result_type: ir.Type,
) !*ir.Operation {
    var builder = ir.OperationBuilder.init(ctx);
    var state = ir.Operation.State.init(name, ir.Location.getUnknown());
    state.addOperands(&.{operand});
    state.addTypes(&.{result_type});
    const op = try builder.create(state);
    try block.addOperation(op);
    return op;
}

fn foldFalseForConstantFolding(
    op_ptr: *const anyopaque,
    results: *ir.interfaces.FoldResults,
) anyerror!void {
    const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
    const attr = try arith.getBoolAttr(op.getContext(), false);
    try results.append(.{ .attribute = attr });
}

test "Choir optimization passes register for textual pipelines" {
    const allocator = testing.allocator;

    var registry = registry_mod.PassRegistry.init(allocator);
    defer registry.deinit();
    try registerOptimizationPassEntries(&registry);

    try testing.expectEqual(
        @as(usize, optimization_pass_registrations.len),
        registry.passes.items.len,
    );
    inline for (optimization_pass_registrations) |registration| {
        try testing.expect(registry.lookupPass(registration.name) != null);
    }
    try testing.expect(registry.lookupPipeline(default_optimization_pipeline_name) != null);

    var manager = pass_mod.PassManager.init(allocator);
    defer manager.deinit();
    try textual_pipeline.parsePassPipeline(
        &registry,
        canonicalization.canonicalization_pass_name ++ "," ++ common_subexpression_elimination_pass_name,
        &manager,
    );

    try testing.expectEqual(@as(usize, 2), manager.root.pipeline.items.len);

    const text = try textual_pipeline.formatPassManagerPipelineAlloc(allocator, &manager);
    defer allocator.free(text);
    try testing.expectEqualStrings(
        canonicalization.canonicalization_pass_name ++ "," ++ common_subexpression_elimination_pass_name,
        text,
    );
}

test "Choir cleanup pipeline materializes from textual registry" {
    const allocator = testing.allocator;

    var registry = registry_mod.PassRegistry.init(allocator);
    defer registry.deinit();
    try registerOptimizationPassEntries(&registry);

    var manager = pass_mod.PassManager.init(allocator);
    defer manager.deinit();
    try textual_pipeline.parsePassPipeline(&registry, default_optimization_pipeline_name, &manager);

    try testing.expectEqual(@as(usize, 11), manager.root.pipeline.items.len);

    const text = try textual_pipeline.formatPassManagerPipelineAlloc(allocator, &manager);
    defer allocator.free(text);
    try testing.expectEqualStrings(
        promotion.memory_promotion_pass_name ++ "," ++
            canonicalization.canonicalization_pass_name ++ "," ++
            constant_folding_pass_name ++ "," ++
            sparse_conditional_constant_propagation_pass_name ++ "," ++
            canonicalization.canonicalization_pass_name ++ "," ++
            common_subexpression_elimination_pass_name ++ "," ++
            load_store_forwarding_pass_name ++ "," ++
            dead_store_elimination_pass_name ++ "," ++
            loop_invariant_code_motion_pass_name ++ "," ++
            common_subexpression_elimination_pass_name ++ "," ++
            dead_code_elimination_pass_name,
        text,
    );
}

test "addDefaultOptimizationPipeline uses Choir cleanup registration" {
    const allocator = testing.allocator;

    var manager = pass_mod.PassManager.init(allocator);
    defer manager.deinit();
    try addDefaultOptimizationPipeline(&manager);

    try testing.expectEqual(@as(usize, 11), manager.root.pipeline.items.len);

    const text = try textual_pipeline.formatPassManagerPipelineAlloc(allocator, &manager);
    defer allocator.free(text);
    try testing.expectEqualStrings(
        promotion.memory_promotion_pass_name ++ "," ++
            canonicalization.canonicalization_pass_name ++ "," ++
            constant_folding_pass_name ++ "," ++
            sparse_conditional_constant_propagation_pass_name ++ "," ++
            canonicalization.canonicalization_pass_name ++ "," ++
            common_subexpression_elimination_pass_name ++ "," ++
            load_store_forwarding_pass_name ++ "," ++
            dead_store_elimination_pass_name ++ "," ++
            loop_invariant_code_motion_pass_name ++ "," ++
            common_subexpression_elimination_pass_name ++ "," ++
            dead_code_elimination_pass_name,
        text,
    );
}

test "Choir cleanup skips unchanged second CSE" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var manager = pass_mod.PassManager.init(allocator);
    defer manager.deinit();
    try addDefaultOptimizationPipeline(&manager);
    try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));

    try testing.expectEqual(@as(u64, 10), manager.stats.pass_runs);
    try testing.expectEqual(@as(u64, 1), manager.stats.passes_skipped);
}

test "Choir cleanup pipeline CSEs values exposed by LICM" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    _ = try ctx.registerOperation("test.loop_pure", .{});
    try ctx.registerOperationInterface(
        "test.loop_write",
        ir.interfaces.EffectOpInterface.entryFor(.{}),
    );

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const outer_block = module.getBodyBlock();
    const index_type = try arith.getIndexType(&ctx);

    const first = (try arith.ConstantOp.createInt(&ctx, loc, index_type, 42)).op;
    try outer_block.addOperation(first);
    try observeValues(&ctx, outer_block, &.{first.getResult(0).?});

    var lower = try arith.ConstantOp.createInt(&ctx, loc, index_type, 0);
    var upper = try arith.ConstantOp.createInt(&ctx, loc, index_type, 4);
    var step = try arith.ConstantOp.createInt(&ctx, loc, index_type, 1);
    try outer_block.addOperation(lower.op);
    try outer_block.addOperation(upper.op);
    try outer_block.addOperation(step.op);

    var for_op = try scf.ForOp.create(&ctx, loc, lower.getResult(), upper.getResult(), step.getResult(), &.{}, &.{});
    try outer_block.addOperation(for_op.op);

    const body_block = for_op.getBodyBlock();
    const inner_pure = (try arith.ConstantOp.createInt(&ctx, loc, index_type, 42)).op;
    try body_block.addOperation(inner_pure);
    var write_state = ir.Operation.State.init("test.loop_write", loc);
    write_state.addOperands(&.{inner_pure.getResult(0).?});
    var builder = ir.OperationBuilder.init(&ctx);
    const write = try builder.create(write_state);
    try body_block.addOperation(write);
    const yield = try scf.YieldOp.create(&ctx, loc, &.{});
    try body_block.addOperation(yield.op);

    var manager = pass_mod.PassManager.init(allocator);
    defer manager.deinit();
    try addDefaultOptimizationPipeline(&manager);
    try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));

    try testing.expect(write.getOperand(0).? == first.getResult(0).?);
    const survivor_any = write.getOperand(0).?.getDefiningOp() orelse return error.ExpectedCseSurvivor;
    const survivor: *ir.Operation = @ptrCast(@alignCast(survivor_any));
    try testing.expectEqualStrings("arith.constant", survivor.name.name);
    try testing.expect(survivor.parent_block == outer_block);
    try testing.expectEqual(@as(u64, 11), manager.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), manager.stats.passes_skipped);
}

test "F10a retains unqualified registered attribute folds" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    _ = try ctx.registerOperation("test.fold_false", .{});
    try ctx.registerOperationInterface(
        "test.fold_false",
        ir.interfaces.FoldOpInterface.entryFor(foldFalseForConstantFolding),
    );

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const bool_type = try arith.getScalarType(&ctx, .bool);

    const folded = try createResultOp(&ctx, block, "test.fold_false", bool_type);
    _ = try createReturn(&ctx, block, &.{folded.getResult(0).?});

    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    var pm = try runConstantFoldingPass(allocator, module.op, &ctx);
    defer pm.deinit();
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "Precision1 Choir cleanup pipeline simplifies computed constant scf.if" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    var one = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    try block.addOperation(one.op);

    var cmp = try arith.CmpOp.create(&ctx, loc, .eq, one.getResult(), one.getResult());
    try block.addOperation(cmp.op);

    const if_op = try scf.IfOp.createWithoutElse(&ctx, loc, cmp.getResult());
    try block.addOperation(if_op.op);

    var manager = pass_mod.PassManager.init(allocator);
    defer manager.deinit();
    try addDefaultOptimizationPipeline(&manager);
    try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));

    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.op, scf.IfOp.operation_name));
}

test "F10a retains unqualified generic unused operations during DCE" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);
    _ = try ctx.registerOperation("test.dead", .{});
    try ctx.registerOperationInterface(
        "test.read_value",
        ir.interfaces.EffectOpInterface.entryFor(.{}),
    );
    try ctx.registerOperationInterface(
        "test.write_value",
        ir.interfaces.EffectOpInterface.entryFor(.{}),
    );

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    const f32_type = try arith.getScalarType(&ctx, .f32);
    const index_type = try arith.getIndexType(&ctx);
    const memref_type = try memref.getMemrefType1D(&ctx, 16, f32_type, .host);
    const memref_arg = try block.addArgument(memref_type, loc);
    const index_arg = try block.addArgument(index_type, loc);

    _ = try createResultOp(&ctx, block, "test.dead", i32_type);
    _ = try createResultOp(&ctx, block, "test.read_value", i32_type);
    _ = try createResultOp(&ctx, block, "test.write_value", i32_type);
    const load = try memref.LoadOp.create(&ctx, loc, memref_arg, index_arg, f32_type);
    try block.addOperation(load.op);

    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    var pm = try runDcePass(allocator, module.op, &ctx);
    defer pm.deinit();
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "F10a retains unqualified unused read declarations during DCE" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);
    try ctx.registerOperationInterface(
        "test.read_operand_value",
        ir.interfaces.EffectOpInterface.entryFor(.{}),
    );

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    const input = try block.addArgument(i32_type, loc);

    _ = try createOperandResultOp(&ctx, block, "test.read_operand_value", input, i32_type);

    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    var pm = try runDcePass(allocator, module.op, &ctx);
    defer pm.deinit();
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "choir-sccp propagates constants through computed scf.if condition" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    var one = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    var two = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 2);
    try block.addOperation(one.op);
    try block.addOperation(two.op);

    var cmp = try arith.CmpOp.create(&ctx, loc, .eq, one.getResult(), one.getResult());
    try block.addOperation(cmp.op);

    var if_op = try scf.IfOp.create(&ctx, loc, cmp.getResult(), &.{i32_type});
    try block.addOperation(if_op.op);

    const then_block = if_op.getThenBlock();
    var sum = try arith.AddOp.create(&ctx, loc, one.getResult(), two.getResult());
    try then_block.addOperation(sum.op);
    const then_yield = try scf.YieldOp.create(&ctx, loc, &.{sum.getResult()});
    try then_block.addOperation(then_yield.op);

    const else_block = if_op.getElseBlock().?;
    const else_yield = try scf.YieldOp.create(&ctx, loc, &.{two.getResult()});
    try else_block.addOperation(else_yield.op);

    const ret = try createReturn(&ctx, block, &.{if_op.getResult(0).?});

    var pm = try runSccpPass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(ConstValue{ .int = 3 }, constantFromValue(ret.op.getOperand(0).?).?);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
}

test "choir-sccp propagates through materialized SSA replacements" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    var one = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    var two = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 2);
    try block.addOperation(one.op);
    try block.addOperation(two.op);

    var sum = try arith.AddOp.create(&ctx, loc, one.getResult(), two.getResult());
    try block.addOperation(sum.op);
    var product = try arith.AddOp.create(&ctx, loc, sum.getResult(), two.getResult());
    try block.addOperation(product.op);
    const ret = try createReturn(&ctx, block, &.{product.getResult()});

    var pm = try runSccpPass(allocator, module.op, &ctx);
    defer pm.deinit();

    const propagated = constantFromValue(ret.op.getOperand(0).?) orelse return error.ExpectedConstant;
    try testing.expectEqual(@as(i64, 5), constInt(propagated).?);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
}

test "choir-sccp propagates common constants from unknown scf.if branches" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const bool_type = try arith.getScalarType(&ctx, .bool);
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const cond = try block.addArgument(bool_type, loc);

    var zero = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 0);
    var seven = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 7);
    try block.addOperation(zero.op);
    try block.addOperation(seven.op);

    var if_op = try scf.IfOp.create(&ctx, loc, cond, &.{i32_type});
    try block.addOperation(if_op.op);

    var then_sum = try arith.AddOp.create(&ctx, loc, seven.getResult(), zero.getResult());
    try if_op.getThenBlock().addOperation(then_sum.op);
    const then_yield = try scf.YieldOp.create(&ctx, loc, &.{then_sum.getResult()});
    try if_op.getThenBlock().addOperation(then_yield.op);

    var else_sum = try arith.AddOp.create(&ctx, loc, zero.getResult(), seven.getResult());
    try if_op.getElseBlock().?.addOperation(else_sum.op);
    const else_yield = try scf.YieldOp.create(&ctx, loc, &.{else_sum.getResult()});
    try if_op.getElseBlock().?.addOperation(else_yield.op);

    const ret = try createReturn(&ctx, block, &.{if_op.getResult(0).?});

    var pm = try runSccpPass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expect(ret.op.getOperand(0).? == if_op.getResult(0).?);
    try testing.expect(constantFromValue(then_yield.op.getOperand(0).?) != null);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
}

test "choir-sccp no-op path uses no pass allocator" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const module = try test_dialect.TestDialect.ModuleOp.create(
        &ctx,
        ir.Location.getUnknown(),
    );

    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var analysis_cache = pass_mod.AnalysisCache.init(failing.allocator(), null);
    defer analysis_cache.deinit();
    var pass_ctx = PassContext.init(
        module.op,
        &ctx,
        failing.allocator(),
        &analysis_cache,
    );
    defer pass_ctx.deinit();

    try testing.expectEqual(
        PassResult.success,
        createSparseConditionalConstantPropagationPass().run(&pass_ctx),
    );
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "choir-sccp enforces its operation nesting boundary" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var root_state = ir.Operation.State.init(
        "test.sccp_depth_root",
        ir.Location.getUnknown(),
    );
    root_state.addRegion();
    const root = try ctx.createOperation(root_state);
    var current = root;
    for (1..maximum_sccp_operation_depth) |_| {
        var child_state = ir.Operation.State.init(
            "test.sccp_depth_child",
            ir.Location.getUnknown(),
        );
        child_state.addRegion();
        const child = try ctx.createOperation(child_state);
        const block = try current.getRegion(0).?.addBlock();
        try block.addOperation(child);
        current = child;
    }

    var manager = pass_mod.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createSparseConditionalConstantPropagationPass());
    try testing.expectEqual(PassResult.success, manager.run(root, &ctx));

    var one_past_state = ir.Operation.State.init(
        "test.sccp_depth_one_past",
        ir.Location.getUnknown(),
    );
    one_past_state.addRegion();
    const one_past = try ctx.createOperation(one_past_state);
    const block = try current.getRegion(0).?.addBlock();
    try block.addOperation(one_past);
    try testing.expectEqual(PassResult.failure, manager.run(root, &ctx));
}

test "choir-licm hoists dependent qualified operations by ancestry" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);
    _ = try ctx.registerOperation("test.loop_pure", .{});
    try ctx.registerOperationInterface(
        "test.loop_write",
        ir.interfaces.EffectOpInterface.entryFor(.{}),
    );

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const outer_block = module.getBodyBlock();
    const index_type = try arith.getScalarType(&ctx, .i64);

    var lower = try arith.ConstantOp.createInt(&ctx, loc, index_type, 0);
    var upper = try arith.ConstantOp.createInt(&ctx, loc, index_type, 4);
    var step = try arith.ConstantOp.createInt(&ctx, loc, index_type, 1);
    try outer_block.addOperation(lower.op);
    try outer_block.addOperation(upper.op);
    try outer_block.addOperation(step.op);

    var for_op = try scf.ForOp.create(&ctx, loc, lower.getResult(), upper.getResult(), step.getResult(), &.{}, &.{});
    try outer_block.addOperation(for_op.op);

    const body_block = for_op.getBodyBlock();
    const pure = (try arith.ConstantOp.createInt(&ctx, loc, index_type, 42)).op;
    try body_block.addOperation(pure);
    const dependent = (try arith.AddOp.create(&ctx, loc, pure.getResult(0).?, step.getResult())).op;
    try body_block.addOperation(dependent);
    var write_state = ir.Operation.State.init("test.loop_write", loc);
    write_state.addOperands(&.{dependent.getResult(0).?});
    write_state.addTypes(&.{index_type});
    var builder = ir.OperationBuilder.init(&ctx);
    const write = try builder.create(write_state);
    try body_block.addOperation(write);
    const yield = try scf.YieldOp.create(&ctx, loc, &.{});
    try body_block.addOperation(yield.op);

    try testing.expectEqual(@as(usize, 1), pure.getResult(0).?.getNumUses());

    var pm = try runLicmPass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expect(pure.parent_block == outer_block);
    try testing.expect(pure.prev_op == step.op);
    try testing.expect(pure.next_op == dependent);
    try testing.expect(dependent.parent_block == outer_block);
    try testing.expect(dependent.prev_op == pure);
    try testing.expect(dependent.next_op == for_op.op);
    try testing.expect(for_op.op.prev_op == dependent);
    try testing.expect(write.parent_block == body_block);
    try testing.expectEqual(@as(usize, 1), pure.getResult(0).?.getNumUses());
    try testing.expectEqual(@as(usize, 1), dependent.getResult(0).?.getNumUses());
    try testing.expect(write.getOperand(0).? == dependent.getResult(0).?);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
}

test "choir-licm hoists nested-loop invariants to the outermost invariant block" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);
    try ctx.registerOperationInterface(
        "test.loop_write",
        ir.interfaces.EffectOpInterface.entryFor(.{}),
    );

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const outer_block = module.getBodyBlock();
    const index_type = try arith.getScalarType(&ctx, .i64);

    var lower = try arith.ConstantOp.createInt(&ctx, loc, index_type, 0);
    var upper = try arith.ConstantOp.createInt(&ctx, loc, index_type, 4);
    var step = try arith.ConstantOp.createInt(&ctx, loc, index_type, 1);
    try outer_block.addOperation(lower.op);
    try outer_block.addOperation(upper.op);
    try outer_block.addOperation(step.op);

    var outer_for = try scf.ForOp.create(&ctx, loc, lower.getResult(), upper.getResult(), step.getResult(), &.{}, &.{});
    try outer_block.addOperation(outer_for.op);
    const outer_body = outer_for.getBodyBlock();
    const outer_iv = outer_body.arguments.items[0];

    var middle_for = try scf.ForOp.create(&ctx, loc, lower.getResult(), upper.getResult(), step.getResult(), &.{}, &.{});
    try outer_body.addOperation(middle_for.op);
    const middle_body = middle_for.getBodyBlock();
    const outer_yield = try scf.YieldOp.create(&ctx, loc, &.{});
    try outer_body.addOperation(outer_yield.op);

    var inner_for = try scf.ForOp.create(&ctx, loc, lower.getResult(), upper.getResult(), step.getResult(), &.{}, &.{});
    try middle_body.addOperation(inner_for.op);
    const inner_body = inner_for.getBodyBlock();
    const middle_yield = try scf.YieldOp.create(&ctx, loc, &.{});
    try middle_body.addOperation(middle_yield.op);

    var invariant = try arith.AddOp.create(&ctx, loc, outer_iv, upper.getResult());
    try inner_body.addOperation(invariant.op);
    var write_state = ir.Operation.State.init("test.loop_write", loc);
    write_state.addOperands(&.{invariant.getResult()});
    write_state.addTypes(&.{index_type});
    var builder = ir.OperationBuilder.init(&ctx);
    const write = try builder.create(write_state);
    try inner_body.addOperation(write);
    const inner_yield = try scf.YieldOp.create(&ctx, loc, &.{});
    try inner_body.addOperation(inner_yield.op);

    var pm = try runLicmPass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expect(invariant.op.parent_block == outer_body);
    try testing.expect(invariant.op.next_op == middle_for.op);
    try testing.expect(write.parent_block == inner_body);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
}

test "F10a retains unqualified memory accesses across ordinary operations" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);
    _ = try ctx.registerOperation("test.noop", .{});

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const f32_type = try arith.getScalarType(&ctx, .f32);
    const index_type = try arith.getIndexType(&ctx);
    const memref_type = try memref.getMemrefType1D(&ctx, 16, f32_type, .host);
    const memref_arg = try block.addArgument(memref_type, loc);
    const index_arg = try block.addArgument(index_type, loc);
    const value_arg = try block.addArgument(f32_type, loc);

    const store = try memref.StoreOp.create(&ctx, loc, value_arg, memref_arg, index_arg);
    try block.addOperation(store.op);
    _ = try createResultOp(&ctx, block, "test.noop", index_type);
    const load = try memref.LoadOp.create(&ctx, loc, memref_arg, index_arg, f32_type);
    try block.addOperation(load.op);
    _ = try createReturn(&ctx, block, &.{load.getResult()});

    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    var pm = try runLoadStoreForwardingPass(allocator, module.op, &ctx);
    defer pm.deinit();
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "choir-load-store-forward stops at generic write effects" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);
    try ctx.registerOperationInterface(
        "test.write_barrier",
        ir.interfaces.EffectOpInterface.entryFor(.{}),
    );

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const f32_type = try arith.getScalarType(&ctx, .f32);
    const index_type = try arith.getIndexType(&ctx);
    const memref_type = try memref.getMemrefType1D(&ctx, 16, f32_type, .host);
    const memref_arg = try block.addArgument(memref_type, loc);
    const index_arg = try block.addArgument(index_type, loc);
    const value_arg = try block.addArgument(f32_type, loc);

    const store = try memref.StoreOp.create(&ctx, loc, value_arg, memref_arg, index_arg);
    try block.addOperation(store.op);
    _ = try createResultOp(&ctx, block, "test.write_barrier", index_type);
    const load = try memref.LoadOp.create(&ctx, loc, memref_arg, index_arg, f32_type);
    try block.addOperation(load.op);
    const ret = try createReturn(&ctx, block, &.{load.getResult()});

    var pm = try runLoadStoreForwardingPass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.op, memref.LoadOp.operation_name));
    try testing.expect(ret.op.getOperand(0).? == load.getResult());
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "F10a retains unqualified memory accesses with independent indexes" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const f32_type = try arith.getScalarType(&ctx, .f32);
    const index_type = try arith.getIndexType(&ctx);
    const memref_type = try memref.getMemrefType1D(&ctx, 16, f32_type, .host);
    _ = try block.addArgument(memref_type, loc);
    _ = try block.addArgument(index_type, loc);
    _ = try block.addArgument(index_type, loc);
    _ = try block.addArgument(f32_type, loc);
    _ = try block.addArgument(f32_type, loc);
    const memref_arg = block.getArgument(0).?;
    const first_index = block.getArgument(1).?;
    const second_index = block.getArgument(2).?;
    const first_value = block.getArgument(3).?;
    const second_value = block.getArgument(4).?;

    const first_store = try memref.StoreOp.create(&ctx, loc, first_value, memref_arg, first_index);
    try block.addOperation(first_store.op);
    const second_store = try memref.StoreOp.create(&ctx, loc, second_value, memref_arg, second_index);
    try block.addOperation(second_store.op);
    const load = try memref.LoadOp.create(&ctx, loc, memref_arg, first_index, f32_type);
    try block.addOperation(load.op);
    _ = try createReturn(&ctx, block, &.{load.getResult()});

    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    var pm = try runLoadStoreForwardingPass(allocator, module.op, &ctx);
    defer pm.deinit();
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "F10a retains unqualified overwritten block-local stores" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const f32_type = try arith.getScalarType(&ctx, .f32);
    const index_type = try arith.getIndexType(&ctx);
    const memref_type = try memref.getMemrefType1D(&ctx, 16, f32_type, .host);
    _ = try block.addArgument(memref_type, loc);
    _ = try block.addArgument(index_type, loc);
    _ = try block.addArgument(f32_type, loc);
    _ = try block.addArgument(f32_type, loc);
    const memref_arg = block.getArgument(0).?;
    const index_arg = block.getArgument(1).?;
    const first_value = block.getArgument(2).?;
    const second_value = block.getArgument(3).?;

    const first_store = try memref.StoreOp.create(&ctx, loc, first_value, memref_arg, index_arg);
    try block.addOperation(first_store.op);
    const second_store = try memref.StoreOp.create(&ctx, loc, second_value, memref_arg, index_arg);
    try block.addOperation(second_store.op);
    const load = try memref.LoadOp.create(&ctx, loc, memref_arg, index_arg, f32_type);
    try block.addOperation(load.op);
    _ = try createReturn(&ctx, block, &.{load.getResult()});

    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    var pm = try runDeadStoreEliminationPass(allocator, module.op, &ctx);
    defer pm.deinit();
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "choir-dse preserves stores observed before overwrite" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const f32_type = try arith.getScalarType(&ctx, .f32);
    const index_type = try arith.getIndexType(&ctx);
    const memref_type = try memref.getMemrefType1D(&ctx, 16, f32_type, .host);
    _ = try block.addArgument(memref_type, loc);
    _ = try block.addArgument(index_type, loc);
    _ = try block.addArgument(f32_type, loc);
    _ = try block.addArgument(f32_type, loc);
    const memref_arg = block.getArgument(0).?;
    const index_arg = block.getArgument(1).?;
    const first_value = block.getArgument(2).?;
    const second_value = block.getArgument(3).?;

    const first_store = try memref.StoreOp.create(&ctx, loc, first_value, memref_arg, index_arg);
    try block.addOperation(first_store.op);
    const load = try memref.LoadOp.create(&ctx, loc, memref_arg, index_arg, f32_type);
    try block.addOperation(load.op);
    const second_store = try memref.StoreOp.create(&ctx, loc, second_value, memref_arg, index_arg);
    try block.addOperation(second_store.op);
    _ = try createReturn(&ctx, block, &.{load.getResult()});

    var pm = try runDeadStoreEliminationPass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(@as(usize, 2), ir.inspection.countOperationsNamed(module.op, memref.StoreOp.operation_name));
    try testing.expect(first_store.op.parent_block != null);
    try testing.expect(second_store.op.parent_block != null);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "choir-dse keeps stores to distinct indexes" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try dialects.registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const f32_type = try arith.getScalarType(&ctx, .f32);
    const index_type = try arith.getIndexType(&ctx);
    const memref_type = try memref.getMemrefType1D(&ctx, 16, f32_type, .host);
    _ = try block.addArgument(memref_type, loc);
    _ = try block.addArgument(index_type, loc);
    _ = try block.addArgument(index_type, loc);
    _ = try block.addArgument(f32_type, loc);
    _ = try block.addArgument(f32_type, loc);
    const memref_arg = block.getArgument(0).?;
    const first_index = block.getArgument(1).?;
    const second_index = block.getArgument(2).?;
    const first_value = block.getArgument(3).?;
    const second_value = block.getArgument(4).?;

    const first_store = try memref.StoreOp.create(&ctx, loc, first_value, memref_arg, first_index);
    try block.addOperation(first_store.op);
    const second_store = try memref.StoreOp.create(&ctx, loc, second_value, memref_arg, second_index);
    try block.addOperation(second_store.op);
    const load = try memref.LoadOp.create(&ctx, loc, memref_arg, first_index, f32_type);
    try block.addOperation(load.op);
    _ = try createReturn(&ctx, block, &.{load.getResult()});

    var pm = try runDeadStoreEliminationPass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(@as(usize, 2), ir.inspection.countOperationsNamed(module.op, memref.StoreOp.operation_name));
    try testing.expect(first_store.op.parent_block != null);
    try testing.expect(second_store.op.parent_block != null);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

fn runEqualitySaturationPass(
    allocator: std.mem.Allocator,
    module: *ir.Operation,
    ctx: *ir.Context,
) !pass_mod.PassManager {
    var pm = pass_mod.PassManager.init(allocator);
    errdefer pm.deinit();
    try pm.addPass(createEqualitySaturationPass());
    try testing.expectEqual(PassResult.success, pm.run(module, ctx));
    return pm;
}

test "Precision1 choir-eqsat-arith strength-reduces multiplication by power of two" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const i32_type = try arith.getI32Type(&ctx);
    _ = try block.addArgument(i32_type, loc);
    const source = block.getArgument(0).?;

    var two = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 2);
    try block.addOperation(two.op);
    var product = try arith.MulOp.create(&ctx, loc, source, two.getResult());
    try block.addOperation(product.op);
    const ret = try createReturn(&ctx, block, &.{product.getResult()});

    var pm = try runEqualitySaturationPass(allocator, module.op, &ctx);
    defer pm.deinit();

    const replacement = ret.op.getOperand(0).?;
    const def_any = replacement.getDefiningOp() orelse return error.TestExpectedResult;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    try testing.expectEqualStrings(arith.ShlOp.operation_name, def_op.name.name);
    try testing.expect(def_op.getOperand(0).? == source);
    try testing.expectEqual(ConstValue{ .int = 1 }, constantFromValue(def_op.getOperand(1).?).?);
    try ir.verifyOperation(module.op, ir.verify.default_options);
}

test "Precision1 choir-eqsat-arith cancels self subtraction to a materialized zero" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const i32_type = try arith.getI32Type(&ctx);
    _ = try block.addArgument(i32_type, loc);
    const source = block.getArgument(0).?;

    var difference = try arith.SubOp.create(&ctx, loc, source, source);
    try block.addOperation(difference.op);
    const ret = try createReturn(&ctx, block, &.{difference.getResult()});

    var pm = try runEqualitySaturationPass(allocator, module.op, &ctx);
    defer pm.deinit();

    const replacement = ret.op.getOperand(0).?;
    try testing.expectEqual(ConstValue{ .int = 0 }, constantFromValue(replacement).?);
    try ir.verifyOperation(module.op, ir.verify.default_options);
}

test "choir-eqsat-arith leaves float addition with positive zero intact" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const f32_type = try arith.getScalarType(&ctx, .f32);
    _ = try block.addArgument(f32_type, loc);
    const source = block.getArgument(0).?;

    var zero = try arith.ConstantOp.createFloat(&ctx, loc, f32_type, 0.0);
    try block.addOperation(zero.op);
    var total = try arith.AddOp.create(&ctx, loc, source, zero.getResult());
    try block.addOperation(total.op);
    const ret = try createReturn(&ctx, block, &.{total.getResult()});

    var pm = try runEqualitySaturationPass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expect(ret.op.getOperand(0).? == total.getResult());
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

const EffectObservation = struct {
    const Event = struct {
        kind: enum {
            output,
            draw,
            retain,
            borrow,
            move,
            release,
            destroy,
            allocate,
            write,
            synchronize,
        },
        value: i64,
    };
    const ValueBinding = struct { value: *ir.Value, number: i64 };
    const Failure = enum { none, divide_by_zero, signed_overflow, bounds, lifetime, capacity };
    bindings: [256]ValueBinding = undefined,
    binding_count: usize = 0,
    events: [128]Event = undefined,
    event_count: usize = 0,
    failure: Failure = .none,
    fuel: usize = 4096,
    draws: i64 = 0,
    global_draws: i64 = 0,
    addressed_draws: [16]i64 = @splat(0),
    allocations: usize = 0,
    capacity: usize = 16,
    references: [16]usize = @splat(0),
    memory: [16][4]i64 = @splat(@splat(0)),

    fn observe(root: *ir.Operation, capacity: usize) !EffectObservation {
        var self = EffectObservation{ .capacity = capacity };
        try self.operation(root, 0);
        return self;
    }

    fn expectEqual(self: *const EffectObservation, after: *const EffectObservation) !void {
        try testing.expectEqual(self.failure, after.failure);
        try testing.expectEqualSlices(
            Event,
            self.events[0..self.event_count],
            after.events[0..after.event_count],
        );
    }

    /// How many events of one kind this run saw.
    fn countEvents(self: *const EffectObservation, kind: @FieldType(Event, "kind")) usize {
        var count: usize = 0;
        for (self.events[0..self.event_count]) |seen| {
            if (seen.kind == kind) count += 1;
        }
        return count;
    }

    /// Compares what the two runs handed out, which is what a caller sees.
    ///
    /// A promotion that is permitted removes writes nobody could observe, so
    /// the event sequences differ by exactly those writes while the outputs
    /// and the failure do not move. Those are compared here, and the writes
    /// are counted by the caller that knows how many it expects to lose.
    fn expectSameOutputs(self: *const EffectObservation, after: *const EffectObservation) !void {
        try testing.expectEqual(self.failure, after.failure);
        var mine: [128]i64 = undefined;
        var theirs: [128]i64 = undefined;
        var mine_count: usize = 0;
        var theirs_count: usize = 0;
        for (self.events[0..self.event_count]) |seen| {
            if (seen.kind != .output) continue;
            mine[mine_count] = seen.value;
            mine_count += 1;
        }
        for (after.events[0..after.event_count]) |seen| {
            if (seen.kind != .output) continue;
            theirs[theirs_count] = seen.value;
            theirs_count += 1;
        }
        try testing.expectEqualSlices(i64, mine[0..mine_count], theirs[0..theirs_count]);
    }

    fn bind(self: *EffectObservation, value: *ir.Value, number: i64) !void {
        for (self.bindings[0..self.binding_count]) |*binding| {
            if (binding.value == value) {
                binding.number = number;
                return;
            }
        }
        if (self.binding_count == self.bindings.len) return error.WitnessValueLimit;
        self.bindings[self.binding_count] = .{ .value = value, .number = number };
        self.binding_count += 1;
    }

    fn valueOf(self: *const EffectObservation, value: *ir.Value) !i64 {
        for (self.bindings[0..self.binding_count]) |binding| {
            if (binding.value == value) return binding.number;
        }
        return error.WitnessUndefinedValue;
    }

    fn event(self: *EffectObservation, kind: @FieldType(Event, "kind"), value: i64) !void {
        if (self.event_count == self.events.len) return error.WitnessEventLimit;
        self.events[self.event_count] = .{ .kind = kind, .value = value };
        self.event_count += 1;
    }

    fn block(self: *EffectObservation, body: *ir.Block, depth: usize) anyerror!void {
        if (depth == 32) return error.WitnessDepthLimit;
        var operations = body.getOperations();
        while (operations.next()) |op| {
            if (self.failure != .none) return;
            try self.operation(op, depth + 1);
        }
    }

    fn operation(self: *EffectObservation, op: *ir.Operation, depth: usize) anyerror!void {
        if (self.fuel == 0) return error.WitnessExecutionLimit;
        self.fuel -= 1;
        const name = op.name.name;
        if (std.mem.eql(
            u8,
            name,
            "test.module",
        ) or std.mem.eql(u8, name, "func.func")) return self.block(
            op.getRegion(0).?.getEntryBlock().?,
            depth,
        );
        if (std.mem.eql(u8, name, "scf.yield")) return;
        if (std.mem.eql(u8, name, "scf.for")) return self.loop(op, depth);
        if (std.mem.eql(u8, name, "scf.if")) {
            const selected: usize = if (try self.valueOf(op.getOperand(0).?) != 0) 0 else 1;
            if (op.getRegion(selected)) |region| try self.block(region.getEntryBlock().?, depth);
            return;
        }
        if (std.mem.eql(u8, name, "test.observe") or std.mem.eql(u8, name, "func.return")) {
            for (op.operands.items) |operand| try self.event(
                .output,
                try self.valueOf(operand.value),
            );
            return;
        }
        if (std.mem.eql(u8, name, "arith.constant")) {
            const value = if (op.getAttrAs(
                ir.Attribute.IntegerAttr,
                "value",
            )) |attr| attr.value else @as(
                i64,
                if (op.getAttrAs(ir.Attribute.BoolAttr, "value").?.value) 1 else 0,
            );
            return self.bind(op.getResult(0).?, value);
        }
        if (std.mem.eql(u8, name, "arith.add") or std.mem.eql(u8, name, "arith.div")) {
            return self.arithmetic(op);
        }
        if (std.mem.eql(u8, name, "arith.cmp")) {
            const lhs = try self.valueOf(op.getOperand(0).?);
            const rhs = try self.valueOf(op.getOperand(1).?);
            const predicate = (arith.CmpOp{ .op = op }).getPredicate();
            if (predicate != .ne) return error.WitnessUnsupportedComparison;
            return self.bind(op.getResult(0).?, if (lhs != rhs) 1 else 0);
        }
        return self.resourceOperation(op);
    }

    fn resourceOperation(self: *EffectObservation, op: *ir.Operation) !void {
        const name = op.name.name;
        if (std.mem.eql(u8, name, "test.draw") or std.mem.eql(u8, name, "test.addressed_draw")) {
            const address = if (op.getOperand(0)) |value| try self.valueOf(value) else 0;
            self.draws += 1;
            const index = std.math.cast(usize, address) orelse return error.WitnessResourceLimit;
            if (index >= self.addressed_draws.len) return error.WitnessResourceLimit;
            const counter = if (op.getNumOperands() == 0) counter: {
                break :counter &self.global_draws;
            } else &self.addressed_draws[index];
            counter.* +%= 1;
            const result = address *% 17 +% counter.*;
            try self.event(.draw, result);
            return self.bind(op.getResult(0).?, result);
        }
        if (std.mem.eql(u8, name, "test.safe_read")) return self.bind(op.getResult(0).?, 7);
        if (std.mem.eql(u8, name, "memref.load")) return self.checkedLoad(op);
        if (std.mem.eql(u8, name, "memref.store")) return self.checkedStore(op);
        if (std.mem.eql(u8, name, "memref.fence")) return self.event(.synchronize, 0);
        if (std.mem.eql(u8, name, "memref.dealloc")) {
            const identity = try self.valueOf(op.getOperand(0).?);
            const index = std.math.cast(usize, identity) orelse return error.WitnessResourceLimit;
            if (index >= self.references.len) return error.WitnessResourceLimit;
            if (self.references[index] == 0) {
                self.failure = .lifetime;
                return;
            }
            self.references[index] = 0;
            return self.event(.destroy, identity);
        }
        if (std.mem.startsWith(u8, name, "rc.")) return self.ownership(op);
        if (std.mem.eql(u8, name, "memref.alloc") or std.mem.eql(u8, name, "memref.alloca")) {
            if (self.allocations == self.capacity) {
                self.failure = .capacity;
                return;
            }
            if (self.allocations == self.references.len) return error.WitnessResourceLimit;
            const identity = self.allocations;
            self.allocations += 1;
            self.references[identity] = 1;
            try self.event(.allocate, @intCast(identity));
            return self.bind(op.getResult(0).?, @intCast(identity));
        }
        return error.WitnessUnsupportedOperation;
    }

    const Access = struct { resource: usize, index: usize };

    fn checkedAccess(
        self: *EffectObservation,
        op: *ir.Operation,
        base_index: usize,
        index_index: usize,
    ) !?Access {
        const base = op.getOperand(base_index).?;
        const identity = try self.valueOf(base);
        const resource = std.math.cast(usize, identity) orelse return error.WitnessResourceLimit;
        if (resource >= self.references.len) return error.WitnessResourceLimit;
        if (self.references[resource] == 0) {
            self.failure = .lifetime;
            return null;
        }
        const index = try self.valueOf(op.getOperand(index_index).?);
        const params = memref.parseMemrefParams(base.type.getDialectParamKey().?).?;
        const extent = params.size orelse return error.WitnessUnsupportedExtent;
        if (index < 0 or @as(u64, @intCast(index)) >= extent) {
            self.failure = .bounds;
            return null;
        }
        if (index >= 4) return error.WitnessResourceLimit;
        return .{ .resource = resource, .index = @intCast(index) };
    }

    fn checkedLoad(self: *EffectObservation, op: *ir.Operation) !void {
        const access = try self.checkedAccess(op, 0, 1) orelse return;
        try self.bind(op.getResult(0).?, self.memory[access.resource][access.index]);
    }

    fn checkedStore(self: *EffectObservation, op: *ir.Operation) !void {
        const access = try self.checkedAccess(op, 1, 2) orelse return;
        const value = try self.valueOf(op.getOperand(0).?);
        self.memory[access.resource][access.index] = value;
        try self.event(.write, value);
    }

    fn arithmetic(self: *EffectObservation, op: *ir.Operation) !void {
        const lhs = try self.valueOf(op.getOperand(0).?);
        const rhs = try self.valueOf(op.getOperand(1).?);
        if (std.mem.eql(u8, op.name.name, "arith.add")) {
            return self.bind(op.getResult(0).?, lhs +% rhs);
        }
        if (rhs == 0) {
            self.failure = .divide_by_zero;
            return;
        }
        if (lhs == std.math.minInt(i64) and rhs == -1) {
            self.failure = .signed_overflow;
            return;
        }
        try self.bind(op.getResult(0).?, @divTrunc(lhs, rhs));
    }

    fn loop(self: *EffectObservation, op: *ir.Operation, depth: usize) !void {
        const loop_op = scf.ForOp{ .op = op };
        var induction = try self.valueOf(loop_op.getLowerBound());
        const upper = try self.valueOf(loop_op.getUpperBound());
        const step = try self.valueOf(loop_op.getStep());
        if (step <= 0 or op.getNumResults() != 0) return error.WitnessUnsupportedLoop;
        while (induction < upper and self.failure == .none) : (induction += step) {
            if (self.fuel == 0) return error.WitnessExecutionLimit;
            self.fuel -= 1;
            try self.bind(loop_op.getBodyBlock().getArgument(0).?, induction);
            try self.block(loop_op.getBodyBlock(), depth);
        }
    }

    fn ownership(self: *EffectObservation, op: *ir.Operation) !void {
        const identity = try self.valueOf(op.getOperand(0).?);
        const index = std.math.cast(usize, identity) orelse return error.WitnessResourceLimit;
        if (index >= self.references.len) return error.WitnessResourceLimit;
        if (self.references[index] == 0) {
            self.failure = .lifetime;
            return;
        }
        const kind: @FieldType(Event, "kind") = if (std.mem.eql(u8, op.name.name, "rc.retain"))
            .retain
        else if (std.mem.eql(
            u8,
            op.name.name,
            "rc.release",
        )) .release else if (std.mem.eql(u8, op.name.name, "rc.borrow")) .borrow else .move;
        try self.event(kind, identity);
        if (kind == .retain) self.references[index] += 1;
        if (kind == .release) {
            self.references[index] -= 1;
            if (self.references[index] == 0) try self.event(.destroy, identity);
        }
        if (op.getResult(0)) |result| try self.bind(result, identity);
    }
};

fn registerObservation(ctx: *ir.Context) !void {
    try ctx.registerOperationInterface("test.observe", ir.interfaces.EffectOpInterface.entryFor(.{
        .complete = true,
        .facts = &.{.{ .event = .{ .kind = .io } }},
    }));
}

fn observeValues(ctx: *ir.Context, block: *ir.Block, values: []const *ir.Value) !void {
    var state = ir.Operation.State.init("test.observe", .unknown);
    state.addOperands(values);
    try block.addOperation(try ctx.createOperation(state));
}

fn witnessConstant(
    ctx: *ir.Context,
    block: *ir.Block,
    kind: dialects.arith.ScalarKind,
    n: i64,
) !*ir.Value {
    var constant = try arith.ConstantOp.createInt(
        ctx,
        .unknown,
        try arith.getScalarType(ctx, kind),
        n,
    );
    try block.addOperation(constant.op);
    return constant.getResult();
}

const LicmWitness = struct {
    trips: i64,
    numerator: i64 = 1,
    denominator: i64 = 0,
    add: bool = false,
    guarded: bool = false,
};

fn checkLicmWitness(case: LicmWitness) !void {
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const outer = module.getBodyBlock();
    const lower = try witnessConstant(&ctx, outer, .index, 0);
    const upper = try witnessConstant(&ctx, outer, .index, case.trips);
    const step = try witnessConstant(&ctx, outer, .index, 1);
    const lhs = try witnessConstant(&ctx, outer, .i64, case.numerator);
    const rhs = try witnessConstant(&ctx, outer, .i64, case.denominator);
    const loop = try scf.ForOp.create(&ctx, .unknown, lower, upper, step, &.{}, &.{});
    try outer.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const candidate = if (case.add) (try arith.AddOp.create(
        &ctx,
        .unknown,
        lhs,
        rhs,
    )).op else (try arith.DivOp.create(&ctx, .unknown, lhs, rhs)).op;
    if (case.guarded) try candidate.setAttr("body_nonzero_proof", try ctx.getBoolAttr(true));
    try body.addOperation(candidate);
    try observeValues(&ctx, body, &.{candidate.getResult(0).?});
    try body.addOperation((try scf.YieldOp.create(&ctx, .unknown, &.{})).op);
    const before = try EffectObservation.observe(module.op, 16);
    const before_ir = try ir.dump.operationAlloc(testing.allocator, module.op);
    defer testing.allocator.free(before_ir);
    var manager = try runLicmPass(testing.allocator, module.op, &ctx);
    defer manager.deinit();
    const after = try EffectObservation.observe(module.op, 16);
    try before.expectEqual(&after);
    const hoists = case.add or (case.denominator != 0 and
        !(case.numerator == std.math.minInt(i64) and case.denominator == -1));
    try testing.expect(candidate.getBlock() == if (hoists) outer else body);
    const after_ir = try ir.dump.operationAlloc(testing.allocator, module.op);
    defer testing.allocator.free(after_ir);
    if (!hoists) try testing.expectEqualStrings(before_ir, after_ir);
}

test "F10a LICM preserves skipped and executed division failures with total add control" {
    try checkLicmWitness(.{ .trips = 0 });
    try checkLicmWitness(.{ .trips = 2 });
    try checkLicmWitness(.{ .trips = 2, .numerator = std.math.minInt(i64), .denominator = -1 });
    try checkLicmWitness(.{ .trips = 0, .guarded = true });
    try checkLicmWitness(.{ .trips = 2, .denominator = 2 });
    try checkLicmWitness(.{ .trips = 0, .add = true });
    try checkLicmWitness(.{
        .trips = 2,
        .numerator = std.math.maxInt(i64),
        .denominator = 1,
        .add = true,
    });
}

test "F10a LICM retains branch-local proof and checks crossed observations" {
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const outer = module.getBodyBlock();
    const lower = try witnessConstant(&ctx, outer, .index, 0);
    const upper = try witnessConstant(&ctx, outer, .index, 2);
    const step = try witnessConstant(&ctx, outer, .index, 1);
    const numerator = try witnessConstant(&ctx, outer, .i64, 1);
    const denominator = try witnessConstant(&ctx, outer, .i64, 0);
    const zero = try witnessConstant(&ctx, outer, .i64, 0);
    var guard = try arith.CmpOp.create(&ctx, .unknown, .ne, denominator, zero);
    try outer.addOperation(guard.op);
    const loop = try scf.ForOp.create(&ctx, .unknown, lower, upper, step, &.{}, &.{});
    try outer.addOperation(loop.op);
    const body = loop.getBodyBlock();
    try observeValues(&ctx, body, &.{numerator});
    const add = try arith.AddOp.create(&ctx, .unknown, numerator, numerator);
    try body.addOperation(add.op);
    const branch = try scf.IfOp.create(&ctx, .unknown, guard.getResult(), &.{});
    try body.addOperation(branch.op);
    const div = try arith.DivOp.create(&ctx, .unknown, numerator, denominator);
    try div.op.setAttr("body_nonzero_proof", try ctx.getBoolAttr(true));
    try branch.getThenBlock().addOperation(div.op);
    try observeValues(&ctx, branch.getThenBlock(), &.{div.getResult()});
    try branch.getThenBlock().addOperation((try scf.YieldOp.create(&ctx, .unknown, &.{})).op);
    try branch.getElseBlock().?.addOperation((try scf.YieldOp.create(&ctx, .unknown, &.{})).op);
    try observeValues(&ctx, body, &.{add.getResult()});
    try body.addOperation((try scf.YieldOp.create(&ctx, .unknown, &.{})).op);
    const before = try EffectObservation.observe(module.op, 16);
    var manager = try runLicmPass(testing.allocator, module.op, &ctx);
    defer manager.deinit();
    const after = try EffectObservation.observe(module.op, 16);
    try before.expectEqual(&after);
    try testing.expectEqual(EffectObservation.Failure.none, after.failure);
    try testing.expect(div.op.getBlock() == branch.getThenBlock());
    try testing.expect(add.op.getBlock() == body);
}

fn checkDeadReadWitness(expired: bool) !void {
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const block = module.getBodyBlock();
    const ty = try arith.getScalarType(&ctx, .i64);
    const memory_type = try memref.getMemrefType1D(&ctx, 1, ty, .host);
    var allocation = try memref.AllocOp.createStatic(&ctx, .unknown, memory_type);
    try block.addOperation(allocation.op);
    const index = try witnessConstant(&ctx, block, .index, if (expired) 0 else 1);
    if (expired) {
        const free = try memref.DeallocOp.create(&ctx, .unknown, allocation.getResult());
        try block.addOperation(free.op);
    }
    const load = try memref.LoadOp.create(&ctx, .unknown, allocation.getResult(), index, ty);
    try block.addOperation(load.op);
    const before = try EffectObservation.observe(module.op, 16);
    var manager = try runDcePass(testing.allocator, module.op, &ctx);
    defer manager.deinit();
    const after = try EffectObservation.observe(module.op, 16);
    try before.expectEqual(&after);
    try testing.expectEqual(
        if (expired) EffectObservation.Failure.lifetime else .bounds,
        after.failure,
    );
    try testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(module.op, "memref.load"),
    );
}

test "F10a DCE retains checked read failures and discards a specified safe read" {
    try checkDeadReadWitness(false);
    try checkDeadReadWitness(true);
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const block = module.getBodyBlock();
    var state = ir.Operation.State.init(
        test_dialect.TestDialect.SafeReadOp.operation_name,
        .unknown,
    );
    state.addTypes(&.{try test_dialect.TestDialect.getI64Type(&ctx)});
    const safe = try ctx.createOperation(state);
    try block.addOperation(safe);
    const before = try EffectObservation.observe(module.op, 16);
    var manager = try runDcePass(testing.allocator, module.op, &ctx);
    defer manager.deinit();
    const after = try EffectObservation.observe(module.op, 16);
    try before.expectEqual(&after);
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(
            module.op,
            test_dialect.TestDialect.SafeReadOp.operation_name,
        ),
    );
}

fn witnessDraw(ctx: *ir.Context, block: *ir.Block, address: ?*ir.Value) !*ir.Operation {
    const name = if (address != null) name: {
        break :name test_dialect.TestDialect.AddressedDrawOp.operation_name;
    } else test_dialect.TestDialect.DrawOp.operation_name;
    var state = ir.Operation.State.init(name, .unknown);
    if (address) |value| state.addOperands(&.{value});
    state.addTypes(&.{try arith.getScalarType(ctx, .i64)});
    const op = try ctx.createOperation(state);
    try block.addOperation(op);
    return op;
}

fn checkDrawWitness(addressed: bool, seeded: bool, transform: Pass) !void {
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const block = module.getBodyBlock();
    const seed = try witnessConstant(&ctx, block, .i64, 37);
    const address = try witnessConstant(&ctx, block, .i64, 4);
    const first = if (seeded) (try arith.AddOp.create(
        &ctx,
        .unknown,
        seed,
        address,
    )).op else try witnessDraw(
        &ctx,
        block,
        if (addressed) address else null,
    );
    if (seeded) try block.addOperation(first);
    const second = if (seeded) (try arith.AddOp.create(
        &ctx,
        .unknown,
        seed,
        address,
    )).op else try witnessDraw(
        &ctx,
        block,
        if (addressed) address else null,
    );
    if (seeded) try block.addOperation(second);
    try observeValues(&ctx, block, &.{ first.getResult(0).?, second.getResult(0).? });
    const before = try EffectObservation.observe(module.op, 16);
    const before_ir = try ir.dump.operationAlloc(testing.allocator, module.op);
    defer testing.allocator.free(before_ir);
    var manager = pass_mod.PassManager.init(testing.allocator);
    defer manager.deinit();
    try manager.addPass(transform);
    try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
    const after = try EffectObservation.observe(module.op, 16);
    try before.expectEqual(&after);
    const name = if (seeded) arith.AddOp.operation_name else if (addressed)
        test_dialect.TestDialect.AddressedDrawOp.operation_name
    else
        test_dialect.TestDialect.DrawOp.operation_name;
    try testing.expectEqual(
        @as(usize, if (seeded) 1 else 2),
        ir.inspection.countOperationsNamed(module.op, name),
    );
    if (!seeded) {
        const after_ir = try ir.dump.operationAlloc(testing.allocator, module.op);
        defer testing.allocator.free(after_ir);
        try testing.expectEqualStrings(before_ir, after_ir);
        try testing.expectEqual(@as(i64, 2), after.draws);
    }
}

test "F10a CSE retains two consuming draws and repeats an explicit seed address function" {
    try checkDrawWitness(false, false, createCommonSubexpressionEliminationPass());
    try checkDrawWitness(true, false, createCommonSubexpressionEliminationPass());
    try checkDrawWitness(true, true, createCommonSubexpressionEliminationPass());
}

fn noEffectWitnessRules(_: *@import("../egraph/root.zig").RewriteSet) anyerror!void {}

fn allEffectWitnessCandidates(_: ?*anyopaque, _: *ir.Operation) anyerror!bool {
    return true;
}

const EffectSaturationPass = @import("saturation.zig").EGraphPass(.{
    .name = "effect-saturation-witness",
    .description = "Exercise consuming-state preservation through saturation",
    .populate_rules = noEffectWitnessRules,
    .options = .{ .candidate = allEffectWitnessCandidates },
});

test "F10a saturation retains draws even with a permissive candidate callback" {
    try checkDrawWitness(false, false, EffectSaturationPass.create());
    try checkDrawWitness(true, false, EffectSaturationPass.create());
    try checkDrawWitness(true, true, EffectSaturationPass.create());
}

fn checkSharedExtractionWitness(consuming: bool) !void {
    const egraph = @import("../egraph/root.zig");
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const block = module.getBodyBlock();
    const initial = try witnessConstant(&ctx, block, .i64, 0);
    try observeValues(&ctx, block, &.{initial});
    const shared = if (consuming) (try witnessDraw(
        &ctx,
        block,
        null,
    )).getResult(0).? else try witnessConstant(
        &ctx,
        block,
        .i64,
        21,
    );
    const pair = try arith.AddOp.create(&ctx, .unknown, shared, shared);
    try block.addOperation(pair.op);
    try observeValues(&ctx, block, &.{pair.getResult()});
    const before = try EffectObservation.observe(module.op, 16);
    const shared_op: *ir.Operation = @ptrCast(@alignCast(shared.getDefiningOp().?));
    const insertion: *ir.Operation = @ptrCast(@alignCast(initial.getDefiningOp().?));
    var graph = egraph.Graph.init(testing.allocator);
    defer graph.deinit();
    const child = try graph.addOperation(shared_op, &.{}, 1, 10);
    const root = try graph.addOperation(pair.op, &.{ child, child }, 1, 11);
    var extraction = try egraph.Extraction.init(testing.allocator, &graph, .{});
    defer extraction.deinit();
    extraction.analyze();
    var rewriter = PatternRewriter.init(testing.allocator, &ctx);
    defer rewriter.deinit();
    const materialized = try extraction.materialize(&rewriter, root, insertion, 0, null);
    const after = try EffectObservation.observe(module.op, 16);
    try before.expectEqual(&after);
    if (consuming) {
        try testing.expect(materialized == null);
    } else {
        const value = materialized orelse return error.WitnessExpectedMaterialization;
        const new_pair: *ir.Operation = @ptrCast(@alignCast(value.getDefiningOp().?));
        try testing.expect(new_pair.getOperand(0) == new_pair.getOperand(1));
        try testing.expect(new_pair.getOperand(0) != shared);
        try testing.expectEqual(
            @as(usize, 3),
            ir.inspection.countOperationsNamed(module.op, arith.ConstantOp.operation_name),
        );
    }
}

test "F10a saturation extraction checks duplication of a shared intermediate" {
    try checkSharedExtractionWitness(true);
    try checkSharedExtractionWitness(false);
}

const MemoryWitnessBarrier = enum { none, release, draw, fence, failure };

fn checkMemoryWitness(barrier_kind: MemoryWitnessBarrier, transform: Pass) !void {
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const block = module.getBodyBlock();
    const ty = try arith.getScalarType(&ctx, .i64);
    const memory_type = try memref.getMemrefType1D(&ctx, 1, ty, .host);
    var allocation = try memref.AllocOp.createStatic(&ctx, .unknown, memory_type);
    try block.addOperation(allocation.op);
    const base = allocation.getResult();
    const index = try witnessConstant(&ctx, block, .index, 0);
    const seven = try witnessConstant(&ctx, block, .i64, 7);
    const nine = try witnessConstant(&ctx, block, .i64, 9);
    const zero = try witnessConstant(&ctx, block, .i64, 0);
    try observeValues(&ctx, block, &.{base});
    try block.addOperation((try memref.StoreOp.create(&ctx, .unknown, seven, base, index)).op);
    const barrier: ?*ir.Operation = switch (barrier_kind) {
        .none => null,
        .release => (try dialects.RcDialect.ReleaseOp.create(&ctx, .unknown, base)).op,
        .draw => try witnessDraw(&ctx, block, null),
        .fence => (try memref.FenceOp.create(&ctx, .unknown, .system, .seq_cst)).op,
        .failure => (try arith.DivOp.create(&ctx, .unknown, seven, zero)).op,
    };
    if (barrier) |op| {
        if (op.getBlock() == null) try block.addOperation(op);
        try testing.expect(invalidatesStores(op));
        try testing.expect(observesOrInvalidatesStores(op));
    }
    try block.addOperation((try memref.StoreOp.create(&ctx, .unknown, nine, base, index)).op);
    const load = try memref.LoadOp.create(&ctx, .unknown, base, index, ty);
    try block.addOperation(load.op);
    try observeValues(&ctx, block, &.{load.getResult()});
    const before = try EffectObservation.observe(module.op, 16);
    const before_ir = try ir.dump.operationAlloc(testing.allocator, module.op);
    defer testing.allocator.free(before_ir);
    var manager = pass_mod.PassManager.init(testing.allocator);
    defer manager.deinit();
    try manager.addPass(transform);
    try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
    const after = try EffectObservation.observe(module.op, 16);
    try before.expectEqual(&after);
    const after_ir = try ir.dump.operationAlloc(testing.allocator, module.op);
    defer testing.allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "F10a forwarding retains unqualified loads and lifetime failure ordering barriers" {
    for (std.enums.values(MemoryWitnessBarrier)) |barrier| {
        try checkMemoryWitness(barrier, createLoadStoreForwardingPass());
    }
}

test "F10a DSE retains unqualified stores and lifetime failure ordering barriers" {
    for (std.enums.values(MemoryWitnessBarrier)) |barrier| {
        try checkMemoryWitness(barrier, createDeadStoreEliminationPass());
    }
}

test "F10a promotion preserves allocation failure and the value a local cell held" {
    for ([_]usize{ 0, 16 }) |capacity| {
        var ctx = try buildTestContext(testing.allocator);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
        const typ = try arith.getScalarType(&ctx, .i64);
        const function = try dialects.func.FuncDialect.FuncOp.create(
            &ctx,
            .unknown,
            "entry",
            &.{},
            &.{typ},
        );
        try module.getBodyBlock().addOperation(function.op);
        const body = function.getEntryBlock();
        const zero = try witnessConstant(&ctx, body, .index, 0);
        const seven = try witnessConstant(&ctx, body, .i64, 7);
        const cell_type = try memref.getMemrefType1D(&ctx, 1, typ, .host);
        const cell = try memref.AllocaOp.createStatic(&ctx, .unknown, cell_type);
        try body.addOperation(cell.op);
        const store = try memref.StoreOp.create(&ctx, .unknown, seven, cell.getResult(), zero);
        try body.addOperation(store.op);
        const load = try memref.LoadOp.create(&ctx, .unknown, cell.getResult(), zero, typ);
        try body.addOperation(load.op);
        const ret = try dialects.func.FuncDialect.ReturnOp.create(
            &ctx,
            .unknown,
            &.{load.getResult()},
        );
        try body.addOperation(ret.op);
        const before = try EffectObservation.observe(function.op, capacity);
        var manager = pass_mod.PassManager.init(testing.allocator);
        defer manager.deinit();
        try manager.addPass(createMemoryPromotionPass());
        try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
        const after = try EffectObservation.observe(function.op, capacity);
        try before.expectSameOutputs(&after);
        try testing.expectEqual(
            if (capacity == 0) EffectObservation.Failure.capacity else .none,
            after.failure,
        );
        const wrote: usize = if (capacity == 0) 0 else 1;
        try testing.expectEqual(wrote, before.countEvents(.write));
        try testing.expectEqual(@as(usize, 0), after.countEvents(.write));
        try testing.expectEqual(before.countEvents(.allocate), after.countEvents(.allocate));
    }
}

test "F10a promotion preserves the writes of a cell an access does not qualify" {
    for ([_]usize{ 0, 16 }) |capacity| {
        var ctx = try buildTestContext(testing.allocator);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
        const typ = try arith.getScalarType(&ctx, .i64);
        const function = try dialects.func.FuncDialect.FuncOp.create(
            &ctx,
            .unknown,
            "entry",
            &.{},
            &.{typ},
        );
        try module.getBodyBlock().addOperation(function.op);
        const body = function.getEntryBlock();
        const zero = try witnessConstant(&ctx, body, .index, 0);
        const seven = try witnessConstant(&ctx, body, .i64, 7);
        const cell_type = try memref.getMemrefType1D(&ctx, 1, typ, .host);
        const cell = try memref.AllocaOp.createStatic(&ctx, .unknown, cell_type);
        try body.addOperation(cell.op);
        const store = try memref.StoreOp.create(&ctx, .unknown, seven, cell.getResult(), zero);
        try body.addOperation(store.op);
        const computed = try arith.AddOp.create(&ctx, .unknown, zero, zero);
        try body.addOperation(computed.op);
        const load = try memref.LoadOp.create(
            &ctx,
            .unknown,
            cell.getResult(),
            computed.getResult(),
            typ,
        );
        try body.addOperation(load.op);
        const ret = try dialects.func.FuncDialect.ReturnOp.create(
            &ctx,
            .unknown,
            &.{load.getResult()},
        );
        try body.addOperation(ret.op);
        const before = try EffectObservation.observe(function.op, capacity);
        var manager = pass_mod.PassManager.init(testing.allocator);
        defer manager.deinit();
        try manager.addPass(createMemoryPromotionPass());
        try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
        const after = try EffectObservation.observe(function.op, capacity);
        try before.expectEqual(&after);
        try testing.expectEqual(
            @as(usize, if (capacity == 0) 0 else 1),
            after.countEvents(.write),
        );
        try testing.expectEqual(
            if (capacity == 0) EffectObservation.Failure.capacity else .none,
            after.failure,
        );
    }
}

fn checkFoldWitness(transform: Pass) !void {
    for ([_]bool{ false, true }) |add| {
        var ctx = try buildTestContext(testing.allocator);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        try registerObservation(&ctx);
        const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
        const body = module.getBodyBlock();
        const lhs = try witnessConstant(&ctx, body, .i64, 6);
        const rhs = try witnessConstant(&ctx, body, .i64, if (add) 0 else 1);
        const operation = if (add) (try arith.AddOp.create(
            &ctx,
            .unknown,
            lhs,
            rhs,
        )).op else (try arith.DivOp.create(&ctx, .unknown, lhs, rhs)).op;
        try body.addOperation(operation);
        const result = operation.getResult(0).?;
        try observeValues(&ctx, body, &.{result});
        const before = try EffectObservation.observe(module.op, 16);
        var manager = pass_mod.PassManager.init(testing.allocator);
        defer manager.deinit();
        try manager.addPass(transform);
        try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
        const after = try EffectObservation.observe(module.op, 16);
        try before.expectEqual(&after);
        const output: *ir.Operation = @ptrCast(@alignCast(body.operations.tail.?));
        try testing.expect(output.getOperand(0).? != result);
    }
}

test "Precision1 constant folding qualifies wrapping add and proved division" {
    try checkFoldWitness(createConstantFoldingPass());
}

test "Precision1 canonicalization qualifies add and proved division" {
    try checkFoldWitness(canonicalization.createCanonicalizationPass());
}

fn checkSelectionWitness(transform: Pass, selected: ?bool) !void {
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const body = module.getBodyBlock();
    const one = try witnessConstant(&ctx, body, .i64, 1);
    const zero = try witnessConstant(&ctx, body, .i64, 0);
    const condition = if (selected) |value| try witnessConstant(
        &ctx,
        body,
        .bool,
        if (value) 1 else 0,
    ) else condition: {
        const cmp = try arith.CmpOp.create(&ctx, .unknown, .ne, one, zero);
        try body.addOperation(cmp.op);
        break :condition cmp.getResult();
    };
    const branch = try scf.IfOp.create(&ctx, .unknown, condition, &.{});
    try body.addOperation(branch.op);
    if (selected != null) {
        const division = try arith.DivOp.create(&ctx, .unknown, one, zero);
        try branch.getThenBlock().addOperation(division.op);
        try observeValues(&ctx, branch.getThenBlock(), &.{division.getResult()});
    }
    const then_yield = try scf.YieldOp.create(&ctx, .unknown, &.{});
    try branch.getThenBlock().addOperation(then_yield.op);
    const else_yield = try scf.YieldOp.create(&ctx, .unknown, &.{});
    try branch.getElseBlock().?.addOperation(else_yield.op);
    try observeValues(&ctx, body, &.{one});
    const before = try EffectObservation.observe(module.op, 16);
    var manager = pass_mod.PassManager.init(testing.allocator);
    defer manager.deinit();
    try manager.addPass(transform);
    try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
    const after = try EffectObservation.observe(module.op, 16);
    try before.expectEqual(&after);
    if (selected == null) try testing.expect(ctx.containsOperation(branch.op));
}

test "F10a canonicalization requires proved region selection" {
    try checkSelectionWitness(canonicalization.createCanonicalizationPass(), null);
    try checkSelectionWitness(canonicalization.createCanonicalizationPass(), false);
    try checkSelectionWitness(canonicalization.createCanonicalizationPass(), true);
}

test "F10a SCCP qualifies add and preserves selected region observations" {
    try checkFoldWitness(createSparseConditionalConstantPropagationPass());
    try checkSelectionWitness(createSparseConditionalConstantPropagationPass(), null);
    try checkSelectionWitness(createSparseConditionalConstantPropagationPass(), false);
    try checkSelectionWitness(createSparseConditionalConstantPropagationPass(), true);
}

fn checkOwnershipWitness(branch_taken: ?bool, pipeline: bool) !void {
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    const rc = dialects.rc.RcDialect;
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const outer = module.getBodyBlock();
    const typ = try arith.getScalarType(&ctx, .i64);
    const cell_type = try memref.getMemrefType1D(&ctx, 1, typ, .host);
    const cell = try memref.AllocOp.createStatic(&ctx, .unknown, cell_type);
    try outer.addOperation(cell.op);
    const body = if (branch_taken) |taken| body: {
        const condition = try witnessConstant(&ctx, outer, .bool, if (taken) 1 else 0);
        const branch = try scf.IfOp.create(&ctx, .unknown, condition, &.{});
        try outer.addOperation(branch.op);
        const yield = try scf.YieldOp.create(&ctx, .unknown, &.{});
        try branch.getElseBlock().?.addOperation(yield.op);
        break :body branch.getThenBlock();
    } else outer;
    const retained = try rc.RetainOp.create(&ctx, .unknown, cell.getResult());
    try body.addOperation(retained.op);
    const borrowed = try rc.BorrowOp.create(&ctx, .unknown, cell.getResult());
    try body.addOperation(borrowed.op);
    try observeValues(&ctx, body, &.{borrowed.getResult()});
    const inner_release = try rc.ReleaseOp.create(&ctx, .unknown, cell.getResult());
    try body.addOperation(inner_release.op);
    if (branch_taken != null) {
        try body.addOperation((try scf.YieldOp.create(&ctx, .unknown, &.{})).op);
    }
    const moved = try rc.MoveOp.create(&ctx, .unknown, cell.getResult());
    try outer.addOperation(moved.op);
    try outer.addOperation((try rc.ReleaseOp.create(&ctx, .unknown, moved.getResult())).op);
    const one = try witnessConstant(&ctx, outer, .i64, 1);
    const dead_add = try arith.AddOp.create(&ctx, .unknown, one, one);
    try outer.addOperation(dead_add.op);
    const before = try EffectObservation.observe(module.op, 16);
    var manager = pass_mod.PassManager.init(testing.allocator);
    defer manager.deinit();
    if (pipeline) {
        try addDefaultOptimizationPipeline(&manager);
    } else {
        try manager.addPass(createDeadCodeEliminationPass());
    }
    try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
    const after = try EffectObservation.observe(module.op, 16);
    try before.expectEqual(&after);
    try testing.expectEqual(EffectObservation.Failure.none, after.failure);
    var destructions: usize = 0;
    for (after.events[0..after.event_count]) |event| {
        if (event.kind == .destroy) destructions += 1;
    }
    try testing.expectEqual(@as(usize, 1), destructions);
    if (!pipeline) try testing.expect(!ctx.containsOperation(dead_add.op));
}

test "F10a ownership preserves allocation backed aliases branch traces and one destructor" {
    for ([_]bool{ false, true }) |pipeline| {
        try checkOwnershipWitness(null, pipeline);
        try checkOwnershipWitness(false, pipeline);
        try checkOwnershipWitness(true, pipeline);
    }
}

fn checkAllocationIdentityWitness(pipeline: bool) !void {
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const body = module.getBodyBlock();
    const typ = try arith.getScalarType(&ctx, .i64);
    const cell_type = try memref.getMemrefType1D(&ctx, 1, typ, .host);
    const first = try memref.AllocOp.createStatic(&ctx, .unknown, cell_type);
    const second = try memref.AllocOp.createStatic(&ctx, .unknown, cell_type);
    try body.addOperation(first.op);
    try body.addOperation(second.op);
    try observeValues(&ctx, body, &.{ first.getResult(), second.getResult() });
    const before = try EffectObservation.observe(module.op, 16);
    var manager = pass_mod.PassManager.init(testing.allocator);
    defer manager.deinit();
    if (pipeline) {
        try addDefaultOptimizationPipeline(&manager);
    } else {
        try manager.addPass(createCommonSubexpressionEliminationPass());
    }
    try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
    const after = try EffectObservation.observe(module.op, 16);
    try before.expectEqual(&after);
    try testing.expectEqual(@as(usize, 2), after.allocations);
}

fn checkAllocationRegionWitness(pipeline: bool) !void {
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const outer = module.getBodyBlock();
    const zero = try witnessConstant(&ctx, outer, .i64, 0);
    const one = try witnessConstant(&ctx, outer, .i64, 1);
    const loop = try scf.ForOp.create(&ctx, .unknown, zero, zero, one, &.{}, &.{});
    try outer.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const add = try arith.AddOp.create(&ctx, .unknown, zero, one);
    try body.addOperation(add.op);
    const typ = try arith.getScalarType(&ctx, .i64);
    const cell_type = try memref.getMemrefType1D(&ctx, 1, typ, .host);
    const cell = try memref.AllocOp.createStatic(&ctx, .unknown, cell_type);
    try body.addOperation(cell.op);
    try observeValues(&ctx, body, &.{ cell.getResult(), add.getResult() });
    try body.addOperation((try scf.YieldOp.create(&ctx, .unknown, &.{})).op);
    const before = try EffectObservation.observe(module.op, 0);
    var manager = pass_mod.PassManager.init(testing.allocator);
    defer manager.deinit();
    if (pipeline) {
        try addDefaultOptimizationPipeline(&manager);
    } else {
        try manager.addPass(createLoopInvariantCodeMotionPass());
    }
    try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
    const after = try EffectObservation.observe(module.op, 0);
    try before.expectEqual(&after);
    try testing.expect(cell.op.getBlock() == body);
    if (!pipeline) try testing.expect(add.op.getBlock() == outer);
}

test "F10a allocation preserves fresh identities" {
    for ([_]bool{ false, true }) |pipeline| try checkAllocationIdentityWitness(pipeline);
}

test "F10a allocation preserves capacity failure region" {
    for ([_]bool{ false, true }) |pipeline| try checkAllocationRegionWitness(pipeline);
}

fn precisionValueOperation(
    ctx: *ir.Context,
    block: *ir.Block,
    name: []const u8,
    typ: ir.Type,
    operands: []const *ir.Value,
) !*ir.Operation {
    var state = ir.Operation.State.init(name, .unknown);
    state.addOperands(operands);
    state.addTypes(&.{typ});
    const operation = try ctx.createOperation(state);
    try block.addOperation(operation);
    return operation;
}

fn precisionFloat(
    ctx: *ir.Context,
    block: *ir.Block,
    kind: dialects.arith.ScalarKind,
    value: f64,
) !*ir.Value {
    var constant = try arith.ConstantOp.createFloat(
        ctx,
        .unknown,
        try arith.getScalarType(ctx, kind),
        value,
    );
    try block.addOperation(constant.op);
    return constant.getResult();
}

const PrecisionLicmCase = struct {
    name: []const u8,
    kind: dialects.arith.ScalarKind,
    divisor: ?i64 = null,
    unary: bool = false,
    hoists: bool = true,
};

fn checkPrecisionLicm(case: PrecisionLicmCase) !void {
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const outer = module.getBodyBlock();
    const typ = try arith.getScalarType(&ctx, case.kind);
    const lhs = try outer.addArgument(typ, .unknown);
    const rhs = if (case.divisor) |n|
        try witnessConstant(&ctx, outer, case.kind, n)
    else
        try outer.addArgument(typ, .unknown);
    const lower = try witnessConstant(&ctx, outer, .index, 0);
    const upper = try witnessConstant(&ctx, outer, .index, 0);
    const step = try witnessConstant(&ctx, outer, .index, 1);
    const loop = try scf.ForOp.create(&ctx, .unknown, lower, upper, step, &.{}, &.{});
    try outer.addOperation(loop.op);
    const body = loop.getBodyBlock();
    const candidate = try precisionValueOperation(
        &ctx,
        body,
        case.name,
        typ,
        if (case.unary) &.{lhs} else &.{ lhs, rhs },
    );
    try observeValues(&ctx, body, &.{candidate.getResult(0).?});
    try body.addOperation((try scf.YieldOp.create(&ctx, .unknown, &.{})).op);
    var manager = try runLicmPass(testing.allocator, module.op, &ctx);
    defer manager.deinit();
    try testing.expect(candidate.getBlock() == if (case.hoists) outer else body);
}

test "Precision1 LICM hoists typed total arithmetic and retains unresolved division" {
    for ([_]PrecisionLicmCase{
        .{ .name = "arith.mul", .kind = .f32 },
        .{ .name = "arith.sqrt", .kind = .f64, .unary = true },
        .{ .name = "arith.sub", .kind = .i32 },
        .{ .name = "arith.div", .kind = .i64, .hoists = false },
        .{ .name = "arith.div", .kind = .i64, .divisor = 2 },
        .{ .name = "arith.div", .kind = .i64, .divisor = -1, .hoists = false },
    }) |case| try checkPrecisionLicm(case);
}

test "Precision1 DCE erases only unused shifts with a proved count" {
    for ([_]?i64{ 0, 7, 8, -1, null }) |count| {
        var ctx = try buildTestContext(testing.allocator);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
        const body = module.getBodyBlock();
        const typ = try arith.getScalarType(&ctx, .i8);
        const lhs = try body.addArgument(typ, .unknown);
        const rhs = if (count) |n| try witnessConstant(
            &ctx,
            body,
            .i8,
            n,
        ) else try body.addArgument(typ, .unknown);
        _ = try precisionValueOperation(&ctx, body, "arith.shl", typ, &.{ lhs, rhs });
        var manager = try runDcePass(testing.allocator, module.op, &ctx);
        defer manager.deinit();
        const erased = if (count) |n| n >= 0 and n < 8 else false;
        try testing.expectEqual(
            @as(usize, if (erased) 0 else 1),
            ir.inspection.countOperationsNamed(module.op, "arith.shl"),
        );
    }
}

test "Precision1 CSE floating add requires the unobservable default environment" {
    for ([_]bool{ false, true }) |observable| {
        var ctx = try buildTestContext(testing.allocator);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        try registerObservation(&ctx);
        ctx.arithmetic_policy.environment_observable = observable;
        const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
        const body = module.getBodyBlock();
        const typ = try arith.getScalarType(&ctx, .f32);
        const lhs = try body.addArgument(typ, .unknown);
        const rhs = try body.addArgument(typ, .unknown);
        const first = try precisionValueOperation(&ctx, body, "arith.add", typ, &.{ lhs, rhs });
        const second = try precisionValueOperation(&ctx, body, "arith.add", typ, &.{ lhs, rhs });
        try observeValues(&ctx, body, &.{ first.getResult(0).?, second.getResult(0).? });
        var manager = pass_mod.PassManager.init(testing.allocator);
        defer manager.deinit();
        try manager.addPass(createCommonSubexpressionEliminationPass());
        try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
        const output: *ir.Operation = @ptrCast(@alignCast(body.operations.tail.?));
        try testing.expectEqual(!observable, output.getOperand(0).? == output.getOperand(1).?);
        try testing.expectEqual(
            @as(usize, if (observable) 2 else 1),
            ir.inspection.countOperationsNamed(module.op, "arith.add"),
        );
    }
}

test "Precision1 negative sqrt explicitly declines folding and positive sqrt folds" {
    for ([_]f64{ -1, 4 }) |input| {
        var ctx = try buildTestContext(testing.allocator);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        try registerObservation(&ctx);
        const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
        const body = module.getBodyBlock();
        const value = try precisionFloat(&ctx, body, .f64, input);
        const candidate = try precisionValueOperation(
            &ctx,
            body,
            "arith.sqrt",
            value.type,
            &.{value},
        );
        try observeValues(&ctx, body, &.{candidate.getResult(0).?});
        var manager = try runConstantFoldingPass(testing.allocator, module.op, &ctx);
        defer manager.deinit();
        const output: *ir.Operation = @ptrCast(@alignCast(body.operations.tail.?));
        const raw = output.getOperand(0).?.getDefiningOp().?;
        const definition: *ir.Operation = @ptrCast(@alignCast(raw));
        if (input < 0) {
            try testing.expectEqualStrings("arith.sqrt", definition.name.name);
        } else {
            try testing.expectEqualStrings("arith.constant", definition.name.name);
            try testing.expectEqual(
                @as(f64, 2),
                definition.getAttrAs(ir.Attribute.FloatAttr, "value").?.getValue(),
            );
        }
    }
}

test "Precision1 integer to float casts fold for every scalar integer and float type" {
    const sources = [_]dialects.arith.ScalarKind{
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .index,
    };
    for (sources) |source| {
        for ([_]dialects.arith.ScalarKind{ .f16, .bf16, .f32, .f64 }) |target| {
            var ctx = try buildTestContext(testing.allocator);
            defer ctx.deinit(testing.allocator);
            try dialects.registerAllDialects(&ctx);
            try registerObservation(&ctx);
            const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
            const body = module.getBodyBlock();
            const value = try witnessConstant(&ctx, body, source, 37);
            const typ = try arith.getScalarType(&ctx, target);
            const candidate = try precisionValueOperation(&ctx, body, "arith.cast", typ, &.{value});
            try observeValues(&ctx, body, &.{candidate.getResult(0).?});
            var manager = try runConstantFoldingPass(testing.allocator, module.op, &ctx);
            defer manager.deinit();
            const output: *ir.Operation = @ptrCast(@alignCast(body.operations.tail.?));
            const raw = output.getOperand(0).?.getDefiningOp().?;
            const definition: *ir.Operation = @ptrCast(@alignCast(raw));
            try testing.expectEqualStrings("arith.constant", definition.name.name);
            try testing.expectEqual(
                @as(f64, 37),
                definition.getAttrAs(ir.Attribute.FloatAttr, "value").?.getValue(),
            );
        }
    }
}

fn precisionEvaluateIdentity(
    _: *const anyopaque,
    operands: []const ir.Attribute,
    _: *const ir.interfaces.EvalContext,
) ir.interfaces.EvalError!ir.Attribute {
    if (operands.len != 1) return error.InvalidOperand;
    return operands[0];
}

test "Precision1 constant folding uses a non arith Evaluatable and preserves its unknown control" {
    for ([_]bool{ false, true }) |qualified| {
        var ctx = try buildTestContext(testing.allocator);
        defer ctx.deinit(testing.allocator);
        try registerObservation(&ctx);
        try ctx.registerOperationInterface(
            "test.evaluate_identity",
            ir.interfaces.Evaluatable.entryFor(
                ir.interfaces.Evaluatable.canAlwaysFold,
                precisionEvaluateIdentity,
            ),
        );
        if (qualified) try ctx.registerOperationInterface(
            "test.evaluate_identity",
            ir.interfaces.EffectOpInterface.entryFor(.{
                .complete = true,
                .facts = &.{.{ .result = .{ .index = 0, .ownership = .none } }},
            }),
        );
        const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
        const body = module.getBodyBlock();
        const value = try witnessConstant(&ctx, body, .i32, 19);
        const candidate = try precisionValueOperation(
            &ctx,
            body,
            "test.evaluate_identity",
            value.type,
            &.{value},
        );
        try observeValues(&ctx, body, &.{candidate.getResult(0).?});
        var manager = try runConstantFoldingPass(testing.allocator, module.op, &ctx);
        defer manager.deinit();
        try testing.expectEqual(
            @as(usize, if (qualified) 0 else 1),
            ir.inspection.countOperationsNamed(module.op, "test.evaluate_identity"),
        );
        if (qualified) {
            const output: *ir.Operation = @ptrCast(@alignCast(body.operations.tail.?));
            try testing.expectEqual(
                ConstValue{ .int = 19 },
                constantFromValue(output.getOperand(0).?).?,
            );
        }
    }
}

const PrecisionCastCase = struct {
    value: f64,
    target: dialects.arith.ScalarKind,
    expected: ?i64,
};

const precision_cast_cases = [_]PrecisionCastCase{
    .{ .value = 127.9, .target = .i8, .expected = 127 },
    .{ .value = -128.9, .target = .i8, .expected = -128 },
    .{ .value = 128, .target = .i8, .expected = null },
    .{ .value = -129, .target = .i8, .expected = null },
    .{ .value = 255.9, .target = .u8, .expected = 255 },
    .{ .value = -0.9, .target = .u8, .expected = 0 },
    .{ .value = 256, .target = .u8, .expected = null },
    .{ .value = -1, .target = .u8, .expected = null },
    .{ .value = 0x1p63, .target = .i64, .expected = null },
    .{ .value = -0x1p63, .target = .i64, .expected = std.math.minInt(i64) },
    .{ .value = -0x1.0000000000001p63, .target = .i64, .expected = null },
    .{ .value = 0x1.fffffffffffffp62, .target = .i64, .expected = 9223372036854774784 },
    .{ .value = 0x1p64, .target = .u64, .expected = null },
    .{ .value = 0x1.fffffffffffffp63, .target = .u64, .expected = -2048 },
    .{ .value = 0x1p64, .target = .index, .expected = null },
    .{ .value = 0x1p63, .target = .index, .expected = std.math.minInt(i64) },
    .{ .value = std.math.nan(f64), .target = .i32, .expected = null },
    .{ .value = std.math.inf(f64), .target = .i32, .expected = null },
    .{ .value = -std.math.inf(f64), .target = .u32, .expected = null },
};

fn checkPrecisionFloatCast(case: PrecisionCastCase, used: bool) !void {
    var ctx = try buildTestContext(testing.allocator);
    defer ctx.deinit(testing.allocator);
    try dialects.registerAllDialects(&ctx);
    try registerObservation(&ctx);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    const body = module.getBodyBlock();
    const value = try precisionFloat(&ctx, body, .f64, case.value);
    const typ = try arith.getScalarType(&ctx, case.target);
    const cast = try precisionValueOperation(&ctx, body, "arith.cast", typ, &.{value});
    if (used) try observeValues(&ctx, body, &.{cast.getResult(0).?});
    var manager = pass_mod.PassManager.init(testing.allocator);
    defer manager.deinit();
    try manager.addPass(createConstantFoldingPass());
    if (!used) try manager.addPass(createDeadCodeEliminationPass());
    try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, if (case.expected == null) 1 else 0),
        ir.inspection.countOperationsNamed(module.op, "arith.cast"),
    );
    if (used) {
        if (case.expected) |expected| {
            const output: *ir.Operation = @ptrCast(@alignCast(body.operations.tail.?));
            try testing.expectEqual(
                ConstValue{ .int = expected },
                constantFromValue(output.getOperand(0).?).?,
            );
        }
    }
}

test "Precision1 float to integer cast folds truncated endpoints and preserves domain failures" {
    for (precision_cast_cases) |case| {
        try checkPrecisionFloatCast(case, true);
        try checkPrecisionFloatCast(case, false);
    }
}

test "Precision1 float to integer cast retains variable sources and observable environments" {
    for ([_]bool{ false, true }) |observable| {
        var ctx = try buildTestContext(testing.allocator);
        defer ctx.deinit(testing.allocator);
        try dialects.registerAllDialects(&ctx);
        ctx.arithmetic_policy.environment_observable = observable;
        const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
        const body = module.getBodyBlock();
        const source = try arith.getScalarType(&ctx, .f32);
        const target = try arith.getScalarType(&ctx, .i32);
        const value = if (observable) try precisionFloat(
            &ctx,
            body,
            .f32,
            37,
        ) else try body.addArgument(source, .unknown);
        _ = try precisionValueOperation(&ctx, body, "arith.cast", target, &.{value});
        var manager = pass_mod.PassManager.init(testing.allocator);
        defer manager.deinit();
        try manager.addPass(createConstantFoldingPass());
        try manager.addPass(createDeadCodeEliminationPass());
        try testing.expectEqual(PassResult.success, manager.run(module.op, &ctx));
        try testing.expectEqual(
            @as(usize, 1),
            ir.inspection.countOperationsNamed(module.op, "arith.cast"),
        );
    }
}
