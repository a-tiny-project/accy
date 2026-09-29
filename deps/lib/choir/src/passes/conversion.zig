const std = @import("std");
const alloc_observe = @import("alloc_observe");
const alloc_arena = @import("alloc_arena");
const alloc_phase = @import("alloc_phase");
const ir = @import("../core/root.zig");
const rewrite = ir.rewrite;

pub const Legality = enum {
    legal,
    recursively_legal,
    dynamic,
    illegal,
    unknown,
};

pub const ConversionTarget = struct {
    allocator: std.mem.Allocator,

    legal_ops: std.StringHashMap(void),

    dynamic_ops: std.StringHashMap(*const fn (*ir.Operation) bool),

    recursively_legal_ops: std.StringHashMap(void),

    illegal_ops: std.StringHashMap(void),

    legal_dialects: std.StringHashMap(void),

    recursively_legal_dialects: std.StringHashMap(void),

    illegal_dialects: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) ConversionTarget {
        return .{
            .allocator = allocator,
            .legal_ops = std.StringHashMap(void).init(allocator),
            .dynamic_ops = std.StringHashMap(*const fn (*ir.Operation) bool).init(allocator),
            .recursively_legal_ops = std.StringHashMap(void).init(allocator),
            .illegal_ops = std.StringHashMap(void).init(allocator),
            .legal_dialects = std.StringHashMap(void).init(allocator),
            .recursively_legal_dialects = std.StringHashMap(void).init(allocator),
            .illegal_dialects = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *ConversionTarget) void {
        self.legal_ops.deinit();
        self.dynamic_ops.deinit();
        self.recursively_legal_ops.deinit();
        self.illegal_ops.deinit();
        self.legal_dialects.deinit();
        self.recursively_legal_dialects.deinit();
        self.illegal_dialects.deinit();
    }

    pub fn addLegalOp(self: *ConversionTarget, op_name: []const u8) !void {
        try self.legal_ops.put(op_name, {});
    }

    pub fn addDynamicallyLegalOp(
        self: *ConversionTarget,
        op_name: []const u8,
        predicate: *const fn (*ir.Operation) bool,
    ) !void {
        try self.dynamic_ops.put(op_name, predicate);
    }

    pub fn addRecursivelyLegalOp(self: *ConversionTarget, op_name: []const u8) !void {
        try self.recursively_legal_ops.put(op_name, {});
    }

    pub fn addIllegalOp(self: *ConversionTarget, op_name: []const u8) !void {
        try self.illegal_ops.put(op_name, {});
    }

    pub fn addLegalDialect(self: *ConversionTarget, dialect_name: []const u8) !void {
        try self.legal_dialects.put(dialect_name, {});
    }

    pub fn addRecursivelyLegalDialect(self: *ConversionTarget, dialect_name: []const u8) !void {
        try self.recursively_legal_dialects.put(dialect_name, {});
    }

    pub fn addIllegalDialect(self: *ConversionTarget, dialect_name: []const u8) !void {
        try self.illegal_dialects.put(dialect_name, {});
    }

    pub fn getOpLegality(self: *const ConversionTarget, op: *ir.Operation) Legality {
        const op_name = op.name.name;

        if (self.illegal_ops.contains(op_name)) {
            return .illegal;
        }
        if (self.legal_ops.contains(op_name)) {
            return .legal;
        }
        if (self.recursively_legal_ops.contains(op_name)) {
            return .recursively_legal;
        }
        if (self.dynamic_ops.get(op_name)) |predicate| {
            return if (predicate(op)) .legal else .illegal;
        }

        const dialect_name = op.name.getDialectNamespace();
        if (self.illegal_dialects.contains(dialect_name)) {
            return .illegal;
        }
        if (self.legal_dialects.contains(dialect_name)) {
            return .legal;
        }
        if (self.recursively_legal_dialects.contains(dialect_name)) {
            return .recursively_legal;
        }

        return .unknown;
    }

    pub fn isRecursivelyLegal(self: *const ConversionTarget, op: *ir.Operation) bool {
        return self.getOpLegality(op) == .recursively_legal;
    }

    pub fn isLegal(self: *const ConversionTarget, op: *ir.Operation) bool {
        const legality = self.getOpLegality(op);
        return legality == .legal or legality == .recursively_legal or legality == .unknown;
    }

    pub fn isIllegal(self: *const ConversionTarget, op: *ir.Operation) bool {
        return self.getOpLegality(op) == .illegal;
    }
};

pub const ConversionResult = enum {
    success,
    failure,
};

pub const ConversionOptions = struct {
    type_converter: ?*const rewrite.TypeConverter = null,
    allow_unknown_ops: ?bool = null,
    max_iterations: u32 = 100,
};

pub fn applyPartialConversion(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    op: *ir.Operation,
    target: *const ConversionTarget,
    patterns: *rewrite.RewritePatternSet,
) ConversionResult {
    return applyPartialConversionWithOptions(allocator, ir_ctx, op, target, patterns, .{});
}

pub fn applyPartialConversionWithOptions(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    op: *ir.Operation,
    target: *const ConversionTarget,
    patterns: *rewrite.RewritePatternSet,
    options: ConversionOptions,
) ConversionResult {
    patterns.seal() catch return .failure;
    var rewriter = rewrite.PatternRewriter.initWithTypeConverter(allocator, ir_ctx, options.type_converter);
    defer rewriter.deinit();

    return runConversion(&rewriter, op, target, patterns, false, options);
}

pub fn applyFullConversion(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    op: *ir.Operation,
    target: *const ConversionTarget,
    patterns: *rewrite.RewritePatternSet,
) ConversionResult {
    return applyFullConversionWithOptions(allocator, ir_ctx, op, target, patterns, .{});
}

pub fn applyFullConversionWithOptions(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    op: *ir.Operation,
    target: *const ConversionTarget,
    patterns: *rewrite.RewritePatternSet,
    options: ConversionOptions,
) ConversionResult {
    patterns.seal() catch return .failure;
    var rewriter = rewrite.PatternRewriter.initWithTypeConverter(allocator, ir_ctx, options.type_converter);
    defer rewriter.deinit();

    return runConversion(&rewriter, op, target, patterns, true, options);
}

const OperationSnapshotFacts = struct {
    context_operation_count: usize,
};

const OperationSnapshotLimits = struct {
    root_op: *ir.Operation,
    target: ?*const ConversionTarget,
    facts: OperationSnapshotFacts,

    fn inspect(
        root_op: *ir.Operation,
        target: ?*const ConversionTarget,
    ) OperationSnapshotLimits {
        return .{
            .root_op = root_op,
            .target = target,
            .facts = .{
                .context_operation_count = root_op.getContext().operationCount(),
            },
        };
    }
};

