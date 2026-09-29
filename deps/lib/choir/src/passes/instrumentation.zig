const std = @import("std");
const pretty = @import("pretty");
const sys = @import("sys");
const ir = @import("../core/root.zig");
const pass_mod = @import("pass/root.zig");
const verify_mod = @import("../core/root.zig").verify;
const hashing = @import("../root.zig").product.hashing;

fn nowNanos() i128 {
    return sys.time.nanoTimestamp();
}

pub const PassInfo = struct {
    name: []const u8,
    description: []const u8,
    target_op: ?*ir.Operation,
    mutation_scope: pass_mod.PassMutationScope = .whole_module,
};

pub const PipelineInfo = struct {
    target_op_name: ?[]const u8,
    depth: usize,
};

pub const AnalysisInfo = struct {
    id: pass_mod.AnalysisId,
    name: []const u8,
    target_op: *ir.Operation,
};

pub const PassStatisticInfo = struct {
    pass: PassInfo,
    name: []const u8,
    description: []const u8,
    value: u64,
};

const PassStatisticsEntry = struct {
    pass_name: []u8,
    name: []u8,
    description: []u8,
    value: u64,
};

pub const PassStatisticSummary = struct {
    pass_name: []const u8,
    name: []const u8,
    description: []const u8,
    value: u64,
};

pub const PassInstrumentation = struct {
    ctx: ?*anyopaque = null,

    runBeforePipeline: ?*const fn (ctx: ?*anyopaque, info: PipelineInfo, op: *ir.Operation) void = null,

    runAfterPipeline: ?*const fn (ctx: ?*anyopaque, info: PipelineInfo, op: *ir.Operation, failed: bool) void = null,

    runBeforePass: ?*const fn (ctx: ?*anyopaque, info: PassInfo) void = null,

    runAfterPass: ?*const fn (ctx: ?*anyopaque, info: PassInfo, modified: bool) void = null,

    runAfterPassFailed: ?*const fn (ctx: ?*anyopaque, info: PassInfo) void = null,

    runBeforeAnalysis: ?*const fn (ctx: ?*anyopaque, info: AnalysisInfo) void = null,

    runAfterAnalysis: ?*const fn (ctx: ?*anyopaque, info: AnalysisInfo) void = null,

    runPassStatistic: ?*const fn (ctx: ?*anyopaque, info: PassStatisticInfo) void = null,

    pub fn beforePipeline(self: *const PassInstrumentation, info: PipelineInfo, op: *ir.Operation) void {
        if (self.runBeforePipeline) |hook| {
            hook(self.ctx, info, op);
        }
    }

    pub fn afterPipeline(self: *const PassInstrumentation, info: PipelineInfo, op: *ir.Operation, failed: bool) void {
        if (self.runAfterPipeline) |hook| {
            hook(self.ctx, info, op, failed);
        }
    }

    pub fn beforePass(self: *const PassInstrumentation, info: PassInfo) void {
        if (self.runBeforePass) |hook| {
            hook(self.ctx, info);
        }
    }

    pub fn afterPass(self: *const PassInstrumentation, info: PassInfo, modified: bool) void {
        if (self.runAfterPass) |hook| {
            hook(self.ctx, info, modified);
        }
    }

    pub fn afterPassFailed(self: *const PassInstrumentation, info: PassInfo) void {
        if (self.runAfterPassFailed) |hook| {
            hook(self.ctx, info);
        }
    }

    pub fn beforeAnalysis(self: *const PassInstrumentation, info: AnalysisInfo) void {
        if (self.runBeforeAnalysis) |hook| {
            hook(self.ctx, info);
        }
    }

    pub fn afterAnalysis(self: *const PassInstrumentation, info: AnalysisInfo) void {
        if (self.runAfterAnalysis) |hook| {
            hook(self.ctx, info);
        }
    }

    pub fn passStatistic(self: *const PassInstrumentation, info: PassStatisticInfo) void {
        if (self.runPassStatistic) |hook| {
            hook(self.ctx, info);
        }
    }
};

pub const PassInstrumentor = struct {
    allocator: std.mem.Allocator,
    instrumentations: std.ArrayListUnmanaged(PassInstrumentation),

    pub fn init(allocator: std.mem.Allocator) PassInstrumentor {
        return .{
            .allocator = allocator,
            .instrumentations = .empty,
        };
    }

    pub fn deinit(self: *PassInstrumentor) void {
        self.instrumentations.deinit(self.allocator);
    }

    pub fn addInstrumentation(self: *PassInstrumentor, inst: PassInstrumentation) !void {
        try self.instrumentations.append(self.allocator, inst);
    }

    pub fn clear(self: *PassInstrumentor) void {
        self.instrumentations.clearRetainingCapacity();
    }

    pub fn runBeforePipeline(self: *const PassInstrumentor, info: PipelineInfo, op: *ir.Operation) void {
        for (self.instrumentations.items) |*inst| {
            inst.beforePipeline(info, op);
        }
    }

    pub fn runAfterPipeline(self: *const PassInstrumentor, info: PipelineInfo, op: *ir.Operation, failed: bool) void {
        var i = self.instrumentations.items.len;
        while (i > 0) {
            i -= 1;
            self.instrumentations.items[i].afterPipeline(info, op, failed);
        }
    }

    pub fn runBeforePass(self: *const PassInstrumentor, info: PassInfo) void {
        for (self.instrumentations.items) |*inst| {
            inst.beforePass(info);
        }
    }

    pub fn runAfterPass(self: *const PassInstrumentor, info: PassInfo, modified: bool) void {
        var i = self.instrumentations.items.len;
        while (i > 0) {
            i -= 1;
            self.instrumentations.items[i].afterPass(info, modified);
        }
    }

    pub fn runAfterPassFailed(self: *const PassInstrumentor, info: PassInfo) void {
        var i = self.instrumentations.items.len;
        while (i > 0) {
            i -= 1;
            self.instrumentations.items[i].afterPassFailed(info);
        }
    }

    pub fn runBeforeAnalysis(self: *const PassInstrumentor, info: AnalysisInfo) void {
        for (self.instrumentations.items) |*inst| {
            inst.beforeAnalysis(info);
        }
    }

    pub fn runAfterAnalysis(self: *const PassInstrumentor, info: AnalysisInfo) void {
        var i = self.instrumentations.items.len;
        while (i > 0) {
            i -= 1;
            self.instrumentations.items[i].afterAnalysis(info);
        }
    }

    pub fn runPassStatistic(self: *const PassInstrumentor, info: PassStatisticInfo) void {
        for (self.instrumentations.items) |*inst| {
            inst.passStatistic(info);
        }
    }
};

