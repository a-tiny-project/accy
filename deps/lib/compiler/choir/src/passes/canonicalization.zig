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

fn appendUser(ctx: *ir.Context, block: *ir.Block, loc: ir.Location, value: *ir.Value) !*ir.Operation {
    var builder = ir.OperationBuilder.init(ctx);
    var user_state = ir.Operation.State.init("test.user", loc);
    user_state.addOperands(&.{value});
    const user = try builder.create(user_state);
    try block.addOperation(user);
    return user;
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

fn populationNoMatch(_: *ir.Operation, _: *rewrite.PatternRewriter) rewrite.PatternResult {
    return .failure;
}