const OperationSnapshotCapacity = struct {
    facts: OperationSnapshotFacts,
    pointer_count: usize,
    storage_bytes: usize,

    pub fn derive(
        limits: OperationSnapshotLimits,
    ) error{CapacityOverflow}!OperationSnapshotCapacity {
        const storage_bytes = std.math.mul(
            usize,
            limits.facts.context_operation_count,
            @sizeOf(*ir.Operation),
        ) catch return error.CapacityOverflow;
        return .{
            .facts = limits.facts,
            .pointer_count = limits.facts.context_operation_count,
            .storage_bytes = storage_bytes,
        };
    }
};

pub const OperationSnapshot = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.conversion_initial_snapshot",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "one_pointer_slot_per_operation_tracked_by_the_root_166d4a84fb6a",
                        .lifetime = .steady,
                        .detail = "one pointer slot per operation tracked by the root Context at snapshot admission",
                    },
                },
                .excluded = &.{
                    "rewrite-created operation extension storage and pattern-rewriter state",
                    "borrowed IR, conversion targets, callbacks, and Context registry storage",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "facts_context_operation_count", "facts.context_operation_count"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(*ir.Operation, "operation"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 1,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "byte overflow, OOM, foreign-Context nesting, or snapshot capacity exhaustion rejects before conversion mutation and leaves admission retryable",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "recursive Operation.walk has no machine-closed call-graph or nesting certificate",
                },
                .foreign = .{
                    .status = .open,
                    .detail = "recursive-legality lookup may invoke a caller-provided dynamic legality predicate",
                },
            },
            .obligations = &.{
                .{ .key = "conversion_snapshot_capacity_capacity_model", .role = .capacity_model },
                .{ .key = "conversion_snapshot_capacity_overload", .role = .overload },
                .{ .key = "conversion_snapshot_sealed_reuse_transitive_risk", .role = .transitive_risk },
                .{ .key = "conversion_snapshot_sealed_reuse_foreign_risk", .role = .foreign_risk },
                .{ .key = "conversion_snapshot_context", .role = .overload },
                .{ .key = "conversion_snapshot_oom_retry", .role = .overload },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    phase: alloc_phase.capacity.Phase,
    capacity: OperationSnapshotCapacity,
    storage: []*ir.Operation,
    operation_count: usize,

    pub const Limits = OperationSnapshotLimits;
    pub const Capacity = OperationSnapshotCapacity;

    const FillContext = struct {
        root_context: *ir.Context,
        target: ?*const ConversionTarget,
        storage: []*ir.Operation,
        operation_count: usize,

        fn visit(
            self: *FillContext,
            op: *ir.Operation,
        ) error{ SnapshotCapacityExceeded, ForeignOperationContext }!ir.WalkResult {
            if (op.getContext() != self.root_context) {
                return error.ForeignOperationContext;
            }
            if (self.operation_count >= self.storage.len) {
                return error.SnapshotCapacityExceeded;
            }
            self.storage[self.operation_count] = op;
            self.operation_count = std.math.add(
                usize,
                self.operation_count,
                1,
            ) catch unreachable;
            if (self.target) |target| {
                if (target.isRecursivelyLegal(op)) return .skip;
            }
            return .advance;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        limits: OperationSnapshotLimits,
    ) !OperationSnapshot {
        const capacity = try OperationSnapshotCapacity.derive(limits);
        const storage = try allocator.alloc(*ir.Operation, capacity.pointer_count);
        errdefer allocator.free(storage);

        var fill = FillContext{
            .root_context = limits.root_op.getContext(),
            .target = limits.target,
            .storage = storage,
            .operation_count = 0,
        };
        const result = try limits.root_op.walk(
            .{ .order = .pre_order },
            &fill,
            FillContext.visit,
        );
        std.debug.assert(result == .advance);

        const snapshot = OperationSnapshot{
            .phase = .initialization,
            .capacity = capacity,
            .storage = storage,
            .operation_count = fill.operation_count,
        };
        snapshot.assertInvariant();
        return snapshot;
    }

    pub fn activate(self: *OperationSnapshot) void {
        if (self.phase != .initialization) {
            @panic("conversion operation snapshot activation is one-way");
        }
        self.phase = .steady;
        self.assertInvariant();
    }

    fn operations(self: *const OperationSnapshot) []const *ir.Operation {
        if (self.phase != .steady) {
            @panic("conversion operation snapshot is not active");
        }
        self.assertInvariant();
        return self.storage[0..self.operation_count];
    }

    pub fn deinit(
        self: *OperationSnapshot,
        allocator: std.mem.Allocator,
    ) void {
        if (self.phase == .teardown) {
            @panic("conversion operation snapshot teardown is terminal");
        }
        self.assertInvariant();
        self.phase = .teardown;
        allocator.free(self.storage);
        self.storage = undefined;
        self.operation_count = undefined;
    }

    fn assertInvariant(self: *const OperationSnapshot) void {
        std.debug.assert(self.phase != .teardown);
        std.debug.assert(self.storage.len == self.capacity.pointer_count);
        std.debug.assert(self.capacity.storage_bytes ==
            self.capacity.pointer_count * @sizeOf(*ir.Operation));
        std.debug.assert(self.operation_count <= self.storage.len);
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(OperationSnapshot);
}

fn collectNestedOps(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    target: ?*const ConversionTarget,
    worklist: *std.ArrayListUnmanaged(*ir.Operation),
) !void {
    var context = CollectNestedOpsContext{
        .allocator = allocator,
        .target = target,
        .worklist = worklist,
    };
    _ = try op.walk(.{ .order = .pre_order }, &context, CollectNestedOpsContext.visit);
}

const CollectNestedOpsContext = struct {
    allocator: std.mem.Allocator,
    target: ?*const ConversionTarget,
    worklist: *std.ArrayListUnmanaged(*ir.Operation),

    fn visit(self: *CollectNestedOpsContext, op: *ir.Operation) !ir.WalkResult {
        try self.worklist.append(self.allocator, op);
        if (self.target) |target| {
            if (target.isRecursivelyLegal(op)) return .skip;
        }
        return .advance;
    }
};

const ConversionWorklist = struct {
    initial: OperationSnapshot,
    created: std.ArrayListUnmanaged(*ir.Operation),

    fn init(
        allocator: std.mem.Allocator,
        root_op: *ir.Operation,
        target: ?*const ConversionTarget,
    ) !ConversionWorklist {
        var initial = try OperationSnapshot.init(
            allocator,
            OperationSnapshotLimits.inspect(root_op, target),
        );
        initial.activate();
        return .{
            .initial = initial,
            .created = .empty,
        };
    }

    fn deinit(
        self: *ConversionWorklist,
        allocator: std.mem.Allocator,
    ) void {
        self.created.deinit(allocator);
        self.initial.deinit(allocator);
    }

    fn len(self: *const ConversionWorklist) usize {
        return std.math.add(
            usize,
            self.initial.operations().len,
            self.created.items.len,
        ) catch unreachable;
    }

    fn get(
        self: *const ConversionWorklist,
        index: usize,
    ) *ir.Operation {
        const initial = self.initial.operations();
        std.debug.assert(index < self.len());
        if (index < initial.len) return initial[index];
        return self.created.items[index - initial.len];
    }

    fn appendNested(
        self: *ConversionWorklist,
        allocator: std.mem.Allocator,
        op: *ir.Operation,
        target: ?*const ConversionTarget,
    ) !void {
        try collectNestedOps(allocator, op, target, &self.created);
    }
};

fn opTypesLegal(op: *ir.Operation, converter: *const rewrite.TypeConverter) bool {
    for (op.operands.items) |operand| {
        if (!converter.isTypeLegal(operand.value.type)) return false;
    }

    for (op.results.items) |*result| {
        if (!converter.isTypeLegal(result.type)) return false;
    }

    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            for (block.arguments.items) |arg| {
                if (!converter.isTypeLegal(arg.type)) return false;
            }
        }
    }

    return true;
}