pub const PassStatisticsInstrumentation = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(PassStatisticsEntry),

    pub fn init(allocator: std.mem.Allocator) PassStatisticsInstrumentation {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *PassStatisticsInstrumentation) void {
        self.reset();
        self.entries.deinit(self.allocator);
    }

    pub fn instrumentation(self: *PassStatisticsInstrumentation) PassInstrumentation {
        return .{
            .ctx = self,
            .runPassStatistic = recordImpl,
        };
    }

    pub fn reset(self: *PassStatisticsInstrumentation) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.pass_name);
            self.allocator.free(entry.name);
            self.allocator.free(entry.description);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn record(self: *PassStatisticsInstrumentation, info: PassStatisticInfo) !void {
        if (self.findEntry(info.pass.name, info.name)) |entry| {
            entry.value +|= info.value;
            return;
        }

        const pass_name = try self.allocator.dupe(u8, info.pass.name);
        errdefer self.allocator.free(pass_name);
        const name = try self.allocator.dupe(u8, info.name);
        errdefer self.allocator.free(name);
        const description = try self.allocator.dupe(u8, info.description);
        errdefer self.allocator.free(description);

        try self.entries.append(self.allocator, .{
            .pass_name = pass_name,
            .name = name,
            .description = description,
            .value = info.value,
        });
    }

    pub fn get(self: *const PassStatisticsInstrumentation, pass_name: []const u8, name: []const u8) ?u64 {
        if (self.findEntry(pass_name, name)) |entry| return entry.value;
        return null;
    }

    pub fn summariesAlloc(
        self: *const PassStatisticsInstrumentation,
        allocator: std.mem.Allocator,
    ) ![]PassStatisticSummary {
        var summaries = try allocator.alloc(PassStatisticSummary, self.entries.items.len);
        errdefer allocator.free(summaries);

        for (self.entries.items, 0..) |entry, index| {
            summaries[index] = .{
                .pass_name = entry.pass_name,
                .name = entry.name,
                .description = entry.description,
                .value = entry.value,
            };
        }
        std.mem.sort(PassStatisticSummary, summaries, {}, summaryLessThan);
        return summaries;
    }

    fn findEntry(self: anytype, pass_name: []const u8, name: []const u8) ?@TypeOf(&self.entries.items[0]) {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.pass_name, pass_name) and std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }

    fn recordImpl(ctx: ?*anyopaque, info: PassStatisticInfo) void {
        const self: *PassStatisticsInstrumentation = @ptrCast(@alignCast(ctx.?));
        self.record(info) catch {};
    }

    fn summaryLessThan(_: void, lhs: PassStatisticSummary, rhs: PassStatisticSummary) bool {
        const pass_order = std.mem.order(u8, lhs.pass_name, rhs.pass_name);
        if (pass_order != .eq) return pass_order == .lt;
        return std.mem.lessThan(u8, lhs.name, rhs.name);
    }
};

pub const PassTimingOptions = struct {
    collect_pass_ir_sizes: bool = false,
    allocation_snapshot_provider: ?PassAllocationSnapshotProvider = null,
};

pub const PassAllocationSnapshot = struct {
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    alloc_bytes: u64 = 0,

    fn delta(after: PassAllocationSnapshot, before: PassAllocationSnapshot) PassAllocationSnapshot {
        return .{
            .alloc_count = after.alloc_count -| before.alloc_count,
            .free_count = after.free_count -| before.free_count,
            .alloc_bytes = after.alloc_bytes -| before.alloc_bytes,
        };
    }
};

pub const PassAllocationSnapshotProvider = struct {
    context: ?*const anyopaque = null,
    snapshot: *const fn (?*const anyopaque) PassAllocationSnapshot,

    fn read(self: PassAllocationSnapshotProvider) PassAllocationSnapshot {
        return self.snapshot(self.context);
    }
};

const PassTimingEntry = struct {
    total_ns: i128 = 0,
    count: u64 = 0,
    modified_count: u64 = 0,
    max_ns: i128 = 0,
    min_ns: i128 = std.math.maxInt(i128),
};

const PassIrSizeEntry = struct {
    count: u64 = 0,
    before_total: u64 = 0,
    after_total: u64 = 0,
    delta_total: i128 = 0,
};

const PassMemoryEntry = struct {
    count: u64 = 0,
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    alloc_bytes: u64 = 0,
};

pub const PipelineTimingSummary = struct {
    target: ?[]const u8,
    depth: usize,
    total_ns: i128,
};

pub const PassRunTimingSummary = struct {
    ordinal: u64,
    name: []const u8,
    elapsed_ns: i128,
    modified: bool,
    op_count_before: ?u64 = null,
    op_count_after: ?u64 = null,
    op_count_delta: ?i128 = null,
    alloc_count: ?u64 = null,
    free_count: ?u64 = null,
    alloc_bytes: ?u64 = null,
};

pub const PassTimingSummary = struct {
    name: []const u8,
    total_ns: i128,
    count: u64,
    modified_count: u64 = 0,
    max_ns: i128,
    min_ns: i128,
    op_count_before: ?u64 = null,
    op_count_after: ?u64 = null,
    op_count_delta: ?i128 = null,
    alloc_count: ?u64 = null,
    free_count: ?u64 = null,
    alloc_bytes: ?u64 = null,
};

