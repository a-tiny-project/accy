const std = @import("std");
const revision = @import("../../product/revision/root.zig");
const choir = @import("../../root.zig");
const ir = @import("../../core/root.zig");
const passes = @import("../root.zig");
const subject = @import("root.zig");
const instrumentation = passes.instrumentation;

const textual_pipeline = passes.textual_pipeline;
const diagnostics = choir.diagnostics;
const AnalysisCache = subject.AnalysisCache;
const Pass = subject.Pass;
const PassContext = subject.PassContext;
const PassFailureKind = subject.PassFailureKind;
const PassFailureReproducer = subject.PassFailureReproducer;
const PassInfo = instrumentation.PassInfo;
const PassInstrumentation = instrumentation.PassInstrumentation;
const PassInstrumentor = instrumentation.PassInstrumentor;
const PassManagerFixedPointResult = subject.PassManagerFixedPointResult;
const PassManagerRunOptions = subject.PassManagerRunOptions;
const PassManagerStats = subject.PassManagerStats;
const PassResult = subject.PassResult;
const PassVerifierFailure = subject.PassVerifierFailure;
const PipelineInfo = instrumentation.PipelineInfo;

const CapturedPassFailure = struct {
    kind: PassFailureKind,
    pass_name: ?[]const u8 = null,
    target_op_name: []const u8,
    target_symbol_name: ?[]const u8 = null,
    verifier_error: ?anyerror = null,
    worker_count: usize = 1,
};

fn recordPassFailure(slot: ?*?CapturedPassFailure, failure: CapturedPassFailure) void {
    if (slot) |captured| {
        if (captured.* == null) captured.* = failure;
    }
}

const PassVerifierConfig = struct {
    options: ir.verify.VerifyOptions,
    failure: *?PassVerifierFailure,

    fn verifyAfterPass(self: *PassVerifierConfig, info: PassInfo) PassResult {
        const op = info.target_op orelse return .success;
        ir.verify.verifyOperation(op, self.options) catch |err| {
            self.failure.* = .{
                .pass_name = info.name,
                .target_op_name = op.name.name,
                .err = err,
            };
            return .failure;
        };
        return .success;
    }
};

const PipelineRun = struct {
    op: *ir.Operation,
    ir_ctx: *ir.Context,
    analysis_cache: *AnalysisCache,
    stats: *PassManagerStats,
    instrumentor: ?*const PassInstrumentor,
    verifier: ?*PassVerifierConfig,
    failure: ?*?CapturedPassFailure,
    options: PassManagerRunOptions,
    allocator: std.mem.Allocator,
};

const PassWork = struct {
    ledger: ?*revision.AccountingV1,
    token: ?u32 = null,
    admitted: bool = true,
    before: PassManagerStats,

    fn begin(pass: Pass, run: *PipelineRun) PassWork {
        var work = PassWork{
            .ledger = run.analysis_cache.accounting,
            .before = run.stats.*,
        };
        if (work.ledger) |ledger| {
            if (run.analysis_cache.allocation_failure.exhausted()) {
                ledger.fail(.exhausted);
                work.admitted = false;
                return work;
            }
        }
        work.token = subject.work.begin(work.ledger, .pass, pass.work_contract, .{
            .operation = run.op,
            .state = pass.state,
            .options = run.options,
        }) catch {
            work.admitted = false;
            return work;
        };
        return work;
    }

    fn normalize(self: PassWork, native: PassResult, pass: Pass, run: *PipelineRun) PassResult {
        const ledger = self.ledger orelse return native;
        if (run.analysis_cache.allocation_failure.exhausted()) ledger.fail(.exhausted);
        const outcome = ledger.view().outcome;
        if (outcome == .exhausted) recordPassFailure(run.failure, .{
            .kind = .exhausted,
            .pass_name = pass.name,
            .target_op_name = run.op.name.name,
            .target_symbol_name = ir.SymbolTable.getSymbolName(run.op),
        });
        return if (outcome == .running) native else .failure;
    }

    fn finish(self: PassWork, result: PassResult, after: PassManagerStats) void {
        const ledger = self.ledger orelse return;
        const counters = revision.receipt.Counters{
            .pass_runs = after.pass_runs - self.before.pass_runs,
            .passes_modified = after.passes_modified - self.before.passes_modified,
        };
        if (self.token) |token| {
            if (result == .failure) ledger.fail(.rejected);
            ledger.finish(token, if (result == .success) .success else .rejected, .{
                .counters = counters,
            }) catch ledger.fail(.rejected);
        } else {
            ledger.observeCounters(counters) catch ledger.fail(.rejected);
            if (result == .failure) ledger.fail(.rejected);
        }
    }
};

