const std = @import("std");
const ir = @import("../core/root.zig");
const rewrite = ir.rewrite;
const pass = @import("pass/root.zig");
const conversion = @import("conversion.zig");
const effects = @import("effects.zig");
const registry = @import("pipeline.zig");
const dialects = @import("../dialects/root.zig");

const arith = dialects.ArithDialect;
const CmpPredicate = dialects.arith.CmpPredicate;
const scf = dialects.ScfDialect;

pub const canonicalization_pass_name = "choir-canonicalize";
pub const canonicalization_pass_description =
    "Apply Choir rewrite patterns and remove trivially dead operations";

pub const PopulatePatternsFn = *const fn (*rewrite.RewritePatternSet) anyerror!void;

const RegisteredDialect = struct {
    name: []const u8,
    vtable: *const rewrite.DialectCanonicalizationInterface.VTable,
};

const InitialPatternFacts = struct {
    registered_fold_count: usize,
};

const InitialPatternLimits = struct {
    facts: InitialPatternFacts,

    const empty: InitialPatternLimits = .{
        .facts = .{ .registered_fold_count = 0 },
    };

    fn inspect(ctx: *ir.Context) error{CapacityOverflow}!InitialPatternLimits {
        var registered_fold_count: usize = 0;
        var iter = ctx.dialect_registry.operation_registry.ops.iterator();
        while (iter.next()) |entry| {
            const op_info = entry.value_ptr.*;
            if (op_info.hasInterface(ir.interfaces.FoldOpInterface.id)) {
                registered_fold_count = std.math.add(
                    usize,
                    registered_fold_count,
                    1,
                ) catch return error.CapacityOverflow;
            }
        }
        return .{
            .facts = .{ .registered_fold_count = registered_fold_count },
        };
    }
};

const InitialPatternCapacity = struct {
    pattern_count: usize,
    fold_name_count: usize,

    fn derive(
        limits: InitialPatternLimits,
        include_builtin_patterns: bool,
        include_registered_fold_patterns: bool,
    ) error{CapacityOverflow}!InitialPatternCapacity {
        const builtin_count = if (include_builtin_patterns)
            builtin_canonicalization_patterns.len
        else
            0;
        const fold_name_count = if (include_registered_fold_patterns)
            limits.facts.registered_fold_count
        else
            0;
        const pattern_count = std.math.add(
            usize,
            builtin_count,
            fold_name_count,
        ) catch return error.CapacityOverflow;
        return .{
            .pattern_count = pattern_count,
            .fold_name_count = fold_name_count,
        };
    }
};

fn byte_slice_less_than(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn registered_dialect_less_than(
    _: void,
    lhs: RegisteredDialect,
    rhs: RegisteredDialect,
) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

pub const PatternPopulationBounds = struct {
    patterns: u64,
    name_bytes: u64,
    visits: u64,
    bytes: u64,
};

/// Reservation for the default builtin/fold population, registered dialect
/// patterns, and the caller's extra specs. This only reads population inputs.
pub fn patternPopulationBounds(
    context: *ir.Context,
    extra: []const rewrite.RewritePatternSpec,
) !PatternPopulationBounds {
    const work = pass.work;
    const limits = InitialPatternLimits.inspect(context) catch return error.WorkOverflow;
    const initial = InitialPatternCapacity.derive(limits, true, true) catch return error.WorkOverflow;
    var count = try work.add(initial.pattern_count, extra.len);
    var names: u64 = 0;
    for (extra) |spec| {
        names = try work.add(names, try work.add(spec.name.len, spec.root_op_name.len));
    }
    for (builtin_canonicalization_patterns) |pattern| {
        names = try work.add(names, try work.add(pattern.spec.name.len, pattern.spec.root_op_name.len));
    }
    var operations = context.dialect_registry.operation_registry.ops.iterator();
    while (operations.next()) |entry| names = try work.add(names, entry.key_ptr.*.len);
    var dialect_count: u64 = 0;
    var interface_count: u64 = 0;
    var interfaces = context.dialect_registry.interfaces.iterator();
    while (interfaces.next()) |entry| {
        names = try work.add(names, entry.key_ptr.*.len);
        interface_count = try work.add(interface_count, entry.value_ptr.items.len);
        for (entry.value_ptr.items) |interface| {
            if (interface.id != rewrite.DialectCanonicalizationInterface.id) continue;
            const table = rewrite.DialectCanonicalizationInterface.fromOpaque(interface.vtable);
            dialect_count = try work.add(dialect_count, 1);
            count = try work.add(count, table.patterns.len);
            for (table.patterns) |pattern| {
                names = try work.add(names, try work.add(pattern.spec.name.len, pattern.spec.root_op_name.len));
            }
            break;
        }
    }
    if (count > std.math.maxInt(u32)) return error.WorkOverflow;
    const index = rewrite.PatternIndex.Capacity.derive(.{
        .patterns = &.{},
        .facts = .{ .pattern_count = @intCast(count) },
    }) catch return error.WorkOverflow;
    const patterns = try work.arrayListGrowth(rewrite.RewritePattern, count);
    const dialect_storage = try work.arrayListGrowth(RegisteredDialect, dialect_count);
    const fold_bytes = try work.multiply(initial.fold_name_count, @sizeOf([]const u8));
    const fold_names = try work.add(fold_bytes, @alignOf([]const u8));
    const alignment = @alignOf(rewrite.RewritePattern) + @alignOf(RegisteredDialect);
    const population_bytes = try work.add(patterns, dialect_storage);
    const sealed_bytes = try work.add(index.working_bytes, alignment);
    const storage = try work.add(population_bytes, try work.add(fold_names, sealed_bytes));
    const population = try work.add(count, context.dialect_registry.operation_registry.ops.count());
    const units = try work.add(try work.add(names, population), interface_count);
    return .{
        .patterns = count,
        .name_bytes = names,
        .visits = try work.multiply(16, try work.multiply(
            try work.add(units, 1),
            try work.add(count, 1),
        )),
        .bytes = storage,
    };
}

const CanonicalizationPatternCatalog = struct {
    ctx: *ir.Context,
    arith_patterns: []const rewrite.RewritePattern,
    arith_patterns_are_static: bool,
    arith_fold_cache: [ArithOperationIndex.operation_count]ArithFoldCacheEntry,
    include_builtin_patterns: bool,
    include_registered_fold_patterns: bool,
    include_registered_canonicalization_patterns: bool,

    fn init(
        ctx: *ir.Context,
        include_builtin_patterns: bool,
        include_registered_fold_patterns: bool,
        include_registered_canonicalization_patterns: bool,
    ) CanonicalizationPatternCatalog {
        const arith_patterns = if (include_registered_canonicalization_patterns)
            registeredDialectPatterns(ctx, arith.name)
        else
            &.{};
        return .{
            .ctx = ctx,
            .arith_patterns = arith_patterns,
            .arith_patterns_are_static = arith_patterns.len == dialects.arith.canonicalization_patterns.len and
                arith_patterns.ptr == dialects.arith.canonicalization_patterns[0..].ptr,
            .arith_fold_cache = @splat(.{}),
            .include_builtin_patterns = include_builtin_patterns,
            .include_registered_fold_patterns = include_registered_fold_patterns,
            .include_registered_canonicalization_patterns = include_registered_canonicalization_patterns,
        };
    }

    fn hasPatterns(self: *const CanonicalizationPatternCatalog) bool {
        if (self.include_builtin_patterns and builtin_canonicalization_patterns.len > 0) {
            return true;
        }
        if (self.include_registered_fold_patterns) {
            var op_iter = self.ctx.dialect_registry.operation_registry.ops.iterator();
            while (op_iter.next()) |entry| {
                if (entry.value_ptr.*.hasInterface(ir.interfaces.FoldOpInterface.id)) {
                    return true;
                }
            }
        }
        if (self.include_registered_canonicalization_patterns) {
            const Interface = rewrite.DialectCanonicalizationInterface;
            var dialect_iter = self.ctx.dialect_registry.interfaces.iterator();
            while (dialect_iter.next()) |entry| {
                for (entry.value_ptr.items) |iface_entry| {
                    if (iface_entry.id != Interface.id) continue;
                    if (Interface.fromOpaque(iface_entry.vtable).patterns.len > 0) {
                        return true;
                    }
                    break;
                }
            }
        }
        return false;
    }

    pub fn applyFirstMatchingPattern(
        self: *CanonicalizationPatternCatalog,
        op: *ir.Operation,
        rewriter: *rewrite.PatternRewriter,
    ) bool {
        if (std.mem.eql(u8, op.name.name, scf.IfOp.operation_name)) {
            return self.include_builtin_patterns and rewriteScfIf(op, rewriter) == .success;
        }
        if (!effects.permitsRepeatableExpression(op)) return false;
        if (arith_operation_index.get(op.name.name)) |route_index| {
            return self.applyArithPatterns(route_index, op, rewriter);
        }

        if (self.include_registered_fold_patterns) {
            if (op.getRegisteredInfo()) |op_info| {
                if (op_info.getInterface(ir.interfaces.FoldOpInterface.id)) |vtable_opaque| {
                    const vtable: *const ir.interfaces.FoldOpInterface.VTable = @ptrCast(@alignCast(vtable_opaque));
                    var attempt = rewrite.PatternRewriteAttempt.init(op, rewriter);
                    if (attempt.finish(rewriteFoldInterfaceWithVTable(op, rewriter, vtable))) {
                        return true;
                    }
                }
            }
        }

        if (self.include_registered_canonicalization_patterns) {
            const dialect_name = op.name.getDialectNamespace();
            const patterns = if (std.mem.eql(u8, dialect_name, arith.name))
                self.arith_patterns
            else
                registeredDialectPatterns(self.ctx, dialect_name);
            for (patterns) |*pattern| {
                if (!std.mem.eql(u8, pattern.spec.root_op_name, op.name.name)) continue;
                if (rewrite.tryApplyRewritePattern(pattern, op, rewriter)) {
                    return true;
                }
            }
        }

        if (self.include_builtin_patterns) {
            if (builtin_canonicalization_pattern_map.get(op.name.name)) |index| {
                if (rewrite.tryApplyRewritePattern(
                    &builtin_canonicalization_patterns[index],
                    op,
                    rewriter,
                )) {
                    return true;
                }
            }
        }

        return false;
    }

    fn applyArithPatterns(
        self: *CanonicalizationPatternCatalog,
        route_index: usize,
        op: *ir.Operation,
        rewriter: *rewrite.PatternRewriter,
    ) bool {
        const route = arith_operation_index.routes[route_index];
        if (self.include_registered_fold_patterns) {
            if (op.getRegisteredInfo()) |op_info| {
                const cache = &self.arith_fold_cache[route_index];
                if (cache.info != op_info) {
                    cache.* = .{
                        .info = op_info,
                        .vtable = foldVTable(op_info),
                    };
                }
                if (cache.vtable) |vtable| {
                    var attempt = rewrite.PatternRewriteAttempt.init(op, rewriter);
                    if (attempt.finish(rewriteFoldInterfaceWithVTable(op, rewriter, vtable))) {
                        return true;
                    }
                }
            }
        }

        if (self.include_registered_canonicalization_patterns and
            (!self.arith_patterns_are_static or route.has_dialect_pattern))
        {
            for (self.arith_patterns) |*pattern| {
                if (!std.mem.eql(u8, pattern.spec.root_op_name, op.name.name)) continue;
                if (rewrite.tryApplyRewritePattern(pattern, op, rewriter)) {
                    return true;
                }
            }
        }

        if (self.include_builtin_patterns) {
            if (route.builtin_pattern_index) |index| {
                if (rewrite.tryApplyRewritePattern(
                    &builtin_canonicalization_patterns[index],
                    op,
                    rewriter,
                )) {
                    return true;
                }
            }
        }

        return false;
    }
};

const ArithFoldCacheEntry = struct {
    info: ?*const ir.interfaces.OperationInfo = null,
    vtable: ?*const ir.interfaces.FoldOpInterface.VTable = null,
};

fn foldVTable(op_info: *const ir.interfaces.OperationInfo) ?*const ir.interfaces.FoldOpInterface.VTable {
    const vtable_opaque = op_info.getInterface(ir.interfaces.FoldOpInterface.id) orelse return null;
    return @ptrCast(@alignCast(vtable_opaque));
}

fn registeredDialectPatterns(
    ctx: *ir.Context,
    dialect_name: []const u8,
) []const rewrite.RewritePattern {
    if (dialect_name.len == 0) return &.{};
    const Interface = rewrite.DialectCanonicalizationInterface;
    const vtable_opaque = ctx.getDialectInterface(dialect_name, Interface.id) orelse return &.{};
    return Interface.fromOpaque(vtable_opaque).patterns;
}

pub const CanonicalizationPassSpec = struct {
    name: []const u8 = canonicalization_pass_name,
    description: []const u8 = canonicalization_pass_description,
    populate_patterns: ?PopulatePatternsFn = null,
    greedy_config: conversion.GreedyRewriteConfig = .{},
    cleanup_dead_ops: bool = true,
    include_builtin_patterns: bool = true,
    include_registered_fold_patterns: bool = true,
    include_registered_canonicalization_patterns: bool = true,
    mutation_scope: pass.PassMutationScope = .isolated,
};

const CanonicalizationPatterns = struct {
    patterns: *rewrite.RewritePatternSet,
    include_scf: bool,

    pub fn applyFirstMatchingPattern(
        self: *CanonicalizationPatterns,
        op: *ir.Operation,
        rewriter: *rewrite.PatternRewriter,
    ) bool {
        if (std.mem.eql(u8, op.name.name, scf.IfOp.operation_name)) {
            return self.include_scf and rewriteScfIf(op, rewriter) == .success;
        }
        if (!effects.permitsRepeatableExpression(op)) return false;
        for (self.patterns.getMatchingPatterns(op)) |*pattern| {
            if (rewrite.tryApplyRewritePattern(pattern, op, rewriter)) return true;
        }
        return false;
    }
};

pub fn CanonicalizationPass(comptime spec: CanonicalizationPassSpec) type {
    return struct {
        pub fn init() pass.Pass {
            return .{
                .name = spec.name,
                .description = spec.description,
                .run_fn = run,
                .mutation_scope = spec.mutation_scope,
            };
        }

        fn run(ctx: *pass.PassContext) pass.PassResult {
            var changed = false;

            if (spec.populate_patterns) |populate| {
                var patterns = rewrite.RewritePatternSet.init(ctx.allocator);
                defer patterns.deinit();

                _ = populateInitialCanonicalizationPatterns(
                    ctx.ir_ctx,
                    &patterns,
                    spec.include_builtin_patterns,
                    spec.include_registered_fold_patterns,
                ) catch return .failure;
                if (spec.include_registered_canonicalization_patterns) {
                    populateRegisteredCanonicalizationPatterns(ctx.ir_ctx, &patterns) catch return .failure;
                }
                populate(&patterns) catch return .failure;
                patterns.seal() catch return .failure;

                if (patterns.count() > 0) {
                    var source = CanonicalizationPatterns{
                        .patterns = &patterns,
                        .include_scf = spec.include_builtin_patterns,
                    };
                    const result = conversion.applyPatternsGreedilyFromSource(
                        ctx.allocator,
                        ctx.ir_ctx,
                        ctx.op,
                        &source,
                        spec.greedy_config,
                    );
                    if (observeGreedyResult(ctx, result) == .failure) return .failure;
                    changed = changed or result.changed;
                }
            } else {
                var catalog = CanonicalizationPatternCatalog.init(
                    ctx.ir_ctx,
                    spec.include_builtin_patterns,
                    spec.include_registered_fold_patterns,
                    spec.include_registered_canonicalization_patterns,
                );
                if (catalog.hasPatterns()) {
                    const result = conversion.applyPatternsGreedilyFromSource(
                        ctx.allocator,
                        ctx.ir_ctx,
                        ctx.op,
                        &catalog,
                        spec.greedy_config,
                    );
                    if (observeGreedyResult(ctx, result) == .failure) return .failure;
                    changed = changed or result.changed;
                }
            }

            if (spec.cleanup_dead_ops) {
                changed = eliminateDeadOps(ctx) or changed;
            }

            if (changed) {
                ctx.markModified();
            } else {
                ctx.preserveAllAnalyses();
            }

            return .success;
        }
    };
}

fn observeGreedyResult(ctx: *pass.PassContext, result: conversion.GreedyRewriteResult) pass.PassResult {
    if (result.changed) ctx.markModified();
    if (ctx.analysis_cache.accounting) |ledger| {
        if (result.termination == .iteration_limit or result.termination == .rewrite_limit) {
            ledger.fail(.exhausted);
        }
        ledger.observeCounters(.{
            .successful_rewrites = result.rewrites,
            .rewrite_iterations = result.iterations,
        }) catch return .failure;
    }
    return if (result.termination == .converged) .success else .failure;
}

pub fn createCanonicalizationPass() pass.Pass {
    return CanonicalizationPass(.{}).init();
}

pub const builtin_canonicalization_patterns = [_]rewrite.RewritePattern{
    rewrite.RewritePattern.init(.{ .name = "choir-scf-if-fold", .root_op_name = scf.IfOp.operation_name, .benefit = 10, .products = .none }, rewriteScfIf),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-add-fold", .root_op_name = arith.AddOp.operation_name, .benefit = 10, .products = .none }, rewriteArithAdd),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-sub-fold", .root_op_name = arith.SubOp.operation_name, .benefit = 10, .products = .{ .operations = &.{arith.ConstantOp.operation_name} } }, rewriteArithSub),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-mul-fold", .root_op_name = arith.MulOp.operation_name, .benefit = 10, .products = .none }, rewriteArithMul),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-div-fold", .root_op_name = arith.DivOp.operation_name, .benefit = 10, .products = .none }, rewriteArithDiv),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-and-fold", .root_op_name = arith.AndOp.operation_name, .benefit = 10, .products = .none }, rewriteArithAnd),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-or-fold", .root_op_name = arith.OrOp.operation_name, .benefit = 10, .products = .none }, rewriteArithOr),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-xor-fold", .root_op_name = arith.XorOp.operation_name, .benefit = 10, .products = .{ .operations = &.{arith.ConstantOp.operation_name} } }, rewriteArithXor),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-not-fold", .root_op_name = arith.NotOp.operation_name, .benefit = 10, .products = .{ .operations = &.{arith.ConstantOp.operation_name} } }, rewriteArithNot),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-shl-fold", .root_op_name = arith.ShlOp.operation_name, .benefit = 10, .products = .none }, rewriteArithShift),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-shr-fold", .root_op_name = arith.ShrOp.operation_name, .benefit = 10, .products = .none }, rewriteArithShift),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-ushr-fold", .root_op_name = arith.UshrOp.operation_name, .benefit = 10, .products = .none }, rewriteArithShift),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-cmp-fold", .root_op_name = arith.CmpOp.operation_name, .benefit = 10, .products = .{ .operations = &.{arith.ConstantOp.operation_name} } }, rewriteArithCmp),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-cast-fold", .root_op_name = arith.CastOp.operation_name, .benefit = 10, .products = .none }, rewriteArithCast),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-bitcast-fold", .root_op_name = arith.BitcastOp.operation_name, .benefit = 10, .products = .none }, rewriteArithBitcast),
    rewrite.RewritePattern.init(.{ .name = "choir-arith-select-fold", .root_op_name = arith.SelectOp.operation_name, .benefit = 10, .products = .{ .operations = &.{arith.NotOp.operation_name} } }, rewriteArithSelect),
};

