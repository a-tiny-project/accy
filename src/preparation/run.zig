const std = @import("std");
const choir = @import("choir");
const sys = @import("sys");

const stage = @import("stage.zig");
const target_profile = @import("target.zig");

const passes = choir.passes;

pub const BackendPreparationStats = struct {
    pass_runs: u64 = 0,
    pass_failures: u64 = 0,
    passes_modified: u64 = 0,
    analysis_hits: u64 = 0,
    analysis_misses: u64 = 0,
    analyses_invalidated: u64 = 0,
};

pub const BackendPreparationFailureKind = passes.PassFailureKind;

pub const BackendPreparationFailure = struct {
    pipeline_name: ?[]const u8 = null,
    failure_kind: ?BackendPreparationFailureKind = null,
    pass_name: ?[]const u8 = null,
    target_op_name: ?[]const u8 = null,
    target_symbol_name: ?[]const u8 = null,
    verifier_error_name: ?[]const u8 = null,
    worker_count: usize = 0,

    pub fn deinit(self: *BackendPreparationFailure, allocator: std.mem.Allocator) void {
        if (self.pass_name) |name| allocator.free(name);
        if (self.target_op_name) |name| allocator.free(name);
        if (self.target_symbol_name) |name| allocator.free(name);
        if (self.verifier_error_name) |name| allocator.free(name);
        self.* = .{};
    }

    pub fn capture(
        self: *BackendPreparationFailure,
        allocator: std.mem.Allocator,
        pipeline_name: []const u8,
        reproducer: *const passes.PassFailureReproducer,
    ) !void {
        self.deinit(allocator);
        errdefer self.deinit(allocator);

        self.pipeline_name = pipeline_name;
        self.failure_kind = reproducer.failure_kind;
        self.worker_count = reproducer.worker_count;
        self.pass_name = try dupeOptional(allocator, reproducer.pass_name);
        self.target_op_name = try dupeOptional(allocator, reproducer.target_op_name);
        self.target_symbol_name = try dupeOptional(allocator, reproducer.target_symbol_name);
        self.verifier_error_name = try dupeOptional(allocator, reproducer.verifier_error_name);
    }

    fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
        if (value) |text| return try allocator.dupe(u8, text);
        return null;
    }
};

pub const BackendPreparationTiming = struct {
    inner: passes.TimingInstrumentation,

    pub const TimingOptions: type = passes.PassTimingOptions;
    pub const AllocationSnapshot: type = passes.PassAllocationSnapshot;
    pub const AllocationSnapshotProvider: type =
        passes.PassAllocationSnapshotProvider;

    pub fn init(allocator: std.mem.Allocator) BackendPreparationTiming {
        return .{ .inner = passes.TimingInstrumentation.init(allocator) };
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: TimingOptions) BackendPreparationTiming {
        return .{ .inner = passes.TimingInstrumentation.initWithOptions(allocator, options) };
    }

    pub fn deinit(self: *BackendPreparationTiming) void {
        self.inner.deinit();
        self.* = undefined;
    }

    fn instrumentation(self: *BackendPreparationTiming) passes.PassInstrumentation {
        return self.inner.instrumentation();
    }

    pub fn getPassTime(self: *const BackendPreparationTiming, name: []const u8) ?i128 {
        return self.inner.getPassTime(name);
    }

    pub fn getPassCount(self: *const BackendPreparationTiming, name: []const u8) ?u64 {
        return self.inner.getPassCount(name);
    }

    pub fn getPassOpCountBefore(self: *const BackendPreparationTiming, name: []const u8) ?u64 {
        return self.inner.getPassOpCountBefore(name);
    }

    pub fn getPassOpCountAfter(self: *const BackendPreparationTiming, name: []const u8) ?u64 {
        return self.inner.getPassOpCountAfter(name);
    }

    pub fn getPassOpCountDelta(self: *const BackendPreparationTiming, name: []const u8) ?i128 {
        return self.inner.getPassOpCountDelta(name);
    }

    pub fn setAllocationSnapshotProvider(
        self: *BackendPreparationTiming,
        provider: ?AllocationSnapshotProvider,
    ) void {
        self.inner.setAllocationSnapshotProvider(provider);
    }

    pub fn getPassAllocCount(self: *const BackendPreparationTiming, name: []const u8) ?u64 {
        return self.inner.getPassAllocCount(name);
    }

    pub fn getPassFreeCount(self: *const BackendPreparationTiming, name: []const u8) ?u64 {
        return self.inner.getPassFreeCount(name);
    }

    pub fn getPassAllocBytes(self: *const BackendPreparationTiming, name: []const u8) ?u64 {
        return self.inner.getPassAllocBytes(name);
    }

    pub fn getAnalysisTime(self: *const BackendPreparationTiming, name: []const u8) ?i128 {
        return self.inner.getAnalysisTime(name);
    }

    pub fn getAnalysisCount(self: *const BackendPreparationTiming, name: []const u8) ?u64 {
        return self.inner.getAnalysisCount(name);
    }

    pub fn collectsPassIrSizes(self: *const BackendPreparationTiming) bool {
        return self.inner.collectsPassIrSizes();
    }
};