pub const PipelineEntry = union(enum) {
    pass: Pass,
    nested: *OpPassManager,
};

pub const OpPassManagerTargetKind = enum {
    root,
    any,
    op,
};

pub const OpPassManager = struct {
    allocator: std.mem.Allocator,
    target_op_name: ?[]const u8,
    target_kind: OpPassManagerTargetKind,
    pipeline: std.ArrayListUnmanaged(PipelineEntry),
    nested_managers: std.ArrayListUnmanaged(*OpPassManager),
    parent: ?*OpPassManager,

    pub fn init(allocator: std.mem.Allocator, target_op_name: ?[]const u8) OpPassManager {
        return initWithTarget(
            allocator,
            if (target_op_name == null) .root else .op,
            target_op_name,
        );
    }

    pub fn initAny(allocator: std.mem.Allocator) OpPassManager {
        return initWithTarget(allocator, .any, null);
    }

    pub fn initWithTarget(
        allocator: std.mem.Allocator,
        target_kind: OpPassManagerTargetKind,
        target_op_name: ?[]const u8,
    ) OpPassManager {
        return .{
            .allocator = allocator,
            .target_op_name = target_op_name,
            .target_kind = target_kind,
            .pipeline = .empty,
            .nested_managers = .empty,
            .parent = null,
        };
    }

    pub fn deinit(self: *OpPassManager) void {
        for (self.nested_managers.items) |nested| {
            nested.deinit();
            self.allocator.destroy(nested);
        }
        for (self.pipeline.items) |*entry| {
            switch (entry.*) {
                .pass => |*pass| pass.deinit(self.allocator),
                .nested => {},
            }
        }
        self.nested_managers.deinit(self.allocator);
        self.pipeline.deinit(self.allocator);
    }

    pub fn addPass(self: *OpPassManager, pass: Pass) !void {
        if (!pass.validRerunContract()) return error.InvalidPassRerunContract;
        try self.pipeline.append(self.allocator, .{ .pass = pass });
    }

    pub fn nest(self: *OpPassManager, op_name: []const u8) !*OpPassManager {
        const nested = try self.allocator.create(OpPassManager);
        nested.* = OpPassManager.init(self.allocator, op_name);
        nested.parent = self;

        try self.nested_managers.append(self.allocator, nested);
        try self.pipeline.append(self.allocator, .{ .nested = nested });

        return nested;
    }

    pub fn nestAny(self: *OpPassManager) !*OpPassManager {
        const nested = try self.allocator.create(OpPassManager);
        nested.* = OpPassManager.initAny(self.allocator);
        nested.parent = self;

        try self.nested_managers.append(self.allocator, nested);
        try self.pipeline.append(self.allocator, .{ .nested = nested });

        return nested;
    }

    pub fn collectDependentDialects(
        self: *const OpPassManager,
        allocator: std.mem.Allocator,
        names: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        for (self.pipeline.items) |entry| {
            switch (entry) {
                .pass => |pass| {
                    for (pass.dependent_dialects) |dialect_name| {
                        try appendDependentDialectName(allocator, names, dialect_name);
                    }
                },
                .nested => |nested_pm| try nested_pm.collectDependentDialects(allocator, names),
            }
        }
    }

    fn matchesOp(self: *const OpPassManager, op: *ir.Operation) bool {
        return switch (self.target_kind) {
            .root, .any => true,
            .op => std.mem.eql(u8, op.name.name, self.target_op_name.?),
        };
    }

    fn matchesScheduledOp(
        self: *const OpPassManager,
        op: *ir.Operation,
        ir_ctx: *ir.Context,
    ) bool {
        return switch (self.target_kind) {
            .root => true,
            .op => self.matchesOp(op),
            .any => self.isRegisteredIsolatedTarget(op, ir_ctx),
        };
    }

    fn canRunOnTarget(
        self: *const OpPassManager,
        op: *ir.Operation,
        ir_ctx: *ir.Context,
    ) bool {
        if (self.target_kind == .root) return true;
        if (self.target_kind == .any) return self.isRegisteredIsolatedTarget(op, ir_ctx);
        const info = op.name.getRegisteredInfo() orelse
            ir_ctx.lookupOperation(op.name.name) orelse return false;
        return info.hasTraitId(ir.traits.IsolatedFromAbove.id);
    }

    fn isRegisteredIsolatedTarget(
        _: *const OpPassManager,
        op: *ir.Operation,
        ir_ctx: *ir.Context,
    ) bool {
        const info = op.name.getRegisteredInfo() orelse
            ir_ctx.lookupOperation(op.name.name) orelse return false;
        return info.hasTraitId(ir.traits.IsolatedFromAbove.id);
    }

    fn instrumentationTargetName(self: *const OpPassManager) ?[]const u8 {
        return switch (self.target_kind) {
            .root => null,
            .any => "any",
            .op => self.target_op_name,
        };
    }

    pub fn runOnOperation(
        self: *OpPassManager,
        op: *ir.Operation,
        ir_ctx: *ir.Context,
        analysis_cache: *AnalysisCache,
        stats: *PassManagerStats,
        instrumentor: ?*const PassInstrumentor,
        verifier: ?*PassVerifierConfig,
        failure: ?*?CapturedPassFailure,
        options: PassManagerRunOptions,
        run_allocator: std.mem.Allocator,
    ) PassResult {
        if (!self.matchesScheduledOp(op, ir_ctx)) {
            return .success;
        }

        const pipeline_info = PipelineInfo{
            .target_op_name = self.instrumentationTargetName(),
            .depth = self.getNestingDepth(),
        };

        if (instrumentor) |inst| {
            inst.runBeforePipeline(pipeline_info, op);
        }

        if (!self.canRunOnTarget(op, ir_ctx)) {
            if (instrumentor) |inst| {
                inst.runAfterPipeline(pipeline_info, op, true);
            }
            recordPassFailure(failure, .{
                .kind = .target,
                .target_op_name = op.name.name,
                .target_symbol_name = ir.SymbolTable.getSymbolName(op),
            });
            return .failure;
        }

        var run = PipelineRun{
            .op = op,
            .ir_ctx = ir_ctx,
            .analysis_cache = analysis_cache,
            .stats = stats,
            .instrumentor = instrumentor,
            .verifier = verifier,
            .failure = failure,
            .options = options,
            .allocator = run_allocator,
        };
        const result = self.runPipelineEntries(&run);
        if (instrumentor) |inst| {
            inst.runAfterPipeline(pipeline_info, op, result == .failure);
        }
        return result;
    }

    fn runPipelineEntries(self: *const OpPassManager, run: *PipelineRun) PassResult {
        var revision_start: usize = 0;

        for (self.pipeline.items, 0..) |entry, entry_index| {
            const result = switch (entry) {
                .pass => |pass| self.runPassEntry(
                    pass,
                    entry_index,
                    &revision_start,
                    run,
                ),
                .nested => |nested_pm| runNestedEntry(
                    nested_pm,
                    entry_index,
                    &revision_start,
                    run,
                ),
            };
            if (result == .failure) return .failure;
        }
        return .success;
    }

    /// A failing pass that reports IR modification preserves only analyses it declared preserved.
    fn runPassEntry(
        self: *const OpPassManager,
        pass: Pass,
        entry_index: usize,
        revision_start: *usize,
        run: *PipelineRun,
    ) PassResult {
        if (run.analysis_cache.accounting == null and
            self.hasRerunIdentity(pass, revision_start.*, entry_index))
        {
            run.stats.passes_skipped += 1;
            return .success;
        }

        const pass_info = PassInfo{
            .name = pass.name,
            .description = pass.description,
            .target_op = run.op,
            .mutation_scope = pass.mutation_scope,
        };
        if (run.instrumentor) |inst| inst.runBeforePass(pass_info);

        var ctx = PassContext.initWithInstrumentorAndOptions(
            run.op,
            run.ir_ctx,
            run.allocator,
            run.analysis_cache,
            run.instrumentor,
            run.options,
        );
        ctx.pass_info = pass_info;
        defer ctx.deinit();

        const work = PassWork.begin(pass, run);
        var finalized: PassResult = .failure;
        defer work.finish(finalized, run.stats.*);
        const native = if (work.admitted) pass.run(&ctx) else PassResult.failure;
        const result = work.normalize(native, pass, run);
        if (work.admitted) run.stats.pass_runs += 1;
        if (ctx.modified) {
            run.stats.passes_modified += 1;
            run.analysis_cache.invalidate(&ctx.preserved);
            revision_start.* = entry_index;
        }
        if (result == .failure) {
            run.stats.pass_failures += 1;
            if (run.instrumentor) |inst| inst.runAfterPassFailed(pass_info);
            recordPassFailure(run.failure, .{
                .kind = .pass,
                .pass_name = pass.name,
                .target_op_name = run.op.name.name,
                .target_symbol_name = ir.SymbolTable.getSymbolName(run.op),
            });
            return .failure;
        }

        if (run.instrumentor) |inst| inst.runAfterPass(pass_info, ctx.modified);
        finalized = verifyPass(pass, pass_info, run);
        return finalized;
    }

    fn verifyPass(pass: Pass, pass_info: PassInfo, run: *PipelineRun) PassResult {
        const verifier = run.verifier orelse return .success;
        if (verifier.verifyAfterPass(pass_info) == .success) return .success;

        run.stats.verifier_failures += 1;
        recordPassFailure(run.failure, .{
            .kind = .verifier,
            .pass_name = pass.name,
            .target_op_name = run.op.name.name,
            .target_symbol_name = ir.SymbolTable.getSymbolName(run.op),
            .verifier_error = if (verifier.failure.*) |failure| failure.err else null,
        });
        return .failure;
    }

    fn runNestedEntry(
        nested: *OpPassManager,
        entry_index: usize,
        revision_start: *usize,
        run: *PipelineRun,
    ) PassResult {
        const modified_before = run.stats.passes_modified;
        const result = nested.walkAndRun(
            run.op,
            run.ir_ctx,
            run.analysis_cache,
            run.stats,
            run.instrumentor,
            run.verifier,
            run.failure,
            run.options,
            run.allocator,
        );
        if (result == .failure) return .failure;
        if (run.stats.passes_modified != modified_before) {
            revision_start.* = entry_index + 1;
        }
        return .success;
    }

    fn hasRerunIdentity(
        self: *const OpPassManager,
        pass: Pass,
        revision_start: usize,
        entry_index: usize,
    ) bool {
        std.debug.assert(revision_start <= entry_index);
        std.debug.assert(entry_index <= self.pipeline.items.len);
        var previous_index = entry_index;
        while (previous_index > revision_start) {
            previous_index -= 1;
            switch (self.pipeline.items[previous_index]) {
                .pass => |previous| if (pass.sameRerunIdentity(previous)) return true,
                .nested => {},
            }
        }
        return false;
    }

    fn walkAndRun(
        self: *OpPassManager,
        root: *ir.Operation,
        ir_ctx: *ir.Context,
        analysis_cache: *AnalysisCache,
        stats: *PassManagerStats,
        instrumentor: ?*const PassInstrumentor,
        verifier: ?*PassVerifierConfig,
        failure: ?*?CapturedPassFailure,
        options: PassManagerRunOptions,
        run_allocator: std.mem.Allocator,
    ) PassResult {
        if (self.canRunNestedTargetsParallel(instrumentor, verifier, options)) {
            const targets = self.collectMatchingTargets(root, ir_ctx) catch return .failure;
            defer if (targets.len != 0) self.allocator.free(targets);

            if (targets.len > 1 and !targetSetOverlaps(targets)) {
                return self.runTargetsParallel(
                    targets,
                    ir_ctx,
                    analysis_cache,
                    stats,
                    verifier,
                    failure,
                    options,
                );
            }
        }
        return self.walkAndRunSerial(
            root,
            ir_ctx,
            analysis_cache,
            stats,
            instrumentor,
            verifier,
            failure,
            options,
            run_allocator,
        );
    }

    fn walkAndRunSerial(
        self: *OpPassManager,
        root: *ir.Operation,
        ir_ctx: *ir.Context,
        analysis_cache: *AnalysisCache,
        stats: *PassManagerStats,
        instrumentor: ?*const PassInstrumentor,
        verifier: ?*PassVerifierConfig,
        failure: ?*?CapturedPassFailure,
        options: PassManagerRunOptions,
        run_allocator: std.mem.Allocator,
    ) PassResult {
        for (root.regions.items) |*region| {
            var block_iter = region.getBlocks();
            while (block_iter.next()) |block| {
                var current_op: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
                while (current_op) |nested_op| {
                    if (self.matchesScheduledOp(nested_op, ir_ctx)) {
                        const result = self.runOnOperation(
                            nested_op,
                            ir_ctx,
                            analysis_cache,
                            stats,
                            instrumentor,
                            verifier,
                            failure,
                            options,
                            run_allocator,
                        );
                        if (result == .failure) {
                            return .failure;
                        }
                    }
                    const walk_result = self.walkAndRunSerial(
                        nested_op,
                        ir_ctx,
                        analysis_cache,
                        stats,
                        instrumentor,
                        verifier,
                        failure,
                        options,
                        run_allocator,
                    );
                    if (walk_result == .failure) {
                        return .failure;
                    }
                    current_op = nested_op.next_op;
                }
            }
        }
        return .success;
    }

    fn canRunNestedTargetsParallel(
        self: *const OpPassManager,
        instrumentor: ?*const PassInstrumentor,
        verifier: ?*PassVerifierConfig,
        options: PassManagerRunOptions,
    ) bool {
        if (instrumentor != null) return false;
        _ = verifier;
        if (!options.requestsParallelism()) return false;
        return self.parallelReadOnlyPipeline();
    }

    fn parallelReadOnlyPipeline(self: *const OpPassManager) bool {
        for (self.pipeline.items) |entry| {
            switch (entry) {
                .pass => |pass| {
                    if (!pass.readOnly() or !pass.parallelStateSafe()) return false;
                },
                .nested => |nested_pm| if (!nested_pm.parallelReadOnlyPipeline()) return false,
            }
        }
        return true;
    }

    fn cloneForParallelTarget(
        self: *const OpPassManager,
        allocator: std.mem.Allocator,
    ) anyerror!OpPassManager {
        var cloned = OpPassManager.initWithTarget(
            allocator,
            self.target_kind,
            self.target_op_name,
        );
        errdefer cloned.deinit();

        for (self.pipeline.items) |entry| {
            switch (entry) {
                .pass => |pass| {
                    var pass_clone = try pass.cloneForParallelTarget(allocator);
                    var pass_registered = false;
                    errdefer if (!pass_registered) pass_clone.deinit(allocator);
                    try cloned.pipeline.append(allocator, .{ .pass = pass_clone });
                    pass_registered = true;
                },
                .nested => |nested_pm| {
                    const nested = try allocator.create(OpPassManager);
                    var nested_initialized = false;
                    var nested_registered = false;
                    errdefer if (!nested_registered) {
                        if (nested_initialized) nested.deinit();
                        allocator.destroy(nested);
                    };
                    nested.* = try nested_pm.cloneForParallelTarget(allocator);
                    nested_initialized = true;
                    nested.parent = &cloned;
                    try cloned.nested_managers.append(allocator, nested);
                    nested_registered = true;
                    try cloned.pipeline.append(allocator, .{ .nested = nested });
                },
            }
        }

        return cloned;
    }

    fn refreshParentLinks(self: *OpPassManager, parent: ?*OpPassManager) void {
        self.parent = parent;
        for (self.nested_managers.items) |nested| {
            nested.refreshParentLinks(self);
        }
    }

    fn collectMatchingTargets(
        self: *OpPassManager,
        root: *ir.Operation,
        ir_ctx: *ir.Context,
    ) ![]*ir.Operation {
        var targets: std.ArrayListUnmanaged(*ir.Operation) = .empty;
        errdefer targets.deinit(self.allocator);

        try self.collectMatchingTargetsInto(root, ir_ctx, &targets);
        return if (targets.items.len == 0)
            &.{}
        else
            try targets.toOwnedSlice(self.allocator);
    }

    fn collectMatchingTargetsInto(
        self: *OpPassManager,
        root: *ir.Operation,
        ir_ctx: *ir.Context,
        targets: *std.ArrayListUnmanaged(*ir.Operation),
    ) !void {
        for (root.regions.items) |*region| {
            var block_iter = region.getBlocks();
            while (block_iter.next()) |block| {
                var current_op: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
                while (current_op) |nested_op| {
                    if (self.matchesScheduledOp(nested_op, ir_ctx)) {
                        try targets.append(self.allocator, nested_op);
                    }
                    try self.collectMatchingTargetsInto(nested_op, ir_ctx, targets);
                    current_op = nested_op.next_op;
                }
            }
        }
    }

    fn runTargetsParallel(
        self: *OpPassManager,
        targets: []const *ir.Operation,
        ir_ctx: *ir.Context,
        analysis_cache: *AnalysisCache,
        stats: *PassManagerStats,
        verifier: ?*PassVerifierConfig,
        failure: ?*?CapturedPassFailure,
        options: PassManagerRunOptions,
    ) PassResult {
        _ = analysis_cache;

        const worker_allocator = options.workerAllocator(self.allocator);
        const slots = self.allocator.alloc(ParallelTargetSlot, targets.len) catch return .failure;
        defer self.allocator.free(slots);
        for (slots) |*slot| slot.* = ParallelTargetSlot.init(worker_allocator);
        defer deinitParallelTargetSlots(slots);
        for (slots) |*slot| {
            slot.manager = self.cloneForParallelTarget(worker_allocator) catch return .failure;
            slot.manager.?.refreshParentLinks(null);
        }

        var batch = ParallelTargetBatch{
            .manager = self,
            .allocator = worker_allocator,
            .ir_ctx = ir_ctx,
            .targets = targets,
            .verifier = verifier,
            .failure = failure,
            .options = options,
            .slots = slots,
        };

        var execution_guard: ?ir.ThreadingExecutionGuard = null;
        if (options.workerCount(targets.len) > 1) {
            execution_guard = ir_ctx.enterMultithreadedExecution();
        }
        defer if (execution_guard) |*guard| guard.deinit();

        ir.threading.parallelForEachIndex(
            self.allocator,
            options,
            targets.len,
            &batch,
            runParallelTarget,
        ) catch return .failure;

        var result: PassResult = .success;
        for (slots) |*slot| {
            mergeStats(stats, slot.stats);
            if (slot.result == .failure) result = .failure;
            if (slot.failure) |captured_failure| {
                var slot_failure = captured_failure;
                slot_failure.worker_count = options.workerCount(targets.len);
                recordPassFailure(failure, slot_failure);
            }
            if (slot.verifier_failure) |verifier_failure| {
                if (verifier) |verify| {
                    if (verify.failure.* == null) verify.failure.* = verifier_failure;
                }
            }
            _ = ir_ctx.replayDiagnostics(&slot.diagnostics) catch {
                result = .failure;
                continue;
            };
        }
        return result;
    }

    pub fn getNestingDepth(self: *const OpPassManager) usize {
        var depth: usize = 0;
        var current: ?*const OpPassManager = self;
        while (current) |pm| {
            if (pm.parent) |parent| {
                depth += 1;
                current = parent;
            } else {
                break;
            }
        }
        return depth;
    }
};