const BuiltinPatternIndex = struct {
    const pattern_count = builtin_canonicalization_patterns.len;
    const slot_count = pattern_count * 2;
    const Slot = std.math.IntFittingRange(0, pattern_count);
    const empty_slot: Slot = @intCast(pattern_count);

    slots: [slot_count]Slot,

    fn initComptime() BuiltinPatternIndex {
        var index = BuiltinPatternIndex{ .slots = @splat(empty_slot) };
        for (builtin_canonicalization_patterns, 0..) |pattern, pattern_index| {
            if (pattern.spec.benefit != rewrite.builtin_pattern_benefit) {
                @compileError("builtin canonicalization patterns must share the builtin benefit tier");
            }
            var slot = slotIndex(pattern.spec.root_op_name);
            while (index.slots[slot] != empty_slot) {
                const existing_index: usize = index.slots[slot];
                if (std.mem.eql(
                    u8,
                    builtin_canonicalization_patterns[existing_index].spec.root_op_name,
                    pattern.spec.root_op_name,
                )) {
                    @compileError("builtin canonicalization patterns require unique roots");
                }
                slot = (slot + 1) % slot_count;
            }
            index.slots[slot] = @intCast(pattern_index);
        }
        return index;
    }

    fn get(self: *const BuiltinPatternIndex, root_name: []const u8) ?usize {
        var slot = slotIndex(root_name);
        var probe_count: usize = 0;
        while (probe_count < slot_count) : (probe_count += 1) {
            const pattern_index = self.slots[slot];
            if (pattern_index == empty_slot) return null;
            const index: usize = pattern_index;
            if (std.mem.eql(
                u8,
                builtin_canonicalization_patterns[index].spec.root_op_name,
                root_name,
            )) {
                return index;
            }
            slot = (slot + 1) % slot_count;
        }
        return null;
    }

    fn slotIndex(root_name: []const u8) usize {
        const hash = std.hash_map.hashString(root_name);
        const reduced = @as(u128, hash) * @as(u128, slot_count);
        return @intCast(reduced >> 64);
    }
};

const builtin_canonicalization_pattern_map = BuiltinPatternIndex.initComptime();

const ArithOperationIndex = struct {
    const operation_count = dialects.arith.spec.operations.len;
    const slot_count = operation_count * 2;
    const Slot = std.math.IntFittingRange(0, operation_count);
    const empty_slot: Slot = @intCast(operation_count);

    const Route = struct {
        has_dialect_pattern: bool,
        builtin_pattern_index: ?usize,
    };

    slots: [slot_count]Slot,
    routes: [operation_count]Route,

    fn initComptime() ArithOperationIndex {
        @setEvalBranchQuota(10_000);
        var index = ArithOperationIndex{
            .slots = @splat(empty_slot),
            .routes = undefined,
        };
        for (dialects.arith.spec.operations, 0..) |op_spec, operation_index| {
            var has_dialect_pattern = false;
            for (dialects.arith.canonicalization_patterns) |pattern| {
                if (std.mem.eql(u8, pattern.spec.root_op_name, op_spec.name)) {
                    has_dialect_pattern = true;
                }
            }
            var builtin_pattern_index: ?usize = null;
            for (builtin_canonicalization_patterns, 0..) |pattern, pattern_index| {
                if (std.mem.eql(u8, pattern.spec.root_op_name, op_spec.name)) {
                    builtin_pattern_index = pattern_index;
                    break;
                }
            }
            index.routes[operation_index] = .{
                .has_dialect_pattern = has_dialect_pattern,
                .builtin_pattern_index = builtin_pattern_index,
            };

            var slot = slotIndex(op_spec.name);
            while (index.slots[slot] != empty_slot) {
                const existing_index: usize = index.slots[slot];
                if (std.mem.eql(
                    u8,
                    dialects.arith.spec.operations[existing_index].name,
                    op_spec.name,
                )) {
                    @compileError("arith operation routes require unique roots");
                }
                slot = (slot + 1) % slot_count;
            }
            index.slots[slot] = @intCast(operation_index);
        }
        return index;
    }

    fn get(self: *const ArithOperationIndex, root_name: []const u8) ?usize {
        var slot = slotIndex(root_name);
        var probe_count: usize = 0;
        while (probe_count < slot_count) : (probe_count += 1) {
            const operation_index = self.slots[slot];
            if (operation_index == empty_slot) return null;
            const index: usize = operation_index;
            if (std.mem.eql(
                u8,
                dialects.arith.spec.operations[index].name,
                root_name,
            )) {
                return index;
            }
            slot = (slot + 1) % slot_count;
        }
        return null;
    }

    fn slotIndex(root_name: []const u8) usize {
        const hash = std.hash_map.hashString(root_name);
        const reduced = @as(u128, hash) * @as(u128, slot_count);
        return @intCast(reduced >> 64);
    }
};