pub const TimingInstrumentation = struct {
    allocator: std.mem.Allocator,
    options: PassTimingOptions,
    pass_times: std.StringHashMapUnmanaged(PassTimingEntry),
    analysis_times: std.StringHashMapUnmanaged(PassTimingEntry),
    pass_ir_sizes: std.StringHashMapUnmanaged(PassIrSizeEntry),
    pass_memory: std.StringHashMapUnmanaged(PassMemoryEntry),
    pass_runs: std.ArrayListUnmanaged(PassRunTimingSummary),
    pipeline_times: std.ArrayListUnmanaged(PipelineTimingSummary),
    timing_stack: std.ArrayListUnmanaged(i128),
    pass_ir_size_stack: std.ArrayListUnmanaged(u64),
    pass_memory_stack: std.ArrayListUnmanaged(PassAllocationSnapshot),

    const FAILED_PUSH_SENTINEL: i128 = std.math.minInt(i128);
    const FAILED_IR_SIZE_SENTINEL: u64 = std.math.maxInt(u64);
    const FAILED_MEMORY_SNAPSHOT = PassAllocationSnapshot{
        .alloc_count = std.math.maxInt(u64),
        .free_count = std.math.maxInt(u64),
        .alloc_bytes = std.math.maxInt(u64),
    };

    pub fn init(allocator: std.mem.Allocator) TimingInstrumentation {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        options: PassTimingOptions,
    ) TimingInstrumentation {
        return .{
            .allocator = allocator,
            .options = options,
            .pass_times = .{},
            .analysis_times = .{},
            .pass_ir_sizes = .{},
            .pass_memory = .{},
            .pass_runs = .empty,
            .pipeline_times = .empty,
            .timing_stack = .empty,
            .pass_ir_size_stack = .empty,
            .pass_memory_stack = .empty,
        };
    }

    pub fn deinit(self: *TimingInstrumentation) void {
        self.pass_times.deinit(self.allocator);
        self.analysis_times.deinit(self.allocator);
        self.pass_ir_sizes.deinit(self.allocator);
        self.pass_memory.deinit(self.allocator);
        self.pass_runs.deinit(self.allocator);
        self.pipeline_times.deinit(self.allocator);
        self.timing_stack.deinit(self.allocator);
        self.pass_ir_size_stack.deinit(self.allocator);
        self.pass_memory_stack.deinit(self.allocator);
    }

    pub fn setAllocationSnapshotProvider(
        self: *TimingInstrumentation,
        provider: ?PassAllocationSnapshotProvider,
    ) void {
        self.options.allocation_snapshot_provider = provider;
    }

    pub fn instrumentation(self: *TimingInstrumentation) PassInstrumentation {
        return .{
            .ctx = self,
            .runBeforePipeline = beforePipelineImpl,
            .runAfterPipeline = afterPipelineImpl,
            .runBeforePass = beforePassImpl,
            .runAfterPass = afterPassImpl,
            .runAfterPassFailed = afterPassFailedImpl,
            .runBeforeAnalysis = beforeAnalysisImpl,
            .runAfterAnalysis = afterAnalysisImpl,
        };
    }

    fn pushTimestamp(self: *TimingInstrumentation) void {
        const timestamp = nowNanos();
        self.timing_stack.append(self.allocator, timestamp) catch {
            self.timing_stack.append(self.allocator, FAILED_PUSH_SENTINEL) catch {};
        };
    }

    fn popTimestamp(self: *TimingInstrumentation) ?i128 {
        if (self.timing_stack.pop()) |value| {
            if (value == FAILED_PUSH_SENTINEL) {
                return null;
            }
            return value;
        }
        return null;
    }

    fn beforePipelineImpl(ctx: ?*anyopaque, _: PipelineInfo, _: *ir.Operation) void {
        const self: *TimingInstrumentation = @ptrCast(@alignCast(ctx.?));
        self.pushTimestamp();
    }

    fn afterPipelineImpl(ctx: ?*anyopaque, info: PipelineInfo, _: *ir.Operation, _: bool) void {
        const self: *TimingInstrumentation = @ptrCast(@alignCast(ctx.?));
        if (self.popTimestamp()) |start| {
            const elapsed = nowNanos() - start;
            self.recordPipelineTiming(info.target_op_name, info.depth, elapsed);
        }
    }

    fn beforePassImpl(ctx: ?*anyopaque, info: PassInfo) void {
        const self: *TimingInstrumentation = @ptrCast(@alignCast(ctx.?));
        self.pushTimestamp();
        if (self.options.collect_pass_ir_sizes) {
            self.pushPassIrSize(info);
        }
        if (self.options.allocation_snapshot_provider != null) {
            self.pushPassMemory();
        }
    }

    fn afterPassImpl(ctx: ?*anyopaque, info: PassInfo, modified: bool) void {
        recordPassTime(ctx, info, modified);
    }

    fn afterPassFailedImpl(ctx: ?*anyopaque, info: PassInfo) void {
        recordPassTime(ctx, info, false);
    }

    fn recordPassTime(ctx: ?*anyopaque, info: PassInfo, modified: bool) void {
        const self: *TimingInstrumentation = @ptrCast(@alignCast(ctx.?));
        const elapsed = if (self.popTimestamp()) |start| nowNanos() - start else null;
        const before = if (self.options.collect_pass_ir_sizes) self.popPassIrSize() else null;
        const before_memory = if (self.options.allocation_snapshot_provider != null) self.popPassMemory() else null;
        var after: ?u64 = null;
        var delta: ?i128 = null;
        var memory_delta: ?PassAllocationSnapshot = null;
        if (before_memory) |snapshot_before| {
            if (self.options.allocation_snapshot_provider) |provider| {
                memory_delta = PassAllocationSnapshot.delta(provider.read(), snapshot_before);
                self.recordPassMemoryValues(info.name, memory_delta.?);
            }
        }
        if (before) |before_count| {
            if (info.target_op) |op| {
                const after_count = countOperationTree(op);
                after = after_count;
                delta = @as(i128, @intCast(after_count)) - @as(i128, @intCast(before_count));
                self.recordPassIrSizeValues(info.name, before_count, after_count, delta.?);
            }
        }
        if (elapsed) |actual| {
            self.record(&self.pass_times, info.name, actual, modified);
            self.recordPassRun(info.name, actual, modified, before, after, delta, memory_delta);
        }
    }

    fn recordPassRun(
        self: *TimingInstrumentation,
        name: []const u8,
        elapsed_ns: i128,
        modified: bool,
        op_count_before: ?u64,
        op_count_after: ?u64,
        op_count_delta: ?i128,
        memory_delta: ?PassAllocationSnapshot,
    ) void {
        self.pass_runs.append(self.allocator, .{
            .ordinal = @intCast(self.pass_runs.items.len + 1),
            .name = name,
            .elapsed_ns = elapsed_ns,
            .modified = modified,
            .op_count_before = op_count_before,
            .op_count_after = op_count_after,
            .op_count_delta = op_count_delta,
            .alloc_count = if (memory_delta) |delta| delta.alloc_count else null,
            .free_count = if (memory_delta) |delta| delta.free_count else null,
            .alloc_bytes = if (memory_delta) |delta| delta.alloc_bytes else null,
        }) catch {};
    }

    fn recordPassIrSizeValues(
        self: *TimingInstrumentation,
        name: []const u8,
        before: u64,
        after: u64,
        delta: i128,
    ) void {
        const gop = self.pass_ir_sizes.getOrPut(self.allocator, name) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.count += 1;
        gop.value_ptr.before_total +|= before;
        gop.value_ptr.after_total +|= after;
        gop.value_ptr.delta_total += delta;
    }

    fn recordPassMemoryValues(
        self: *TimingInstrumentation,
        name: []const u8,
        memory_delta: PassAllocationSnapshot,
    ) void {
        const gop = self.pass_memory.getOrPut(self.allocator, name) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.count += 1;
        gop.value_ptr.alloc_count +|= memory_delta.alloc_count;
        gop.value_ptr.free_count +|= memory_delta.free_count;
        gop.value_ptr.alloc_bytes +|= memory_delta.alloc_bytes;
    }

    fn beforeAnalysisImpl(ctx: ?*anyopaque, _: AnalysisInfo) void {
        const self: *TimingInstrumentation = @ptrCast(@alignCast(ctx.?));
        self.pushTimestamp();
    }

    fn afterAnalysisImpl(ctx: ?*anyopaque, info: AnalysisInfo) void {
        const self: *TimingInstrumentation = @ptrCast(@alignCast(ctx.?));
        if (self.popTimestamp()) |start| {
            const elapsed = nowNanos() - start;
            self.record(&self.analysis_times, info.name, elapsed, false);
        }
    }

    fn record(
        self: *TimingInstrumentation,
        table: *std.StringHashMapUnmanaged(PassTimingEntry),
        name: []const u8,
        elapsed: i128,
        modified: bool,
    ) void {
        const gop = table.getOrPut(self.allocator, name) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.total_ns += elapsed;
        gop.value_ptr.count += 1;
        if (modified) gop.value_ptr.modified_count += 1;
        if (elapsed > gop.value_ptr.max_ns) gop.value_ptr.max_ns = elapsed;
        if (elapsed < gop.value_ptr.min_ns) gop.value_ptr.min_ns = elapsed;
    }

    pub fn recordPipelineTiming(
        self: *TimingInstrumentation,
        target: ?[]const u8,
        depth: usize,
        elapsed_ns: i128,
    ) void {
        self.pipeline_times.append(self.allocator, .{
            .target = target,
            .depth = depth,
            .total_ns = elapsed_ns,
        }) catch {};
    }

    fn pushPassIrSize(self: *TimingInstrumentation, info: PassInfo) void {
        const size = if (info.target_op) |op| countOperationTree(op) else FAILED_IR_SIZE_SENTINEL;
        self.pass_ir_size_stack.append(self.allocator, size) catch {
            self.pass_ir_size_stack.append(self.allocator, FAILED_IR_SIZE_SENTINEL) catch {};
        };
    }

    fn popPassIrSize(self: *TimingInstrumentation) ?u64 {
        const size = self.pass_ir_size_stack.pop() orelse return null;
        if (size == FAILED_IR_SIZE_SENTINEL) return null;
        return size;
    }

    fn pushPassMemory(self: *TimingInstrumentation) void {
        const provider = self.options.allocation_snapshot_provider orelse return;
        self.pass_memory_stack.append(self.allocator, provider.read()) catch {
            self.pass_memory_stack.append(self.allocator, FAILED_MEMORY_SNAPSHOT) catch {};
        };
    }

    fn popPassMemory(self: *TimingInstrumentation) ?PassAllocationSnapshot {
        const snapshot = self.pass_memory_stack.pop() orelse return null;
        if (snapshot.alloc_count == FAILED_MEMORY_SNAPSHOT.alloc_count and
            snapshot.free_count == FAILED_MEMORY_SNAPSHOT.free_count and
            snapshot.alloc_bytes == FAILED_MEMORY_SNAPSHOT.alloc_bytes)
        {
            return null;
        }
        return snapshot;
    }

    fn countOperationTree(op: *ir.Operation) u64 {
        var count: u64 = 1;
        for (op.regions.items) |*region| {
            var block_iter = region.getBlocks();
            while (block_iter.next()) |block| {
                var op_node = block.operations.head;
                while (op_node) |node| {
                    const child: *ir.Operation = @ptrCast(@alignCast(node));
                    count +|= countOperationTree(child);
                    op_node = child.next_op;
                }
            }
        }
        return count;
    }

    pub fn getPassTime(self: *const TimingInstrumentation, name: []const u8) ?i128 {
        if (self.pass_times.get(name)) |entry| {
            return entry.total_ns;
        }
        return null;
    }

    pub fn getPassCount(self: *const TimingInstrumentation, name: []const u8) ?u64 {
        if (self.pass_times.get(name)) |entry| {
            return entry.count;
        }
        return null;
    }

    pub fn getPassModifiedCount(self: *const TimingInstrumentation, name: []const u8) ?u64 {
        if (self.pass_times.get(name)) |entry| {
            return entry.modified_count;
        }
        return null;
    }

    pub fn getPassOpCountBefore(self: *const TimingInstrumentation, name: []const u8) ?u64 {
        if (self.pass_ir_sizes.get(name)) |entry| {
            return entry.before_total;
        }
        return null;
    }

    pub fn getPassOpCountAfter(self: *const TimingInstrumentation, name: []const u8) ?u64 {
        if (self.pass_ir_sizes.get(name)) |entry| {
            return entry.after_total;
        }
        return null;
    }

    pub fn getPassOpCountDelta(self: *const TimingInstrumentation, name: []const u8) ?i128 {
        if (self.pass_ir_sizes.get(name)) |entry| {
            return entry.delta_total;
        }
        return null;
    }

    pub fn getPassAllocCount(self: *const TimingInstrumentation, name: []const u8) ?u64 {
        if (self.pass_memory.get(name)) |entry| {
            return entry.alloc_count;
        }
        return null;
    }

    pub fn getPassFreeCount(self: *const TimingInstrumentation, name: []const u8) ?u64 {
        if (self.pass_memory.get(name)) |entry| {
            return entry.free_count;
        }
        return null;
    }

    pub fn getPassAllocBytes(self: *const TimingInstrumentation, name: []const u8) ?u64 {
        if (self.pass_memory.get(name)) |entry| {
            return entry.alloc_bytes;
        }
        return null;
    }

    pub fn getAnalysisTime(self: *const TimingInstrumentation, name: []const u8) ?i128 {
        if (self.analysis_times.get(name)) |entry| {
            return entry.total_ns;
        }
        return null;
    }

    pub fn getAnalysisCount(self: *const TimingInstrumentation, name: []const u8) ?u64 {
        if (self.analysis_times.get(name)) |entry| {
            return entry.count;
        }
        return null;
    }

    pub fn hasPassTimings(self: *const TimingInstrumentation) bool {
        return self.pass_times.count() != 0;
    }

    pub fn hasAnalysisTimings(self: *const TimingInstrumentation) bool {
        return self.analysis_times.count() != 0;
    }

    pub fn hasPipelineTimings(self: *const TimingInstrumentation) bool {
        return self.pipeline_times.items.len != 0;
    }

    pub fn collectsPassIrSizes(self: *const TimingInstrumentation) bool {
        return self.options.collect_pass_ir_sizes;
    }

    pub fn collectsPassMemory(self: *const TimingInstrumentation) bool {
        return self.options.allocation_snapshot_provider != null;
    }

    pub fn pipelineSummariesAlloc(
        self: *const TimingInstrumentation,
        allocator: std.mem.Allocator,
    ) ![]PipelineTimingSummary {
        const summaries = try allocator.alloc(PipelineTimingSummary, self.pipeline_times.items.len);
        @memcpy(summaries, self.pipeline_times.items);
        return summaries;
    }

    pub fn passRunSummariesAlloc(
        self: *const TimingInstrumentation,
        allocator: std.mem.Allocator,
    ) ![]PassRunTimingSummary {
        const summaries = try allocator.alloc(PassRunTimingSummary, self.pass_runs.items.len);
        @memcpy(summaries, self.pass_runs.items);
        return summaries;
    }

    pub fn passSummariesAlloc(
        self: *const TimingInstrumentation,
        allocator: std.mem.Allocator,
    ) ![]PassTimingSummary {
        var summaries = try allocator.alloc(PassTimingSummary, self.pass_times.count());
        errdefer allocator.free(summaries);

        var index: usize = 0;
        var iter = self.pass_times.iterator();
        while (iter.next()) |entry| : (index += 1) {
            summaries[index] = timingSummary(entry.key_ptr.*, entry.value_ptr.*);
            if (self.pass_ir_sizes.get(entry.key_ptr.*)) |ir_size| {
                summaries[index].op_count_before = ir_size.before_total;
                summaries[index].op_count_after = ir_size.after_total;
                summaries[index].op_count_delta = ir_size.delta_total;
            }
            if (self.pass_memory.get(entry.key_ptr.*)) |memory| {
                summaries[index].alloc_count = memory.alloc_count;
                summaries[index].free_count = memory.free_count;
                summaries[index].alloc_bytes = memory.alloc_bytes;
            }
        }
        std.mem.sort(PassTimingSummary, summaries, {}, timingSummaryLessThan);
        return summaries;
    }

    pub fn analysisSummariesAlloc(
        self: *const TimingInstrumentation,
        allocator: std.mem.Allocator,
    ) ![]PassTimingSummary {
        var summaries = try allocator.alloc(PassTimingSummary, self.analysis_times.count());
        errdefer allocator.free(summaries);

        var index: usize = 0;
        var iter = self.analysis_times.iterator();
        while (iter.next()) |entry| : (index += 1) {
            summaries[index] = timingSummary(entry.key_ptr.*, entry.value_ptr.*);
        }
        std.mem.sort(PassTimingSummary, summaries, {}, timingSummaryLessThan);
        return summaries;
    }

    fn timingSummary(name: []const u8, entry: PassTimingEntry) PassTimingSummary {
        return .{
            .name = name,
            .total_ns = entry.total_ns,
            .count = entry.count,
            .modified_count = entry.modified_count,
            .max_ns = entry.max_ns,
            .min_ns = entry.min_ns,
        };
    }

    fn timingSummaryLessThan(_: void, lhs: PassTimingSummary, rhs: PassTimingSummary) bool {
        return std.mem.lessThan(u8, lhs.name, rhs.name);
    }
};