pub const PassManager = struct {
    allocator: std.mem.Allocator,
    root: OpPassManager,
    stats: PassManagerStats,
    instrumentor: ?PassInstrumentor,
    verifier_enabled: bool,
    verifier_options: ir.verify.VerifyOptions,
    last_verifier_failure: ?PassVerifierFailure,
    last_failure_reproducer: ?PassFailureReproducer,

    pub fn init(allocator: std.mem.Allocator) PassManager {
        return .{
            .allocator = allocator,
            .root = OpPassManager.init(allocator, null),
            .stats = .{},
            .instrumentor = null,
            .verifier_enabled = false,
            .verifier_options = ir.verify.default_options,
            .last_verifier_failure = null,
            .last_failure_reproducer = null,
        };
    }

    pub fn deinit(self: *PassManager) void {
        self.clearLastFailureReproducer();
        if (self.instrumentor) |*inst| {
            inst.deinit();
        }
        self.root.deinit();
    }

    pub fn addPass(self: *PassManager, pass: Pass) !void {
        try self.root.addPass(pass);
    }

    pub fn nest(self: *PassManager, op_name: []const u8) !*OpPassManager {
        return self.root.nest(op_name);
    }

    pub fn nestAny(self: *PassManager) !*OpPassManager {
        return self.root.nestAny();
    }

    pub fn resetStats(self: *PassManager) void {
        self.stats.reset();
    }

    pub fn addInstrumentation(self: *PassManager, inst: PassInstrumentation) !void {
        if (self.instrumentor == null) {
            self.instrumentor = PassInstrumentor.init(self.allocator);
        }
        try self.instrumentor.?.addInstrumentation(inst);
    }

    pub fn getInstrumentor(self: *PassManager) ?*const PassInstrumentor {
        if (self.instrumentor) |*inst| {
            return inst;
        }
        return null;
    }

    pub fn enableVerifier(self: *PassManager) void {
        self.enableVerifierWithOptions(ir.verify.default_options);
    }

    pub fn enableVerifierWithOptions(self: *PassManager, options: ir.verify.VerifyOptions) void {
        self.verifier_enabled = true;
        self.verifier_options = options;
        self.last_verifier_failure = null;
    }

    pub fn disableVerifier(self: *PassManager) void {
        self.verifier_enabled = false;
        self.last_verifier_failure = null;
    }

    pub fn verifierEnabled(self: *const PassManager) bool {
        return self.verifier_enabled;
    }

    pub fn getLastVerifierFailure(self: *const PassManager) ?PassVerifierFailure {
        return self.last_verifier_failure;
    }

    pub fn getLastFailureReproducer(self: *const PassManager) ?*const PassFailureReproducer {
        if (self.last_failure_reproducer) |*reproducer| return reproducer;
        return null;
    }

    pub fn run(self: *PassManager, op: *ir.Operation, ir_ctx: *ir.Context) PassResult {
        return self.runWithOptions(op, ir_ctx, .{});
    }

    pub fn runWithOptions(
        self: *PassManager,
        op: *ir.Operation,
        ir_ctx: *ir.Context,
        options: PassManagerRunOptions,
    ) PassResult {
        var analysis_cache = AnalysisCache.init(self.allocator, null);
        defer analysis_cache.deinit();

        return self.runWithAnalysisCache(op, ir_ctx, &analysis_cache, options);
    }

    pub fn runWithAnalysisCache(
        self: *PassManager,
        op: *ir.Operation,
        ir_ctx: *ir.Context,
        analysis_cache: *AnalysisCache,
        options: PassManagerRunOptions,
    ) PassResult {
        if (analysis_cache.accounting) |ledger| {
            if (ledger.view().outcome != .running) return .failure;
        }
        self.clearLastFailureReproducer();
        self.last_verifier_failure = null;
        if (analysis_cache.accounting) |ledger| {
            if (options.max_threads != 1 or options.worker_allocator != null) {
                ledger.missingContract();
                ledger.fail(.rejected);
                self.captureFailureReproducer(op, options, .{
                    .kind = .target,
                    .target_op_name = op.name.name,
                    .target_symbol_name = ir.SymbolTable.getSymbolName(op),
                });
                return .failure;
            }
        }

        if (self.prepareDependentDialects(ir_ctx) == .failure) {
            self.captureFailureReproducer(op, options, null);
            return .failure;
        }

        const previous_stats = analysis_cache.stats;
        analysis_cache.stats = &self.stats;
        defer analysis_cache.stats = previous_stats;

        const inst_ptr: ?*const PassInstrumentor = if (self.instrumentor) |*inst| inst else null;
        var verifier_config = self.beginVerifierRun();
        const verifier_ptr: ?*PassVerifierConfig = if (verifier_config) |*config| config else null;

        const pass_runs_before = self.stats.pass_runs;
        defer ir_ctx.recordPassRuns(self.stats.pass_runs - pass_runs_before);
        var failure: ?CapturedPassFailure = null;
        const result = self.root.runOnOperation(
            op,
            ir_ctx,
            analysis_cache,
            &self.stats,
            inst_ptr,
            verifier_ptr,
            &failure,
            options,
            self.allocator,
        );
        if (result == .failure) self.captureFailureReproducer(op, options, failure);
        return result;
    }

    pub fn runToFixedPoint(
        self: *PassManager,
        op: *ir.Operation,
        ir_ctx: *ir.Context,
        max_iterations: usize,
    ) PassManagerFixedPointResult {
        return self.runToFixedPointWithOptions(op, ir_ctx, max_iterations, .{});
    }

    pub fn runToFixedPointWithOptions(
        self: *PassManager,
        op: *ir.Operation,
        ir_ctx: *ir.Context,
        max_iterations: usize,
        options: PassManagerRunOptions,
    ) PassManagerFixedPointResult {
        var fixed_point: PassManagerFixedPointResult = .{};
        self.clearLastFailureReproducer();
        self.last_verifier_failure = null;

        if (self.prepareDependentDialects(ir_ctx) == .failure) {
            fixed_point.result = .failure;
            self.captureFailureReproducer(op, options, null);
            return fixed_point;
        }

        var analysis_cache = AnalysisCache.init(self.allocator, &self.stats);
        defer analysis_cache.deinit();

        const inst_ptr: ?*const PassInstrumentor = if (self.instrumentor) |*inst| inst else null;
        var verifier_config = self.beginVerifierRun();
        const verifier_ptr: ?*PassVerifierConfig = if (verifier_config) |*config| config else null;

        const pass_runs_before = self.stats.pass_runs;
        defer ir_ctx.recordPassRuns(self.stats.pass_runs - pass_runs_before);
        for (0..max_iterations) |_| {
            const before_modified = self.stats.passes_modified;
            fixed_point.iterations += 1;

            var failure: ?CapturedPassFailure = null;
            const result = self.root.runOnOperation(
                op,
                ir_ctx,
                &analysis_cache,
                &self.stats,
                inst_ptr,
                verifier_ptr,
                &failure,
                options,
                self.allocator,
            );
            if (result == .failure) {
                fixed_point.result = .failure;
                self.captureFailureReproducer(op, options, failure);
                return fixed_point;
            }

            const iteration_changed = self.stats.passes_modified != before_modified;
            fixed_point.changed = fixed_point.changed or iteration_changed;
            if (!iteration_changed) break;
        }

        return fixed_point;
    }

    fn clearLastFailureReproducer(self: *PassManager) void {
        if (self.last_failure_reproducer) |*reproducer| {
            reproducer.deinit(self.allocator);
            self.last_failure_reproducer = null;
        }
    }

    fn captureFailureReproducer(
        self: *PassManager,
        op: *ir.Operation,
        options: PassManagerRunOptions,
        failure: ?CapturedPassFailure,
    ) void {
        self.clearLastFailureReproducer();

        const pipeline_text = textual_pipeline.formatPassManagerPipelineAlloc(
            self.allocator,
            self,
        ) catch return;

        const ir_text = ir.dump.operationAlloc(self.allocator, op) catch {
            self.allocator.free(pipeline_text);
            return;
        };

        var reproducer = PassFailureReproducer{
            .pipeline = pipeline_text,
            .ir = ir_text,
            .max_threads = options.max_threads,
            .worker_count = if (failure) |captured| captured.worker_count else 1,
            .verifier_enabled = self.verifier_enabled,
        };
        var stored = false;
        defer if (!stored) reproducer.deinit(self.allocator);

        if (failure) |captured| {
            reproducer.failure_kind = captured.kind;
            if (captured.pass_name) |name| {
                reproducer.pass_name = self.allocator.dupe(u8, name) catch return;
            }
            reproducer.target_op_name = self.allocator.dupe(
                u8,
                captured.target_op_name,
            ) catch return;
            if (captured.target_symbol_name) |name| {
                reproducer.target_symbol_name = self.allocator.dupe(u8, name) catch return;
            }
            reproducer.verifier_error = captured.verifier_error;
            if (captured.verifier_error) |err| {
                reproducer.verifier_error_name = self.allocator.dupe(
                    u8,
                    @errorName(err),
                ) catch return;
            }
        }

        self.last_failure_reproducer = reproducer;
        stored = true;
    }

    fn beginVerifierRun(self: *PassManager) ?PassVerifierConfig {
        if (!self.verifier_enabled) return null;
        return .{
            .options = self.verifier_options,
            .failure = &self.last_verifier_failure,
        };
    }

    fn prepareDependentDialects(self: *PassManager, ir_ctx: *ir.Context) PassResult {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(self.allocator);

        self.root.collectDependentDialects(self.allocator, &names) catch return .failure;

        for (names.items) |name| {
            _ = ir_ctx.getOrLoadDialect(name) catch return .failure;
        }

        return .success;
    }
};