const arith_operation_index = ArithOperationIndex.initComptime();

pub fn populateBuiltinCanonicalizationPatterns(patterns: *rewrite.RewritePatternSet) !void {
    try patterns.ensureUnusedCapacity(builtin_canonicalization_patterns.len);
    try populateBuiltinCanonicalizationPatternsReserved(patterns);
}

fn populateBuiltinCanonicalizationPatternsReserved(patterns: *rewrite.RewritePatternSet) !void {
    for (builtin_canonicalization_patterns) |pattern| {
        try patterns.add(pattern);
    }
}

pub fn registeredFoldPatternSpec(op_name: []const u8) rewrite.RewritePatternSpec {
    return .{
        .name = "choir-fold-interface",
        .root_op_name = op_name,
        .benefit = rewrite.fold_pattern_benefit,
        .kind = .fold,
        .products = .{ .operations = &.{arith.ConstantOp.operation_name} },
    };
}

pub fn populateRegisteredFoldPatterns(ctx: *ir.Context, patterns: *rewrite.RewritePatternSet) !void {
    const limits = try InitialPatternLimits.inspect(ctx);
    const capacity = try InitialPatternCapacity.derive(limits, false, true);
    try patterns.ensureUnusedCapacity(capacity.pattern_count);
    try populateRegisteredFoldPatternsReserved(ctx, patterns, capacity.fold_name_count);
}

fn populateRegisteredFoldPatternsReserved(
    ctx: *ir.Context,
    patterns: *rewrite.RewritePatternSet,
    expected_count: usize,
) !void {
    var op_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer op_names.deinit(patterns.allocator);
    try op_names.ensureTotalCapacityPrecise(patterns.allocator, expected_count);

    var iter = ctx.dialect_registry.operation_registry.ops.iterator();
    while (iter.next()) |entry| {
        const op_info = entry.value_ptr.*;
        if (op_info.hasInterface(ir.interfaces.FoldOpInterface.id)) {
            if (op_names.items.len == expected_count) {
                return error.OperationRegistryChanged;
            }
            op_names.appendAssumeCapacity(entry.key_ptr.*);
        }
    }
    if (op_names.items.len != expected_count) return error.OperationRegistryChanged;

    std.mem.sort([]const u8, op_names.items, {}, byte_slice_less_than);

    for (op_names.items) |op_name| {
        try patterns.add(rewrite.RewritePattern.init(registeredFoldPatternSpec(op_name), rewriteFoldInterface));
    }
}

fn populateInitialCanonicalizationPatterns(
    ctx: *ir.Context,
    patterns: *rewrite.RewritePatternSet,
    include_builtin_patterns: bool,
    include_registered_fold_patterns: bool,
) !InitialPatternCapacity {
    const limits = if (include_registered_fold_patterns)
        try InitialPatternLimits.inspect(ctx)
    else
        InitialPatternLimits.empty;
    const capacity = try InitialPatternCapacity.derive(
        limits,
        include_builtin_patterns,
        include_registered_fold_patterns,
    );
    try patterns.ensureUnusedCapacity(capacity.pattern_count);
    if (include_builtin_patterns) {
        try populateBuiltinCanonicalizationPatternsReserved(patterns);
    }
    if (include_registered_fold_patterns) {
        try populateRegisteredFoldPatternsReserved(ctx, patterns, capacity.fold_name_count);
    }
    return capacity;
}

pub fn populateRegisteredCanonicalizationPatterns(ctx: *ir.Context, patterns: *rewrite.RewritePatternSet) !void {
    const Interface = rewrite.DialectCanonicalizationInterface;
    var registered: std.ArrayListUnmanaged(RegisteredDialect) = .empty;
    defer registered.deinit(patterns.allocator);

    var iter = ctx.dialect_registry.interfaces.iterator();
    while (iter.next()) |entry| {
        for (entry.value_ptr.items) |iface_entry| {
            if (iface_entry.id == Interface.id) {
                try registered.append(patterns.allocator, .{
                    .name = entry.key_ptr.*,
                    .vtable = Interface.fromOpaque(iface_entry.vtable),
                });
                break;
            }
        }
    }

    std.mem.sort(RegisteredDialect, registered.items, {}, registered_dialect_less_than);

    for (registered.items) |entry| {
        try patterns.ensureUnusedCapacity(entry.vtable.patterns.len);
        for (entry.vtable.patterns) |pattern| {
            try patterns.add(pattern);
        }
    }
}

pub const canonicalization_pass_registration = registry.PassRegistration{
    .name = canonicalization_pass_name,
    .description = canonicalization_pass_description,
    .pass = createCanonicalizationPass(),
};

pub fn eliminateDeadOps(ctx: *pass.PassContext) bool {
    var modified = false;
    while (eliminateDeadOpsInOperation(ctx.op)) {
        modified = true;
    }
    return modified;
}

fn eliminateDeadOpsInOperation(op: *ir.Operation) bool {
    var changed = false;
    var region_index = op.regions.items.len;
    while (region_index > 0) {
        region_index -= 1;
        const region = &op.regions.items[region_index];
        var block = region.blocks.tail;
        while (block) |current_block| {
            const previous_block = current_block.prev;
            var current: ?*ir.Operation = @ptrCast(@alignCast(current_block.operations.tail));
            while (current) |current_op| {
                const previous = current_op.prev_op;
                if (current_op.regions.items.len > 0) {
                    changed = eliminateDeadOpsInOperation(current_op) or changed;
                }
                if (isTriviallyDead(current_op)) {
                    current_op.erase();
                    changed = true;
                }
                current = previous;
            }
            block = previous_block;
        }
    }
    return changed;
}

pub fn isTriviallyDead(op: *ir.Operation) bool {
    if (op.regions.items.len > 0) return false;
    if (op.getNumResults() == 0) return false;
    if (!op.hasNoUses()) return false;

    const traits = op.getTraits();
    if (traits.is_terminator) return false;
    if (op.hasInterface(ir.interfaces.SymbolOpInterface)) return false;
    return effects.permitsDiscard(op);
}

fn rewriteScfIf(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    const if_op = scf.IfOp{ .op = op };
    const condition = constantBoolFromValue(if_op.getCondition()) orelse return .failure;
    if (op.getNumResults() == 0) {
        return rewriteEffectlessConstantIf(if_op, condition, rewriter);
    }
    return rewriteYieldOnlyConstantIf(if_op, condition, rewriter);
}

fn rewriteFoldInterface(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    const vtable = op.getInterface(ir.interfaces.FoldOpInterface) orelse return .failure;
    return rewriteFoldInterfaceWithVTable(op, rewriter, vtable);
}

fn rewriteFoldInterfaceWithVTable(
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
    vtable: *const ir.interfaces.FoldOpInterface.VTable,
) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const result_count = op.getNumResults();
    var inline_results: [1]ir.interfaces.FoldResult = undefined;
    const result_storage = if (result_count <= inline_results.len)
        inline_results[0..result_count]
    else
        rewriter.allocator.alloc(ir.interfaces.FoldResult, result_count) catch return .failure;
    defer if (result_count > inline_results.len) rewriter.allocator.free(result_storage);

    var folded = ir.interfaces.FoldResults.init(result_storage);
    const op_opaque: *const anyopaque = @ptrCast(op);
    vtable.fold(op_opaque, &folded) catch return .failure;
    const folded_results = folded.slice();

    if (folded_results.len == 0) return .failure;
    if (folded_results.len != result_count) return .failure;

    var inline_values: [1]*ir.Value = undefined;
    const values = if (result_count <= inline_values.len)
        inline_values[0..result_count]
    else
        rewriter.allocator.alloc(*ir.Value, result_count) catch return .failure;
    defer if (result_count > inline_values.len) rewriter.allocator.free(values);

    for (folded_results, 0..) |result, index| {
        const op_result = op.getResult(index) orelse return .failure;
        const value = switch (result) {
            .value => |value| value,
            .attribute => |attr| materializeFoldAttribute(op, op_result.type, attr, rewriter) orelse return .failure,
        };
        if (!op_result.type.eql(value.type)) return .failure;
        if (valueDefinedWithinOp(value, op)) return .failure;
        values[index] = value;
    }

    rewriter.replaceOp(op, values) catch return .failure;
    return .success;
}

fn materializeFoldAttribute(
    op: *ir.Operation,
    ty: ir.Type,
    attr: ir.Attribute,
    rewriter: *rewrite.PatternRewriter,
) ?*ir.Value {
    if (!canMaterializeArithAttribute(ty, attr)) return null;

    rewriter.setInsertionPointBefore(op);
    var state = ir.Operation.State.init(arith.ConstantOp.operation_name, op.location);
    state.addTypes(&.{ty});
    const uses_properties = state.setPropertiesAttrIfRegistered(rewriter.ir_ctx, attr) catch return null;
    const const_op = rewriter.create(state) catch return null;
    if (!uses_properties) const_op.setAttr("value", attr) catch return null;
    return const_op.getResult(0);
}

fn canMaterializeArithAttribute(ty: ir.Type, attr: ir.Attribute) bool {
    if (isBoolType(ty)) return arith.getBoolValue(attr) != null;
    if (isIntegerLikeType(ty)) return arith.getIntValue(attr) != null;
    if (isFloatLikeType(ty)) return arith.getFloatValue(attr) != null;
    return false;
}

fn rewriteArithSelect(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const select = arith.SelectOp{ .op = op };
    const condition_value = select.getCondition();
    const true_value = select.getTrueValue();
    const false_value = select.getFalseValue();
    if (true_value == false_value) {
        rewriter.replaceOpWithValue(op, true_value) catch return .failure;
        return .success;
    }
    if (true_value == condition_value) {
        if (constantBoolEquals(false_value, false)) return rewriteSameTypeForwarding(op, condition_value, rewriter);
        if (constantBoolEquals(false_value, true)) return rewriteSameTypeForwarding(op, false_value, rewriter);
    }
    if (false_value == condition_value) {
        if (constantBoolEquals(true_value, true)) return rewriteSameTypeForwarding(op, condition_value, rewriter);
        if (constantBoolEquals(true_value, false)) return rewriteSameTypeForwarding(op, true_value, rewriter);
    }
    if (constantBoolEquals(true_value, true) and constantBoolEquals(false_value, false)) {
        return rewriteSameTypeForwarding(op, condition_value, rewriter);
    }
    if (constantBoolEquals(true_value, false) and constantBoolEquals(false_value, true)) {
        return rewriteBoolNot(op, condition_value, rewriter);
    }
    const condition = constantBoolFromValue(condition_value) orelse return .failure;
    rewriter.replaceOpWithValue(op, if (condition) true_value else false_value) catch return .failure;
    return .success;
}

fn rewriteArithCast(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const cast = arith.CastOp{ .op = op };
    return rewriteSameTypeUnaryForwarding(op, cast.getInput(), rewriter);
}

fn rewriteArithBitcast(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const cast = arith.BitcastOp{ .op = op };
    return rewriteSameTypeUnaryForwarding(op, cast.getInput(), rewriter);
}

fn rewriteArithAdd(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const operands = binaryOperands(op) orelse return .failure;
    if (constantIntEquals(operands.rhs, 0)) return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    if (constantIntEquals(operands.lhs, 0)) return rewriteSameTypeForwarding(op, operands.rhs, rewriter);
    return .failure;
}

fn rewriteArithSub(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const operands = binaryOperands(op) orelse return .failure;
    if (constantIntEquals(operands.rhs, 0)) return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    if (operands.lhs == operands.rhs) return rewriteIntConstant(op, 0, rewriter);
    return .failure;
}

fn rewriteArithMul(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const operands = binaryOperands(op) orelse return .failure;
    if (constantIntEquals(operands.rhs, 0)) return rewriteSameTypeForwarding(op, operands.rhs, rewriter);
    if (constantIntEquals(operands.lhs, 0)) return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    if (constantIntEquals(operands.rhs, 1)) return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    if (constantIntEquals(operands.lhs, 1)) return rewriteSameTypeForwarding(op, operands.rhs, rewriter);
    return .failure;
}

