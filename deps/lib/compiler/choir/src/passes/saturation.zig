const std = @import("std");
const ir = @import("../core/root.zig");
const passes = @import("root.zig");
const pass_mod = passes.pass;
const rewrite = ir.rewrite;
const effects = passes.effects;
const egraph = @import("../egraph/root.zig");
const graph_mod = egraph.graph;
const rules_mod = egraph.rules;
const pattern_mod = egraph.pattern;
const extract_mod = egraph.extract;

const ClassId = graph_mod.ClassId;
const Graph = graph_mod.Graph;
const RewriteContext = rules_mod.RewriteContext;
const RewriteSet = rules_mod.RewriteSet;
const CandidateFn = rules_mod.CandidateFn;
const PopulateRulesFn = rules_mod.PopulateRulesFn;
const work = pass_mod.work;

/// Bounds for a fixed rule set that only merges a result with a dominating SSA
/// value. Such rules add no nodes. Their cost model permits only linear failed
/// materialization paths: extraction can explore a cycle before retaining an
/// operation, but cannot create an expression. Arbitrary rules do not qualify.
pub fn eliminationWorkBound(input: work.Input, rule_count: u64, iterations: u32) !work.Bounds {
    if (iterations == 0) return error.MissingWorkContract;
    const census = try work.Census.inspect(input.operation);
    const nodes = try work.add(census.values, census.operands);
    const blocks = try work.add(nodes, 1);
    const rebuilds = try work.add(nodes, try work.multiply(iterations, blocks));
    var storage = Graph.mergeStorageBound(nodes, census.atoms, blocks, rebuilds) catch
        return error.WorkOverflow;
    storage = try work.add(storage, extract_mod.Extraction.choiceStorageBound(nodes, blocks) catch
        return error.WorkOverflow);
    const candidates = try work.arrayListGrowth(CandidateResult, census.operations);
    const values = try work.hashMapGrowth(*ir.Value, ClassId, nodes);
    const operands = try work.arrayListGrowth(ClassId, census.operands);
    storage = try work.add(storage, try work.multiply(blocks, try work.add(
        candidates,
        try work.add(values, operands),
    )));
    storage = try work.add(storage, try work.arrayListGrowth(rules_mod.RewriteRule, rule_count));
    const visiting = try work.hashMapGrowth(u32, void, nodes);
    const operand_values = try work.arrayListGrowth(*ir.Value, census.operands);
    const materialization = try work.add(visiting, try work.multiply(nodes, operand_values));
    storage = try work.add(storage, try work.multiply(census.operations, materialization));
    const erasures = try work.arrayListGrowth(*ir.Operation, census.operations);
    storage = try work.add(storage, try work.multiply(2, erasures));
    const population = try work.add(nodes, 1);
    const scans = try work.multiply(try work.add(rebuilds, iterations), try work.multiply(
        population,
        try work.multiply(population, population),
    ));
    const units = try work.add(try work.add(census.atoms, census.input_bytes), 1);
    const attempts_per_iteration = try work.multiply(rule_count, try work.multiply(population, population));
    const attempts = try work.multiply(iterations, attempts_per_iteration);
    const visits = try work.multiply(scans, try work.multiply(try work.add(rule_count, 64), units));
    return .{
        .work = .{
            .input_bytes = census.input_bytes,
            .output_bytes = input.operation.context.capacity.storage_bytes,
            .structural_visits = visits,
            .rewrite_attempts = attempts,
            .allocation_capacity = try work.add(storage, input.operation.context.capacity.storage_bytes),
        },
        .workspace = storage,
    };
}

pub const OptimizationOptions = struct {
    max_iterations: u32 = 8,
    max_rewrites: u32 = 1024,
    candidate: CandidateFn = defaultCandidate,
    candidate_context: ?*anyopaque = null,
};

pub const OptimizationStats = struct {
    classes_created: usize = 0,
    nodes_added: usize = 0,
    unions: usize = 0,
    rebuilds: usize = 0,
    rewrites: usize = 0,
    replacements: usize = 0,
    iterations: u64 = 0,
    termination: OptimizationTermination = .converged,

    pub fn modified(self: OptimizationStats) bool {
        return self.replacements != 0;
    }
};

pub const OptimizationTermination = enum { converged, iteration_limit, rewrite_limit };