fn appendDependentDialectName(
    allocator: std.mem.Allocator,
    names: *std.ArrayListUnmanaged([]const u8),
    name: []const u8,
) !void {
    if (name.len == 0) return error.EmptyDependentDialectName;
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(allocator, name);
}

fn mergeStats(into: *PassManagerStats, other: PassManagerStats) void {
    into.pass_runs += other.pass_runs;
    into.passes_skipped += other.passes_skipped;
    into.pass_failures += other.pass_failures;
    into.verifier_failures += other.verifier_failures;
    into.passes_modified += other.passes_modified;
    into.analysis_hits += other.analysis_hits;
    into.analysis_misses += other.analysis_misses;
    into.analyses_invalidated += other.analyses_invalidated;
}

fn targetSetOverlaps(targets: []const *ir.Operation) bool {
    for (targets, 0..) |left, left_index| {
        for (targets[left_index + 1 ..]) |right| {
            if (left.isProperAncestor(right) or right.isProperAncestor(left)) return true;
        }
    }
    return false;
}

const ParallelTargetSlot = struct {
    result: PassResult = .success,
    stats: PassManagerStats = .{},
    verifier_failure: ?PassVerifierFailure = null,
    failure: ?CapturedPassFailure = null,
    diagnostics: diagnostics.CaptureBuffer,
    manager: ?OpPassManager = null,

    fn init(allocator: std.mem.Allocator) ParallelTargetSlot {
        return .{ .diagnostics = diagnostics.CaptureBuffer.init(allocator) };
    }

    fn deinit(self: *ParallelTargetSlot) void {
        if (self.manager) |*manager| manager.deinit();
        self.diagnostics.deinit();
        self.* = undefined;
    }
};