pub const IRPrintingOptions = struct {
    print_before: bool = false,
    print_after: bool = false,
    print_after_change: bool = false,
    print_before_pipeline: bool = false,
    print_after_pipeline: bool = false,
    writer: ?*std.Io.Writer = null,
};

pub const IRPrintingInstrumentation = struct {
    allocator: std.mem.Allocator,
    options: IRPrintingOptions,
    last_hash: ?u64 = null,
    output: std.ArrayListUnmanaged(u8),

    pub fn init(
        allocator: std.mem.Allocator,
        options: IRPrintingOptions,
    ) IRPrintingInstrumentation {
        return .{
            .allocator = allocator,
            .options = options,
            .output = .empty,
        };
    }

    pub fn deinit(self: *IRPrintingInstrumentation) void {
        self.output.deinit(self.allocator);
    }

    pub fn instrumentation(self: *IRPrintingInstrumentation) PassInstrumentation {
        return .{
            .ctx = self,
            .runBeforePipeline = if (self.options.print_before_pipeline) beforePipelineImpl else null,
            .runAfterPipeline = if (self.options.print_after_pipeline) afterPipelineImpl else null,
            .runBeforePass = if (self.options.print_before) beforePassImpl else null,
            .runAfterPass = if (self.options.print_after or self.options.print_after_change) afterPassImpl else null,
        };
    }

    fn beforePipelineImpl(ctx: ?*anyopaque, info: PipelineInfo, op: *ir.Operation) void {
        const self: *IRPrintingInstrumentation = @ptrCast(@alignCast(ctx.?));
        self.printHeader("Before pipeline", info.target_op_name, info.depth);
        self.printOp(op);
    }

    fn afterPipelineImpl(ctx: ?*anyopaque, info: PipelineInfo, op: *ir.Operation, failed: bool) void {
        const self: *IRPrintingInstrumentation = @ptrCast(@alignCast(ctx.?));
        if (failed) {
            self.printHeader("After pipeline (FAILED)", info.target_op_name, info.depth);
        } else {
            self.printHeader("After pipeline", info.target_op_name, info.depth);
        }
        self.printOp(op);
    }

    fn beforePassImpl(ctx: ?*anyopaque, info: PassInfo) void {
        const self: *IRPrintingInstrumentation = @ptrCast(@alignCast(ctx.?));
        self.printHeader("Before pass", info.name, 0);
        if (info.target_op) |op| {
            self.last_hash = self.computeOpHash(op);
            self.printOp(op);
        }
    }

    fn afterPassImpl(ctx: ?*anyopaque, info: PassInfo, modified: bool) void {
        const self: *IRPrintingInstrumentation = @ptrCast(@alignCast(ctx.?));

        if (self.options.print_after_change) {
            if (info.target_op) |op| {
                const new_hash = self.computeOpHash(op);
                if (self.last_hash != null and new_hash != null) {
                    if (self.last_hash.? == new_hash.?) {
                        return;
                    }
                }
            }
        }

        const label = if (modified) "After pass (modified)" else "After pass";
        self.printHeader(label, info.name, 0);
        if (info.target_op) |op| {
            self.printOp(op);
        }
    }

    fn printHeader(self: *IRPrintingInstrumentation, label: []const u8, name: ?[]const u8, depth: usize) void {
        self.print("\n", .{});
        for (0..depth) |_| {
            self.print("  ", .{});
        }
        self.print("// === {s}", .{label});
        if (name) |n| {
            self.print(": {s}", .{n});
        }
        self.print(" ===\n", .{});
    }

    fn printOp(self: *IRPrintingInstrumentation, op: *ir.Operation) void {
        self.output.clearRetainingCapacity();

        self.print("{s}", .{op.name.name});
        self.printAttrs(op);
        self.print("\n", .{});
    }

    fn printAttrs(self: *IRPrintingInstrumentation, op: *const ir.Operation) void {
        var attrs = op.getAttrs();
        const first = attrs.next() orelse return;
        self.print(" {{{s}", .{first.name});
        while (attrs.next()) |attr| self.print(", {s}", .{attr.name});
        self.print("}}", .{});
    }

    fn print(self: *IRPrintingInstrumentation, comptime fmt: []const u8, args: anytype) void {
        if (self.options.writer) |writer| {
            writer.print(fmt, args) catch {};
        } else {
            pretty.diagnostic.writeStderrText(fmt, args);
        }
    }

    fn computeOpHash(self: *IRPrintingInstrumentation, op: *ir.Operation) ?u64 {
        return hashing.operationFingerprint(self.allocator, op) catch null;
    }
};