/// Physical counters do not replace pre-pass admission. Transient callers may
/// consume partial optimization; an accounted producer cannot publish it as success.
pub fn observeOptimization(ctx: *pass_mod.PassContext, stats: OptimizationStats) bool {
    const ledger = ctx.analysis_cache.accounting orelse return true;
    if (stats.termination != .converged) ledger.fail(.exhausted);
    ledger.observeCounters(.{
        .successful_rewrites = stats.rewrites,
        .rewrite_iterations = stats.iterations,
    }) catch return false;
    return stats.termination == .converged;
}

pub const PassConfig = struct {
    name: []const u8,
    description: []const u8,
    populate_rules: PopulateRulesFn,
    options: OptimizationOptions = .{},
    mutation_scope: pass_mod.PassMutationScope = .isolated,
};

pub fn EGraphPass(comptime config: PassConfig) type {
    return struct {
        pub fn create() pass_mod.Pass {
            return .{
                .name = config.name,
                .description = config.description,
                .run_fn = run,
                .mutation_scope = config.mutation_scope,
            };
        }

        fn run(ctx: *pass_mod.PassContext) pass_mod.PassResult {
            var rules = RewriteSet.init(ctx.allocator);
            defer rules.deinit();

            config.populate_rules(&rules) catch return .failure;
            const stats = runOptimization(ctx.allocator, ctx.ir_ctx, ctx.op, &rules, config.options) catch return .failure;
            if (stats.modified()) {
                ctx.markModified();
            } else {
                ctx.preserveAllAnalyses();
            }
            if (!observeOptimization(ctx, stats)) return .failure;
            return .success;
        }
    };
}

pub fn defaultCandidate(_: ?*anyopaque, op: *ir.Operation) anyerror!bool {
    if (op.getNumResults() != 1) return false;
    if (op.getNumRegions() != 0) return false;
    if (op.getNumSuccessors() != 0) return false;

    const traits = op.getTraits();
    if (traits.is_terminator) return false;
    if (op.hasInterface(ir.interfaces.SymbolOpInterface)) return false;
    return effects.permitsRepeatableExpression(op);
}

pub fn runOptimization(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    root: *ir.Operation,
    rules: *RewriteSet,
    options: OptimizationOptions,
) !OptimizationStats {
    rules.sortByBenefit();

    var rewriter = rewrite.PatternRewriter.init(allocator, ir_ctx);
    defer rewriter.deinit();

    var state = OptimizerState{
        .allocator = allocator,
        .ir_ctx = ir_ctx,
        .rules = rules,
        .options = options,
        .rewriter = &rewriter,
    };
    try state.optimizeOperation(root);
    if (state.stats.replacements > 0) {
        rewriter.finalize(root);
    }
    return state.stats;
}

const CandidateResult = struct {
    op: *ir.Operation,
    value: *ir.Value,
    class: ClassId,
    order: usize,
};