fn rewriteArithDiv(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const operands = binaryOperands(op) orelse return .failure;
    if (constantIntEquals(operands.rhs, 1)) return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    return .failure;
}

fn rewriteArithAnd(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const operands = binaryOperands(op) orelse return .failure;
    if (operands.lhs == operands.rhs) return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    if (constantBoolEquals(operands.rhs, false) or constantIntEquals(operands.rhs, 0)) {
        return rewriteSameTypeForwarding(op, operands.rhs, rewriter);
    }
    if (constantBoolEquals(operands.lhs, false) or constantIntEquals(operands.lhs, 0)) {
        return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    }
    if (constantBoolEquals(operands.rhs, true) or constantIntEquals(operands.rhs, -1)) {
        return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    }
    if (constantBoolEquals(operands.lhs, true) or constantIntEquals(operands.lhs, -1)) {
        return rewriteSameTypeForwarding(op, operands.rhs, rewriter);
    }
    return .failure;
}

fn rewriteArithOr(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const operands = binaryOperands(op) orelse return .failure;
    if (operands.lhs == operands.rhs) return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    if (constantBoolEquals(operands.rhs, true) or constantIntEquals(operands.rhs, -1)) {
        return rewriteSameTypeForwarding(op, operands.rhs, rewriter);
    }
    if (constantBoolEquals(operands.lhs, true) or constantIntEquals(operands.lhs, -1)) {
        return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    }
    if (constantBoolEquals(operands.rhs, false) or constantIntEquals(operands.rhs, 0)) {
        return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    }
    if (constantBoolEquals(operands.lhs, false) or constantIntEquals(operands.lhs, 0)) {
        return rewriteSameTypeForwarding(op, operands.rhs, rewriter);
    }
    return .failure;
}

fn rewriteArithXor(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const operands = binaryOperands(op) orelse return .failure;
    if (operands.lhs == operands.rhs) return rewriteZeroLikeConstant(op, rewriter);
    if (constantBoolEquals(operands.rhs, false) or constantIntEquals(operands.rhs, 0)) {
        return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    }
    if (constantBoolEquals(operands.lhs, false) or constantIntEquals(operands.lhs, 0)) {
        return rewriteSameTypeForwarding(op, operands.rhs, rewriter);
    }
    return .failure;
}

fn rewriteArithNot(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const not = arith.NotOp{ .op = op };
    const input = not.getInput();
    if (constantBoolFromValue(input)) |value| {
        return rewriteBoolConstant(op, !value, rewriter);
    }

    const def_any = input.getDefiningOp() orelse return .failure;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!std.mem.eql(u8, def_op.name.name, arith.NotOp.operation_name)) return .failure;
    const inner_not = arith.NotOp{ .op = def_op };
    const result = rewriteSameTypeForwarding(op, inner_not.getInput(), rewriter);
    if (result != .success) return result;
    if (def_op.hasOneUse()) {
        rewriter.eraseOp(def_op) catch return .failure;
    }
    return .success;
}

fn rewriteArithShift(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const operands = binaryOperands(op) orelse return .failure;
    if (constantIntEquals(operands.rhs, 0)) return rewriteSameTypeForwarding(op, operands.lhs, rewriter);
    return .failure;
}

fn rewriteArithCmp(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    if (!effects.permitsRepeatableExpression(op)) return .failure;
    const operands = binaryOperands(op) orelse return .failure;
    if (operands.lhs != operands.rhs) return .failure;
    const cmp = arith.CmpOp{ .op = op };
    const predicate = cmp.getPredicate() orelse return .failure;
    const folded = cmpSelfResult(predicate, operands.lhs.type) orelse return .failure;
    return rewriteBoolConstant(op, folded, rewriter);
}

fn rewriteSameTypeUnaryForwarding(
    op: *ir.Operation,
    input: *ir.Value,
    rewriter: *rewrite.PatternRewriter,
) rewrite.PatternResult {
    return rewriteSameTypeForwarding(op, input, rewriter);
}

fn rewriteSameTypeForwarding(
    op: *ir.Operation,
    input: *ir.Value,
    rewriter: *rewrite.PatternRewriter,
) rewrite.PatternResult {
    if (op.getNumResults() != 1) return .failure;
    const result = op.getResult(0) orelse return .failure;
    if (!result.type.eql(input.type)) return .failure;
    rewriter.replaceOpWithValue(op, input) catch return .failure;
    return .success;
}