fn resolveAllowUnknownOps(options: ConversionOptions, require_full: bool) bool {
    return options.allow_unknown_ops orelse !require_full;
}

fn isOpLegal(target: *const ConversionTarget, op: *ir.Operation, options: ConversionOptions, allow_unknown_ops: bool) bool {
    const legality = target.getOpLegality(op);
    const base_legal = switch (legality) {
        .legal => true,
        .recursively_legal => true,
        .illegal => false,
        .unknown => allow_unknown_ops,
        .dynamic => allow_unknown_ops,
    };
    if (!base_legal) return false;

    if (options.type_converter) |converter| {
        if (!opTypesLegal(op, converter)) return false;
    }

    return true;
}

fn mustLegalizeOp(target: *const ConversionTarget, op: *ir.Operation, allow_unknown_ops: bool, require_full: bool) bool {
    if (require_full) return true;
    return switch (target.getOpLegality(op)) {
        .illegal => true,
        .unknown, .dynamic => !allow_unknown_ops,
        .legal, .recursively_legal => false,
    };
}

fn runConversion(
    rewriter: *rewrite.PatternRewriter,
    root_op: *ir.Operation,
    target: *const ConversionTarget,
    patterns: *const rewrite.RewritePatternSet,
    require_full: bool,
    options: ConversionOptions,
) ConversionResult {
    var worklist = ConversionWorklist.init(
        rewriter.allocator,
        root_op,
        target,
    ) catch return .failure;
    defer worklist.deinit(rewriter.allocator);

    var changed = true;
    var iterations: u32 = 0;
    const max_iterations: u32 = if (options.max_iterations == 0) std.math.maxInt(u32) else options.max_iterations;
    const allow_unknown_ops = resolveAllowUnknownOps(options, require_full);

    while (changed and iterations < max_iterations) {
        changed = false;
        iterations += 1;

        const initial_worklist_len = worklist.len();

        var i: usize = 0;
        while (i < initial_worklist_len) {
            const op = worklist.get(i);

            if (rewriter.isScheduledForErase(op)) {
                i += 1;
                continue;
            }

            if (isOpLegal(target, op, options, allow_unknown_ops)) {
                i += 1;
                continue;
            }

            var pattern_applied = false;
            for (patterns.getMatchingPatterns(op)) |pattern| {
                if (pattern.matchesAfterRoot(op)) {
                    const created_before = rewriter.created_ops.items.len;

                    const result = blk: {
                        var guard = rewriter.insertionGuard();
                        defer guard.deinit();
                        rewriter.setInsertionPointBefore(op);
                        break :blk pattern.apply(op, rewriter);
                    };
                    if (result == .success) {
                        pattern_applied = true;
                        changed = true;

                        for (rewriter.created_ops.items[created_before..]) |new_op| {
                            worklist.appendNested(
                                rewriter.allocator,
                                new_op,
                                target,
                            ) catch return .failure;
                        }
                        break;
                    }
                }
            }

            if (!pattern_applied and mustLegalizeOp(target, op, allow_unknown_ops, require_full)) {
                return .failure;
            }

            i += 1;
        }
    }

    const hit_iteration_limit = changed and iterations >= max_iterations;
    if (require_full and hit_iteration_limit) {
        var work_index: usize = 0;
        while (work_index < worklist.len()) : (work_index += 1) {
            const work_op = worklist.get(work_index);
            if (rewriter.isScheduledForErase(work_op)) continue;
            if (!isOpLegal(target, work_op, options, allow_unknown_ops)) return .failure;
        }
    }

    rewriter.finalize(root_op);
    return .success;
}

pub const GreedyRewriteStrictness = enum {
    existing_ops,
    existing_and_new_ops,
};

pub const GreedyRewriteConfig = struct {
    max_iterations: u32 = 10,
    max_rewrites: u32 = 0,
    strictness: GreedyRewriteStrictness = .existing_and_new_ops,
};

const GreedyRewriteTermination = enum {
    converged,
    iteration_limit,
    rewrite_limit,
    invalid_context,
    invalid_patterns,
};

pub const GreedyRewriteResult = struct {
    termination: Termination,
    changed: bool = false,
    /// Traversals begun, including the converging or interrupted traversal.
    iterations: u32 = 0,
    rewrites: u32 = 0,

    pub const Termination: type = GreedyRewriteTermination;
};

const GreedyRewriteIterationStorage = struct {
    pub const inline_bytes: usize = 2 * 1024;

    buffer: [inline_bytes]u8 = undefined,
    fallback_allocator: std.mem.Allocator,
    stack_fallback: alloc_observe.buffer.First = undefined,

    fn init(fallback_allocator: std.mem.Allocator) GreedyRewriteIterationStorage {
        return .{ .fallback_allocator = fallback_allocator };
    }

    fn allocator(self: *GreedyRewriteIterationStorage) std.mem.Allocator {
        self.stack_fallback = .init(&self.buffer, self.fallback_allocator);
        return self.stack_fallback.allocator();
    }
};