pub const VerifierInstrumentationFailure = struct {
    pass_name: []const u8,
    err: anyerror,
};

pub const VerifierInstrumentationOptions = struct {
    verify_options: verify_mod.VerifyOptions = verify_mod.default_options,
    stop_on_failure: bool = true,
};

pub const VerifierInstrumentation = struct {
    allocator: std.mem.Allocator,
    options: verify_mod.VerifyOptions,
    failures: std.ArrayListUnmanaged(VerifierInstrumentationFailure),
    stop_on_failure: bool,
    has_stopped: bool,

    pub fn init(allocator: std.mem.Allocator, options: verify_mod.VerifyOptions) VerifierInstrumentation {
        return initWithOptions(allocator, .{ .verify_options = options });
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        options: VerifierInstrumentationOptions,
    ) VerifierInstrumentation {
        return .{
            .allocator = allocator,
            .options = options.verify_options,
            .failures = .empty,
            .stop_on_failure = options.stop_on_failure,
            .has_stopped = false,
        };
    }

    pub fn deinit(self: *VerifierInstrumentation) void {
        self.failures.deinit(self.allocator);
    }

    pub fn instrumentation(self: *VerifierInstrumentation) PassInstrumentation {
        return .{
            .ctx = self,
            .runAfterPass = afterPassImpl,
        };
    }

    fn afterPassImpl(ctx: ?*anyopaque, info: PassInfo, _: bool) void {
        const self: *VerifierInstrumentation = @ptrCast(@alignCast(ctx.?));

        if (self.stop_on_failure and self.has_stopped) {
            return;
        }

        if (info.target_op) |op| {
            verify_mod.verifyOperation(op, self.options) catch |err| {
                self.failures.append(self.allocator, .{
                    .pass_name = info.name,
                    .err = err,
                }) catch {};

                if (self.stop_on_failure) {
                    self.has_stopped = true;
                }
            };
        }
    }

    pub fn hasFailures(self: *const VerifierInstrumentation) bool {
        return self.failures.items.len > 0;
    }

    pub fn getFailureCount(self: *const VerifierInstrumentation) usize {
        return self.failures.items.len;
    }

    pub fn wasStopped(self: *const VerifierInstrumentation) bool {
        return self.has_stopped;
    }

    pub fn reset(self: *VerifierInstrumentation) void {
        self.failures.clearRetainingCapacity();
        self.has_stopped = false;
    }

    pub fn printFailures(self: *const VerifierInstrumentation, writer: anytype) !void {
        for (self.failures.items) |failure| {
            try writer.print("Verification failed after pass '{s}': {}\n", .{ failure.pass_name, failure.err });
        }
        if (self.has_stopped) {
            try writer.print("(Verification stopped after first failure)\n", .{});
        }
    }
};