fn rewriteBoolConstant(
    op: *ir.Operation,
    value: bool,
    rewriter: *rewrite.PatternRewriter,
) rewrite.PatternResult {
    if (op.getNumResults() != 1) return .failure;
    const result = op.getResult(0) orelse return .failure;
    if (!isBoolType(result.type)) return .failure;

    rewriter.setInsertionPointBefore(op);
    var state = ir.Operation.State.init(arith.ConstantOp.operation_name, op.location);
    state.addTypes(&.{result.type});
    const attr = arith.getBoolAttr(rewriter.ir_ctx, value) catch return .failure;
    const uses_properties = state.setPropertiesAttrIfRegistered(rewriter.ir_ctx, attr) catch return .failure;
    if (!uses_properties) state.addAttributes(&.{.{ .name = "value", .value = attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteIntConstant(
    op: *ir.Operation,
    value: i64,
    rewriter: *rewrite.PatternRewriter,
) rewrite.PatternResult {
    if (op.getNumResults() != 1) return .failure;
    const result = op.getResult(0) orelse return .failure;
    if (!isIntegerLikeType(result.type)) return .failure;

    rewriter.setInsertionPointBefore(op);
    var state = ir.Operation.State.init(arith.ConstantOp.operation_name, op.location);
    state.addTypes(&.{result.type});
    const attr = arith.getIntAttr(rewriter.ir_ctx, value) catch return .failure;
    const uses_properties = state.setPropertiesAttrIfRegistered(rewriter.ir_ctx, attr) catch return .failure;
    if (!uses_properties) state.addAttributes(&.{.{ .name = "value", .value = attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteZeroLikeConstant(
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
) rewrite.PatternResult {
    if (op.getNumResults() != 1) return .failure;
    const result = op.getResult(0) orelse return .failure;
    if (isBoolType(result.type)) return rewriteBoolConstant(op, false, rewriter);
    return rewriteIntConstant(op, 0, rewriter);
}

fn rewriteBoolNot(
    op: *ir.Operation,
    input: *ir.Value,
    rewriter: *rewrite.PatternRewriter,
) rewrite.PatternResult {
    if (op.getNumResults() != 1) return .failure;
    const result = op.getResult(0) orelse return .failure;
    if (!result.type.eql(input.type) or !isBoolType(result.type)) return .failure;

    rewriter.setInsertionPointBefore(op);
    var state = ir.Operation.State.init(arith.NotOp.operation_name, op.location);
    state.addOperands(&.{input});
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn cmpSelfResult(predicate_value: CmpPredicate, ty: ir.Type) ?bool {
    if (isBoolType(ty)) {
        return switch (predicate_value) {
            .eq => true,
            .ne => false,
            else => null,
        };
    }
    if (!isIntegerLikeType(ty)) return null;
    return switch (predicate_value) {
        .eq, .le, .ge, .sle, .sge, .ule, .uge => true,
        .ne, .lt, .gt, .slt, .sgt, .ult, .ugt => false,
    };
}

fn rewriteEffectlessConstantIf(
    if_op: scf.IfOp,
    condition: bool,
    rewriter: *rewrite.PatternRewriter,
) rewrite.PatternResult {
    const selected = selectedIfBlock(if_op, condition) orelse {
        rewriter.eraseOp(if_op.op) catch return .failure;
        return .success;
    };
    if (!blockIsEmptyOrZeroYield(selected)) return .failure;
    rewriter.eraseOp(if_op.op) catch return .failure;
    return .success;
}

fn rewriteYieldOnlyConstantIf(
    if_op: scf.IfOp,
    condition: bool,
    rewriter: *rewrite.PatternRewriter,
) rewrite.PatternResult {
    const selected = selectedIfBlock(if_op, condition) orelse return .failure;
    const yield = singleYieldOp(selected) orelse return .failure;
    if (yield.operands.items.len != if_op.op.getNumResults()) return .failure;

    const values = rewriter.allocator.alloc(*ir.Value, yield.operands.items.len) catch return .failure;
    defer rewriter.allocator.free(values);

    for (yield.operands.items, 0..) |operand, index| {
        const value = operand.value;
        if (valueDefinedWithinOp(value, if_op.op)) return .failure;
        values[index] = value;
    }

    rewriter.replaceOp(if_op.op, values) catch return .failure;
    return .success;
}

fn selectedIfBlock(if_op: scf.IfOp, condition: bool) ?*ir.Block {
    if (condition) return if_op.getThenBlock();
    return if_op.getElseBlock();
}

fn blockIsEmptyOrZeroYield(block: *ir.Block) bool {
    const first = block.operations.head orelse return true;
    const op: *ir.Operation = @ptrCast(@alignCast(first));
    if (op.next_op != null) return false;
    if (!std.mem.eql(u8, op.name.name, scf.YieldOp.operation_name)) return false;
    return op.operands.items.len == 0;
}

fn singleYieldOp(block: *ir.Block) ?*ir.Operation {
    const first = block.operations.head orelse return null;
    const op: *ir.Operation = @ptrCast(@alignCast(first));
    if (op.next_op != null) return null;
    if (!std.mem.eql(u8, op.name.name, scf.YieldOp.operation_name)) return null;
    return op;
}

fn constantBoolFromValue(value: *ir.Value) ?bool {
    const def_any = value.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!std.mem.eql(u8, def_op.name.name, arith.ConstantOp.operation_name)) return null;
    if (def_op.getAttrAs(ir.Attribute.BoolAttr, "value")) |bool_attr| return bool_attr.getValue();
    if (def_op.getAttrAs(ir.Attribute.IntegerAttr, "value")) |int_attr| {
        const int_value = int_attr.getValue();
        if (!isBoolType(value.type)) return null;
        return int_value != 0;
    }
    return null;
}

fn constantIntFromValue(value: *ir.Value) ?i64 {
    if (!isIntegerLikeType(value.type)) return null;
    const def_any = value.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!std.mem.eql(u8, def_op.name.name, arith.ConstantOp.operation_name)) return null;
    const int_attr = def_op.getAttrAs(ir.Attribute.IntegerAttr, "value") orelse return null;
    return int_attr.getValue();
}

fn constantIntEquals(value: *ir.Value, expected: i64) bool {
    return (constantIntFromValue(value) orelse return false) == expected;
}

fn constantBoolEquals(value: *ir.Value, expected: bool) bool {
    return (constantBoolFromValue(value) orelse return false) == expected;
}

fn isBoolType(ty: ir.Type) bool {
    return dialects.arith.scalarKindFromType(ty) == .bool;
}

fn isIntegerLikeType(ty: ir.Type) bool {
    const kind = dialects.arith.scalarKindFromType(ty) orelse return false;
    return dialects.arith.scalarKindIsSignedInteger(kind);
}

fn isFloatLikeType(ty: ir.Type) bool {
    const kind = dialects.arith.scalarKindFromType(ty) orelse return false;
    return switch (kind) {
        .f16, .f32, .f64 => true,
        else => false,
    };
}

const BinaryOperands = struct {
    lhs: *ir.Value,
    rhs: *ir.Value,
};

fn binaryOperands(op: *ir.Operation) ?BinaryOperands {
    if (op.operands.items.len != 2) return null;
    return .{
        .lhs = op.operands.items[0].value,
        .rhs = op.operands.items[1].value,
    };
}

fn valueDefinedWithinOp(value: *ir.Value, ancestor: *ir.Operation) bool {
    if (value.getDefiningOp()) |def_any| {
        const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
        return ancestor.isAncestor(def_op);
    }
    if (value.getOwnerBlock()) |block_any| {
        const block: *ir.Block = @ptrCast(@alignCast(block_any));
        const parent_op = block.getParentOperation() orelse return false;
        return ancestor.isAncestor(parent_op);
    }
    return false;
}

fn populateIdentityPattern(patterns: *rewrite.RewritePatternSet) anyerror!void {
    try patterns.add(rewrite.RewritePattern.init(.{
        .name = "test-identity",
        .root_op_name = "test.identity",
        .benefit = 1,
        .products = .none,
    }, rewriteIdentity));
}

fn rewriteIdentity(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    const input = op.getOperand(0) orelse return .failure;
    rewriter.replaceOpWithValue(op, input) catch return .failure;
    return .success;
}

fn foldIdentityOp(
    op_ptr: *const anyopaque,
    results: *ir.interfaces.FoldResults,
) anyerror!void {
    const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
    if (op.operands.items.len != 1) return;
    try results.append(.{ .value = op.operands.items[0].value });
}

fn foldFalseAttribute(
    op_ptr: *const anyopaque,
    results: *ir.interfaces.FoldResults,
) anyerror!void {
    const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
    const attr = try arith.getBoolAttr(op.getContext(), false);
    try results.append(.{ .attribute = attr });
}

fn foldPairOp(
    op_ptr: *const anyopaque,
    results: *ir.interfaces.FoldResults,
) anyerror!void {
    const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
    if (op.operands.items.len != 2) return;
    try results.append(.{ .value = op.operands.items[0].value });
    try results.append(.{ .value = op.operands.items[1].value });
}

test "builtin canonicalization patterns materialize from inspectable specs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();

    try populateBuiltinCanonicalizationPatterns(&patterns);

    try testing.expectEqual(builtin_canonicalization_patterns.len, patterns.patterns.items.len);
    for (builtin_canonicalization_patterns, patterns.patterns.items, 0..) |entry, pattern, index| {
        try testing.expectEqualStrings(entry.spec.name, pattern.spec.name);
        try testing.expectEqualStrings(entry.spec.root_op_name, pattern.spec.root_op_name);
        try testing.expectEqual(entry.spec.benefit, pattern.spec.benefit);
        try testing.expectEqual(entry.spec.kind, pattern.spec.kind);
        try testing.expectEqual(index, builtin_canonicalization_pattern_map.get(entry.spec.root_op_name).?);
    }
    switch (builtin_canonicalization_patterns[2].spec.products) {
        .operations => |ops| try testing.expectEqualStrings(arith.ConstantOp.operation_name, ops[0]),
        else => return error.TestExpectedBuiltinProducts,
    }
}

test "CanonicalizationPass borrows its default catalog without allocating" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, dialects.arith.spec);

    const module = try test_dialect.TestDialect.ModuleOp.create(
        &ctx,
        ir.Location.getUnknown(),
    );

    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var analysis_cache = pass.AnalysisCache.init(failing.allocator(), null);
    defer analysis_cache.deinit();
    var pass_ctx = pass.PassContext.init(
        module.op,
        &ctx,
        failing.allocator(),
        &analysis_cache,
    );
    defer pass_ctx.deinit();

    try testing.expectEqual(
        pass.PassResult.success,
        createCanonicalizationPass().run(&pass_ctx),
    );
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "populateRegisteredFoldPatterns orders fold hooks by operation name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    _ = try ctx.registerOperation("test.z_fold", .{});
    try ctx.registerOperationInterface(
        "test.z_fold",
        ir.interfaces.FoldOpInterface.entryFor(foldIdentityOp),
    );
    _ = try ctx.registerOperation("test.a_fold", .{});
    try ctx.registerOperationInterface(
        "test.a_fold",
        ir.interfaces.FoldOpInterface.entryFor(foldIdentityOp),
    );

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();

    try populateRegisteredFoldPatterns(&ctx, &patterns);

    try testing.expectEqual(@as(usize, 2), patterns.patterns.items.len);
    try testing.expectEqualStrings("choir-fold-interface", patterns.patterns.items[0].spec.name);
    try testing.expectEqual(.fold, patterns.patterns.items[0].spec.kind);
    try testing.expectEqualStrings("test.a_fold", patterns.patterns.items[0].spec.root_op_name);
    try testing.expectEqualStrings("test.z_fold", patterns.patterns.items[1].spec.root_op_name);
    switch (patterns.patterns.items[0].spec.products) {
        .operations => |ops| try testing.expectEqualStrings(arith.ConstantOp.operation_name, ops[0]),
        else => return error.TestExpectedFoldProducts,
    }
}

test "initial canonicalization pattern capacity follows registered folds" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    _ = try ctx.registerOperation("test.z_fold", .{});
    try ctx.registerOperationInterface(
        "test.z_fold",
        ir.interfaces.FoldOpInterface.entryFor(foldIdentityOp),
    );
    _ = try ctx.registerOperation("test.a_fold", .{});
    try ctx.registerOperationInterface(
        "test.a_fold",
        ir.interfaces.FoldOpInterface.entryFor(foldIdentityOp),
    );

    const limits = try InitialPatternLimits.inspect(&ctx);
    try testing.expectEqual(@as(usize, 2), limits.facts.registered_fold_count);

    const full = try InitialPatternCapacity.derive(limits, true, true);
    try testing.expectEqual(
        builtin_canonicalization_patterns.len + 2,
        full.pattern_count,
    );
    try testing.expectEqual(@as(usize, 2), full.fold_name_count);

    const builtin_only = try InitialPatternCapacity.derive(limits, true, false);
    try testing.expectEqual(
        builtin_canonicalization_patterns.len,
        builtin_only.pattern_count,
    );
    try testing.expectEqual(@as(usize, 0), builtin_only.fold_name_count);

    const maximum_fold_count = std.math.maxInt(usize) -
        builtin_canonicalization_patterns.len;
    const maximum = try InitialPatternCapacity.derive(.{
        .facts = .{ .registered_fold_count = maximum_fold_count },
    }, true, true);
    try testing.expectEqual(std.math.maxInt(usize), maximum.pattern_count);
    try testing.expectError(
        error.CapacityOverflow,
        InitialPatternCapacity.derive(.{
            .facts = .{ .registered_fold_count = maximum_fold_count + 1 },
        }, true, true),
    );

    var stale_patterns = rewrite.RewritePatternSet.init(allocator);
    defer stale_patterns.deinit();
    try stale_patterns.ensureUnusedCapacity(1);
    try testing.expectError(
        error.OperationRegistryChanged,
        populateRegisteredFoldPatternsReserved(&ctx, &stale_patterns, 1),
    );
    try testing.expectEqual(@as(usize, 0), stale_patterns.patterns.items.len);
}

test "initial canonicalization patterns reuse one builder backing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    _ = try ctx.registerOperation("test.z_fold", .{});
    try ctx.registerOperationInterface(
        "test.z_fold",
        ir.interfaces.FoldOpInterface.entryFor(foldIdentityOp),
    );
    _ = try ctx.registerOperation("test.a_fold", .{});
    try ctx.registerOperationInterface(
        "test.a_fold",
        ir.interfaces.FoldOpInterface.entryFor(foldIdentityOp),
    );

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();

    const limits = try InitialPatternLimits.inspect(&ctx);
    const capacity = try InitialPatternCapacity.derive(limits, true, true);
    try patterns.ensureUnusedCapacity(capacity.pattern_count);
    const base_pointer = patterns.patterns.items.ptr;
    try populateBuiltinCanonicalizationPatternsReserved(&patterns);
    try populateRegisteredFoldPatternsReserved(
        &ctx,
        &patterns,
        capacity.fold_name_count,
    );

    try testing.expectEqual(capacity.pattern_count, patterns.patterns.items.len);
    try testing.expectEqual(base_pointer, patterns.patterns.items.ptr);
    try testing.expect(patterns.patterns.capacity >= capacity.pattern_count);
}

fn checkInitialCanonicalizationPatternFailures(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
) !void {
    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();

    const capacity = try populateInitialCanonicalizationPatterns(
        ctx,
        &patterns,
        true,
        true,
    );
    try std.testing.expectEqual(capacity.pattern_count, patterns.patterns.items.len);
}

test "initial canonicalization pattern population is retryable after allocation failure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    _ = try ctx.registerOperation("test.fold", .{});
    try ctx.registerOperationInterface(
        "test.fold",
        ir.interfaces.FoldOpInterface.entryFor(foldIdentityOp),
    );

    try testing.checkAllAllocationFailures(
        allocator,
        checkInitialCanonicalizationPatternFailures,
        .{&ctx},
    );
}

fn appendUser(ctx: *ir.Context, block: *ir.Block, loc: ir.Location, value: *ir.Value) !*ir.Operation {
    var builder = ir.OperationBuilder.init(ctx);
    var user_state = ir.Operation.State.init("test.user", loc);
    user_state.addOperands(&.{value});
    const user = try builder.create(user_state);
    try block.addOperation(user);
    return user;
}

test "CanonicalizationPass retains unqualified operations with registered fold interfaces" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    _ = try ctx.registerOperation("test.fold_identity", .{});
    try ctx.registerOperationInterface(
        "test.fold_identity",
        ir.interfaces.FoldOpInterface.entryFor(foldIdentityOp),
    );

    const loc = ir.Location.getUnknown();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const value = try block.addArgument(i32_type, loc);

    var builder = ir.OperationBuilder.init(&ctx);
    var fold_state = ir.Operation.State.init("test.fold_identity", loc);
    fold_state.addOperands(&.{value});
    fold_state.addTypes(&.{i32_type});
    const identity = try builder.create(fold_state);
    try block.addOperation(identity);
    const user = try appendUser(&ctx, block, loc, identity.getResult(0).?);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expect(user.getNumOperands() > 0);
    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "CanonicalizationPass retains unqualified multi-result folds" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    _ = try ctx.registerOperation("test.fold_pair", .{});
    try ctx.registerOperationInterface(
        "test.fold_pair",
        ir.interfaces.FoldOpInterface.entryFor(foldPairOp),
    );

    const loc = ir.Location.getUnknown();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const first = try block.addArgument(i32_type, loc);
    const second = try block.addArgument(i32_type, loc);

    var builder = ir.OperationBuilder.init(&ctx);
    var fold_state = ir.Operation.State.init("test.fold_pair", loc);
    fold_state.addOperands(&.{ first, second });
    fold_state.addTypes(&.{ i32_type, i32_type });
    const pair = try builder.create(fold_state);
    try block.addOperation(pair);
    const first_user = try appendUser(&ctx, block, loc, pair.getResult(0).?);
    const second_user = try appendUser(&ctx, block, loc, pair.getResult(1).?);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(CanonicalizationPass(.{ .include_builtin_patterns = false }).init());

    try testing.expect(first_user.getNumOperands() > 0);
    try testing.expect(second_user.getNumOperands() > 0);
    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "CanonicalizationPass retains unqualified attribute folds" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    _ = try ctx.registerOperation("test.fold_false", .{});
    try ctx.registerOperationInterface(
        "test.fold_false",
        ir.interfaces.FoldOpInterface.entryFor(foldFalseAttribute),
    );

    const loc = ir.Location.getUnknown();
    const bool_type = try arith.getScalarType(&ctx, .bool);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    var fold_state = ir.Operation.State.init("test.fold_false", loc);
    fold_state.addTypes(&.{bool_type});
    const folded = try builder.create(fold_state);
    try block.addOperation(folded);
    const user = try appendUser(&ctx, block, loc, folded.getResult(0).?);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(CanonicalizationPass(.{ .include_builtin_patterns = false }).init());

    try testing.expect(user.getNumOperands() > 0);
    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "Precision1 CanonicalizationPass applies arith fold hooks without builtin patterns" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, dialects.arith.spec);

    const loc = ir.Location.getUnknown();
    const bool_type = try arith.getScalarType(&ctx, .bool);
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const condition = try block.addArgument(bool_type, loc);
    const value = try block.addArgument(i32_type, loc);

    const zero = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 0);
    try block.addOperation(zero.op);
    const one = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    try block.addOperation(one.op);
    const true_value = try arith.ConstantOp.createBool(&ctx, loc, true);
    try block.addOperation(true_value.op);

    const add = try arith.AddOp.create(&ctx, loc, value, zero.getResult());
    try block.addOperation(add.op);
    const add_user = try appendUser(&ctx, block, loc, add.getResult());

    const sub_same = try arith.SubOp.create(&ctx, loc, value, value);
    try block.addOperation(sub_same.op);
    const sub_same_user = try appendUser(&ctx, block, loc, sub_same.getResult());

    const mul = try arith.MulOp.create(&ctx, loc, one.getResult(), value);
    try block.addOperation(mul.op);
    const mul_user = try appendUser(&ctx, block, loc, mul.getResult());

    const cmp_same = try arith.CmpOp.create(&ctx, loc, .eq, value, value);
    try block.addOperation(cmp_same.op);
    const cmp_same_user = try appendUser(&ctx, block, loc, cmp_same.getResult());

    const shl = try arith.ShlOp.create(&ctx, loc, value, zero.getResult());
    try block.addOperation(shl.op);
    const shl_user = try appendUser(&ctx, block, loc, shl.getResult());

    const and_op = try arith.AndOp.create(&ctx, loc, condition, true_value.getResult());
    try block.addOperation(and_op.op);
    const and_user = try appendUser(&ctx, block, loc, and_op.getResult());

    const xor_same = try arith.XorOp.create(&ctx, loc, condition, condition);
    try block.addOperation(xor_same.op);
    const xor_same_user = try appendUser(&ctx, block, loc, xor_same.getResult());

    const not_true = try arith.NotOp.create(&ctx, loc, true_value.getResult());
    try block.addOperation(not_true.op);
    const not_true_user = try appendUser(&ctx, block, loc, not_true.getResult());

    const cast = try arith.CastOp.create(&ctx, loc, value, i32_type);
    try block.addOperation(cast.op);
    const cast_user = try appendUser(&ctx, block, loc, cast.getResult());

    const select = try arith.SelectOp.create(&ctx, loc, condition, value, value);
    try block.addOperation(select.op);
    const select_user = try appendUser(&ctx, block, loc, select.getResult());

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(CanonicalizationPass(.{ .include_builtin_patterns = false }).init());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.AddOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.SubOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.MulOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.CmpOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.ShlOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.AndOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.XorOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.NotOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.CastOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.SelectOp.operation_name),
    );
    try testing.expect(add_user.getOperand(0).? == value);
    try testing.expectEqual(@as(i64, 0), constantIntFromValue(sub_same_user.getOperand(0).?).?);
    try testing.expect(mul_user.getOperand(0).? == value);
    try testing.expectEqual(true, constantBoolFromValue(cmp_same_user.getOperand(0).?).?);
    try testing.expect(shl_user.getOperand(0).? == value);
    try testing.expect(and_user.getOperand(0).? == condition);
    try testing.expectEqual(false, constantBoolFromValue(xor_same_user.getOperand(0).?).?);
    try testing.expectEqual(false, constantBoolFromValue(not_true_user.getOperand(0).?).?);
    try testing.expect(cast_user.getOperand(0).? == value);
    try testing.expect(select_user.getOperand(0).? == value);
}