fn GreedyRewriteWalk(comptime PatternSource: type) type {
    return struct {
        source: *PatternSource,
        rewriter: *rewrite.PatternRewriter,
        creation_boundary: u31,
        rewrite_limit: u32,
        rewrites: *u32,
        changed: bool = false,
        limit_reached: bool = false,
        invalid_context: bool = false,

        const Self = @This();

        fn visit(self: *Self, op: *ir.Operation) ir.WalkResult {
            if (op.getContext() != self.rewriter.ir_ctx) {
                self.invalid_context = true;
                return .interrupt;
            }
            if (!op.createdBefore(self.creation_boundary)) return .skip;
            if (self.rewriter.isScheduledForErase(op)) return .advance;

            if (self.source.applyFirstMatchingPattern(op, self.rewriter)) {
                self.changed = true;
                self.rewrites.* += 1;
                if (self.rewrites.* >= self.rewrite_limit) {
                    self.limit_reached = true;
                    return .interrupt;
                }
            }
            return .advance;
        }

        fn apply(self: *Self, op: *ir.Operation) bool {
            const result = op.walk(.{ .order = .pre_order }, self, visit) catch unreachable;
            return result == .advance;
        }

        fn assertInterrupted(self: *const Self) void {
            if (self.limit_reached) return;
            std.debug.assert(self.invalid_context);
        }
    };
}

pub fn applyPatternsGreedily(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    root_op: *ir.Operation,
    patterns: *rewrite.RewritePatternSet,
    config: GreedyRewriteConfig,
) GreedyRewriteResult {
    patterns.seal() catch return .{ .termination = .invalid_patterns };

    return applyPatternsGreedilyFromSource(
        allocator,
        ir_ctx,
        root_op,
        patterns,
        config,
    );
}

pub fn applyPatternsGreedilyFromSource(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    root_op: *ir.Operation,
    source: anytype,
    config: GreedyRewriteConfig,
) GreedyRewriteResult {
    const PatternSource = @TypeOf(source.*);
    const Walk = GreedyRewriteWalk(PatternSource);
    const iteration_limit = if (config.max_iterations == 0) std.math.maxInt(u32) else config.max_iterations;
    const rewrite_limit = if (config.max_rewrites == 0) std.math.maxInt(u32) else config.max_rewrites;

    var result = GreedyRewriteResult{ .termination = .iteration_limit };

    while (result.iterations < iteration_limit) {
        result.iterations += 1;
        var rewrite_storage = GreedyRewriteIterationStorage.init(allocator);
        var rewriter = rewrite.PatternRewriter.init(rewrite_storage.allocator(), ir_ctx);
        defer rewriter.deinit();
        defer rewriter.finalize(root_op);

        const process_new_ops = config.strictness == .existing_and_new_ops;
        var walk = Walk{
            .source = source,
            .rewriter = &rewriter,
            .creation_boundary = ir_ctx.operationCreationBoundary(),
            .rewrite_limit = rewrite_limit,
            .rewrites = &result.rewrites,
        };
        if (!walk.apply(root_op)) {
            walk.assertInterrupted();
            result.changed = result.changed or walk.changed;
            result.termination = if (walk.limit_reached) .rewrite_limit else .invalid_context;
            return result;
        }

        if (process_new_ops) {
            var created_index: usize = 0;
            while (created_index < rewriter.created_ops.items.len) : (created_index += 1) {
                walk.creation_boundary = ir_ctx.operationCreationBoundary();
                if (!walk.apply(rewriter.created_ops.items[created_index])) {
                    walk.assertInterrupted();
                    result.changed = result.changed or walk.changed;
                    result.termination = if (walk.limit_reached) .rewrite_limit else .invalid_context;
                    return result;
                }
            }
        }

        result.changed = result.changed or walk.changed;
        if (!walk.changed) {
            result.termination = .converged;
            return result;
        }
    }

    return result;
}

test "conversion target" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var target = ConversionTarget.init(allocator);
    defer target.deinit();

    try target.addLegalDialect("wasm");

    try target.addIllegalDialect("arith");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();

    var ctx = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer ctx.deinit(arena.allocator());
    try ctx.allowUnregistered();

    const state = ir.Operation.State.init("arith.addi", ir.Location.getUnknown());
    const op = try ctx.createOperation(state);

    try testing.expect(target.isIllegal(op));

    try target.addLegalOp("arith.addi");
    try testing.expect(target.isLegal(op));
}

test "conversion target recursively legal op skips nested illegal operations" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    var parent_state = ir.Operation.State.init("test.container", loc);
    parent_state.addRegion();
    const parent = try ctx.createOperation(parent_state);
    const block = try (parent.getRegion(0) orelse return error.TestExpectedRegion).addBlock();

    const child_state = ir.Operation.State.init("test.child", loc);
    const child = try ctx.createOperation(child_state);
    try block.addOperation(child);

    var target = ConversionTarget.init(allocator);
    defer target.deinit();
    try target.addRecursivelyLegalOp("test.container");
    try target.addIllegalOp("test.child");
    try testing.expect(target.isRecursivelyLegal(parent));
    try testing.expect(target.isIllegal(child));

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();

    try testing.expectEqual(
        ConversionResult.success,
        applyFullConversion(allocator, &ctx, parent, &target, &patterns),
    );
}

test "conversion modes distinguish unknown and illegal operations" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var target = ConversionTarget.init(allocator);
    defer target.deinit();

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();

    const loc = ir.Location.getUnknown();

    const partial_unknown = try ctx.createOperation(ir.Operation.State.init("test.unknown", loc));
    try testing.expectEqual(
        ConversionResult.success,
        applyPartialConversion(allocator, &ctx, partial_unknown, &target, &patterns),
    );

    const full_unknown = try ctx.createOperation(ir.Operation.State.init("test.unknown", loc));
    try testing.expectEqual(
        ConversionResult.failure,
        applyFullConversion(allocator, &ctx, full_unknown, &target, &patterns),
    );

    const explicitly_allowed = try ctx.createOperation(ir.Operation.State.init("test.unknown", loc));
    try testing.expectEqual(
        ConversionResult.success,
        applyFullConversionWithOptions(
            allocator,
            &ctx,
            explicitly_allowed,
            &target,
            &patterns,
            .{ .allow_unknown_ops = true },
        ),
    );

    try target.addIllegalOp("test.illegal");
    const partial_illegal = try ctx.createOperation(ir.Operation.State.init("test.illegal", loc));
    try testing.expectEqual(
        ConversionResult.failure,
        applyPartialConversion(allocator, &ctx, partial_illegal, &target, &patterns),
    );
}

