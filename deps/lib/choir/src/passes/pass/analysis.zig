const std = @import("std");
const revision = @import("../../product/revision/root.zig");
const ir = @import("../../core/root.zig");
const passes = @import("../root.zig");
const subject = @import("root.zig");
const instrumentation = passes.instrumentation;

const AnalysisId = subject.AnalysisId;
const AnalysisInfo = instrumentation.AnalysisInfo;
const PassInfo = instrumentation.PassInfo;
const PassInstrumentor = instrumentation.PassInstrumentor;
const PassManagerRunOptions = subject.PassManagerRunOptions;
const PassManagerStats = subject.PassManagerStats;
const analysisId = subject.analysisId;

pub const AnalysisDescriptor = struct {
    work_contract: ?subject.work.Contract = null,
    id: AnalysisId,
    name: []const u8,
    required_interfaces: []const ir.InterfaceId = &.{},
};

pub fn Analysis(
    comptime Value: type,
    comptime name: []const u8,
    comptime required_interfaces: []const ir.InterfaceId,
    comptime compute: *const fn (*PassContext, *ir.Operation) anyerror!*Value,
    comptime cleanup: ?*const fn (*Value, std.mem.Allocator) void,
    comptime work_contract: ?subject.work.Contract,
) type {
    return struct {
        pub const id = analysisId(name);
        pub const value_type = Value;
        pub const descriptor = AnalysisDescriptor{
            .id = id,
            .name = name,
            .required_interfaces = required_interfaces,
            .work_contract = work_contract,
        };

        pub fn get(ctx: *PassContext, op: *ir.Operation) !*Value {
            const raw = try ctx.getAnalysis(op, &descriptor, computeOpaque, cleanupOpaque);
            return @ptrCast(@alignCast(raw));
        }

        pub fn preserve(ctx: *PassContext) !void {
            try ctx.preserveAnalysis(id);
        }

        fn computeOpaque(ctx: *PassContext, op: *ir.Operation) anyerror!*anyopaque {
            return @ptrCast(try compute(ctx, op));
        }

        fn cleanupOpaque(raw: *anyopaque, allocator: std.mem.Allocator) void {
            if (cleanup) |cleanup_fn| {
                cleanup_fn(@ptrCast(@alignCast(raw)), allocator);
            }
        }
    };
}

pub const PreservedAnalyses = struct {
    allocator: std.mem.Allocator,
    preserve_all: bool = false,
    analysis_set: []const AnalysisId,
    runtime_analyses: std.AutoHashMap(AnalysisId, void),
    interfaces: std.AutoHashMap(ir.InterfaceId, void),

    pub fn init(allocator: std.mem.Allocator) PreservedAnalyses {
        return .{
            .allocator = allocator,
            .analysis_set = &.{},
            .runtime_analyses = std.AutoHashMap(AnalysisId, void).init(allocator),
            .interfaces = std.AutoHashMap(ir.InterfaceId, void).init(allocator),
            .preserve_all = false,
        };
    }

    pub fn deinit(self: *PreservedAnalyses) void {
        self.runtime_analyses.deinit();
        self.interfaces.deinit();
    }

    pub fn preserveAll(self: *PreservedAnalyses) void {
        self.preserve_all = true;
    }

    pub fn preserveAnalysisSet(self: *PreservedAnalyses, comptime ids: []const AnalysisId) void {
        std.debug.assert(self.analysis_set.len == 0);
        self.analysis_set = ids;
    }

    pub fn preserveAnalysis(self: *PreservedAnalyses, id: AnalysisId) !void {
        for (self.analysis_set) |preserved_id| {
            if (preserved_id == id) return;
        }
        try self.runtime_analyses.put(id, {});
    }

    pub fn preserveInterface(self: *PreservedAnalyses, id: ir.InterfaceId) !void {
        try self.interfaces.put(id, {});
    }

    fn preservesDescriptor(self: *const PreservedAnalyses, desc: *const AnalysisDescriptor) bool {
        if (self.preserve_all) return true;
        for (self.analysis_set) |id| {
            if (id == desc.id) return true;
        }
        if (self.runtime_analyses.contains(desc.id)) return true;
        if (desc.required_interfaces.len == 0) return false;
        for (desc.required_interfaces) |iface| {
            if (!self.interfaces.contains(iface)) return false;
        }
        return true;
    }
};

const AnalysisKey = struct {
    op: *ir.Operation,
    analysis: AnalysisId,
};

const AnalysisEntry = struct {
    descriptor: *const AnalysisDescriptor,
    value: *anyopaque,
    cleanup: ?*const fn (*anyopaque, std.mem.Allocator) void,
};