test "Precision1 CanonicalizationPass applies arith canonicalization hooks without builtin or fold patterns" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, dialects.arith.spec);

    const loc = ir.Location.getUnknown();
    const bool_type = try arith.getScalarType(&ctx, .bool);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const condition = try block.addArgument(bool_type, loc);

    const false_value = try arith.ConstantOp.createBool(&ctx, loc, false);
    try block.addOperation(false_value.op);
    const true_value = try arith.ConstantOp.createBool(&ctx, loc, true);
    try block.addOperation(true_value.op);

    const select = try arith.SelectOp.create(&ctx, loc, condition, false_value.getResult(), true_value.getResult());
    try block.addOperation(select.op);
    const select_user = try appendUser(&ctx, block, loc, select.getResult());

    const inner_not = try arith.NotOp.create(&ctx, loc, condition);
    try block.addOperation(inner_not.op);
    const outer_not = try arith.NotOp.create(&ctx, loc, inner_not.getResult());
    try block.addOperation(outer_not.op);
    const outer_user = try appendUser(&ctx, block, loc, outer_not.getResult());

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(CanonicalizationPass(.{
        .include_builtin_patterns = false,
        .include_registered_fold_patterns = false,
    }).init());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.SelectOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(module.op, arith.NotOp.operation_name),
    );
    try testing.expect(outer_user.getOperand(0).? == condition);

    const replacement = select_user.getOperand(0).?;
    const def_any = replacement.getDefiningOp().?;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    try testing.expectEqualStrings(arith.NotOp.operation_name, def_op.name.name);
    const not = arith.NotOp{ .op = def_op };
    try testing.expect(not.getInput() == condition);
}

test "CanonicalizationPass folds constant scf.if yielding external values" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    const condition = try arith.ConstantOp.createBool(&ctx, loc, true);
    try block.addOperation(condition.op);
    const then_value = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 11);
    try block.addOperation(then_value.op);
    const else_value = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 22);
    try block.addOperation(else_value.op);

    const if_op = try scf.IfOp.create(&ctx, loc, condition.getResult(), &.{i32_type});
    try block.addOperation(if_op.op);
    const then_yield = try scf.YieldOp.create(&ctx, loc, &.{then_value.getResult()});
    try if_op.getThenBlock().addOperation(then_yield.op);
    const else_yield = try scf.YieldOp.create(&ctx, loc, &.{else_value.getResult()});
    try if_op.getElseBlock().?.addOperation(else_yield.op);

    var builder = ir.OperationBuilder.init(&ctx);
    var user_state = ir.Operation.State.init("test.user", loc);
    user_state.addOperands(&.{if_op.getResult(0).?});
    const user = try builder.create(user_state);
    try block.addOperation(user);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.op, scf.IfOp.operation_name));
    try testing.expect(user.getOperand(0).? == then_value.getResult());
}

test "Precision1 CanonicalizationPass folds arith.select with constant condition" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const true_value = try block.addArgument(i32_type, loc);
    const false_value = try block.addArgument(i32_type, loc);

    const condition = try arith.ConstantOp.createBool(&ctx, loc, true);
    try block.addOperation(condition.op);
    const select = try arith.SelectOp.create(&ctx, loc, condition.getResult(), true_value, false_value);
    try block.addOperation(select.op);

    var builder = ir.OperationBuilder.init(&ctx);
    var user_state = ir.Operation.State.init("test.user", loc);
    user_state.addOperands(&.{select.getResult()});
    const user = try builder.create(user_state);
    try block.addOperation(user);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.SelectOp.operation_name),
    );
    try testing.expect(user.getOperand(0).? == true_value);
}

test "Precision1 CanonicalizationPass folds arith.select with identical values" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const bool_type = try arith.getScalarType(&ctx, .bool);
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const condition = try block.addArgument(bool_type, loc);
    const value = try block.addArgument(i32_type, loc);

    const select = try arith.SelectOp.create(&ctx, loc, condition, value, value);
    try block.addOperation(select.op);

    var builder = ir.OperationBuilder.init(&ctx);
    var user_state = ir.Operation.State.init("test.user", loc);
    user_state.addOperands(&.{select.getResult()});
    const user = try builder.create(user_state);
    try block.addOperation(user);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.SelectOp.operation_name),
    );
    try testing.expect(user.getOperand(0).? == value);
}

test "Precision1 CanonicalizationPass forwards boolean arith.select identity" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const bool_type = try arith.getScalarType(&ctx, .bool);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const condition = try block.addArgument(bool_type, loc);

    const true_value = try arith.ConstantOp.createBool(&ctx, loc, true);
    try block.addOperation(true_value.op);
    const false_value = try arith.ConstantOp.createBool(&ctx, loc, false);
    try block.addOperation(false_value.op);

    const select = try arith.SelectOp.create(&ctx, loc, condition, true_value.getResult(), false_value.getResult());
    try block.addOperation(select.op);
    const user = try appendUser(&ctx, block, loc, select.getResult());

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.SelectOp.operation_name),
    );
    try testing.expect(user.getOperand(0).? == condition);
}

test "Precision1 CanonicalizationPass rewrites boolean arith.select inverse" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const bool_type = try arith.getScalarType(&ctx, .bool);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const condition = try block.addArgument(bool_type, loc);

    const false_value = try arith.ConstantOp.createBool(&ctx, loc, false);
    try block.addOperation(false_value.op);
    const true_value = try arith.ConstantOp.createBool(&ctx, loc, true);
    try block.addOperation(true_value.op);

    const select = try arith.SelectOp.create(&ctx, loc, condition, false_value.getResult(), true_value.getResult());
    try block.addOperation(select.op);
    const user = try appendUser(&ctx, block, loc, select.getResult());

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.SelectOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(module.op, arith.NotOp.operation_name),
    );

    const replacement = user.getOperand(0).?;
    const def_any = replacement.getDefiningOp().?;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    try testing.expectEqualStrings(arith.NotOp.operation_name, def_op.name.name);
    const not = arith.NotOp{ .op = def_op };
    try testing.expect(not.getInput() == condition);
}

test "Precision1 CanonicalizationPass folds boolean arith.select absorption" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const bool_type = try arith.getScalarType(&ctx, .bool);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const condition = try block.addArgument(bool_type, loc);

    const true_value = try arith.ConstantOp.createBool(&ctx, loc, true);
    try block.addOperation(true_value.op);
    const false_value = try arith.ConstantOp.createBool(&ctx, loc, false);
    try block.addOperation(false_value.op);

    const true_absorb = try arith.SelectOp.create(&ctx, loc, condition, condition, false_value.getResult());
    try block.addOperation(true_absorb.op);
    const true_absorb_user = try appendUser(&ctx, block, loc, true_absorb.getResult());

    const false_absorb = try arith.SelectOp.create(&ctx, loc, condition, true_value.getResult(), condition);
    try block.addOperation(false_absorb.op);
    const false_absorb_user = try appendUser(&ctx, block, loc, false_absorb.getResult());

    const true_constant = try arith.SelectOp.create(&ctx, loc, condition, condition, true_value.getResult());
    try block.addOperation(true_constant.op);
    const true_constant_user = try appendUser(&ctx, block, loc, true_constant.getResult());

    const false_constant = try arith.SelectOp.create(&ctx, loc, condition, false_value.getResult(), condition);
    try block.addOperation(false_constant.op);
    const false_constant_user = try appendUser(&ctx, block, loc, false_constant.getResult());

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.SelectOp.operation_name),
    );
    try testing.expect(true_absorb_user.getOperand(0).? == condition);
    try testing.expect(false_absorb_user.getOperand(0).? == condition);
    try testing.expectEqual(true, constantBoolFromValue(true_constant_user.getOperand(0).?).?);
    try testing.expectEqual(false, constantBoolFromValue(false_constant_user.getOperand(0).?).?);
}

test "Precision1 CanonicalizationPass forwards same-type arith.cast" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const value = try block.addArgument(i32_type, loc);

    const cast = try arith.CastOp.create(&ctx, loc, value, i32_type);
    try block.addOperation(cast.op);

    var builder = ir.OperationBuilder.init(&ctx);
    var user_state = ir.Operation.State.init("test.user", loc);
    user_state.addOperands(&.{cast.getResult()});
    const user = try builder.create(user_state);
    try block.addOperation(user);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.CastOp.operation_name),
    );
    try testing.expect(user.getOperand(0).? == value);
}

test "Precision1 CanonicalizationPass forwards same-type arith.bitcast" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const value = try block.addArgument(i32_type, loc);

    const cast = try arith.BitcastOp.create(&ctx, loc, value, i32_type);
    try block.addOperation(cast.op);

    var builder = ir.OperationBuilder.init(&ctx);
    var user_state = ir.Operation.State.init("test.user", loc);
    user_state.addOperands(&.{cast.getResult()});
    const user = try builder.create(user_state);
    try block.addOperation(user);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.BitcastOp.operation_name),
    );
    try testing.expect(user.getOperand(0).? == value);
}