const OptimizerState = struct {
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    rules: *RewriteSet,
    options: OptimizationOptions,
    rewriter: *rewrite.PatternRewriter,
    stats: OptimizationStats = .{},
    value_order: usize = 0,

    fn optimizeOperation(self: *OptimizerState, op: *ir.Operation) !void {
        for (op.regions.items) |*region| {
            var block_iter = region.getBlocks();
            while (block_iter.next()) |block| {
                try self.optimizeBlock(block);

                var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
                while (current) |nested_op| {
                    try self.optimizeOperation(nested_op);
                    current = nested_op.next_op;
                }
            }
        }
    }

    fn optimizeBlock(self: *OptimizerState, block: *ir.Block) !void {
        var graph = Graph.init(self.allocator);
        defer graph.deinit();

        var value_classes = std.AutoHashMap(*ir.Value, ClassId).init(self.allocator);
        defer value_classes.deinit();

        var candidates: std.ArrayListUnmanaged(CandidateResult) = .empty;
        defer candidates.deinit(self.allocator);

        for (block.arguments.items) |argument| {
            const class = try graph.addValue(argument, 0, self.nextOrder());
            try value_classes.put(argument, class);
        }

        var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
        while (current) |op| {
            const candidate = op.getNumResults() == 1 and
                op.getNumRegions() == 0 and
                op.getNumSuccessors() == 0 and
                try defaultCandidate(null, op) and
                try self.options.candidate(self.options.candidate_context, op);

            if (candidate) {
                var operand_classes = std.ArrayListUnmanaged(ClassId).empty;
                defer operand_classes.deinit(self.allocator);
                try operand_classes.ensureTotalCapacity(self.allocator, op.getOperandValues().len);

                for (op.getOperandValues()) |operand| {
                    operand_classes.appendAssumeCapacity(try self.classForValue(&graph, &value_classes, operand));
                }

                const order = self.nextOrder();
                const class = try graph.addOperation(op, operand_classes.items, 1, order);
                const result = op.getResult(0).?;
                try value_classes.put(result, class);
                try candidates.append(self.allocator, .{ .op = op, .value = result, .class = class, .order = order });
            } else {
                for (op.results.items) |*result| {
                    const class = try graph.addValue(result, 0, self.nextOrder());
                    try value_classes.put(result, class);
                }
            }

            current = op.next_op;
        }

        try self.saturate(&graph);
        try self.replaceCandidates(&graph, &value_classes, candidates.items);

        self.stats.classes_created += graph.stats.classes_created;
        self.stats.nodes_added += graph.stats.nodes_added;
        self.stats.unions += graph.stats.unions;
        self.stats.rebuilds += graph.stats.rebuilds;
    }

    fn nextOrder(self: *OptimizerState) usize {
        const order = self.value_order;
        self.value_order += 1;
        return order;
    }

    fn classForValue(
        self: *OptimizerState,
        graph: *Graph,
        value_classes: *std.AutoHashMap(*ir.Value, ClassId),
        value: *ir.Value,
    ) !ClassId {
        if (value_classes.get(value)) |existing| return graph.find(existing);
        const class = try graph.addValue(value, 0, self.nextOrder());
        try value_classes.put(value, class);
        return class;
    }

    fn saturate(self: *OptimizerState, graph: *Graph) !void {
        const iteration_limit = if (self.options.max_iterations == 0) std.math.maxInt(u32) else self.options.max_iterations;
        const rewrite_limit = if (self.options.max_rewrites == 0) std.math.maxInt(u32) else self.options.max_rewrites;

        var iteration: u32 = 0;
        while (iteration < iteration_limit) : (iteration += 1) {
            self.stats.iterations += 1;
            const budget = rewrite_limit - self.stats.rewrites;
            const applied = try self.applyRulesOnce(graph, budget);
            self.stats.rewrites += applied;
            if (applied == 0) return;
            _ = try graph.rebuild();
            if (self.stats.rewrites >= rewrite_limit) {
                self.noteTermination(.rewrite_limit);
                return;
            }
        }
        self.noteTermination(.iteration_limit);
    }

    fn noteTermination(self: *OptimizerState, cause: OptimizationTermination) void {
        if (self.stats.termination == .converged) self.stats.termination = cause;
    }

    fn applyRulesOnce(self: *OptimizerState, graph: *Graph, budget: usize) !usize {
        var ctx = RewriteContext{ .graph = graph };
        var applied: usize = 0;

        const class_count = graph.classCount();
        for (0..class_count) |index| {
            const id = ClassId{ .index = @intCast(index) };
            const root = graph.find(id);
            if (!root.eql(id)) continue;

            var node_index: usize = 0;
            while (node_index < graph.nodes(root).len) : (node_index += 1) {
                const node = graph.nodes(root)[node_index];
                for (self.rules.rules.items) |rule| {
                    if (applied >= budget) return applied;
                    if (try rule.apply(&ctx, root, &node)) {
                        applied += 1;
                    }
                }
                if (self.rules.constant_model) |*model| {
                    for (self.rules.patterns.items) |*rule| {
                        if (applied >= budget) return applied;
                        if (try pattern_mod.applyRule(graph, self.ir_ctx, model, rule, root, &node)) {
                            applied += 1;
                        }
                    }
                }
            }
        }

        return applied;
    }

    fn replaceCandidates(
        self: *OptimizerState,
        graph: *Graph,
        value_classes: *std.AutoHashMap(*ir.Value, ClassId),
        candidates: []const CandidateResult,
    ) !void {
        if (candidates.len == 0) return;

        var extraction = try extract_mod.Extraction.init(self.allocator, graph, self.rules.resolvedCostModel());
        defer extraction.deinit();
        extraction.analyze();

        for (candidates) |candidate| {
            const root = graph.find(candidate.class);

            if (extraction.usableValue(root, candidate.order, candidate.value)) |value| {
                try self.rewriter.replaceOpWithValue(candidate.op, value);
                self.stats.replacements += 1;
                continue;
            }

            var own_cost: u64 = extraction.model.operationCost(candidate.op.name.name);
            for (candidate.op.getOperandValues()) |operand| {
                const operand_class = value_classes.get(operand) orelse continue;
                own_cost +|= extraction.classCost(operand_class);
            }

            if (extraction.nodeCost(root) >= own_cost) continue;
            const replacement = try extraction.materialize(
                self.rewriter,
                root,
                candidate.op,
                candidate.order,
                candidate.value,
            ) orelse continue;
            if (replacement == candidate.value) continue;
            try self.rewriter.replaceOpWithValue(candidate.op, replacement);
            self.stats.replacements += 1;
        }
    }
};