fn checkGreedyEraseIterationStorage(
    operation_count: usize,
    fail_index: usize,
    expected_allocations: usize,
    expected_allocated_bytes: usize,
    expected_failure: bool,
) !void {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const module_op = try test_dialect.TestDialect.ModuleOp.create(
        &ctx,
        .unknown,
    );
    const module_block = module_op.getBodyBlock();
    var builder = ir.OperationBuilder.init(&ctx);
    for (0..operation_count) |_| {
        try module_block.addOperation(try builder.create(
            ir.Operation.State.init("test.source", .unknown),
        ));
    }

    var patterns = rewrite.RewritePatternSet.init(testing.allocator);
    defer patterns.deinit();
    try patterns.add(rewrite.RewritePattern.init(
        testRewriteSpec("test.source", 1),
        dummyRewrite,
    ));
    try patterns.seal();

    var failing = testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = fail_index },
    );
    const result = applyPatternsGreedily(
        failing.allocator(),
        &ctx,
        module_op.op,
        &patterns,
        .{},
    );
    try testing.expectEqual(.converged, result.termination);
    try testing.expect(result.changed);
    try testing.expectEqual(expected_allocations, failing.alloc_index);
    try testing.expectEqual(expected_allocated_bytes, failing.allocated_bytes);
    try testing.expectEqual(expected_failure, failing.has_induced_failure);
    var remaining = module_block.getOperations();
    try testing.expect(remaining.next() == null);
}

fn rewriteToLow(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    const state = ir.Operation.State.init("test.low", op.location);
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteToHigh(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    const state = ir.Operation.State.init("test.high", op.location);
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn matchNever(_: *ir.Operation) bool {
    return false;
}

fn rewriteAToB(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    const state = ir.Operation.State.init("test.b", op.location);
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteBToC(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    const state = ir.Operation.State.init("test.c", op.location);
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteInsertBeforeFutureOp(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    const middle = op.next_op orelse return .failure;
    const future = middle.next_op orelse return .failure;
    rewriter.setInsertionPointBefore(future);
    _ = rewriter.create(ir.Operation.State.init("test.new", op.location)) catch return .failure;
    rewriter.eraseOp(op) catch return .failure;
    return .success;
}

fn checkOperationSnapshotInitFailures(
    allocator: std.mem.Allocator,
    root_op: *ir.Operation,
) !void {
    var snapshot = try OperationSnapshot.init(
        allocator,
        OperationSnapshotLimits.inspect(root_op, null),
    );
    defer snapshot.deinit(allocator);
    snapshot.activate();
    try std.testing.expect(snapshot.operations().len > 0);
}

test "conversion snapshot derives pointer capacity from the authoritative Context registry" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(OperationSnapshot, "conversion_snapshot_capacity_capacity_model"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(OperationSnapshot, "conversion_snapshot_capacity_overload"),
        );
    }

    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const func_op = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "nested_ops", &.{ i32_type, i32_type });
    try module_block.addOperation(func_op.op);

    const func_block = func_op.getEntryBlock();
    const func_args = func_op.getArguments();
    const arg0 = func_args[0];
    const arg1 = func_args[1];

    const binary1_op = try test_dialect.TestDialect.BinaryOp.create(&ctx, loc, arg0, arg1);
    try func_block.addOperation(binary1_op.op);

    const binary2_op = try test_dialect.TestDialect.BinaryOp.create(&ctx, loc, arg0, arg1);
    try func_block.addOperation(binary2_op.op);

    _ = try ctx.createOperation(ir.Operation.State.init("test.detached", loc));

    const limits = OperationSnapshotLimits.inspect(module_op.op, null);
    try testing.expectEqual(ctx.operationCount(), limits.facts.context_operation_count);
    try testing.expectEqual(@as(usize, 5), limits.facts.context_operation_count);
    const capacity = try OperationSnapshotCapacity.derive(limits);
    try testing.expectEqual(@as(usize, 5), capacity.pointer_count);
    try testing.expectEqual(
        capacity.pointer_count * @sizeOf(*ir.Operation),
        capacity.storage_bytes,
    );

    var snapshot = try OperationSnapshot.init(testing.allocator, limits);
    defer snapshot.deinit(testing.allocator);
    snapshot.activate();
    const operations = snapshot.operations();
    try testing.expectEqual(@as(usize, 4), operations.len);
    try testing.expectEqual(@as(usize, 5), snapshot.storage.len);

    try testing.expectEqualStrings("test.module", operations[0].name.name);
    try testing.expectEqualStrings("test.func", operations[1].name.name);
    try testing.expectEqualStrings("test.binary", operations[2].name.name);
    try testing.expectEqualStrings("test.binary", operations[3].name.name);

    const maximum_pointer_count = std.math.maxInt(usize) / @sizeOf(*ir.Operation);
    var boundary_limits = limits;
    boundary_limits.facts.context_operation_count = maximum_pointer_count;
    const maximum = try OperationSnapshotCapacity.derive(boundary_limits);
    try testing.expectEqual(
        maximum_pointer_count * @sizeOf(*ir.Operation),
        maximum.storage_bytes,
    );
    boundary_limits.facts.context_operation_count = maximum_pointer_count + 1;
    try testing.expectError(
        error.CapacityOverflow,
        OperationSnapshotCapacity.derive(boundary_limits),
    );
}

test "conversion snapshot reuses fixed backing throughout steady traversal" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(OperationSnapshot, "conversion_snapshot_sealed_reuse_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(OperationSnapshot, "conversion_snapshot_sealed_reuse_foreign_risk"),
        );
    }

    const testing = std.testing;
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const root_op = try ctx.createOperation(
        ir.Operation.State.init("test.snapshot", .unknown),
    );
    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(testing.allocator);
    var maybe_snapshot: ?OperationSnapshot = null;
    errdefer {
        if (phase_allocator.phase() == .initialization) {
            phase_allocator.abortInitialization();
        }
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (maybe_snapshot) |*snapshot| {
            if (snapshot.phase != .teardown) {
                snapshot.deinit(phase_allocator.teardownAllocator());
            }
        }
        if (phase_allocator.phase() == .teardown) phase_allocator.deinit();
    }

    maybe_snapshot = try OperationSnapshot.init(
        phase_allocator.initializationAllocator(),
        OperationSnapshotLimits.inspect(root_op, null),
    );
    const snapshot = &maybe_snapshot.?;
    const storage_pointer = snapshot.storage.ptr;
    phase_allocator.seal();
    snapshot.activate();

    for (0..64) |_| {
        const operations = snapshot.operations();
        try testing.expectEqual(@as(usize, 1), operations.len);
        try testing.expectEqual(root_op, operations[0]);
        try testing.expectEqual(storage_pointer, operations.ptr);
    }
    try testing.expectEqual(
        alloc_phase.PhaseViolations{},
        phase_allocator.violations(),
    );

    phase_allocator.beginTeardown();
    snapshot.deinit(phase_allocator.teardownAllocator());
    maybe_snapshot = null;
    try testing.expectEqual(
        alloc_phase.PhaseViolations{},
        phase_allocator.violations(),
    );
    phase_allocator.deinit();
}