test "Precision1 CanonicalizationPass forwards integer arithmetic identities" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const value = try block.addArgument(i32_type, loc);

    const zero = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 0);
    try block.addOperation(zero.op);
    const one = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    try block.addOperation(one.op);
    const all_ones = try arith.ConstantOp.createInt(&ctx, loc, i32_type, -1);
    try block.addOperation(all_ones.op);

    const add_rhs = try arith.AddOp.create(&ctx, loc, value, zero.getResult());
    try block.addOperation(add_rhs.op);
    const add_rhs_user = try appendUser(&ctx, block, loc, add_rhs.getResult());

    const add_lhs = try arith.AddOp.create(&ctx, loc, zero.getResult(), value);
    try block.addOperation(add_lhs.op);
    const add_lhs_user = try appendUser(&ctx, block, loc, add_lhs.getResult());

    const sub_rhs = try arith.SubOp.create(&ctx, loc, value, zero.getResult());
    try block.addOperation(sub_rhs.op);
    const sub_rhs_user = try appendUser(&ctx, block, loc, sub_rhs.getResult());

    const sub_same = try arith.SubOp.create(&ctx, loc, value, value);
    try block.addOperation(sub_same.op);
    const sub_same_user = try appendUser(&ctx, block, loc, sub_same.getResult());

    const mul_rhs = try arith.MulOp.create(&ctx, loc, value, one.getResult());
    try block.addOperation(mul_rhs.op);
    const mul_rhs_user = try appendUser(&ctx, block, loc, mul_rhs.getResult());

    const mul_lhs = try arith.MulOp.create(&ctx, loc, one.getResult(), value);
    try block.addOperation(mul_lhs.op);
    const mul_lhs_user = try appendUser(&ctx, block, loc, mul_lhs.getResult());

    const mul_zero_rhs = try arith.MulOp.create(&ctx, loc, value, zero.getResult());
    try block.addOperation(mul_zero_rhs.op);
    const mul_zero_rhs_user = try appendUser(&ctx, block, loc, mul_zero_rhs.getResult());

    const mul_zero_lhs = try arith.MulOp.create(&ctx, loc, zero.getResult(), value);
    try block.addOperation(mul_zero_lhs.op);
    const mul_zero_lhs_user = try appendUser(&ctx, block, loc, mul_zero_lhs.getResult());

    const div_rhs = try arith.DivOp.create(&ctx, loc, value, one.getResult());
    try block.addOperation(div_rhs.op);
    const div_rhs_user = try appendUser(&ctx, block, loc, div_rhs.getResult());

    const and_rhs = try arith.AndOp.create(&ctx, loc, value, all_ones.getResult());
    try block.addOperation(and_rhs.op);
    const and_rhs_user = try appendUser(&ctx, block, loc, and_rhs.getResult());

    const and_same = try arith.AndOp.create(&ctx, loc, value, value);
    try block.addOperation(and_same.op);
    const and_same_user = try appendUser(&ctx, block, loc, and_same.getResult());

    const and_zero = try arith.AndOp.create(&ctx, loc, value, zero.getResult());
    try block.addOperation(and_zero.op);
    const and_zero_user = try appendUser(&ctx, block, loc, and_zero.getResult());

    const or_rhs = try arith.OrOp.create(&ctx, loc, value, zero.getResult());
    try block.addOperation(or_rhs.op);
    const or_rhs_user = try appendUser(&ctx, block, loc, or_rhs.getResult());

    const or_same = try arith.OrOp.create(&ctx, loc, value, value);
    try block.addOperation(or_same.op);
    const or_same_user = try appendUser(&ctx, block, loc, or_same.getResult());

    const or_all_ones = try arith.OrOp.create(&ctx, loc, all_ones.getResult(), value);
    try block.addOperation(or_all_ones.op);
    const or_all_ones_user = try appendUser(&ctx, block, loc, or_all_ones.getResult());

    const xor_lhs = try arith.XorOp.create(&ctx, loc, zero.getResult(), value);
    try block.addOperation(xor_lhs.op);
    const xor_lhs_user = try appendUser(&ctx, block, loc, xor_lhs.getResult());

    const xor_same = try arith.XorOp.create(&ctx, loc, value, value);
    try block.addOperation(xor_same.op);
    const xor_same_user = try appendUser(&ctx, block, loc, xor_same.getResult());

    const shl_rhs = try arith.ShlOp.create(&ctx, loc, value, zero.getResult());
    try block.addOperation(shl_rhs.op);
    const shl_rhs_user = try appendUser(&ctx, block, loc, shl_rhs.getResult());

    const shr_rhs = try arith.ShrOp.create(&ctx, loc, value, zero.getResult());
    try block.addOperation(shr_rhs.op);
    const shr_rhs_user = try appendUser(&ctx, block, loc, shr_rhs.getResult());

    const ushr_rhs = try arith.UshrOp.create(&ctx, loc, value, zero.getResult());
    try block.addOperation(ushr_rhs.op);
    const ushr_rhs_user = try appendUser(&ctx, block, loc, ushr_rhs.getResult());

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expect(add_rhs_user.getOperand(0).? == value);
    try testing.expect(add_lhs_user.getOperand(0).? == value);
    try testing.expect(sub_rhs_user.getOperand(0).? == value);
    try testing.expectEqual(@as(i64, 0), constantIntFromValue(sub_same_user.getOperand(0).?).?);
    try testing.expect(mul_rhs_user.getOperand(0).? == value);
    try testing.expect(mul_lhs_user.getOperand(0).? == value);
    try testing.expect(mul_zero_rhs_user.getOperand(0).? == zero.getResult());
    try testing.expect(mul_zero_lhs_user.getOperand(0).? == zero.getResult());
    try testing.expect(div_rhs_user.getOperand(0).? == value);
    try testing.expect(and_rhs_user.getOperand(0).? == value);
    try testing.expect(and_same_user.getOperand(0).? == value);
    try testing.expect(and_zero_user.getOperand(0).? == zero.getResult());
    try testing.expect(or_rhs_user.getOperand(0).? == value);
    try testing.expect(or_same_user.getOperand(0).? == value);
    try testing.expect(or_all_ones_user.getOperand(0).? == all_ones.getResult());
    try testing.expect(xor_lhs_user.getOperand(0).? == value);
    try testing.expectEqual(@as(i64, 0), constantIntFromValue(xor_same_user.getOperand(0).?).?);
    try testing.expect(shl_rhs_user.getOperand(0).? == value);
    try testing.expect(shr_rhs_user.getOperand(0).? == value);
    try testing.expect(ushr_rhs_user.getOperand(0).? == value);
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.AddOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.SubOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.MulOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.DivOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.AndOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.OrOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.XorOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.ShlOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.ShrOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.UshrOp.operation_name),
    );
}

test "Precision1 CanonicalizationPass forwards boolean arithmetic identities" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const bool_type = try arith.getScalarType(&ctx, .bool);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const value = try block.addArgument(bool_type, loc);

    const true_value = try arith.ConstantOp.createBool(&ctx, loc, true);
    try block.addOperation(true_value.op);
    const false_value = try arith.ConstantOp.createBool(&ctx, loc, false);
    try block.addOperation(false_value.op);

    const and_rhs = try arith.AndOp.create(&ctx, loc, value, true_value.getResult());
    try block.addOperation(and_rhs.op);
    const and_rhs_user = try appendUser(&ctx, block, loc, and_rhs.getResult());

    const and_lhs = try arith.AndOp.create(&ctx, loc, true_value.getResult(), value);
    try block.addOperation(and_lhs.op);
    const and_lhs_user = try appendUser(&ctx, block, loc, and_lhs.getResult());

    const and_same = try arith.AndOp.create(&ctx, loc, value, value);
    try block.addOperation(and_same.op);
    const and_same_user = try appendUser(&ctx, block, loc, and_same.getResult());

    const and_false = try arith.AndOp.create(&ctx, loc, value, false_value.getResult());
    try block.addOperation(and_false.op);
    const and_false_user = try appendUser(&ctx, block, loc, and_false.getResult());

    const or_rhs = try arith.OrOp.create(&ctx, loc, value, false_value.getResult());
    try block.addOperation(or_rhs.op);
    const or_rhs_user = try appendUser(&ctx, block, loc, or_rhs.getResult());

    const or_lhs = try arith.OrOp.create(&ctx, loc, false_value.getResult(), value);
    try block.addOperation(or_lhs.op);
    const or_lhs_user = try appendUser(&ctx, block, loc, or_lhs.getResult());

    const or_same = try arith.OrOp.create(&ctx, loc, value, value);
    try block.addOperation(or_same.op);
    const or_same_user = try appendUser(&ctx, block, loc, or_same.getResult());

    const or_true = try arith.OrOp.create(&ctx, loc, true_value.getResult(), value);
    try block.addOperation(or_true.op);
    const or_true_user = try appendUser(&ctx, block, loc, or_true.getResult());

    const xor_rhs = try arith.XorOp.create(&ctx, loc, value, false_value.getResult());
    try block.addOperation(xor_rhs.op);
    const xor_rhs_user = try appendUser(&ctx, block, loc, xor_rhs.getResult());

    const xor_lhs = try arith.XorOp.create(&ctx, loc, false_value.getResult(), value);
    try block.addOperation(xor_lhs.op);
    const xor_lhs_user = try appendUser(&ctx, block, loc, xor_lhs.getResult());

    const xor_same = try arith.XorOp.create(&ctx, loc, value, value);
    try block.addOperation(xor_same.op);
    const xor_same_user = try appendUser(&ctx, block, loc, xor_same.getResult());

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expect(and_rhs_user.getOperand(0).? == value);
    try testing.expect(and_lhs_user.getOperand(0).? == value);
    try testing.expect(and_same_user.getOperand(0).? == value);
    try testing.expect(and_false_user.getOperand(0).? == false_value.getResult());
    try testing.expect(or_rhs_user.getOperand(0).? == value);
    try testing.expect(or_lhs_user.getOperand(0).? == value);
    try testing.expect(or_same_user.getOperand(0).? == value);
    try testing.expect(or_true_user.getOperand(0).? == true_value.getResult());
    try testing.expect(xor_rhs_user.getOperand(0).? == value);
    try testing.expect(xor_lhs_user.getOperand(0).? == value);
    try testing.expectEqual(false, constantBoolFromValue(xor_same_user.getOperand(0).?).?);
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.AndOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.OrOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.XorOp.operation_name),
    );
}

test "Precision1 CanonicalizationPass folds arith.not identities" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const bool_type = try arith.getScalarType(&ctx, .bool);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const value = try block.addArgument(bool_type, loc);

    const true_value = try arith.ConstantOp.createBool(&ctx, loc, true);
    try block.addOperation(true_value.op);
    const false_value = try arith.ConstantOp.createBool(&ctx, loc, false);
    try block.addOperation(false_value.op);

    const not_true = try arith.NotOp.create(&ctx, loc, true_value.getResult());
    try block.addOperation(not_true.op);
    const not_true_user = try appendUser(&ctx, block, loc, not_true.getResult());

    const not_false = try arith.NotOp.create(&ctx, loc, false_value.getResult());
    try block.addOperation(not_false.op);
    const not_false_user = try appendUser(&ctx, block, loc, not_false.getResult());

    const inner_not = try arith.NotOp.create(&ctx, loc, value);
    try block.addOperation(inner_not.op);
    const outer_not = try arith.NotOp.create(&ctx, loc, inner_not.getResult());
    try block.addOperation(outer_not.op);
    const outer_not_user = try appendUser(&ctx, block, loc, outer_not.getResult());

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(module.op, arith.NotOp.operation_name),
    );
    try testing.expectEqual(false, constantBoolFromValue(not_true_user.getOperand(0).?).?);
    try testing.expectEqual(true, constantBoolFromValue(not_false_user.getOperand(0).?).?);
    try testing.expect(outer_not_user.getOperand(0).? == value);
}