pub const AnalysisCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(AnalysisKey, AnalysisEntry),
    stats: ?*PassManagerStats,
    accounting: ?*revision.AccountingV1 = null,
    allocation_failure: subject.work.AllocationFailure = .{},
    entry_limit: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, stats: ?*PassManagerStats) AnalysisCache {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap(AnalysisKey, AnalysisEntry).init(allocator),
            .stats = stats,
        };
    }

    /// The ledger outlives this fresh cache and every computation using it.
    pub fn initAccounted(
        allocator: std.mem.Allocator,
        stats: ?*PassManagerStats,
        accounting: *revision.AccountingV1,
        allocation_failure: subject.work.AllocationFailure,
        entry_limit: u32,
    ) !AnalysisCache {
        if (allocation_failure.exhausted()) {
            accounting.fail(.exhausted);
            return error.WorkExhausted;
        }
        var cache = init(allocator, stats);
        cache.accounting = accounting;
        cache.allocation_failure = allocation_failure;
        cache.entry_limit = entry_limit;
        errdefer cache.deinit();
        const bytes = storageBound(entry_limit) catch |err| {
            accounting.fail(.exhausted);
            return err;
        };
        const token = try accounting.begin(.input, .{
            .identity = .{ .name = "choir-analysis-cache", .version = 1 },
            .work = .{ .allocation_capacity = bytes },
            .workspace = bytes,
            .retained_storage = bytes,
        });
        cache.entries.ensureTotalCapacity(entry_limit) catch |err| {
            const failure = allocation_failure.classify(err);
            accounting.fail(if (failure == error.WorkExhausted) .exhausted else .rejected);
            try accounting.finish(token, .rejected, .{});
            return failure;
        };
        try accounting.finish(token, .success, .{});
        return cache;
    }

    /// Bounds the pinned HashMap header, aligned keys/values and one-byte slot metadata.
    /// The table is allocated once, before the first computation, without later growth.
    pub fn storageBound(entry_limit: u32) !u64 {
        if (entry_limit == 0) return 0;
        const load_capacity = @as(u64, entry_limit) * 100 / 80 + 1;
        if (load_capacity > std.math.maxInt(u32)) return error.WorkOverflow;
        const capacity = std.math.ceilPowerOfTwo(u32, @intCast(load_capacity)) catch
            return error.WorkOverflow;
        if (capacity > std.math.maxInt(u32) / 80) return error.WorkOverflow;
        const slots: u64 = @max(8, capacity);
        const slot_bytes = 1 + @sizeOf(AnalysisKey) + @sizeOf(AnalysisEntry);
        const alignment = @max(@alignOf(usize), @alignOf(AnalysisKey), @alignOf(AnalysisEntry));
        const bytes = 4 * @sizeOf(usize) + 3 * alignment + slots * slot_bytes;
        if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
        return bytes;
    }

    pub fn deinit(self: *AnalysisCache) void {
        var iter = self.entries.valueIterator();
        while (iter.next()) |entry| {
            if (entry.cleanup) |cleanup| {
                cleanup(entry.value, self.allocator);
            }
        }
        self.entries.deinit();
    }

    pub fn getOrCompute(
        self: *AnalysisCache,
        ctx: *PassContext,
        op: *ir.Operation,
        descriptor: *const AnalysisDescriptor,
        compute: *const fn (*PassContext, *ir.Operation) anyerror!*anyopaque,
        cleanup: ?*const fn (*anyopaque, std.mem.Allocator) void,
        instrumentor: ?*const PassInstrumentor,
    ) !*anyopaque {
        try self.requireRunning();
        const key = AnalysisKey{ .op = op, .analysis = descriptor.id };
        if (self.entries.get(key)) |entry| {
            if (self.accounting) |ledger| try ledger.observeCounters(.{ .analysis_hits = 1 });
            if (self.stats) |stats| stats.analysis_hits += 1;
            return entry.value;
        }
        const run = try Computation.begin(self.accounting, descriptor, op, ctx.run_options);
        if (self.entry_limit) |limit| {
            if (self.entries.count() >= limit) {
                try run.finish(error.WorkExhausted, false);
                return error.WorkExhausted;
            }
        }
        const value = self.computeAndCache(
            ctx,
            op,
            descriptor,
            compute,
            cleanup,
            instrumentor,
        ) catch |err| {
            const failure = self.allocation_failure.classify(err);
            try run.finish(failure, true);
            return failure;
        };
        try run.finish(null, true);
        return value;
    }

    /// Refresh replaces the cached value in place; failure must leave it intact.
    pub fn refresh(
        self: *AnalysisCache,
        ctx: *PassContext,
        op: *ir.Operation,
        descriptor: *const AnalysisDescriptor,
        refresh_value: *const fn (*PassContext, *ir.Operation, *anyopaque) anyerror!void,
        instrumentor: ?*const PassInstrumentor,
    ) !void {
        try self.requireRunning();
        const entry = self.entries.get(.{ .op = op, .analysis = descriptor.id }) orelse
            return error.UncachedAnalysis;
        const run = try Computation.begin(self.accounting, entry.descriptor, op, ctx.run_options);
        const info = AnalysisInfo{
            .id = descriptor.id,
            .name = descriptor.name,
            .target_op = op,
        };
        if (instrumentor) |inst| inst.runBeforeAnalysis(info);
        refresh_value(ctx, op, entry.value) catch |err| {
            if (instrumentor) |inst| inst.runAfterAnalysis(info);
            const failure = self.allocation_failure.classify(err);
            try run.finish(failure, true);
            return failure;
        };
        if (instrumentor) |inst| inst.runAfterAnalysis(info);
        self.requireRunning() catch |err| {
            try run.finish(err, true);
            return err;
        };
        if (self.stats) |stats| stats.analysis_misses += 1;
        try run.finish(null, true);
    }

    fn computeAndCache(
        self: *AnalysisCache,
        ctx: *PassContext,
        op: *ir.Operation,
        descriptor: *const AnalysisDescriptor,
        compute: *const fn (*PassContext, *ir.Operation) anyerror!*anyopaque,
        cleanup: ?*const fn (*anyopaque, std.mem.Allocator) void,
        instrumentor: ?*const PassInstrumentor,
    ) !*anyopaque {
        const info = AnalysisInfo{
            .id = descriptor.id,
            .name = descriptor.name,
            .target_op = op,
        };
        if (instrumentor) |inst| inst.runBeforeAnalysis(info);
        const value = compute(ctx, op) catch |err| {
            if (instrumentor) |inst| inst.runAfterAnalysis(info);
            return err;
        };
        if (instrumentor) |inst| inst.runAfterAnalysis(info);
        errdefer if (cleanup) |cleanup_fn| cleanup_fn(value, self.allocator);
        try self.requireRunning();

        const key = AnalysisKey{ .op = op, .analysis = descriptor.id };
        const entry = AnalysisEntry{ .descriptor = descriptor, .value = value, .cleanup = cleanup };
        if (self.entry_limit != null) {
            self.entries.putAssumeCapacityNoClobber(key, entry);
        } else {
            try self.entries.put(key, entry);
        }
        if (self.stats) |stats| stats.analysis_misses += 1;
        return value;
    }

    fn requireRunning(self: *AnalysisCache) !void {
        const ledger = self.accounting orelse return;
        if (ledger.view().outcome != .running) return error.TerminalWorkOutcome;
        if (self.allocation_failure.exhausted()) {
            ledger.fail(.exhausted);
            return error.WorkExhausted;
        }
    }

    pub fn invalidate(self: *AnalysisCache, preserved: *const PreservedAnalyses) void {
        if (preserved.preserve_all) return;

        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            if (!preserved.preservesDescriptor(kv.value_ptr.descriptor)) {
                const entry = kv.value_ptr.*;
                self.entries.removeByPtr(kv.key_ptr);
                if (entry.cleanup) |cleanup| {
                    cleanup(entry.value, self.allocator);
                }
                if (self.stats) |stats| stats.analyses_invalidated += 1;
            }
        }
    }
};