test "conversion snapshot rejects foreign Context nesting before activation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(OperationSnapshot, "conversion_snapshot_context"),
        );
    }

    const test_dialect = @import("../dialects/fixture/root.zig");
    var root_context = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer root_context.deinit(std.testing.allocator);
    try root_context.allowUnregistered();
    var foreign_context = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer foreign_context.deinit(std.testing.allocator);
    try foreign_context.allowUnregistered();

    const module_op = try test_dialect.TestDialect.ModuleOp.create(
        &root_context,
        .unknown,
    );
    const foreign_op = try foreign_context.createOperation(
        ir.Operation.State.init("test.foreign", .unknown),
    );
    try module_op.getBodyBlock().addOperation(foreign_op);
    defer module_op.getBodyBlock().detachOperation(foreign_op);

    try std.testing.expectError(
        error.ForeignOperationContext,
        OperationSnapshot.init(
            std.testing.allocator,
            OperationSnapshotLimits.inspect(module_op.op, null),
        ),
    );
}

test "conversion snapshot initialization survives every allocation failure" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(OperationSnapshot, "conversion_snapshot_oom_retry"),
        );
    }

    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try ctx.allowUnregistered();
    const root_op = try ctx.createOperation(
        ir.Operation.State.init("test.snapshot", .unknown),
    );

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkOperationSnapshotInitFailures,
        .{root_op},
    );
    try checkOperationSnapshotInitFailures(std.testing.allocator, root_op);
}

test "applyFullConversion converts nested illegal ops" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    _ = try module_block.addArgument(i32_type, loc);
    _ = try module_block.addArgument(i32_type, loc);
    const arg0 = module_block.arguments.items[0];
    const arg1 = module_block.arguments.items[1];

    const binary_op = try test_dialect.TestDialect.BinaryOp.create(&ctx, loc, arg0, arg1);
    try module_block.addOperation(binary_op.op);

    var target = ConversionTarget.init(allocator);
    defer target.deinit();
    try target.addIllegalOp("test.binary");
    try target.addLegalDialect("test");

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();

    const result = applyFullConversion(allocator, &ctx, module_op.op, &target, &patterns);
    try testing.expectEqual(ConversionResult.failure, result);
}

test "applyFullConversion succeeds when nested ops converted" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    _ = try module_block.addArgument(i32_type, loc);
    _ = try module_block.addArgument(i32_type, loc);
    const arg0 = module_block.arguments.items[0];
    const arg1 = module_block.arguments.items[1];

    const binary_op = try test_dialect.TestDialect.BinaryOp.create(&ctx, loc, arg0, arg1);
    try module_block.addOperation(binary_op.op);

    var target = ConversionTarget.init(allocator);
    defer target.deinit();
    try target.addIllegalOp("test.binary");
    try target.addLegalDialect("test");

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.binary", 1), dummyRewrite));

    const result = applyFullConversion(allocator, &ctx, module_op.op, &target, &patterns);
    try testing.expectEqual(ConversionResult.success, result);
}

test "applyFullConversion fails when type conversion required" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    const i64_type = try test_dialect.TestDialect.getI64Type(&ctx);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();
    const const_op = try test_dialect.TestDialect.ConstantOp.create(&ctx, loc, i32_type, 7);
    try module_block.addOperation(const_op.op);

    var target = ConversionTarget.init(allocator);
    defer target.deinit();
    try target.addLegalDialect("test");

    var converter = rewrite.TypeConverter.init(allocator);
    defer converter.deinit();
    try converter.addConversion(i32_type, &.{i64_type});

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();

    const result = applyFullConversionWithOptions(
        allocator,
        &ctx,
        module_op.op,
        &target,
        &patterns,
        .{ .type_converter = &converter },
    );
    try testing.expectEqual(ConversionResult.failure, result);
}

test "applyFullConversion converts types with pattern" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    const Helpers = struct {
        fn rewriteConstantWithConvertedType(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
            const td = @import("../dialects/fixture/root.zig");
            const converter = rewriter.getTypeConverter() orelse return .failure;
            const result = op.getResult(0) orelse return .failure;
            const converted_types = converter.convertType(result.type) orelse return .failure;
            if (converted_types.len != 1) return .failure;
            const new_type = converted_types[0];

            const const_op = td.TestDialect.ConstantOp{ .op = op };
            const value = const_op.getValue() orelse return .failure;
            const value_attr = td.TestDialect.getIntegerAttr(rewriter.ir_ctx, value) catch return .failure;

            var state = ir.Operation.State.init(td.TestDialect.ConstantOp.operation_name, op.location);
            state.addTypes(&.{new_type});
            state.addAttributes(&.{.{ .name = "value", .value = value_attr }});

            _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
            return .success;
        }
    };

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    const i64_type = try test_dialect.TestDialect.getI64Type(&ctx);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();
    const const_op = try test_dialect.TestDialect.ConstantOp.create(&ctx, loc, i32_type, 11);
    try module_block.addOperation(const_op.op);

    var target = ConversionTarget.init(allocator);
    defer target.deinit();
    try target.addLegalDialect("test");

    var converter = rewrite.TypeConverter.init(allocator);
    defer converter.deinit();
    try converter.addConversion(i32_type, &.{i64_type});

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.constant", 1), Helpers.rewriteConstantWithConvertedType));

    const result = applyFullConversionWithOptions(
        allocator,
        &ctx,
        module_op.op,
        &target,
        &patterns,
        .{ .type_converter = &converter },
    );
    try testing.expectEqual(ConversionResult.success, result);

    const head_op: *ir.Operation = @ptrCast(@alignCast(module_block.operations.head.?));
    const result_type = head_op.getResult(0).?.type;
    try testing.expect(result_type.eql(i64_type));
}