pub const CountingInstrumentation = struct {
    pipeline_count: usize = 0,
    pass_count: usize = 0,
    pass_failures: usize = 0,
    analysis_count: usize = 0,

    pub fn instrumentation(self: *CountingInstrumentation) PassInstrumentation {
        return .{
            .ctx = self,
            .runBeforePipeline = beforePipelineImpl,
            .runBeforePass = beforePassImpl,
            .runAfterPassFailed = afterPassFailedImpl,
            .runBeforeAnalysis = beforeAnalysisImpl,
        };
    }

    fn beforePipelineImpl(ctx: ?*anyopaque, _: PipelineInfo, _: *ir.Operation) void {
        const self: *CountingInstrumentation = @ptrCast(@alignCast(ctx.?));
        self.pipeline_count += 1;
    }

    fn beforePassImpl(ctx: ?*anyopaque, _: PassInfo) void {
        const self: *CountingInstrumentation = @ptrCast(@alignCast(ctx.?));
        self.pass_count += 1;
    }

    fn afterPassFailedImpl(ctx: ?*anyopaque, _: PassInfo) void {
        const self: *CountingInstrumentation = @ptrCast(@alignCast(ctx.?));
        self.pass_failures += 1;
    }

    fn beforeAnalysisImpl(ctx: ?*anyopaque, _: AnalysisInfo) void {
        const self: *CountingInstrumentation = @ptrCast(@alignCast(ctx.?));
        self.analysis_count += 1;
    }

    pub fn reset(self: *CountingInstrumentation) void {
        self.* = .{};
    }
};