fn deinitParallelTargetSlots(slots: []ParallelTargetSlot) void {
    for (slots) |*slot| slot.deinit();
}

const ParallelTargetBatch = struct {
    manager: *OpPassManager,
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    targets: []const *ir.Operation,
    verifier: ?*PassVerifierConfig,
    failure: ?*?CapturedPassFailure,
    options: PassManagerRunOptions,
    slots: []ParallelTargetSlot,
};

fn runParallelTarget(batch: *ParallelTargetBatch, index: usize) void {
    var capture = batch.ir_ctx.captureDiagnostics(&batch.slots[index].diagnostics);
    var capture_guard = capture.enter();
    defer capture_guard.deinit();

    var stats: PassManagerStats = .{};
    var analysis_cache = AnalysisCache.init(batch.allocator, &stats);
    defer analysis_cache.deinit();

    var local_verifier: PassVerifierConfig = undefined;
    const verifier_ptr: ?*PassVerifierConfig = if (batch.verifier) |verify| blk: {
        local_verifier = .{
            .options = verify.options,
            .failure = &batch.slots[index].verifier_failure,
        };
        break :blk &local_verifier;
    } else null;

    const target_manager = &batch.slots[index].manager.?;
    const result = target_manager.runOnOperation(
        batch.targets[index],
        batch.ir_ctx,
        &analysis_cache,
        &stats,
        null,
        verifier_ptr,
        &batch.slots[index].failure,
        batch.options,
        batch.allocator,
    );
    batch.slots[index].result = result;
    batch.slots[index].stats = stats;
}