test "applyFullConversion respects max_iterations" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    const loc = ir.Location.getUnknown();

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ctx.deinit(allocator);
        try ctx.allowUnregistered();

        const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
        const module_block = module_op.getBodyBlock();

        var builder = ir.OperationBuilder.init(&ctx);
        const state = ir.Operation.State.init("test.a", loc);
        const op = try builder.create(state);
        try module_block.addOperation(op);

        var target = ConversionTarget.init(allocator);
        defer target.deinit();
        try target.addLegalDialect("test");
        try target.addIllegalOp("test.a");
        try target.addIllegalOp("test.b");

        var patterns = rewrite.RewritePatternSet.init(allocator);
        defer patterns.deinit();
        try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.a", 1), rewriteAToB));
        try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.b", 1), rewriteBToC));

        const result = applyFullConversionWithOptions(
            allocator,
            &ctx,
            module_op.op,
            &target,
            &patterns,
            .{ .max_iterations = 1 },
        );
        try testing.expectEqual(ConversionResult.failure, result);

        const head_op: *ir.Operation = @ptrCast(@alignCast(module_block.operations.head.?));
        try testing.expectEqualStrings("test.b", head_op.name.name);
    }

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ctx.deinit(allocator);
        try ctx.allowUnregistered();

        const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
        const module_block = module_op.getBodyBlock();

        var builder = ir.OperationBuilder.init(&ctx);
        const state = ir.Operation.State.init("test.a", loc);
        const op = try builder.create(state);
        try module_block.addOperation(op);

        var target = ConversionTarget.init(allocator);
        defer target.deinit();
        try target.addLegalDialect("test");
        try target.addIllegalOp("test.a");
        try target.addIllegalOp("test.b");

        var patterns = rewrite.RewritePatternSet.init(allocator);
        defer patterns.deinit();
        try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.a", 1), rewriteAToB));
        try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.b", 1), rewriteBToC));

        const result = applyFullConversionWithOptions(
            allocator,
            &ctx,
            module_op.op,
            &target,
            &patterns,
            .{ .max_iterations = 2 },
        );
        try testing.expectEqual(ConversionResult.success, result);

        const head_op: *ir.Operation = @ptrCast(@alignCast(module_block.operations.head.?));
        try testing.expectEqualStrings("test.c", head_op.name.name);
    }
}

test "applyPatternsGreedily prefers higher benefit patterns" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    const state = ir.Operation.State.init("test.source", loc);
    const op = try builder.create(state);
    try module_block.addOperation(op);

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.source", 1), rewriteToLow));
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.source", 10), rewriteToHigh));

    const result = applyPatternsGreedily(
        allocator,
        &ctx,
        module_op.op,
        &patterns,
        .{},
    );
    try testing.expectEqual(.converged, result.termination);
    try testing.expect(result.changed);

    const head_op: *ir.Operation = @ptrCast(@alignCast(module_block.operations.head.?));
    try testing.expectEqualStrings("test.high", head_op.name.name);
}

test "applyPatternsGreedily honors pattern match predicates" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    const state = ir.Operation.State.init("test.source", loc);
    const op = try builder.create(state);
    try module_block.addOperation(op);

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();
    try patterns.add(rewrite.RewritePattern.initWithMatch(testRewriteSpec("test.source", 10), matchNever, rewriteToHigh));
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.source", 1), rewriteToLow));

    const result = applyPatternsGreedily(
        allocator,
        &ctx,
        module_op.op,
        &patterns,
        .{},
    );
    try testing.expectEqual(.converged, result.termination);
    try testing.expect(result.changed);

    const head_op: *ir.Operation = @ptrCast(@alignCast(module_block.operations.head.?));
    try testing.expectEqualStrings("test.low", head_op.name.name);
}

test "greedy rewrite iteration storage has an exact erase boundary and fallback" {
    try std.testing.expectEqual(
        @as(usize, 2 * 1024),
        GreedyRewriteIterationStorage.inline_bytes,
    );
    try checkGreedyEraseIterationStorage(227, 0, 0, 0, false);
    try checkGreedyEraseIterationStorage(228, 1, 1, 2_864, false);
    try checkGreedyEraseIterationStorage(228, 0, 0, 0, true);
}

test "applyPatternsGreedily default rewrite budget handles large modules" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    for (0..1024) |_| {
        const op = try builder.create(ir.Operation.State.init("test.source", loc));
        try module_block.addOperation(op);
    }

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.source", 1), rewriteToHigh));

    const result = applyPatternsGreedily(
        allocator,
        &ctx,
        module_op.op,
        &patterns,
        .{},
    );
    try testing.expectEqual(.converged, result.termination);
    try testing.expect(result.changed);

    var iter = module_block.getOperations();
    while (iter.next()) |op| {
        try testing.expectEqualStrings("test.high", op.name.name);
    }
}

test "applyPatternsGreedily borrows unchanged operation traversal" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    for (0..128) |_| {
        const op = try builder.create(ir.Operation.State.init("test.source", loc));
        try module_block.addOperation(op);
    }

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.other", 1), dummyRewrite));
    try patterns.seal();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const result = applyPatternsGreedily(
        failing.allocator(),
        &ctx,
        module_op.op,
        &patterns,
        .{},
    );
    try testing.expectEqual(.converged, result.termination);
    try testing.expect(!result.changed);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "applyPatternsGreedily excludes new operations encountered ahead" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    inline for (&.{ "test.seed", "test.middle", "test.future" }) |name| {
        try module_block.addOperation(try builder.create(ir.Operation.State.init(name, loc)));
    }

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();
    try patterns.add(rewrite.RewritePattern.init(
        testRewriteSpec("test.seed", 1),
        rewriteInsertBeforeFutureOp,
    ));
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.new", 1), rewriteToHigh));
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.middle", 1), rewriteToHigh));
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.future", 1), rewriteToHigh));

    const result = applyPatternsGreedily(
        allocator,
        &ctx,
        module_op.op,
        &patterns,
        .{
            .max_iterations = 1,
            .strictness = .existing_ops,
        },
    );
    try testing.expectEqual(.iteration_limit, result.termination);
    try testing.expect(result.changed);
    try expectRewriterBlockNames(module_block, &.{ "test.high", "test.new", "test.high" });
}

test "applyPatternsGreedily rejects foreign Context nesting" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var root_context = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer root_context.deinit(testing.allocator);
    try root_context.allowUnregistered();
    var foreign_context = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer foreign_context.deinit(testing.allocator);
    try foreign_context.allowUnregistered();

    const module_op = try test_dialect.TestDialect.ModuleOp.create(
        &root_context,
        .unknown,
    );
    const module_block = module_op.getBodyBlock();
    const foreign_op = try foreign_context.createOperation(
        ir.Operation.State.init("test.foreign", .unknown),
    );
    try module_block.addOperation(foreign_op);
    defer module_block.detachOperation(foreign_op);
    const source_op = try root_context.createOperation(
        ir.Operation.State.init("test.source", .unknown),
    );
    try module_block.addOperation(source_op);

    var patterns = rewrite.RewritePatternSet.init(testing.allocator);
    defer patterns.deinit();
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.source", 1), rewriteToHigh));

    const result = applyPatternsGreedily(
        testing.allocator,
        &root_context,
        module_op.op,
        &patterns,
        .{},
    );
    try testing.expectEqual(.invalid_context, result.termination);
    try testing.expect(!result.changed);
    try testing.expectEqual(1, result.iterations);
    try testing.expectEqual(0, result.rewrites);
    try expectRewriterBlockNames(module_block, &.{ "test.foreign", "test.source" });
    module_block.detachOperation(foreign_op);
    try module_block.addOperation(foreign_op);
    const after_mutation = applyPatternsGreedily(
        testing.allocator,
        &root_context,
        module_op.op,
        &patterns,
        .{},
    );
    try testing.expectEqualDeep(GreedyRewriteResult{
        .termination = .invalid_context,
        .changed = true,
        .iterations = 1,
        .rewrites = 1,
    }, after_mutation);
    try expectRewriterBlockNames(module_block, &.{ "test.high", "test.foreign" });
}