const BasicHookTracker = struct {
    var called_before: bool = false;
    var called_after: bool = false;

    fn beforeImpl(_: ?*anyopaque, _: PassInfo) void {
        called_before = true;
    }

    fn afterImpl(_: ?*anyopaque, _: PassInfo, _: bool) void {
        called_after = true;
    }
};

fn ChainedInstrumentationType(comptime before_value: u8, comptime after_value: u8) type {
    return struct {
        var order_ptr: *[4]u8 = undefined;
        var idx_ptr: *usize = undefined;

        fn before(_: ?*anyopaque, _: PassInfo) void {
            order_ptr[idx_ptr.*] = before_value;
            idx_ptr.* += 1;
        }

        fn after(_: ?*anyopaque, _: PassInfo, _: bool) void {
            order_ptr[idx_ptr.*] = after_value;
            idx_ptr.* += 1;
        }
    };
}

const FirstChainedInstrumentation = ChainedInstrumentationType('1', 'A');
const SecondChainedInstrumentation = ChainedInstrumentationType('2', 'B');

test "PassInstrumentation basic hooks" {
    const testing = std.testing;

    BasicHookTracker.called_before = false;
    BasicHookTracker.called_after = false;

    const inst = PassInstrumentation{
        .runBeforePass = BasicHookTracker.beforeImpl,
        .runAfterPass = BasicHookTracker.afterImpl,
    };

    const info = PassInfo{
        .name = "test-pass",
        .description = "Test pass",
        .target_op = null,
    };

    inst.beforePass(info);
    try testing.expect(BasicHookTracker.called_before);
    try testing.expect(!BasicHookTracker.called_after);

    inst.afterPass(info, false);
    try testing.expect(BasicHookTracker.called_after);
}

test "PassInstrumentor chains multiple instrumentations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var instrumentor = PassInstrumentor.init(allocator);
    defer instrumentor.deinit();

    var order: [4]u8 = undefined;
    var idx: usize = 0;

    FirstChainedInstrumentation.order_ptr = &order;
    FirstChainedInstrumentation.idx_ptr = &idx;
    SecondChainedInstrumentation.order_ptr = &order;
    SecondChainedInstrumentation.idx_ptr = &idx;

    try instrumentor.addInstrumentation(.{
        .runBeforePass = FirstChainedInstrumentation.before,
        .runAfterPass = FirstChainedInstrumentation.after,
    });
    try instrumentor.addInstrumentation(.{
        .runBeforePass = SecondChainedInstrumentation.before,
        .runAfterPass = SecondChainedInstrumentation.after,
    });

    const info = PassInfo{ .name = "test", .description = "", .target_op = null };

    instrumentor.runBeforePass(info);
    instrumentor.runAfterPass(info, false);

    try testing.expectEqualStrings("12BA", &order);
}

test "TimingInstrumentation records pass times" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var timing = TimingInstrumentation.init(allocator);
    defer timing.deinit();

    const inst = timing.instrumentation();

    const info = PassInfo{
        .name = "test-pass",
        .description = "Test pass",
        .target_op = null,
    };

    inst.beforePass(info);
    inst.afterPass(info, false);

    try testing.expect(timing.getPassCount("test-pass") != null);
    try testing.expectEqual(@as(u64, 1), timing.getPassCount("test-pass").?);
    try testing.expectEqual(@as(u64, 0), timing.getPassModifiedCount("test-pass").?);
    try testing.expect(timing.getPassTime("test-pass") != null);
    try testing.expect(!timing.collectsPassIrSizes());
    try testing.expect(timing.getPassOpCountBefore("test-pass") == null);
}