pub const BackendPreparationRunOptions = struct {
    timing: ?*BackendPreparationTiming = null,
    failure: ?*BackendPreparationFailure = null,
    target_profile: ?target_profile.BackendTargetProfile = null,
    generated_scan_schedules: []const target_profile.GeneratedScanScheduleDecision = &.{},
    generated_row_pipeline_schedules: []const target_profile.GeneratedRowPipelineScheduleDecision = &.{},
    tensor: stage.TensorLoweringOptions = .{},
    now: *const fn () i128 = sys.time.nanoTimestamp,
};

pub const BackendPreparationRun = struct {
    total_ns: u64,
    contract_ns: u64 = 0,
    tensor_ns: u64 = 0,
    dispatch_ns: u64 = 0,
    memory_ns: u64 = 0,
    kernel_ns: u64 = 0,
    target_ns: u64 = 0,
    initial_choir_ops: u64,
    final_choir_ops: u64,
    semantic_fingerprint: ?u64 = null,
    contract_fingerprint: u64 = 0,
    tensor_fingerprint: u64 = 0,
    /// A caller reads this field to show whether the dispatch plans of two runs look alike. The
    /// field holds a 64-bit summary of the plans made by the dispatch stage, zero when the stage
    /// has not run. It is for display, and no product key or reuse decision reads it.
    dispatch_fingerprint: u64 = 0,
    /// A caller reads this field to show whether the memory plans of two runs look alike. The field
    /// holds a 64-bit summary of the buffer, memory-space and layout plans made by the memory
    /// stage, zero when the stage has not run. It is for display, and no product key or reuse
    /// decision reads it.
    memory_fingerprint: u64 = 0,
    /// A caller reads this field to show whether the kernel plans of two runs look alike. The field
    /// holds a 64-bit summary of the kernel outline and generated kernels made by the kernel stage,
    /// zero when the stage has not run. It is for display, and no product key or reuse decision
    /// reads it.
    kernel_fingerprint: u64 = 0,
    target_fingerprint: u64 = 0,
    contract_stats: BackendPreparationStats = .{},
    tensor_stats: BackendPreparationStats = .{},
    dispatch_stats: BackendPreparationStats = .{},
    memory_stats: BackendPreparationStats = .{},
    kernel_stats: BackendPreparationStats = .{},
    target_stats: BackendPreparationStats = .{},
    target_profile: ?target_profile.BackendTargetProfile = null,
};

pub fn addTimingInstrumentation(pm: *passes.PassManager, timing: *BackendPreparationTiming) !void {
    try pm.addInstrumentation(timing.instrumentation());
}

pub fn backendPreparationStats(stats: passes.PassManagerStats) BackendPreparationStats {
    return .{
        .pass_runs = stats.pass_runs,
        .pass_failures = stats.pass_failures,
        .passes_modified = stats.passes_modified,
        .analysis_hits = stats.analysis_hits,
        .analysis_misses = stats.analysis_misses,
        .analyses_invalidated = stats.analyses_invalidated,
    };
}

pub fn stageTotal(run: BackendPreparationRun) u64 {
    return run.contract_ns +|
        run.tensor_ns +|
        run.dispatch_ns +|
        run.memory_ns +|
        run.kernel_ns +|
        run.target_ns;
}