test "applyPatternsGreedily strictness controls new op processing" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ctx.deinit(allocator);
        try ctx.allowUnregistered();

        const loc = ir.Location.getUnknown();
        const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
        const module_block = module_op.getBodyBlock();

        var builder = ir.OperationBuilder.init(&ctx);
        const state = ir.Operation.State.init("test.a", loc);
        const op = try builder.create(state);
        try module_block.addOperation(op);

        var patterns = rewrite.RewritePatternSet.init(allocator);
        defer patterns.deinit();
        try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.a", 1), rewriteAToB));
        try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.b", 1), rewriteBToC));

        const result = applyPatternsGreedily(
            allocator,
            &ctx,
            module_op.op,
            &patterns,
            .{
                .max_iterations = 1,
                .strictness = .existing_ops,
            },
        );
        try testing.expectEqual(.iteration_limit, result.termination);
        try testing.expect(result.changed);

        const head_op: *ir.Operation = @ptrCast(@alignCast(module_block.operations.head.?));
        try testing.expectEqualStrings("test.b", head_op.name.name);
    }

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ctx.deinit(allocator);
        try ctx.allowUnregistered();

        const loc = ir.Location.getUnknown();
        const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
        const module_block = module_op.getBodyBlock();

        var builder = ir.OperationBuilder.init(&ctx);
        const state = ir.Operation.State.init("test.a", loc);
        const op = try builder.create(state);
        try module_block.addOperation(op);

        var patterns = rewrite.RewritePatternSet.init(allocator);
        defer patterns.deinit();
        try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.a", 1), rewriteAToB));
        try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.b", 1), rewriteBToC));

        const result = applyPatternsGreedily(
            allocator,
            &ctx,
            module_op.op,
            &patterns,
            .{
                .max_iterations = 1,
                .strictness = .existing_and_new_ops,
            },
        );
        try testing.expectEqual(.iteration_limit, result.termination);
        try testing.expect(result.changed);

        const head_op: *ir.Operation = @ptrCast(@alignCast(module_block.operations.head.?));
        try testing.expectEqualStrings("test.c", head_op.name.name);
    }
}

fn testRewriteSpec(root_op_name: []const u8, benefit: rewrite.PatternBenefit) rewrite.RewritePatternSpec {
    return .{ .name = root_op_name, .root_op_name = root_op_name, .benefit = benefit };
}

fn dummyRewrite(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    rewriter.eraseOp(op) catch return .failure;
    return .success;
}

fn expectRewriterBlockNames(block: *ir.Block, expected: []const []const u8) !void {
    var iter = block.getOperations();
    for (expected) |name| {
        const op = iter.next() orelse return error.TestExpectedOperation;
        try std.testing.expectEqualStrings(name, op.name.name);
    }
    try std.testing.expect(iter.next() == null);
}

test "applyPatternsGreedily reports exact iteration and rewrite termination" {
    try checkGreedyTermination(
        .{ .max_iterations = 1, .strictness = .existing_ops },
        .iteration_limit,
        1,
        1,
    );
    try checkGreedyTermination(
        .{ .max_iterations = 2, .strictness = .existing_ops },
        .iteration_limit,
        2,
        2,
    );
    try checkGreedyTermination(
        .{ .max_iterations = 3, .strictness = .existing_ops },
        .converged,
        3,
        2,
    );
    try checkGreedyTermination(
        .{ .max_iterations = 0, .strictness = .existing_ops },
        .converged,
        3,
        2,
    );
    try checkGreedyTermination(.{ .max_rewrites = 1 }, .rewrite_limit, 1, 1);
    try checkGreedyTermination(.{ .max_rewrites = 2 }, .rewrite_limit, 1, 2);
    try checkGreedyTermination(.{ .max_rewrites = 3 }, .converged, 2, 2);
}

fn checkGreedyTermination(
    config: GreedyRewriteConfig,
    termination: GreedyRewriteResult.Termination,
    iterations: u32,
    rewrites: u32,
) !void {
    const expected = GreedyRewriteResult{
        .termination = termination,
        .changed = true,
        .iterations = iterations,
        .rewrites = rewrites,
    };
    const fixture = @import("../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try context.allowUnregistered();
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const block = module.getBodyBlock();
    const source = try context.createOperation(ir.Operation.State.init("test.a", .unknown));
    try block.addOperation(source);
    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.a", 1), rewriteAToB));
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.b", 1), rewriteBToC));
    const result = applyPatternsGreedily(allocator, &context, module.op, &patterns, config);
    try std.testing.expectEqualDeep(expected, result);
    try expectRewriterBlockNames(block, if (expected.rewrites == 1) &.{"test.b"} else &.{"test.c"});
    const settled = applyPatternsGreedily(allocator, &context, module.op, &patterns, .{});
    try std.testing.expectEqualDeep(GreedyRewriteResult{
        .termination = .converged,
        .changed = expected.rewrites == 1,
        .iterations = if (expected.rewrites == 1) 2 else 1,
        .rewrites = if (expected.rewrites == 1) 1 else 0,
    }, settled);
}

test "applyPatternsGreedily reports pattern admission refusal before traversal" {
    const fixture = @import("../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var patterns = rewrite.RewritePatternSet.init(failing.allocator());
    defer patterns.deinit();
    try patterns.add(rewrite.RewritePattern.init(testRewriteSpec("test.a", 1), rewriteAToB));
    failing.fail_index = failing.alloc_index;
    const result = applyPatternsGreedily(allocator, &context, module.op, &patterns, .{});
    const refused = GreedyRewriteResult{ .termination = .invalid_patterns };
    try std.testing.expectEqualDeep(refused, result);
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    const retried = applyPatternsGreedily(allocator, &context, module.op, &patterns, .{});
    try std.testing.expectEqualDeep(GreedyRewriteResult{
        .termination = .converged,
        .iterations = 1,
    }, retried);
}