test "TimingInstrumentation records pass IR operation deltas when enabled" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);

    var timing = TimingInstrumentation.initWithOptions(allocator, .{ .collect_pass_ir_sizes = true });
    defer timing.deinit();
    const inst = timing.instrumentation();

    const info = PassInfo{
        .name = "grow-ir",
        .description = "Test pass that adds an operation",
        .target_op = module_op.op,
    };

    inst.beforePass(info);
    const func_op = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "f", &.{});
    try module_op.getBodyBlock().addOperation(func_op.op);
    inst.afterPass(info, true);

    try testing.expect(timing.collectsPassIrSizes());
    try testing.expectEqual(@as(u64, 1), timing.getPassModifiedCount("grow-ir").?);
    try testing.expectEqual(@as(u64, 1), timing.getPassOpCountBefore("grow-ir").?);
    try testing.expectEqual(@as(u64, 2), timing.getPassOpCountAfter("grow-ir").?);
    try testing.expectEqual(@as(i128, 1), timing.getPassOpCountDelta("grow-ir").?);

    const summaries = try timing.passSummariesAlloc(allocator);
    defer allocator.free(summaries);
    try testing.expectEqual(@as(usize, 1), summaries.len);
    try testing.expectEqualStrings("grow-ir", summaries[0].name);
    try testing.expectEqual(@as(u64, 1), summaries[0].modified_count);
    try testing.expectEqual(@as(u64, 1), summaries[0].op_count_before.?);
    try testing.expectEqual(@as(u64, 2), summaries[0].op_count_after.?);
    try testing.expectEqual(@as(i128, 1), summaries[0].op_count_delta.?);

    const runs = try timing.passRunSummariesAlloc(allocator);
    defer allocator.free(runs);
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqual(@as(u64, 1), runs[0].ordinal);
    try testing.expectEqualStrings("grow-ir", runs[0].name);
    try testing.expect(runs[0].modified);
    try testing.expectEqual(@as(u64, 1), runs[0].op_count_before.?);
    try testing.expectEqual(@as(u64, 2), runs[0].op_count_after.?);
    try testing.expectEqual(@as(i128, 1), runs[0].op_count_delta.?);
}

test "TimingInstrumentation preserves duplicate pass run order" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);

    var timing = TimingInstrumentation.initWithOptions(allocator, .{ .collect_pass_ir_sizes = true });
    defer timing.deinit();
    const inst = timing.instrumentation();

    const info = PassInfo{
        .name = "duplicate-pass",
        .description = "Duplicate pass",
        .target_op = module_op.op,
    };

    inst.beforePass(info);
    inst.afterPass(info, false);

    inst.beforePass(info);
    const func_op = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "f", &.{});
    try module_op.getBodyBlock().addOperation(func_op.op);
    inst.afterPass(info, true);

    const runs = try timing.passRunSummariesAlloc(allocator);
    defer allocator.free(runs);
    try testing.expectEqual(@as(usize, 2), runs.len);
    try testing.expectEqual(@as(u64, 1), runs[0].ordinal);
    try testing.expectEqual(@as(u64, 2), runs[1].ordinal);
    try testing.expectEqualStrings("duplicate-pass", runs[0].name);
    try testing.expectEqualStrings("duplicate-pass", runs[1].name);
    try testing.expect(!runs[0].modified);
    try testing.expect(runs[1].modified);
    try testing.expectEqual(@as(i128, 0), runs[0].op_count_delta.?);
    try testing.expectEqual(@as(i128, 1), runs[1].op_count_delta.?);
}

test "CountingInstrumentation counts events" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var counter = CountingInstrumentation{};
    const inst = counter.instrumentation();

    var instrumentor = PassInstrumentor.init(allocator);
    defer instrumentor.deinit();
    try instrumentor.addInstrumentation(inst);

    const test_dialect = @import("../dialects/fixture/root.zig");

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    instrumentor.runBeforePipeline(.{ .target_op_name = null, .depth = 0 }, module_op.op);
    instrumentor.runBeforePass(.{ .name = "pass1", .description = "", .target_op = null });
    instrumentor.runAfterPass(.{ .name = "pass1", .description = "", .target_op = null }, false);
    instrumentor.runBeforePass(.{ .name = "pass2", .description = "", .target_op = null });
    instrumentor.runAfterPassFailed(.{ .name = "pass2", .description = "", .target_op = null });
    instrumentor.runAfterPipeline(.{ .target_op_name = null, .depth = 0 }, module_op.op, true);

    try testing.expectEqual(@as(usize, 1), counter.pipeline_count);
    try testing.expectEqual(@as(usize, 2), counter.pass_count);
    try testing.expectEqual(@as(usize, 1), counter.pass_failures);
}

test "VerifierInstrumentation verifies operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const options = verify_mod.VerifyOptions{
        .check_terminators = false,
        .require_terminators = false,
        .recursive = false,
        .check_use_def = false,
        .check_cfg = false,
    };

    var verifier = VerifierInstrumentation.init(allocator, options);
    defer verifier.deinit();

    try testing.expect(!verifier.hasFailures());
    try testing.expectEqual(@as(usize, 0), verifier.getFailureCount());
}

test "IRPrintingInstrumentation print_after_change" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var printer = IRPrintingInstrumentation.init(allocator, .{
        .print_after_change = true,
    });
    defer printer.deinit();

    try testing.expect(printer.options.print_after_change);
    try testing.expect(!printer.options.print_before);
    try testing.expect(!printer.options.print_after);
}

test "PassInstrumentor clear removes all instrumentations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var instrumentor = PassInstrumentor.init(allocator);
    defer instrumentor.deinit();

    try instrumentor.addInstrumentation(.{});
    try instrumentor.addInstrumentation(.{});
    try testing.expectEqual(@as(usize, 2), instrumentor.instrumentations.items.len);

    instrumentor.clear();
    try testing.expectEqual(@as(usize, 0), instrumentor.instrumentations.items.len);
}