test "Precision1 CanonicalizationPass folds arith.cmp self comparisons" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const f32_type = try arith.getScalarType(&ctx, .f32);
    const bool_type = try arith.getScalarType(&ctx, .bool);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const int_value = try block.addArgument(i32_type, loc);
    const bool_value = try block.addArgument(bool_type, loc);
    const float_value = try block.addArgument(f32_type, loc);

    const int_eq = try arith.CmpOp.create(&ctx, loc, .eq, int_value, int_value);
    try block.addOperation(int_eq.op);
    const int_eq_user = try appendUser(&ctx, block, loc, int_eq.getResult());

    const int_ult = try arith.CmpOp.create(&ctx, loc, .ult, int_value, int_value);
    try block.addOperation(int_ult.op);
    const int_ult_user = try appendUser(&ctx, block, loc, int_ult.getResult());

    const bool_eq = try arith.CmpOp.create(&ctx, loc, .eq, bool_value, bool_value);
    try block.addOperation(bool_eq.op);
    const bool_eq_user = try appendUser(&ctx, block, loc, bool_eq.getResult());

    const bool_ne = try arith.CmpOp.create(&ctx, loc, .ne, bool_value, bool_value);
    try block.addOperation(bool_ne.op);
    const bool_ne_user = try appendUser(&ctx, block, loc, bool_ne.getResult());

    const float_eq = try arith.CmpOp.create(&ctx, loc, .eq, float_value, float_value);
    try block.addOperation(float_eq.op);
    const float_eq_user = try appendUser(&ctx, block, loc, float_eq.getResult());

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(module.op, arith.CmpOp.operation_name),
    );
    try testing.expectEqual(
        @as(usize, 4),
        ir.inspection.countOperationsNamed(module.op, arith.ConstantOp.operation_name),
    );
    try testing.expectEqual(true, constantBoolFromValue(int_eq_user.getOperand(0).?).?);
    try testing.expectEqual(false, constantBoolFromValue(int_ult_user.getOperand(0).?).?);
    try testing.expectEqual(true, constantBoolFromValue(bool_eq_user.getOperand(0).?).?);
    try testing.expectEqual(false, constantBoolFromValue(bool_ne_user.getOperand(0).?).?);
    try testing.expect(float_eq_user.getOperand(0).? == float_eq.getResult());
}

test "CanonicalizationPass retains unqualified empty scf.if with unknown condition" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const bool_type = try arith.getScalarType(&ctx, .bool);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const condition = try block.addArgument(bool_type, loc);

    const if_op = try scf.IfOp.createWithoutElse(&ctx, loc, condition);
    try block.addOperation(if_op.op);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "CanonicalizationPass retains unqualified scf.if with equivalent yields" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const bool_type = try arith.getScalarType(&ctx, .bool);
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const condition = try block.addArgument(bool_type, loc);
    const value = try block.addArgument(i32_type, loc);

    const if_op = try scf.IfOp.create(&ctx, loc, condition, &.{i32_type});
    try block.addOperation(if_op.op);
    const then_yield = try scf.YieldOp.create(&ctx, loc, &.{value});
    try if_op.getThenBlock().addOperation(then_yield.op);
    const else_yield = try scf.YieldOp.create(&ctx, loc, &.{value});
    try if_op.getElseBlock().?.addOperation(else_yield.op);

    const user = try appendUser(&ctx, block, loc, if_op.getResult(0).?);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expect(user.getNumOperands() > 0);
    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "CanonicalizationPass erases constant false scf.if without else" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    const condition = try arith.ConstantOp.createBool(&ctx, loc, false);
    try block.addOperation(condition.op);
    const if_op = try scf.IfOp.createWithoutElse(&ctx, loc, condition.getResult());
    try block.addOperation(if_op.op);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.op, scf.IfOp.operation_name));
}

test "CanonicalizationPass keeps constant scf.if yielding branch-local values" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    const condition = try arith.ConstantOp.createBool(&ctx, loc, true);
    try block.addOperation(condition.op);
    const else_value = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 22);
    try block.addOperation(else_value.op);

    const if_op = try scf.IfOp.create(&ctx, loc, condition.getResult(), &.{i32_type});
    try block.addOperation(if_op.op);
    const then_value = try arith.ConstantOp.createInt(&ctx, loc, i32_type, 11);
    try if_op.getThenBlock().addOperation(then_value.op);
    const then_yield = try scf.YieldOp.create(&ctx, loc, &.{then_value.getResult()});
    try if_op.getThenBlock().addOperation(then_yield.op);
    const else_yield = try scf.YieldOp.create(&ctx, loc, &.{else_value.getResult()});
    try if_op.getElseBlock().?.addOperation(else_yield.op);

    var builder = ir.OperationBuilder.init(&ctx);
    var user_state = ir.Operation.State.init("test.user", loc);
    user_state.addOperands(&.{if_op.getResult(0).?});
    const user = try builder.create(user_state);
    try block.addOperation(user);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(module.op, scf.IfOp.operation_name),
    );
    try testing.expect(user.getOperand(0).? == if_op.getResult(0).?);
}

test "CanonicalizationPass retains unqualified operations with populated rewrite patterns" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();
    const arg = try block.addArgument(i32_type, loc);

    var builder = ir.OperationBuilder.init(&ctx);
    var identity_state = ir.Operation.State.init("test.identity", loc);
    identity_state.addOperands(&.{arg});
    identity_state.addTypes(&.{i32_type});
    const identity = try builder.create(identity_state);
    try block.addOperation(identity);

    var user_state = ir.Operation.State.init("test.user", loc);
    user_state.addOperands(&.{identity.getResult(0).?});
    const user = try builder.create(user_state);
    try block.addOperation(user);

    const TestCanonicalizationPass = CanonicalizationPass(.{
        .name = "test-canonicalize",
        .description = "test canonicalization pass",
        .populate_patterns = populateIdentityPattern,
    });

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(TestCanonicalizationPass.init());

    try testing.expect(user.getNumOperands() > 0);
    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "CanonicalizationPass retains unqualified unused operations" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    _ = try ctx.registerOperation("test.dead", .{});
    _ = try ctx.registerOperation("test.effect", .{});

    const loc = ir.Location.getUnknown();
    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    var dead_state = ir.Operation.State.init("test.dead", loc);
    dead_state.addTypes(&.{i32_type});
    const dead = try builder.create(dead_state);
    try block.addOperation(dead);

    var effect_state = ir.Operation.State.init("test.effect", loc);
    effect_state.addTypes(&.{i32_type});
    const effect = try builder.create(effect_state);
    try block.addOperation(effect);

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    const before_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(before_ir);
    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    const after_ir = try ir.dump.operationAlloc(allocator, module.op);
    defer allocator.free(after_ir);
    try testing.expectEqualStrings(before_ir, after_ir);
}

test "CanonicalizationPass preserves analyses when unchanged" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(createCanonicalizationPass());

    try testing.expectEqual(pass.PassResult.success, manager.run(module.op, &ctx));
    try testing.expectEqual(@as(u64, 0), manager.stats.passes_modified);
}

test "CanonicalizationPass reports limits and mutation through both pattern routes" {
    inline for (.{ false, true }) |explicit| {
        try checkCanonicalizationTermination(explicit, .{}, false, false, false);
        try checkCanonicalizationTermination(explicit, .{}, false, false, true);
        try checkCanonicalizationTermination(explicit, .{}, true, false, true);
        try checkCanonicalizationTermination(explicit, .{}, true, false, false);
        try checkCanonicalizationTermination(explicit, .{ .max_iterations = 1 }, true, true, false);
        try checkCanonicalizationTermination(explicit, .{ .max_rewrites = 1 }, true, true, false);
    }
}

fn noExtraCanonicalizationPatterns(_: *rewrite.RewritePatternSet) !void {}

fn checkCanonicalizationTermination(
    comptime explicit: bool,
    comptime config: conversion.GreedyRewriteConfig,
    add_rewrite: bool,
    exhausted: bool,
    invalid: bool,
) !void {
    const revision = @import("../product/revision/root.zig");
    const fixture = @import("../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try ir.dialects.loadDialectSpec(&context, dialects.arith.spec);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const block = module.getBodyBlock();
    const user = try appendTerminationRewrite(&context, block, add_rewrite);
    var foreign = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer foreign.deinit(allocator);
    try foreign.allowUnregistered();
    const foreign_state = ir.Operation.State.init("test.foreign", .unknown);
    const foreign_op = try foreign.createOperation(foreign_state);
    if (invalid) try block.addOperation(foreign_op);
    defer if (invalid) block.detachOperation(foreign_op);
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .uniform(std.math.maxInt(u64)),
        .workspace = 1 << 20,
        .events = 16,
    }, &.{});
    defer ledger.destroy();
    var cache = try pass.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 8);
    defer cache.deinit();
    var manager = pass.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(CanonicalizationPass(.{
        .populate_patterns = if (explicit) noExtraCanonicalizationPatterns else null,
        .greedy_config = config,
        .cleanup_dead_ops = false,
    }).init());
    const result = manager.runWithAnalysisCache(module.op, &context, &cache, .{ .max_threads = 1 });
    try std.testing.expectEqual(
        if (exhausted or invalid) pass.PassResult.failure else .success,
        result,
    );
    try checkTerminationReceipt(&manager, ledger, add_rewrite, exhausted, invalid);
    try std.testing.expect(user.getOperand(0).? == block.arguments.items[0]);
    try std.testing.expectEqual(
        0,
        ir.inspection.countOperationsNamed(module.op, arith.AddOp.operation_name),
    );
}

fn checkTerminationReceipt(
    manager: *const pass.PassManager,
    ledger: *@import("../product/revision/root.zig").AccountingV1,
    add_rewrite: bool,
    exhausted: bool,
    invalid: bool,
) !void {
    const revision = @import("../product/revision/root.zig");
    const receipt = ledger.view();
    const ordinary: revision.receipt.Outcome = if (invalid) .rejected else .running;
    const outcome: revision.receipt.Outcome = if (exhausted) .exhausted else ordinary;
    try std.testing.expectEqual(outcome, receipt.outcome);
    try std.testing.expectEqual(
        @intFromBool(add_rewrite),
        receipt.executed.counters.successful_rewrites,
    );
    const iterations: u64 = if (add_rewrite and !exhausted and !invalid) 2 else 1;
    try std.testing.expectEqual(iterations, receipt.executed.counters.rewrite_iterations);
    try std.testing.expectEqual(
        @intFromBool(add_rewrite),
        receipt.executed.counters.passes_modified,
    );
    try std.testing.expectEqual(1, receipt.executed.counters.pass_runs);
    if (exhausted) {
        try std.testing.expectEqual(
            .exhausted,
            manager.getLastFailureReproducer().?.failure_kind.?,
        );
        try std.testing.expectError(error.WorkExhausted, ledger.producersComplete());
    }
}

fn appendTerminationRewrite(
    context: *ir.Context,
    block: *ir.Block,
    add_rewrite: bool,
) !*ir.Operation {
    const typ = try arith.getScalarType(context, .i32);
    const value = try block.addArgument(typ, .unknown);
    var output = value;
    if (add_rewrite) {
        const zero = try arith.ConstantOp.createInt(context, .unknown, typ, 0);
        try block.addOperation(zero.op);
        const add = try arith.AddOp.create(context, .unknown, value, zero.getResult());
        try block.addOperation(add.op);
        output = add.getResult();
    }
    return appendUser(context, block, .unknown, output);
}

test "canonicalization population bounds cover sealed builder allocation traffic" {
    const fixed = @import("alloc_fixed");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try ir.dialects.loadDialectSpec(&context, dialects.arith.spec);
    const specs: [64]rewrite.RewritePatternSpec = @splat(.{
        .name = "population-extra",
        .root_op_name = "test.extra",
    });
    for ([_]usize{ 0, 1, 64 }) |extra| {
        const bounds = try patternPopulationBounds(&context, specs[0..extra]);
        const bytes = try allocator.alignedAlloc(u8, .@"64", @intCast(bounds.bytes));
        defer allocator.free(bytes);
        var backing = fixed.Tracked.init(bytes);
        var retained = fixed.Monotonic.init(backing.allocator(), bytes.len);
        var patterns = rewrite.RewritePatternSet.init(retained.allocator());
        defer patterns.deinit();
        _ = try populateInitialCanonicalizationPatterns(&context, &patterns, true, true);
        try populateRegisteredCanonicalizationPatterns(&context, &patterns);
        for (specs[0..extra]) |spec| {
            try patterns.add(rewrite.RewritePattern.init(spec, populationNoMatch));
        }
        try patterns.seal();
        try std.testing.expectEqual(bounds.patterns, patterns.count());
        const used = if (retained.current) |*current| fixed.used(current) else 0;
        try std.testing.expect(used <= bounds.bytes);
        try std.testing.expect(!backing.exhausted);
    }
}

fn populationNoMatch(_: *ir.Operation, _: *rewrite.PatternRewriter) rewrite.PatternResult {
    return .failure;
}