const Computation = struct {
    ledger: ?*revision.AccountingV1,
    token: ?u32,

    fn begin(
        ledger: ?*revision.AccountingV1,
        descriptor: *const AnalysisDescriptor,
        op: *ir.Operation,
        options: PassManagerRunOptions,
    ) !Computation {
        return .{
            .ledger = ledger,
            .token = try subject.work.begin(
                ledger,
                .analysis,
                descriptor.work_contract,
                .{ .operation = op, .options = options },
            ),
        };
    }

    fn finish(self: Computation, err: ?anyerror, ran: bool) !void {
        const ledger = self.ledger orelse return;
        if (err) |failure| ledger.fail(if (failure == error.WorkExhausted or
            failure == error.WorkOverflow) .exhausted else .rejected);
        if (self.token) |token| {
            try ledger.finish(token, if (err == null) .success else .rejected, .{
                .work = .{ .analysis_computations = if (ran) 1 else 0 },
                .counters = .{ .analysis_misses = if (err == null) 1 else 0 },
            });
        } else if (err == null) {
            try ledger.observeCounters(.{ .analysis_misses = 1 });
        }
    }
};

pub const PassContext = struct {
    op: *ir.Operation,

    ir_ctx: *ir.Context,

    allocator: std.mem.Allocator,

    analysis_cache: *AnalysisCache,

    preserved: PreservedAnalyses,

    modified: bool,

    instrumentor: ?*const PassInstrumentor,

    run_options: PassManagerRunOptions,

    pass_info: ?PassInfo,

    pub fn init(
        op: *ir.Operation,
        ir_ctx: *ir.Context,
        allocator: std.mem.Allocator,
        analysis_cache: *AnalysisCache,
    ) PassContext {
        return initWithOptions(op, ir_ctx, allocator, analysis_cache, .{});
    }

    pub fn initWithOptions(
        op: *ir.Operation,
        ir_ctx: *ir.Context,
        allocator: std.mem.Allocator,
        analysis_cache: *AnalysisCache,
        options: PassManagerRunOptions,
    ) PassContext {
        return initWithInstrumentorAndOptions(op, ir_ctx, allocator, analysis_cache, null, options);
    }

    pub fn initWithInstrumentor(
        op: *ir.Operation,
        ir_ctx: *ir.Context,
        allocator: std.mem.Allocator,
        analysis_cache: *AnalysisCache,
        instrumentor: ?*const PassInstrumentor,
    ) PassContext {
        return initWithInstrumentorAndOptions(
            op,
            ir_ctx,
            allocator,
            analysis_cache,
            instrumentor,
            .{},
        );
    }

    pub fn initWithInstrumentorAndOptions(
        op: *ir.Operation,
        ir_ctx: *ir.Context,
        allocator: std.mem.Allocator,
        analysis_cache: *AnalysisCache,
        instrumentor: ?*const PassInstrumentor,
        options: PassManagerRunOptions,
    ) PassContext {
        return .{
            .op = op,
            .ir_ctx = ir_ctx,
            .allocator = allocator,
            .analysis_cache = analysis_cache,
            .preserved = PreservedAnalyses.init(allocator),
            .modified = false,
            .instrumentor = instrumentor,
            .run_options = options,
            .pass_info = null,
        };
    }

    pub fn deinit(self: *PassContext) void {
        self.preserved.deinit();
    }

    pub fn markModified(self: *PassContext) void {
        self.modified = true;
    }

    pub fn preserveAllAnalyses(self: *PassContext) void {
        self.preserved.preserveAll();
    }

    pub fn preserveAnalysisSet(self: *PassContext, comptime ids: []const AnalysisId) void {
        self.preserved.preserveAnalysisSet(ids);
    }

    pub fn preserveAnalysis(self: *PassContext, id: AnalysisId) !void {
        try self.preserved.preserveAnalysis(id);
    }

    pub fn preserveInterface(self: *PassContext, id: ir.InterfaceId) !void {
        try self.preserved.preserveInterface(id);
    }

    pub fn getAnalysis(
        self: *PassContext,
        op: *ir.Operation,
        descriptor: *const AnalysisDescriptor,
        compute: *const fn (*PassContext, *ir.Operation) anyerror!*anyopaque,
        cleanup: ?*const fn (*anyopaque, std.mem.Allocator) void,
    ) !*anyopaque {
        return self.analysis_cache.getOrCompute(
            self,
            op,
            descriptor,
            compute,
            cleanup,
            self.instrumentor,
        );
    }

    pub fn refreshAnalysis(
        self: *PassContext,
        op: *ir.Operation,
        descriptor: *const AnalysisDescriptor,
        refresh: *const fn (*PassContext, *ir.Operation, *anyopaque) anyerror!void,
    ) !void {
        try self.analysis_cache.refresh(self, op, descriptor, refresh, self.instrumentor);
    }

    pub fn incrementStatistic(
        self: *PassContext,
        name: []const u8,
        description: []const u8,
    ) void {
        self.addStatistic(name, description, 1);
    }

    pub fn addStatistic(
        self: *PassContext,
        name: []const u8,
        description: []const u8,
        value: u64,
    ) void {
        const pass_info = self.pass_info orelse return;
        const inst = self.instrumentor orelse return;
        inst.runPassStatistic(.{
            .pass = pass_info,
            .name = name,
            .description = description,
            .value = value,
        });
    }

    pub fn workerCount(self: *const PassContext, item_count: usize) usize {
        return self.run_options.workerCount(item_count);
    }

    pub fn workerAllocator(self: *const PassContext) std.mem.Allocator {
        return self.run_options.workerAllocator(self.allocator);
    }
};