test "saturation termination distinguishes convergence and both internal limits" {
    try checkSaturationTermination(.{ .max_iterations = 1 }, .iteration_limit, 1);
    try checkSaturationTermination(.{ .max_rewrites = 1 }, .rewrite_limit, 1);
    try checkSaturationTermination(.{ .max_iterations = 2 }, .converged, 2);
    try checkSaturationTermination(.{ .max_iterations = 0, .max_rewrites = 0 }, .converged, 2);
}

fn mergeFirstClass(ctx: *RewriteContext, class: ClassId, _: *const graph_mod.Node) !bool {
    return ctx.merge(class, .{ .index = 0 });
}

fn checkSaturationTermination(
    options: OptimizationOptions,
    expected: OptimizationTermination,
    iterations: u64,
) !void {
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try context.allowUnregistered();
    var op_builder = ir.OperationBuilder.init(&context);
    const root = try op_builder.create(ir.Operation.State.init("test.root", ir.Location.getUnknown()));
    var rewriter = rewrite.PatternRewriter.init(allocator, &context);
    defer rewriter.deinit();
    var graph = Graph.init(allocator);
    defer graph.deinit();
    _ = try graph.addNode(&.{ .kind = .operation, .op_name = "test.left" });
    _ = try graph.addNode(&.{ .kind = .operation, .op_name = "test.right" });
    var rules = RewriteSet.init(allocator);
    defer rules.deinit();
    try rules.add(.{ .name = "merge-first", .apply = mergeFirstClass });
    var state = OptimizerState{
        .allocator = allocator,
        .ir_ctx = &context,
        .rules = &rules,
        .options = options,
        .rewriter = &rewriter,
    };
    try state.saturate(&graph);
    try std.testing.expectEqual(expected, state.stats.termination);
    try std.testing.expectEqual(iterations, state.stats.iterations);
    try std.testing.expectEqual(1, state.stats.rewrites);
    try checkOptimizationReceipt(root, state.stats);
}

fn checkOptimizationReceipt(root: *ir.Operation, stats: OptimizationStats) !void {
    const allocator = std.testing.allocator;
    const revision = @import("../product/root.zig").revision;
    const identity = revision.record.Version{ .name = "saturation-test", .version = 1 };
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .uniform(std.math.maxInt(u64)),
        .workspace = 1024 * 1024,
        .events = 16,
    }, &.{identity});
    defer ledger.destroy();
    var cache = try pass_mod.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 8);
    defer cache.deinit();
    var context = pass_mod.PassContext.init(root, root.context, allocator, &cache);
    defer context.deinit();
    const token = try ledger.begin(.pass, .{ .identity = identity, .work = .{} });
    try std.testing.expectEqual(
        stats.termination == .converged,
        observeOptimization(&context, stats),
    );
    try ledger.finish(token, .success, .{});
    const receipt = ledger.view();
    try std.testing.expectEqual(stats.rewrites, receipt.executed.counters.successful_rewrites);
    try std.testing.expectEqual(stats.iterations, receipt.executed.counters.rewrite_iterations);
    const exhausted = stats.termination != .converged;
    try std.testing.expectEqual(exhausted, receipt.outcome == .exhausted);
    try std.testing.expectEqual(exhausted, receipt.events[token].outcome == .exhausted);
}
