const std = @import("std");
const pretty_json = @import("pretty").json;
const event = @import("event.zig");
const frame_mod = @import("frame.zig");
const gpu_mod = @import("gpu.zig");
const memory_mod = @import("memory.zig");
const plot_mod = @import("plot.zig");
const report = @import("report.zig");
const summary = @import("summary.zig");

pub const schema = "tracy.compare/v0";

pub const Options = struct {
    top: usize = 20,
    frame_budget_ns: ?u64 = null,
    min_frame_delta_ns: u64 = 0,
    min_zone_delta_ns: u64 = 0,
    min_gpu_delta_ns: u64 = 0,
    min_memory_delta_bytes: u64 = 0,
    min_memory_lifetime_delta_ns: u64 = 0,
    include_stable: bool = false,
};

pub const Analyzer = struct {
    summary: summary.Analyzer,
    frames: frame_mod.Analyzer,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{
            .summary = summary.Analyzer.init(allocator),
            .frames = frame_mod.Analyzer.init(allocator),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.frames.deinit();
        self.summary.deinit();
        self.* = undefined;
    }

    pub fn ingestJsonlBytes(self: *Analyzer, bytes: []const u8) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| try self.ingestJsonLine(line);
    }

    pub fn ingestJsonLine(self: *Analyzer, line: []const u8) !void {
        try self.summary.ingestJsonLine(line);
        try self.frames.ingestJsonLine(line);
    }
};

const Status = enum {
    changed,
    new,
    removed,
    stable,

    fn tag(self: Status) []const u8 {
        return switch (self) {
            .changed => "changed",
            .new => "new",
            .removed => "removed",
            .stable => "stable",
        };
    }
};

const Counts = struct {
    shared: usize = 0,
    changed: usize = 0,
    stable: usize = 0,
    new: usize = 0,
    removed: usize = 0,

    fn observe(self: *Counts, status: Status) void {
        switch (status) {
            .changed => {
                self.shared += 1;
                self.changed += 1;
            },
            .stable => {
                self.shared += 1;
                self.stable += 1;
            },
            .new => self.new += 1,
            .removed => self.removed += 1,
        }
    }
};

const ZoneMetric = enum {
    total,
    mean,
    min,
    p50,
    p90,
    p99,
    max,

    fn tag(self: ZoneMetric) []const u8 {
        return @tagName(self);
    }
};

const ZoneValues = struct {
    count: u64 = 0,
    duration_samples: u64 = 0,
    total_ns: u64 = 0,
    mean_ns: u64 = 0,
    min_ns: u64 = 0,
    p50_ns: u64 = 0,
    p90_ns: u64 = 0,
    p99_ns: u64 = 0,
    max_ns: u64 = 0,

    fn from(summary_value: ?summary.ZoneSummary) ZoneValues {
        const row = summary_value orelse return .{};
        return .{
            .count = row.count,
            .duration_samples = row.duration_samples,
            .total_ns = row.total_ns,
            .mean_ns = row.meanNs(),
            .min_ns = if (row.duration_samples == 0) 0 else row.min_ns,
            .p50_ns = row.percentileNs(50),
            .p90_ns = row.percentileNs(90),
            .p99_ns = row.percentileNs(99),
            .max_ns = row.max_ns,
        };
    }

    fn value(self: ZoneValues, metric: ZoneMetric) u64 {
        return switch (metric) {
            .total => self.total_ns,
            .mean => self.mean_ns,
            .min => self.min_ns,
            .p50 => self.p50_ns,
            .p90 => self.p90_ns,
            .p99 => self.p99_ns,
            .max => self.max_ns,
        };
    }
};

const ZoneDelta = struct {
    name: []const u8,
    status: Status,
    baseline: ZoneValues,
    run: ZoneValues,
    baseline_evidence: []const u8,
    run_evidence: []const u8,

    fn evidence(self: ZoneDelta) []const u8 {
        if (!std.mem.eql(u8, self.baseline_evidence, "complete")) return "partial";
        if (!std.mem.eql(u8, self.run_evidence, "complete")) return "partial";
        if (self.baseline.count != self.baseline.duration_samples) return "partial";
        if (self.run.count != self.run.duration_samples) return "partial";
        return "complete";
    }

    fn populationChanged(self: ZoneDelta) bool {
        if (self.baseline.count != self.run.count) return true;
        return self.baseline.duration_samples != self.run.duration_samples;
    }

    fn delta(self: ZoneDelta, metric: ZoneMetric) i128 {
        return signedDelta(self.baseline.value(metric), self.run.value(metric));
    }

    fn magnitude(self: ZoneDelta) u128 {
        var result: u128 = 0;
        inline for (std.meta.tags(ZoneMetric)) |metric| {
            result = @max(result, absI128(self.delta(metric)));
        }
        return result;
    }
};

const MemoryValues = struct {
    allocations: u64 = 0,
    frees: u64 = 0,
    unmatched_frees: u64 = 0,
    duplicate_allocations: u64 = 0,
    right_censored_allocations: u64 = 0,
    completed_lifetimes: u64 = 0,
    lifetime_samples: u64 = 0,
    timestamp_regressions: u64 = 0,
    untracked_allocations: u64 = 0,
    size_mismatches: u64 = 0,
    allocated_bytes: u64 = 0,
    freed_bytes: u64 = 0,
    live_bytes: u64 = 0,
    high_water_live_bytes: u64 = 0,
    total_lifetime_ns: u64 = 0,
    mean_lifetime_ns: u64 = 0,
    min_lifetime_ns: u64 = 0,
    p50_lifetime_ns: u64 = 0,
    p90_lifetime_ns: u64 = 0,
    p99_lifetime_ns: u64 = 0,
    max_lifetime_ns: u64 = 0,

    fn from(summary_value: ?memory_mod.Summary) MemoryValues {
        const value = summary_value orelse return .{};
        return .{
            .allocations = value.allocations,
            .frees = value.frees,
            .unmatched_frees = value.unmatched_frees,
            .duplicate_allocations = value.duplicate_allocations,
            .right_censored_allocations = value.active_allocations,
            .completed_lifetimes = value.completed_lifetimes,
            .lifetime_samples = value.lifetime_samples,
            .timestamp_regressions = value.timestamp_regressions,
            .untracked_allocations = value.untracked_allocations,
            .size_mismatches = value.size_mismatches,
            .allocated_bytes = value.allocated_bytes,
            .freed_bytes = value.freed_bytes,
            .live_bytes = value.live_bytes,
            .high_water_live_bytes = value.high_water_live_bytes,
            .total_lifetime_ns = value.total_lifetime_ns,
            .mean_lifetime_ns = value.meanLifetimeNs(),
            .min_lifetime_ns = value.min_lifetime_ns,
            .p50_lifetime_ns = value.p50_lifetime_ns,
            .p90_lifetime_ns = value.p90_lifetime_ns,
            .p99_lifetime_ns = value.p99_lifetime_ns,
            .max_lifetime_ns = value.max_lifetime_ns,
        };
    }
};

const MemoryDelta = struct {
    name: []const u8,
    status: Status,
    baseline: MemoryValues,
    run: MemoryValues,
    baseline_lifetime_evidence: []const u8,
    run_lifetime_evidence: []const u8,

    fn evidence(self: MemoryDelta) []const u8 {
        if (!std.mem.eql(u8, self.baseline_lifetime_evidence, "complete")) return "partial";
        if (!std.mem.eql(u8, self.run_lifetime_evidence, "complete")) return "partial";
        return "complete";
    }

    fn byteMagnitude(self: MemoryDelta) u128 {
        var result: u128 = 0;
        inline for (.{
            signedDelta(self.baseline.high_water_live_bytes, self.run.high_water_live_bytes),
            signedDelta(self.baseline.live_bytes, self.run.live_bytes),
            signedDelta(self.baseline.allocated_bytes, self.run.allocated_bytes),
            signedDelta(self.baseline.freed_bytes, self.run.freed_bytes),
        }) |delta| result = @max(result, absI128(delta));
        return result;
    }

    fn lifetimeMagnitude(self: MemoryDelta) u128 {
        var result: u128 = 0;
        inline for (.{
            signedDelta(self.baseline.total_lifetime_ns, self.run.total_lifetime_ns),
            signedDelta(self.baseline.mean_lifetime_ns, self.run.mean_lifetime_ns),
            signedDelta(self.baseline.min_lifetime_ns, self.run.min_lifetime_ns),
            signedDelta(self.baseline.p50_lifetime_ns, self.run.p50_lifetime_ns),
            signedDelta(self.baseline.p90_lifetime_ns, self.run.p90_lifetime_ns),
            signedDelta(self.baseline.p99_lifetime_ns, self.run.p99_lifetime_ns),
            signedDelta(self.baseline.max_lifetime_ns, self.run.max_lifetime_ns),
        }) |delta| result = @max(result, absI128(delta));
        return result;
    }

    fn populationChanged(self: MemoryDelta) bool {
        if (self.baseline.allocations != self.run.allocations) return true;
        if (self.baseline.frees != self.run.frees) return true;
        if (self.baseline.right_censored_allocations != self.run.right_censored_allocations) {
            return true;
        }
        if (self.baseline.completed_lifetimes != self.run.completed_lifetimes) return true;
        return self.baseline.lifetime_samples != self.run.lifetime_samples;
    }

    fn anomaliesChanged(self: MemoryDelta) bool {
        if (self.baseline.unmatched_frees != self.run.unmatched_frees) return true;
        if (self.baseline.duplicate_allocations != self.run.duplicate_allocations) return true;
        if (self.baseline.timestamp_regressions != self.run.timestamp_regressions) return true;
        if (self.baseline.untracked_allocations != self.run.untracked_allocations) return true;
        return self.baseline.size_mismatches != self.run.size_mismatches;
    }
};

const PlotCompatibility = enum {
    matching,
    mismatch,
    unknown,
    not_applicable,

    fn tag(self: PlotCompatibility) []const u8 {
        return switch (self) {
            .matching => "matching",
            .mismatch => "mismatch",
            .unknown => "unknown",
            .not_applicable => "not_applicable",
        };
    }
};

const PlotMetric = enum {
    min,
    p50,
    p90,
    p99,
    max,
    mean,
    last,
    range,

    fn tag(self: PlotMetric) []const u8 {
        return @tagName(self);
    }

    fn value(self: PlotMetric, plot: plot_mod.Summary) f64 {
        return switch (self) {
            .min => plot.min,
            .p50 => plot.p50,
            .p90 => plot.p90,
            .p99 => plot.p99,
            .max => plot.max,
            .mean => plot.mean,
            .last => plot.last,
            .range => plot.range,
        };
    }
};

const PlotDelta = struct {
    name: []const u8,
    status: Status,
    partial: bool,
    compatibility: PlotCompatibility,
    baseline: ?plot_mod.Summary,
    run: ?plot_mod.Summary,

    fn evidence(self: PlotDelta) []const u8 {
        return if (self.partial) "partial" else "complete";
    }

    fn valuesComparable(self: PlotDelta) bool {
        if (self.baseline == null or self.run == null) return false;
        return self.compatibility != .mismatch;
    }

    fn magnitude(self: PlotDelta) f64 {
        if (!self.valuesComparable()) {
            const base_extent = if (self.baseline) |plot|
                @max(absF64(plot.min), absF64(plot.max))
            else
                0;
            const run_extent = if (self.run) |plot|
                @max(absF64(plot.min), absF64(plot.max))
            else
                0;
            return @max(base_extent, run_extent);
        }
        var result: f64 = 0;
        inline for (std.meta.tags(PlotMetric)) |metric| {
            result = @max(result, absF64(self.delta(metric).?));
        }
        return result;
    }

    fn delta(self: PlotDelta, metric: PlotMetric) ?f64 {
        if (!self.valuesComparable()) return null;
        return metric.value(self.run.?) - metric.value(self.baseline.?);
    }
};

const GpuDelta = struct {
    name: []const u8,
    status: Status,
    base_count: u64 = 0,
    run_count: u64 = 0,
    base_completed_zones: u64 = 0,
    run_completed_zones: u64 = 0,
    base_total_gpu_ns: u64 = 0,
    run_total_gpu_ns: u64 = 0,
    base_mean_gpu_ns: u64 = 0,
    run_mean_gpu_ns: u64 = 0,

    fn deltaTotalGpuNs(self: GpuDelta) i128 {
        return signedDelta(self.base_total_gpu_ns, self.run_total_gpu_ns);
    }

    fn deltaMeanGpuNs(self: GpuDelta) i128 {
        return signedDelta(self.base_mean_gpu_ns, self.run_mean_gpu_ns);
    }

    fn magnitude(self: GpuDelta) u128 {
        return @max(
            absI128(self.deltaTotalGpuNs()),
            absI128(self.deltaMeanGpuNs()),
        );
    }

    fn evidence(self: GpuDelta) []const u8 {
        if (self.base_count != self.base_completed_zones) return "partial";
        if (self.run_count != self.run_completed_zones) return "partial";
        return "complete";
    }
};

const FrameDelta = struct {
    name: []const u8,
    status: Status,
    partial: bool,
    budget_ns: ?u64,
    base_marks: u64 = 0,
    run_marks: u64 = 0,
    base_frames: u64 = 0,
    run_frames: u64 = 0,
    base_mean_ns: u64 = 0,
    run_mean_ns: u64 = 0,
    base_p50_ns: u64 = 0,
    run_p50_ns: u64 = 0,
    base_p90_ns: u64 = 0,
    run_p90_ns: u64 = 0,
    base_p99_ns: u64 = 0,
    run_p99_ns: u64 = 0,
    base_max_ns: u64 = 0,
    run_max_ns: u64 = 0,
    base_discrepancy_ns: u64 = 0,
    run_discrepancy_ns: u64 = 0,
    base_over_budget_frames: u64 = 0,
    run_over_budget_frames: u64 = 0,
    base_over_budget_per_mille: u64 = 0,
    run_over_budget_per_mille: u64 = 0,
    base_missed_intervals: u64 = 0,
    run_missed_intervals: u64 = 0,
    base_missed_per_1000_frames: u64 = 0,
    run_missed_per_1000_frames: u64 = 0,
    base_total_overrun_ns: u64 = 0,
    run_total_overrun_ns: u64 = 0,
    base_max_overrun_ns: u64 = 0,
    run_max_overrun_ns: u64 = 0,
    base_longest_overrun_streak: u64 = 0,
    run_longest_overrun_streak: u64 = 0,

    fn evidence(self: FrameDelta) []const u8 {
        return if (self.partial) "partial" else "complete";
    }

    fn magnitude(self: FrameDelta) u128 {
        var result: u128 = 0;
        inline for (.{
            signedDelta(self.base_mean_ns, self.run_mean_ns),
            signedDelta(self.base_p50_ns, self.run_p50_ns),
            signedDelta(self.base_p90_ns, self.run_p90_ns),
            signedDelta(self.base_p99_ns, self.run_p99_ns),
            signedDelta(self.base_max_ns, self.run_max_ns),
            signedDelta(self.base_discrepancy_ns, self.run_discrepancy_ns),
        }) |delta| result = @max(result, absI128(delta));
        return result;
    }

    fn populationChanged(self: FrameDelta) bool {
        return self.base_marks != self.run_marks or self.base_frames != self.run_frames;
    }

    fn budgetChanged(self: FrameDelta) bool {
        if (self.budget_ns == null) return false;
        if (self.base_over_budget_frames != self.run_over_budget_frames) return true;
        if (self.base_over_budget_per_mille != self.run_over_budget_per_mille) return true;
        if (self.base_missed_intervals != self.run_missed_intervals) return true;
        if (self.base_missed_per_1000_frames != self.run_missed_per_1000_frames) return true;
        if (self.base_total_overrun_ns != self.run_total_overrun_ns) return true;
        if (self.base_max_overrun_ns != self.run_max_overrun_ns) return true;
        return self.base_longest_overrun_streak != self.run_longest_overrun_streak;
    }
};

const FrameEvidence = struct {
    baseline: std.ArrayListUnmanaged(frame_mod.Summary) = .empty,
    run: std.ArrayListUnmanaged(frame_mod.Summary) = .empty,
    deltas: std.ArrayListUnmanaged(FrameDelta) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        baseline: *frame_mod.Analyzer,
        run: *frame_mod.Analyzer,
        options: Options,
    ) !FrameEvidence {
        if (options.frame_budget_ns == 0) return error.InvalidBudget;
        var result: FrameEvidence = .{};
        errdefer result.deinit(allocator);
        const frame_options = frame_mod.Options{
            .top = options.top,
            .sort = .name,
            .budget_ns = options.frame_budget_ns,
        };
        result.baseline = try frame_mod.collectSummaries(allocator, baseline, frame_options);
        result.run = try frame_mod.collectSummaries(allocator, run, frame_options);
        const partial = frameCapturePartial(baseline) or frameCapturePartial(run);
        result.deltas = try collectFrameDeltas(
            allocator,
            result.baseline.items,
            result.run.items,
            partial,
            options,
        );
        return result;
    }

    fn deinit(self: *FrameEvidence, allocator: std.mem.Allocator) void {
        self.deltas.deinit(allocator);
        self.run.deinit(allocator);
        self.baseline.deinit(allocator);
        self.* = undefined;
    }
};

const PlotEvidence = struct {
    baseline: std.ArrayListUnmanaged(plot_mod.Summary) = .empty,
    run: std.ArrayListUnmanaged(plot_mod.Summary) = .empty,
    deltas: std.ArrayListUnmanaged(PlotDelta) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        baseline: *summary.Analyzer,
        run: *summary.Analyzer,
        options: Options,
    ) !PlotEvidence {
        var result: PlotEvidence = .{};
        errdefer result.deinit(allocator);
        result.baseline = try baseline.plots.collectSummaries(allocator, .{ .sort = .name });
        result.run = try run.plots.collectSummaries(allocator, .{ .sort = .name });
        const partial = plotCapturePartial(baseline) or plotCapturePartial(run);
        result.deltas = try collectPlotDeltas(
            allocator,
            result.baseline.items,
            result.run.items,
            partial,
            options,
        );
        return result;
    }

    fn deinit(self: *PlotEvidence, allocator: std.mem.Allocator) void {
        self.deltas.deinit(allocator);
        self.run.deinit(allocator);
        self.baseline.deinit(allocator);
        self.* = undefined;
    }
};

const MemoryEvidence = struct {
    baseline: std.ArrayListUnmanaged(memory_mod.Summary) = .empty,
    run: std.ArrayListUnmanaged(memory_mod.Summary) = .empty,
    deltas: std.ArrayListUnmanaged(MemoryDelta) = .empty,
    baseline_allocator: ?std.mem.Allocator = null,
    run_allocator: ?std.mem.Allocator = null,

    fn init(
        allocator: std.mem.Allocator,
        baseline: *summary.Analyzer,
        run: *summary.Analyzer,
        options: Options,
    ) !MemoryEvidence {
        var result: MemoryEvidence = .{};
        errdefer result.deinit(allocator);
        result.baseline_allocator = baseline.allocator;
        result.baseline = try baseline.collectMemory();
        result.run_allocator = run.allocator;
        result.run = try run.collectMemory();
        result.deltas = try collectMemoryDeltas(
            allocator,
            result.baseline.items,
            result.run.items,
            baseline.memory.lifetimeEvidence(),
            run.memory.lifetimeEvidence(),
            options,
        );
        return result;
    }

    fn deinit(self: *MemoryEvidence, allocator: std.mem.Allocator) void {
        self.deltas.deinit(allocator);
        if (self.run_allocator) |actual| self.run.deinit(actual);
        if (self.baseline_allocator) |actual| self.baseline.deinit(actual);
        self.* = undefined;
    }
};

const GpuEvidence = struct {
    baseline: std.ArrayListUnmanaged(gpu_mod.Summary) = .empty,
    run: std.ArrayListUnmanaged(gpu_mod.Summary) = .empty,
    deltas: std.ArrayListUnmanaged(GpuDelta) = .empty,
    baseline_allocator: ?std.mem.Allocator = null,
    run_allocator: ?std.mem.Allocator = null,

    fn init(
        allocator: std.mem.Allocator,
        baseline: *summary.Analyzer,
        run: *summary.Analyzer,
        options: Options,
    ) !GpuEvidence {
        var result: GpuEvidence = .{};
        errdefer result.deinit(allocator);
        result.baseline_allocator = baseline.allocator;
        result.baseline = try baseline.collectGpu();
        result.run_allocator = run.allocator;
        result.run = try run.collectGpu();
        result.deltas = try collectGpuDeltas(
            allocator,
            result.baseline.items,
            result.run.items,
            options,
        );
        return result;
    }

    fn deinit(self: *GpuEvidence, allocator: std.mem.Allocator) void {
        self.deltas.deinit(allocator);
        if (self.run_allocator) |actual| gpu_mod.deinitSummaries(actual, &self.run);
        if (self.baseline_allocator) |actual| gpu_mod.deinitSummaries(actual, &self.baseline);
        self.* = undefined;
    }
};

const Evidence = struct {
    frames: FrameEvidence = .{},
    plots: PlotEvidence = .{},
    zones: std.ArrayListUnmanaged(ZoneDelta) = .empty,
    memory: MemoryEvidence = .{},
    gpu: GpuEvidence = .{},

    fn init(
        allocator: std.mem.Allocator,
        baseline: *Analyzer,
        run: *Analyzer,
        options: Options,
    ) !Evidence {
        var result: Evidence = .{};
        errdefer result.deinit(allocator);
        result.frames = try FrameEvidence.init(
            allocator,
            &baseline.frames,
            &run.frames,
            options,
        );
        result.plots = try PlotEvidence.init(
            allocator,
            &baseline.summary,
            &run.summary,
            options,
        );
        result.zones = try collectZoneDeltas(
            allocator,
            &baseline.summary,
            &run.summary,
            options,
        );
        result.memory = try MemoryEvidence.init(
            allocator,
            &baseline.summary,
            &run.summary,
            options,
        );
        result.gpu = try GpuEvidence.init(
            allocator,
            &baseline.summary,
            &run.summary,
            options,
        );
        return result;
    }

    fn deinit(self: *Evidence, allocator: std.mem.Allocator) void {
        self.gpu.deinit(allocator);
        self.memory.deinit(allocator);
        self.zones.deinit(allocator);
        self.plots.deinit(allocator);
        self.frames.deinit(allocator);
        self.* = undefined;
    }
};

pub fn writeTextFromJsonlPaths(
    allocator: std.mem.Allocator,
    baseline_path: []const u8,
    run_path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var baseline = Analyzer.init(allocator);
    defer baseline.deinit();
    try ingestPath(&baseline, baseline_path);

    var run = Analyzer.init(allocator);
    defer run.deinit();
    try ingestPath(&run, run_path);

    try writeText(allocator, &baseline, &run, writer, options);
}

pub fn writeJsonlFromJsonlPaths(
    allocator: std.mem.Allocator,
    baseline_path: []const u8,
    run_path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var baseline = Analyzer.init(allocator);
    defer baseline.deinit();
    try ingestPath(&baseline, baseline_path);

    var run = Analyzer.init(allocator);
    defer run.deinit();
    try ingestPath(&run, run_path);

    try writeJsonl(allocator, &baseline, &run, writer, options);
}

pub fn ingestPath(analyzer: *Analyzer, path: []const u8) !void {
    return report.ingestJsonlPath(analyzer, path);
}

pub fn writeText(
    allocator: std.mem.Allocator,
    baseline: *Analyzer,
    run: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var evidence = try Evidence.init(allocator, baseline, run, options);
    defer evidence.deinit(allocator);
    try writeCaptureText(&baseline.summary, &run.summary, writer);
    try writeFrameText(baseline, run, writer, evidence.frames.deltas.items, options);
    try writePlotText(
        &baseline.summary,
        &run.summary,
        writer,
        evidence.plots.deltas.items,
        options.top,
    );
    try writeZoneText(
        &baseline.summary,
        &run.summary,
        writer,
        evidence.zones.items,
        options.top,
    );
    try writeMemoryText(
        &baseline.summary,
        &run.summary,
        writer,
        evidence.memory.deltas.items,
        options.top,
    );
    try writeGpuText(
        &baseline.summary,
        &run.summary,
        writer,
        evidence.gpu.deltas.items,
        options.top,
    );
}

fn writeCaptureText(
    baseline: *summary.Analyzer,
    run: *summary.Analyzer,
    writer: *std.Io.Writer,
) !void {
    const base_integrity = baseline.captureIntegrity();
    const run_integrity = run.captureIntegrity();
    try writer.print(
        "tracy compare capture baseline_integrity={s} run_integrity={s} " ++
            "baseline_unbalanced_events={d} run_unbalanced_events={d}\n",
        .{
            base_integrity.status,
            run_integrity.status,
            base_integrity.unbalanced_event_count,
            run_integrity.unbalanced_event_count,
        },
    );
}

fn writeFrameText(
    baseline: *Analyzer,
    run: *Analyzer,
    writer: *std.Io.Writer,
    rows: []const FrameDelta,
    options: Options,
) !void {
    const counts = countStatuses(rows);
    try writer.print(
        "tracy compare frames shared={d} changed={d} stable={d} new={d} removed={d} " ++
            "partial={d} baseline_marks={d} run_marks={d} baseline_frames={d} " ++
            "run_frames={d} baseline_out_of_order_marks={d} run_out_of_order_marks={d}",
        .{
            counts.shared,
            counts.changed,
            counts.stable,
            counts.new,
            counts.removed,
            framePartialCount(rows),
            baseline.frames.counters.marks,
            run.frames.counters.marks,
            baseline.frames.counters.frames,
            run.frames.counters.frames,
            baseline.frames.counters.out_of_order_marks,
            run.frames.counters.out_of_order_marks,
        },
    );
    try writer.writeAll(" budget_ns=");
    try writeOptionalU64Text(writer, options.frame_budget_ns);
    try writer.writeByte('\n');
    for (rows[0..@min(options.top, rows.len)]) |row| {
        try writeFrameTextRow(writer, row);
        if (row.budget_ns != null) try writeFrameBudgetTextRow(writer, row);
    }
}

fn writeFrameTextRow(writer: *std.Io.Writer, row: FrameDelta) !void {
    try writer.print("frame status={s} evidence={s} name=", .{
        row.status.tag(),
        row.evidence(),
    });
    try pretty_json.writeString(writer, row.name);
    try writer.print(
        " base_marks={d} run_marks={d} delta_marks={d} base_frames={d} " ++
            "run_frames={d} delta_frames={d} base_mean_ns={d} run_mean_ns={d} " ++
            "delta_mean_ns={d} base_p50_ns={d} run_p50_ns={d} delta_p50_ns={d} " ++
            "base_p90_ns={d} run_p90_ns={d} delta_p90_ns={d} base_p99_ns={d} " ++
            "run_p99_ns={d} delta_p99_ns={d} base_max_ns={d} run_max_ns={d} " ++
            "delta_max_ns={d} base_discrepancy_ns={d} run_discrepancy_ns={d} " ++
            "delta_discrepancy_ns={d}\n",
        .{
            row.base_marks,
            row.run_marks,
            signedDelta(row.base_marks, row.run_marks),
            row.base_frames,
            row.run_frames,
            signedDelta(row.base_frames, row.run_frames),
            row.base_mean_ns,
            row.run_mean_ns,
            signedDelta(row.base_mean_ns, row.run_mean_ns),
            row.base_p50_ns,
            row.run_p50_ns,
            signedDelta(row.base_p50_ns, row.run_p50_ns),
            row.base_p90_ns,
            row.run_p90_ns,
            signedDelta(row.base_p90_ns, row.run_p90_ns),
            row.base_p99_ns,
            row.run_p99_ns,
            signedDelta(row.base_p99_ns, row.run_p99_ns),
            row.base_max_ns,
            row.run_max_ns,
            signedDelta(row.base_max_ns, row.run_max_ns),
            row.base_discrepancy_ns,
            row.run_discrepancy_ns,
            signedDelta(row.base_discrepancy_ns, row.run_discrepancy_ns),
        },
    );
}

fn writeFrameBudgetTextRow(writer: *std.Io.Writer, row: FrameDelta) !void {
    try writer.print("frame-budget status={s} evidence={s} name=", .{
        row.status.tag(),
        row.evidence(),
    });
    try pretty_json.writeString(writer, row.name);
    try writer.print(
        " budget_ns={d} base_over_budget_frames={d} run_over_budget_frames={d} " ++
            "delta_over_budget_frames={d} base_over_budget_per_mille={d} " ++
            "run_over_budget_per_mille={d} delta_over_budget_per_mille={d} " ++
            "base_missed_intervals={d} run_missed_intervals={d} " ++
            "delta_missed_intervals={d} base_missed_per_1000_frames={d} " ++
            "run_missed_per_1000_frames={d} delta_missed_per_1000_frames={d} " ++
            "base_total_overrun_ns={d} run_total_overrun_ns={d} " ++
            "delta_total_overrun_ns={d} base_max_overrun_ns={d} " ++
            "run_max_overrun_ns={d} delta_max_overrun_ns={d} " ++
            "base_longest_overrun_streak={d} run_longest_overrun_streak={d} " ++
            "delta_longest_overrun_streak={d}\n",
        .{
            row.budget_ns.?,
            row.base_over_budget_frames,
            row.run_over_budget_frames,
            signedDelta(row.base_over_budget_frames, row.run_over_budget_frames),
            row.base_over_budget_per_mille,
            row.run_over_budget_per_mille,
            signedDelta(row.base_over_budget_per_mille, row.run_over_budget_per_mille),
            row.base_missed_intervals,
            row.run_missed_intervals,
            signedDelta(row.base_missed_intervals, row.run_missed_intervals),
            row.base_missed_per_1000_frames,
            row.run_missed_per_1000_frames,
            signedDelta(row.base_missed_per_1000_frames, row.run_missed_per_1000_frames),
            row.base_total_overrun_ns,
            row.run_total_overrun_ns,
            signedDelta(row.base_total_overrun_ns, row.run_total_overrun_ns),
            row.base_max_overrun_ns,
            row.run_max_overrun_ns,
            signedDelta(row.base_max_overrun_ns, row.run_max_overrun_ns),
            row.base_longest_overrun_streak,
            row.run_longest_overrun_streak,
            signedDelta(
                row.base_longest_overrun_streak,
                row.run_longest_overrun_streak,
            ),
        },
    );
}

fn writePlotText(
    baseline: *summary.Analyzer,
    run: *summary.Analyzer,
    writer: *std.Io.Writer,
    rows: []const PlotDelta,
    top: usize,
) !void {
    const counts = countStatuses(rows);
    try writer.print(
        "tracy compare plots shared={d} changed={d} stable={d} new={d} removed={d} " ++
            "partial={d} unit_mismatch={d} unit_unknown={d} " ++
            "baseline_samples={d} run_samples={d} baseline_configurations={d} " ++
            "run_configurations={d} baseline_configuration_conflicts={d} " ++
            "run_configuration_conflicts={d} baseline_ignored_missing_values={d} " ++
            "run_ignored_missing_values={d} baseline_ignored_nonfinite={d} " ++
            "run_ignored_nonfinite={d}\n",
        .{
            counts.shared,
            counts.changed,
            counts.stable,
            counts.new,
            counts.removed,
            plotPartialCount(rows),
            plotCompatibilityCount(rows, .mismatch),
            plotCompatibilityCount(rows, .unknown),
            baseline.plots.counters.samples,
            run.plots.counters.samples,
            baseline.plots.counters.configurations,
            run.plots.counters.configurations,
            baseline.plots.counters.configuration_conflicts,
            run.plots.counters.configuration_conflicts,
            baseline.plots.counters.ignored_missing_values,
            run.plots.counters.ignored_missing_values,
            baseline.plots.counters.ignored_nonfinite,
            run.plots.counters.ignored_nonfinite,
        },
    );
    for (rows[0..@min(top, rows.len)]) |row| try writePlotTextRow(writer, row);
}

fn writePlotTextRow(writer: *std.Io.Writer, row: PlotDelta) !void {
    const baseline = plotOrEmpty(row.baseline, row.name);
    const run = plotOrEmpty(row.run, row.name);
    try writer.print(
        "plot status={s} evidence={s} unit_compatibility={s} name=",
        .{ row.status.tag(), row.evidence(), row.compatibility.tag() },
    );
    try pretty_json.writeString(writer, row.name);
    try writePlotDefinitionText(writer, row);
    try writer.print(
        " base_samples={d} run_samples={d} delta_samples={d} " ++
            "base_threads={d} run_threads={d} delta_threads={d} " ++
            "base_duration_ns={d} run_duration_ns={d} delta_duration_ns={d}",
        .{
            baseline.count,
            run.count,
            signedDelta(baseline.count, run.count),
            baseline.threads,
            run.threads,
            signedDelta(baseline.threads, run.threads),
            baseline.duration_ns,
            run.duration_ns,
            signedDelta(baseline.duration_ns, run.duration_ns),
        },
    );
    try writer.writeByte('\n');
    try writePlotStyleTextRow(writer, row);
    try writePlotDistributionTextRow(writer, row);
}

fn writePlotDefinitionText(writer: *std.Io.Writer, row: PlotDelta) !void {
    const baseline = plotOrEmpty(row.baseline, row.name);
    const run = plotOrEmpty(row.run, row.name);
    try writer.writeAll(" base_kind=");
    try writeOptionalStringText(writer, baseline.kind);
    try writer.writeAll(" run_kind=");
    try writeOptionalStringText(writer, run.kind);
    try writer.writeAll(" base_unit=");
    try writeOptionalStringText(writer, baseline.unit);
    try writer.writeAll(" run_unit=");
    try writeOptionalStringText(writer, run.unit);
}

fn writePlotStyleTextRow(writer: *std.Io.Writer, row: PlotDelta) !void {
    const baseline = plotOrEmpty(row.baseline, row.name);
    const run = plotOrEmpty(row.run, row.name);
    try writer.print("plot-style status={s} evidence={s} name=", .{
        row.status.tag(),
        row.evidence(),
    });
    try pretty_json.writeString(writer, row.name);
    try writer.print(
        " base_configured={} run_configured={} base_step={} run_step={} " ++
            "base_fill={} run_fill={} base_color=",
        .{
            baseline.configured,
            run.configured,
            baseline.step,
            run.step,
            baseline.fill,
            run.fill,
        },
    );
    try writeOptionalU32Text(writer, baseline.color);
    try writer.writeAll(" run_color=");
    try writeOptionalU32Text(writer, run.color);
    try writer.print(
        " base_configurations={d} run_configurations={d} " ++
            "base_configuration_conflicts={d} run_configuration_conflicts={d}",
        .{
            baseline.configurations,
            run.configurations,
            baseline.configuration_conflicts,
            run.configuration_conflicts,
        },
    );
    try writer.writeByte('\n');
}

fn writePlotDistributionTextRow(writer: *std.Io.Writer, row: PlotDelta) !void {
    const baseline = plotOrEmpty(row.baseline, row.name);
    const run = plotOrEmpty(row.run, row.name);
    try writer.print(
        "plot-distribution status={s} evidence={s} unit_compatibility={s} name=",
        .{ row.status.tag(), row.evidence(), row.compatibility.tag() },
    );
    try pretty_json.writeString(writer, row.name);
    inline for (std.meta.tags(PlotMetric)) |metric| {
        try writePlotMetricText(
            writer,
            metric.tag(),
            metric.value(baseline),
            metric.value(run),
            row.delta(metric),
        );
    }
    try writer.writeByte('\n');
}

fn writePlotMetricText(
    writer: *std.Io.Writer,
    label: []const u8,
    baseline: f64,
    run: f64,
    delta: ?f64,
) !void {
    try writer.print(" base_{s}={d} run_{s}={d} delta_{s}=", .{
        label,
        baseline,
        label,
        run,
        label,
    });
    try writeOptionalF64Text(writer, delta);
}

fn writeZoneText(
    baseline: *summary.Analyzer,
    run: *summary.Analyzer,
    writer: *std.Io.Writer,
    rows: []const ZoneDelta,
    top: usize,
) !void {
    const counts = countStatuses(rows);
    try writer.print(
        "tracy compare zones shared={d} changed={d} stable={d} new={d} removed={d} " ++
            "partial={d} baseline_duration_evidence={s} run_duration_evidence={s} " ++
            "baseline_duration_samples={d} run_duration_samples={d} " ++
            "baseline_timestamp_regressions={d} run_timestamp_regressions={d} " ++
            "baseline_duration_ns={d} run_duration_ns={d} delta_duration_ns={d}\n",
        .{
            counts.shared,
            counts.changed,
            counts.stable,
            counts.new,
            counts.removed,
            zonePartialCount(rows),
            baseline.zoneDurationEvidence(),
            run.zoneDurationEvidence(),
            baseline.counters.zone_duration_samples,
            run.counters.zone_duration_samples,
            baseline.counters.zone_timestamp_regressions,
            run.counters.zone_timestamp_regressions,
            baseline.durationNs(),
            run.durationNs(),
            signedDelta(baseline.durationNs(), run.durationNs()),
        },
    );
    for (rows[0..@min(top, rows.len)]) |zone| try writeZoneTextRow(writer, zone);
}

fn writeZoneTextRow(writer: *std.Io.Writer, zone: ZoneDelta) !void {
    try writer.print("zone status={s} evidence={s} name=", .{
        zone.status.tag(),
        zone.evidence(),
    });
    try pretty_json.writeString(writer, zone.name);
    try writer.print(
        " base_count={d} run_count={d} " ++
            "base_duration_samples={d} run_duration_samples={d}",
        .{
            zone.baseline.count,
            zone.run.count,
            zone.baseline.duration_samples,
            zone.run.duration_samples,
        },
    );
    inline for (std.meta.tags(ZoneMetric)) |metric| {
        try writeZoneMetricText(writer, metric, zone);
    }
    try writer.writeByte('\n');
}

fn writeZoneMetricText(
    writer: *std.Io.Writer,
    metric: ZoneMetric,
    zone: ZoneDelta,
) !void {
    try writer.print(" base_{s}_ns={d} run_{s}_ns={d} delta_{s}_ns={d}", .{
        metric.tag(),
        zone.baseline.value(metric),
        metric.tag(),
        zone.run.value(metric),
        metric.tag(),
        zone.delta(metric),
    });
}

fn writeMemoryText(
    baseline: *summary.Analyzer,
    run: *summary.Analyzer,
    writer: *std.Io.Writer,
    rows: []const MemoryDelta,
    top: usize,
) !void {
    const counts = countStatuses(rows);
    try writer.print(
        "tracy compare memory shared={d} changed={d} stable={d} new={d} removed={d} " ++
            "partial={d} baseline_lifetime_evidence={s} run_lifetime_evidence={s}\n",
        .{
            counts.shared,
            counts.changed,
            counts.stable,
            counts.new,
            counts.removed,
            memoryPartialCount(rows),
            baseline.memory.lifetimeEvidence(),
            run.memory.lifetimeEvidence(),
        },
    );
    for (rows[0..@min(top, rows.len)]) |item| try writeMemoryTextRow(writer, item);
}

fn writeMemoryTextRow(writer: *std.Io.Writer, item: MemoryDelta) !void {
    try writer.print("memory status={s} name=", .{item.status.tag()});
    try pretty_json.writeString(writer, item.name);
    try writer.print(" evidence={s}\n", .{item.evidence()});
    try writeMemoryBytesText(writer, item);
    try writeMemoryLifetimesText(writer, item);
    try writeMemoryIntegrityText(writer, item);
}

fn writeMemoryBytesText(writer: *std.Io.Writer, item: MemoryDelta) !void {
    try writer.print(
        "  bytes base_high_water_live_bytes={d} run_high_water_live_bytes={d} " ++
            "delta_high_water_live_bytes={d} base_live_bytes={d} run_live_bytes={d} " ++
            "delta_live_bytes={d} base_allocated_bytes={d} run_allocated_bytes={d} " ++
            "delta_allocated_bytes={d} base_freed_bytes={d} run_freed_bytes={d} " ++
            "delta_freed_bytes={d}\n",
        .{
            item.baseline.high_water_live_bytes,
            item.run.high_water_live_bytes,
            signedDelta(item.baseline.high_water_live_bytes, item.run.high_water_live_bytes),
            item.baseline.live_bytes,
            item.run.live_bytes,
            signedDelta(item.baseline.live_bytes, item.run.live_bytes),
            item.baseline.allocated_bytes,
            item.run.allocated_bytes,
            signedDelta(item.baseline.allocated_bytes, item.run.allocated_bytes),
            item.baseline.freed_bytes,
            item.run.freed_bytes,
            signedDelta(item.baseline.freed_bytes, item.run.freed_bytes),
        },
    );
}

fn writeMemoryLifetimesText(writer: *std.Io.Writer, item: MemoryDelta) !void {
    try writer.print(
        "  lifetimes base_completed={d} run_completed={d} base_samples={d} run_samples={d} " ++
            "base_total_ns={d} run_total_ns={d} delta_total_ns={d} base_mean_ns={d} " ++
            "run_mean_ns={d} delta_mean_ns={d} base_min_ns={d} run_min_ns={d} " ++
            "delta_min_ns={d} base_p50_ns={d} run_p50_ns={d} delta_p50_ns={d} " ++
            "base_p90_ns={d} run_p90_ns={d} delta_p90_ns={d} base_p99_ns={d} " ++
            "run_p99_ns={d} delta_p99_ns={d} base_max_ns={d} run_max_ns={d} " ++
            "delta_max_ns={d}\n",
        .{
            item.baseline.completed_lifetimes,
            item.run.completed_lifetimes,
            item.baseline.lifetime_samples,
            item.run.lifetime_samples,
            item.baseline.total_lifetime_ns,
            item.run.total_lifetime_ns,
            signedDelta(item.baseline.total_lifetime_ns, item.run.total_lifetime_ns),
            item.baseline.mean_lifetime_ns,
            item.run.mean_lifetime_ns,
            signedDelta(item.baseline.mean_lifetime_ns, item.run.mean_lifetime_ns),
            item.baseline.min_lifetime_ns,
            item.run.min_lifetime_ns,
            signedDelta(item.baseline.min_lifetime_ns, item.run.min_lifetime_ns),
            item.baseline.p50_lifetime_ns,
            item.run.p50_lifetime_ns,
            signedDelta(item.baseline.p50_lifetime_ns, item.run.p50_lifetime_ns),
            item.baseline.p90_lifetime_ns,
            item.run.p90_lifetime_ns,
            signedDelta(item.baseline.p90_lifetime_ns, item.run.p90_lifetime_ns),
            item.baseline.p99_lifetime_ns,
            item.run.p99_lifetime_ns,
            signedDelta(item.baseline.p99_lifetime_ns, item.run.p99_lifetime_ns),
            item.baseline.max_lifetime_ns,
            item.run.max_lifetime_ns,
            signedDelta(item.baseline.max_lifetime_ns, item.run.max_lifetime_ns),
        },
    );
}

fn writeMemoryIntegrityText(writer: *std.Io.Writer, item: MemoryDelta) !void {
    try writer.print(
        "  integrity baseline_evidence={s} run_evidence={s} base_allocations={d} " ++
            "run_allocations={d} base_frees={d} run_frees={d} base_right_censored={d} " ++
            "run_right_censored={d} base_unmatched_frees={d} run_unmatched_frees={d} " ++
            "base_duplicate_allocations={d} run_duplicate_allocations={d} " ++
            "base_timestamp_regressions={d} run_timestamp_regressions={d} " ++
            "base_untracked_allocations={d} run_untracked_allocations={d} " ++
            "base_size_mismatches={d} run_size_mismatches={d}\n",
        .{
            item.baseline_lifetime_evidence,
            item.run_lifetime_evidence,
            item.baseline.allocations,
            item.run.allocations,
            item.baseline.frees,
            item.run.frees,
            item.baseline.right_censored_allocations,
            item.run.right_censored_allocations,
            item.baseline.unmatched_frees,
            item.run.unmatched_frees,
            item.baseline.duplicate_allocations,
            item.run.duplicate_allocations,
            item.baseline.timestamp_regressions,
            item.run.timestamp_regressions,
            item.baseline.untracked_allocations,
            item.run.untracked_allocations,
            item.baseline.size_mismatches,
            item.run.size_mismatches,
        },
    );
}

fn writeGpuText(
    baseline: *summary.Analyzer,
    run: *summary.Analyzer,
    writer: *std.Io.Writer,
    rows: []const GpuDelta,
    top: usize,
) !void {
    const counts = countStatuses(rows);
    try writer.print(
        "tracy compare gpu shared={d} changed={d} stable={d} new={d} removed={d} " ++
            "partial={d} baseline_incomplete_zones={d} run_incomplete_zones={d} " ++
            "baseline_unmatched_ends={d} run_unmatched_ends={d} " ++
            "baseline_unmatched_times={d} run_unmatched_times={d}\n",
        .{
            counts.shared,
            counts.changed,
            counts.stable,
            counts.new,
            counts.removed,
            gpuPartialCount(rows),
            baseline.gpu.incompleteZoneCount(),
            run.gpu.incompleteZoneCount(),
            baseline.gpu.counters.unmatched_ends,
            run.gpu.counters.unmatched_ends,
            baseline.gpu.counters.unmatched_times,
            run.gpu.counters.unmatched_times,
        },
    );
    for (rows[0..@min(top, rows.len)]) |row| try writeGpuTextRow(writer, row);
}

fn writeGpuTextRow(writer: *std.Io.Writer, row: GpuDelta) !void {
    try writer.print("gpu status={s} evidence={s} name=", .{
        row.status.tag(),
        row.evidence(),
    });
    try pretty_json.writeString(writer, row.name);
    try writer.print(
        " base_total_gpu_ns={d} run_total_gpu_ns={d} delta_total_gpu_ns={d} " ++
            "base_mean_gpu_ns={d} run_mean_gpu_ns={d} delta_mean_gpu_ns={d} " ++
            "base_count={d} run_count={d} base_completed_zones={d} " ++
            "run_completed_zones={d}\n",
        .{
            row.base_total_gpu_ns,
            row.run_total_gpu_ns,
            row.deltaTotalGpuNs(),
            row.base_mean_gpu_ns,
            row.run_mean_gpu_ns,
            row.deltaMeanGpuNs(),
            row.base_count,
            row.run_count,
            row.base_completed_zones,
            row.run_completed_zones,
        },
    );
}

pub fn writeJsonl(
    allocator: std.mem.Allocator,
    baseline: *Analyzer,
    run: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var evidence = try Evidence.init(allocator, baseline, run, options);
    defer evidence.deinit(allocator);
    try writeComparisonSummaryJson(baseline, run, writer, evidence, options);
    try writeFrameJson(writer, evidence.frames.deltas.items, options.top);
    try writePlotJson(writer, evidence.plots.deltas.items, options.top);
    try writeZoneJson(writer, evidence.zones.items, options.top);
    try writeMemoryJson(writer, evidence.memory.deltas.items, options.top);
    try writeGpuJson(writer, evidence.gpu.deltas.items, options.top);
}

fn writeComparisonSummaryJson(
    baseline: *Analyzer,
    run: *Analyzer,
    writer: *std.Io.Writer,
    evidence: Evidence,
    options: Options,
) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "summary");
    try writeComparisonCountFields(object, evidence);
    try writePlotCountFields(object, baseline, run, evidence.plots.deltas.items);
    try writeZoneEvidenceFields(object, baseline, run);
    try object.field("baseline_duration_ns", baseline.summary.durationNs());
    try object.field("run_duration_ns", run.summary.durationNs());
    try object.field(
        "delta_duration_ns",
        signedDelta(baseline.summary.durationNs(), run.summary.durationNs()),
    );
    try object.field("frame_budget_ns", options.frame_budget_ns);
    try writeComparisonIntegrityFields(object, baseline, run);
    try object.endLine();
}

fn writeZoneEvidenceFields(
    object: pretty_json.Object,
    baseline: *Analyzer,
    run: *Analyzer,
) !void {
    try object.field(
        "baseline_zone_duration_samples",
        baseline.summary.counters.zone_duration_samples,
    );
    try object.field(
        "run_zone_duration_samples",
        run.summary.counters.zone_duration_samples,
    );
    try object.field(
        "baseline_zone_timestamp_regressions",
        baseline.summary.counters.zone_timestamp_regressions,
    );
    try object.field(
        "run_zone_timestamp_regressions",
        run.summary.counters.zone_timestamp_regressions,
    );
    try object.field(
        "baseline_zone_duration_evidence",
        baseline.summary.zoneDurationEvidence(),
    );
    try object.field("run_zone_duration_evidence", run.summary.zoneDurationEvidence());
}

fn writeComparisonCountFields(object: pretty_json.Object, evidence: Evidence) !void {
    const frame_counts = countStatuses(evidence.frames.deltas.items);
    const zone_counts = countStatuses(evidence.zones.items);
    const memory_counts = countStatuses(evidence.memory.deltas.items);
    const gpu_counts = countStatuses(evidence.gpu.deltas.items);
    try object.field("frame_shared", frame_counts.shared);
    try object.field("frame_changed", frame_counts.changed);
    try object.field("frame_stable", frame_counts.stable);
    try object.field("frame_new", frame_counts.new);
    try object.field("frame_removed", frame_counts.removed);
    try object.field("frame_partial", framePartialCount(evidence.frames.deltas.items));
    try object.field("zone_shared", zone_counts.shared);
    try object.field("zone_changed", zone_counts.changed);
    try object.field("zone_stable", zone_counts.stable);
    try object.field("zone_new", zone_counts.new);
    try object.field("zone_removed", zone_counts.removed);
    try object.field("zone_partial", zonePartialCount(evidence.zones.items));
    try object.field("memory_shared", memory_counts.shared);
    try object.field("memory_changed", memory_counts.changed);
    try object.field("memory_stable", memory_counts.stable);
    try object.field("memory_new", memory_counts.new);
    try object.field("memory_removed", memory_counts.removed);
    try object.field("memory_partial", memoryPartialCount(evidence.memory.deltas.items));
    try object.field("gpu_shared", gpu_counts.shared);
    try object.field("gpu_changed", gpu_counts.changed);
    try object.field("gpu_stable", gpu_counts.stable);
    try object.field("gpu_new", gpu_counts.new);
    try object.field("gpu_removed", gpu_counts.removed);
    try object.field("gpu_partial", gpuPartialCount(evidence.gpu.deltas.items));
}

fn writePlotCountFields(
    object: pretty_json.Object,
    baseline: *Analyzer,
    run: *Analyzer,
    rows: []const PlotDelta,
) !void {
    const counts = countStatuses(rows);
    try object.field("plot_shared", counts.shared);
    try object.field("plot_changed", counts.changed);
    try object.field("plot_stable", counts.stable);
    try object.field("plot_new", counts.new);
    try object.field("plot_removed", counts.removed);
    try object.field("plot_partial", plotPartialCount(rows));
    try object.field("plot_unit_mismatch", plotCompatibilityCount(rows, .mismatch));
    try object.field("plot_unit_unknown", plotCompatibilityCount(rows, .unknown));
    try object.field("baseline_plot_samples", baseline.summary.plots.counters.samples);
    try object.field("run_plot_samples", run.summary.plots.counters.samples);
    try object.field(
        "baseline_plot_configurations",
        baseline.summary.plots.counters.configurations,
    );
    try object.field(
        "run_plot_configurations",
        run.summary.plots.counters.configurations,
    );
    try object.field(
        "baseline_plot_configuration_conflicts",
        baseline.summary.plots.counters.configuration_conflicts,
    );
    try object.field(
        "run_plot_configuration_conflicts",
        run.summary.plots.counters.configuration_conflicts,
    );
    try object.field(
        "baseline_plot_ignored_missing_values",
        baseline.summary.plots.counters.ignored_missing_values,
    );
    try object.field(
        "run_plot_ignored_missing_values",
        run.summary.plots.counters.ignored_missing_values,
    );
    try object.field(
        "baseline_plot_ignored_nonfinite",
        baseline.summary.plots.counters.ignored_nonfinite,
    );
    try object.field(
        "run_plot_ignored_nonfinite",
        run.summary.plots.counters.ignored_nonfinite,
    );
}

fn writeComparisonIntegrityFields(
    object: pretty_json.Object,
    baseline: *Analyzer,
    run: *Analyzer,
) !void {
    const base_integrity = baseline.summary.captureIntegrity();
    const run_integrity = run.summary.captureIntegrity();
    try object.field("baseline_capture_integrity", base_integrity.status);
    try object.field("run_capture_integrity", run_integrity.status);
    try object.field("baseline_unbalanced_events", base_integrity.unbalanced_event_count);
    try object.field("run_unbalanced_events", run_integrity.unbalanced_event_count);
    try object.field(
        "baseline_frame_out_of_order_marks",
        baseline.frames.counters.out_of_order_marks,
    );
    try object.field(
        "run_frame_out_of_order_marks",
        run.frames.counters.out_of_order_marks,
    );
    try object.field(
        "baseline_gpu_incomplete_zones",
        baseline.summary.gpu.incompleteZoneCount(),
    );
    try object.field(
        "run_gpu_incomplete_zones",
        run.summary.gpu.incompleteZoneCount(),
    );
    try object.field(
        "baseline_gpu_unmatched_ends",
        baseline.summary.gpu.counters.unmatched_ends,
    );
    try object.field(
        "run_gpu_unmatched_ends",
        run.summary.gpu.counters.unmatched_ends,
    );
    try object.field(
        "baseline_gpu_unmatched_times",
        baseline.summary.gpu.counters.unmatched_times,
    );
    try object.field(
        "run_gpu_unmatched_times",
        run.summary.gpu.counters.unmatched_times,
    );
}

fn writeFrameJson(writer: *std.Io.Writer, rows: []const FrameDelta, top: usize) !void {
    for (rows[0..@min(top, rows.len)]) |row| {
        try writeFrameJsonRow(writer, row);
        if (row.budget_ns != null) try writeFrameBudgetJsonRow(writer, row);
    }
}

fn writeFrameJsonRow(writer: *std.Io.Writer, row: FrameDelta) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try writeFrameFields(object, "frame", row);
    try object.field("base_marks", row.base_marks);
    try object.field("run_marks", row.run_marks);
    try object.field("delta_marks", signedDelta(row.base_marks, row.run_marks));
    try object.field("base_frames", row.base_frames);
    try object.field("run_frames", row.run_frames);
    try object.field("delta_frames", signedDelta(row.base_frames, row.run_frames));
    try object.field("base_mean_ns", row.base_mean_ns);
    try object.field("run_mean_ns", row.run_mean_ns);
    try object.field("delta_mean_ns", signedDelta(row.base_mean_ns, row.run_mean_ns));
    try object.field("base_p50_ns", row.base_p50_ns);
    try object.field("run_p50_ns", row.run_p50_ns);
    try object.field("delta_p50_ns", signedDelta(row.base_p50_ns, row.run_p50_ns));
    try object.field("base_p90_ns", row.base_p90_ns);
    try object.field("run_p90_ns", row.run_p90_ns);
    try object.field("delta_p90_ns", signedDelta(row.base_p90_ns, row.run_p90_ns));
    try object.field("base_p99_ns", row.base_p99_ns);
    try object.field("run_p99_ns", row.run_p99_ns);
    try object.field("delta_p99_ns", signedDelta(row.base_p99_ns, row.run_p99_ns));
    try object.field("base_max_ns", row.base_max_ns);
    try object.field("run_max_ns", row.run_max_ns);
    try object.field("delta_max_ns", signedDelta(row.base_max_ns, row.run_max_ns));
    try object.field("base_discrepancy_ns", row.base_discrepancy_ns);
    try object.field("run_discrepancy_ns", row.run_discrepancy_ns);
    try object.field(
        "delta_discrepancy_ns",
        signedDelta(row.base_discrepancy_ns, row.run_discrepancy_ns),
    );
    try object.endLine();
}

fn writeFrameBudgetJsonRow(writer: *std.Io.Writer, row: FrameDelta) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try writeFrameFields(object, "frame_budget", row);
    try object.field("budget_ns", row.budget_ns.?);
    try object.field("base_over_budget_frames", row.base_over_budget_frames);
    try object.field("run_over_budget_frames", row.run_over_budget_frames);
    try object.field(
        "delta_over_budget_frames",
        signedDelta(row.base_over_budget_frames, row.run_over_budget_frames),
    );
    try object.field("base_over_budget_per_mille", row.base_over_budget_per_mille);
    try object.field("run_over_budget_per_mille", row.run_over_budget_per_mille);
    try object.field(
        "delta_over_budget_per_mille",
        signedDelta(row.base_over_budget_per_mille, row.run_over_budget_per_mille),
    );
    try object.field("base_missed_intervals", row.base_missed_intervals);
    try object.field("run_missed_intervals", row.run_missed_intervals);
    try object.field(
        "delta_missed_intervals",
        signedDelta(row.base_missed_intervals, row.run_missed_intervals),
    );
    try object.field("base_missed_per_1000_frames", row.base_missed_per_1000_frames);
    try object.field("run_missed_per_1000_frames", row.run_missed_per_1000_frames);
    try object.field(
        "delta_missed_per_1000_frames",
        signedDelta(row.base_missed_per_1000_frames, row.run_missed_per_1000_frames),
    );
    try object.field("base_total_overrun_ns", row.base_total_overrun_ns);
    try object.field("run_total_overrun_ns", row.run_total_overrun_ns);
    try object.field(
        "delta_total_overrun_ns",
        signedDelta(row.base_total_overrun_ns, row.run_total_overrun_ns),
    );
    try object.field("base_max_overrun_ns", row.base_max_overrun_ns);
    try object.field("run_max_overrun_ns", row.run_max_overrun_ns);
    try object.field(
        "delta_max_overrun_ns",
        signedDelta(row.base_max_overrun_ns, row.run_max_overrun_ns),
    );
    try object.field("base_longest_overrun_streak", row.base_longest_overrun_streak);
    try object.field("run_longest_overrun_streak", row.run_longest_overrun_streak);
    try object.field(
        "delta_longest_overrun_streak",
        signedDelta(row.base_longest_overrun_streak, row.run_longest_overrun_streak),
    );
    try object.endLine();
}

fn writeFrameFields(object: pretty_json.Object, kind: []const u8, row: FrameDelta) !void {
    try object.field("schema", schema);
    try object.field("kind", kind);
    try object.field("status", row.status.tag());
    try object.field("evidence", row.evidence());
    try object.field("name", row.name);
}

fn writePlotJson(writer: *std.Io.Writer, rows: []const PlotDelta, top: usize) !void {
    for (rows[0..@min(top, rows.len)]) |row| {
        const baseline = plotOrEmpty(row.baseline, row.name);
        const run = plotOrEmpty(row.run, row.name);
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "plot");
        try object.field("status", row.status.tag());
        try object.field("evidence", row.evidence());
        try object.field("unit_compatibility", row.compatibility.tag());
        try object.field("name", row.name);
        try writePlotDefinitionFields(object, row);
        try object.field("base_samples", baseline.count);
        try object.field("run_samples", run.count);
        try object.field("delta_samples", signedDelta(baseline.count, run.count));
        try object.field("base_threads", baseline.threads);
        try object.field("run_threads", run.threads);
        try object.field("delta_threads", signedDelta(baseline.threads, run.threads));
        try object.field("base_duration_ns", baseline.duration_ns);
        try object.field("run_duration_ns", run.duration_ns);
        try object.field(
            "delta_duration_ns",
            signedDelta(baseline.duration_ns, run.duration_ns),
        );
        try writePlotDistributionFields(object, row);
        try object.endLine();
    }
}

fn writePlotDefinitionFields(object: pretty_json.Object, row: PlotDelta) !void {
    const baseline = plotOrEmpty(row.baseline, row.name);
    const run = plotOrEmpty(row.run, row.name);
    try object.field("base_present", row.baseline != null);
    try object.field("run_present", row.run != null);
    try object.field("base_kind", baseline.kind);
    try object.field("run_kind", run.kind);
    try object.field("base_unit", baseline.unit);
    try object.field("run_unit", run.unit);
    try object.field("base_configured", baseline.configured);
    try object.field("run_configured", run.configured);
    try object.field("base_step", baseline.step);
    try object.field("run_step", run.step);
    try object.field("base_fill", baseline.fill);
    try object.field("run_fill", run.fill);
    try object.field("base_color", baseline.color);
    try object.field("run_color", run.color);
    try object.field("base_configurations", baseline.configurations);
    try object.field("run_configurations", run.configurations);
    try object.field("base_configuration_conflicts", baseline.configuration_conflicts);
    try object.field("run_configuration_conflicts", run.configuration_conflicts);
}

fn writePlotDistributionFields(object: pretty_json.Object, row: PlotDelta) !void {
    const baseline = plotOrEmpty(row.baseline, row.name);
    const run = plotOrEmpty(row.run, row.name);
    inline for (std.meta.tags(PlotMetric)) |metric| {
        try writePlotMetricFields(
            object,
            metric.tag(),
            metric.value(baseline),
            metric.value(run),
            row.delta(metric),
        );
    }
}

fn writePlotMetricFields(
    object: pretty_json.Object,
    label: []const u8,
    baseline: f64,
    run: f64,
    delta: ?f64,
) !void {
    try object.fieldParts(&.{ "base_", label }, baseline);
    try object.fieldParts(&.{ "run_", label }, run);
    try object.fieldParts(&.{ "delta_", label }, delta);
}

fn writeZoneJson(writer: *std.Io.Writer, rows: []const ZoneDelta, top: usize) !void {
    for (rows[0..@min(top, rows.len)]) |zone| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "zone");
        try object.field("status", zone.status.tag());
        try object.field("evidence", zone.evidence());
        try object.field("name", zone.name);
        try object.field("base_count", zone.baseline.count);
        try object.field("run_count", zone.run.count);
        try object.field("base_duration_samples", zone.baseline.duration_samples);
        try object.field("run_duration_samples", zone.run.duration_samples);
        inline for (std.meta.tags(ZoneMetric)) |metric| {
            try writeZoneMetricFields(object, metric, zone);
        }
        try object.endLine();
    }
}

fn writeZoneMetricFields(
    object: pretty_json.Object,
    metric: ZoneMetric,
    zone: ZoneDelta,
) !void {
    try object.fieldParts(
        &.{ "base_", metric.tag(), "_ns" },
        zone.baseline.value(metric),
    );
    try object.fieldParts(
        &.{ "run_", metric.tag(), "_ns" },
        zone.run.value(metric),
    );
    try object.fieldParts(&.{ "delta_", metric.tag(), "_ns" }, zone.delta(metric));
}

fn writeDeltaFields(
    object: pretty_json.Object,
    label: []const u8,
    baseline: anytype,
    run: anytype,
    delta: anytype,
) !void {
    try object.fieldParts(&.{ "base_", label }, baseline);
    try object.fieldParts(&.{ "run_", label }, run);
    try object.fieldParts(&.{ "delta_", label }, delta);
}

fn writeMemoryJson(writer: *std.Io.Writer, rows: []const MemoryDelta, top: usize) !void {
    for (rows[0..@min(top, rows.len)]) |item| try writeMemoryJsonRow(writer, item);
}

fn writeMemoryJsonRow(writer: *std.Io.Writer, item: MemoryDelta) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("schema", schema);
    try object.field("kind", "memory");
    try object.field("status", item.status.tag());
    try object.field("evidence", item.evidence());
    try object.field("name", item.name);
    try writeMemoryByteFields(object, item);
    try writeMemoryLifetimeFields(object, item);
    try writeMemoryIntegrityFields(object, item);
    try object.endLine();
}

fn writeMemoryByteFields(object: pretty_json.Object, item: MemoryDelta) !void {
    try writeDeltaFields(
        object,
        "high_water_live_bytes",
        item.baseline.high_water_live_bytes,
        item.run.high_water_live_bytes,
        signedDelta(item.baseline.high_water_live_bytes, item.run.high_water_live_bytes),
    );
    try writeDeltaFields(
        object,
        "live_bytes",
        item.baseline.live_bytes,
        item.run.live_bytes,
        signedDelta(item.baseline.live_bytes, item.run.live_bytes),
    );
    try writeDeltaFields(
        object,
        "allocated_bytes",
        item.baseline.allocated_bytes,
        item.run.allocated_bytes,
        signedDelta(item.baseline.allocated_bytes, item.run.allocated_bytes),
    );
    try writeDeltaFields(
        object,
        "freed_bytes",
        item.baseline.freed_bytes,
        item.run.freed_bytes,
        signedDelta(item.baseline.freed_bytes, item.run.freed_bytes),
    );
}

fn writeMemoryLifetimeFields(object: pretty_json.Object, item: MemoryDelta) !void {
    try object.field("base_completed_lifetimes", item.baseline.completed_lifetimes);
    try object.field("run_completed_lifetimes", item.run.completed_lifetimes);
    try object.field("base_lifetime_samples", item.baseline.lifetime_samples);
    try object.field("run_lifetime_samples", item.run.lifetime_samples);
    try writeDeltaFields(
        object,
        "lifetime_total_ns",
        item.baseline.total_lifetime_ns,
        item.run.total_lifetime_ns,
        signedDelta(item.baseline.total_lifetime_ns, item.run.total_lifetime_ns),
    );
    try writeDeltaFields(
        object,
        "lifetime_mean_ns",
        item.baseline.mean_lifetime_ns,
        item.run.mean_lifetime_ns,
        signedDelta(item.baseline.mean_lifetime_ns, item.run.mean_lifetime_ns),
    );
    try writeDeltaFields(
        object,
        "lifetime_min_ns",
        item.baseline.min_lifetime_ns,
        item.run.min_lifetime_ns,
        signedDelta(item.baseline.min_lifetime_ns, item.run.min_lifetime_ns),
    );
    try writeDeltaFields(
        object,
        "lifetime_p50_ns",
        item.baseline.p50_lifetime_ns,
        item.run.p50_lifetime_ns,
        signedDelta(item.baseline.p50_lifetime_ns, item.run.p50_lifetime_ns),
    );
    try writeDeltaFields(
        object,
        "lifetime_p90_ns",
        item.baseline.p90_lifetime_ns,
        item.run.p90_lifetime_ns,
        signedDelta(item.baseline.p90_lifetime_ns, item.run.p90_lifetime_ns),
    );
    try writeDeltaFields(
        object,
        "lifetime_p99_ns",
        item.baseline.p99_lifetime_ns,
        item.run.p99_lifetime_ns,
        signedDelta(item.baseline.p99_lifetime_ns, item.run.p99_lifetime_ns),
    );
    try writeDeltaFields(
        object,
        "lifetime_max_ns",
        item.baseline.max_lifetime_ns,
        item.run.max_lifetime_ns,
        signedDelta(item.baseline.max_lifetime_ns, item.run.max_lifetime_ns),
    );
}

fn writeMemoryIntegrityFields(object: pretty_json.Object, item: MemoryDelta) !void {
    try object.field("baseline_lifetime_evidence", item.baseline_lifetime_evidence);
    try object.field("run_lifetime_evidence", item.run_lifetime_evidence);
    try object.field("base_allocations", item.baseline.allocations);
    try object.field("run_allocations", item.run.allocations);
    try object.field("base_frees", item.baseline.frees);
    try object.field("run_frees", item.run.frees);
    try object.field(
        "base_right_censored_allocations",
        item.baseline.right_censored_allocations,
    );
    try object.field(
        "run_right_censored_allocations",
        item.run.right_censored_allocations,
    );
    try object.field("base_unmatched_frees", item.baseline.unmatched_frees);
    try object.field("run_unmatched_frees", item.run.unmatched_frees);
    try object.field("base_duplicate_allocations", item.baseline.duplicate_allocations);
    try object.field("run_duplicate_allocations", item.run.duplicate_allocations);
    try object.field("base_timestamp_regressions", item.baseline.timestamp_regressions);
    try object.field("run_timestamp_regressions", item.run.timestamp_regressions);
    try object.field("base_untracked_allocations", item.baseline.untracked_allocations);
    try object.field("run_untracked_allocations", item.run.untracked_allocations);
    try object.field("base_size_mismatches", item.baseline.size_mismatches);
    try object.field("run_size_mismatches", item.run.size_mismatches);
}

fn writeGpuJson(writer: *std.Io.Writer, rows: []const GpuDelta, top: usize) !void {
    for (rows[0..@min(top, rows.len)]) |row| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "gpu");
        try object.field("status", row.status.tag());
        try object.field("evidence", row.evidence());
        try object.field("name", row.name);
        try object.field("base_total_gpu_ns", row.base_total_gpu_ns);
        try object.field("run_total_gpu_ns", row.run_total_gpu_ns);
        try object.field("delta_total_gpu_ns", row.deltaTotalGpuNs());
        try object.field("base_mean_gpu_ns", row.base_mean_gpu_ns);
        try object.field("run_mean_gpu_ns", row.run_mean_gpu_ns);
        try object.field("delta_mean_gpu_ns", row.deltaMeanGpuNs());
        try object.field("base_count", row.base_count);
        try object.field("run_count", row.run_count);
        try object.field("base_completed_zones", row.base_completed_zones);
        try object.field("run_completed_zones", row.run_completed_zones);
        try object.endLine();
    }
}

fn collectFrameDeltas(
    allocator: std.mem.Allocator,
    baseline: []frame_mod.Summary,
    run: []frame_mod.Summary,
    partial: bool,
    options: Options,
) !std.ArrayListUnmanaged(FrameDelta) {
    var rows: std.ArrayListUnmanaged(FrameDelta) = .empty;
    errdefer rows.deinit(allocator);
    std.mem.sort(frame_mod.Summary, baseline, {}, frameSummaryNameLessThan);
    std.mem.sort(frame_mod.Summary, run, {}, frameSummaryNameLessThan);
    var base_index: usize = 0;
    var run_index: usize = 0;
    try mergeFrameDeltas(
        allocator,
        &rows,
        baseline,
        run,
        &base_index,
        &run_index,
        partial,
        options,
    );
    try appendFrameTails(
        allocator,
        &rows,
        baseline[base_index..],
        run[run_index..],
        partial,
        options,
    );
    std.mem.sort(FrameDelta, rows.items, {}, frameDeltaGreaterThan);
    return rows;
}

fn mergeFrameDeltas(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(FrameDelta),
    baseline: []const frame_mod.Summary,
    run: []const frame_mod.Summary,
    base_index: *usize,
    run_index: *usize,
    partial: bool,
    options: Options,
) !void {
    while (base_index.* < baseline.len and run_index.* < run.len) {
        const base_row = baseline[base_index.*];
        const run_row = run[run_index.*];
        if (std.mem.eql(u8, base_row.name, run_row.name)) {
            try appendFrameDelta(
                allocator,
                rows,
                base_row.name,
                base_row,
                run_row,
                partial,
                options,
            );
            base_index.* += 1;
            run_index.* += 1;
        } else if (std.mem.lessThan(u8, base_row.name, run_row.name)) {
            try appendFrameDelta(
                allocator,
                rows,
                base_row.name,
                base_row,
                null,
                partial,
                options,
            );
            base_index.* += 1;
        } else {
            try appendFrameDelta(
                allocator,
                rows,
                run_row.name,
                null,
                run_row,
                partial,
                options,
            );
            run_index.* += 1;
        }
    }
}

fn appendFrameTails(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(FrameDelta),
    baseline: []const frame_mod.Summary,
    run: []const frame_mod.Summary,
    partial: bool,
    options: Options,
) !void {
    for (baseline) |row| {
        try appendFrameDelta(
            allocator,
            rows,
            row.name,
            row,
            null,
            partial,
            options,
        );
    }
    for (run) |row| {
        try appendFrameDelta(
            allocator,
            rows,
            row.name,
            null,
            row,
            partial,
            options,
        );
    }
}

fn appendFrameDelta(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(FrameDelta),
    name: []const u8,
    baseline: ?frame_mod.Summary,
    run: ?frame_mod.Summary,
    partial: bool,
    options: Options,
) !void {
    const row = frameDelta(name, baseline, run, partial, options.frame_budget_ns);
    if (includeFrame(row, options)) try rows.append(allocator, row);
}

fn frameSummaryNameLessThan(_: void, left: frame_mod.Summary, right: frame_mod.Summary) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn collectPlotDeltas(
    allocator: std.mem.Allocator,
    baseline: []plot_mod.Summary,
    run: []plot_mod.Summary,
    partial: bool,
    options: Options,
) !std.ArrayListUnmanaged(PlotDelta) {
    var rows: std.ArrayListUnmanaged(PlotDelta) = .empty;
    errdefer rows.deinit(allocator);
    std.mem.sort(plot_mod.Summary, baseline, {}, plotSummaryNameLessThan);
    std.mem.sort(plot_mod.Summary, run, {}, plotSummaryNameLessThan);
    var base_index: usize = 0;
    var run_index: usize = 0;
    while (base_index < baseline.len and run_index < run.len) {
        const base_row = baseline[base_index];
        const run_row = run[run_index];
        if (std.mem.eql(u8, base_row.name, run_row.name)) {
            try appendPlotDelta(
                allocator,
                &rows,
                base_row.name,
                base_row,
                run_row,
                partial,
                options,
            );
            base_index += 1;
            run_index += 1;
        } else if (std.mem.lessThan(u8, base_row.name, run_row.name)) {
            try appendPlotDelta(allocator, &rows, base_row.name, base_row, null, partial, options);
            base_index += 1;
        } else {
            try appendPlotDelta(allocator, &rows, run_row.name, null, run_row, partial, options);
            run_index += 1;
        }
    }
    for (baseline[base_index..]) |row| {
        try appendPlotDelta(allocator, &rows, row.name, row, null, partial, options);
    }
    for (run[run_index..]) |row| {
        try appendPlotDelta(allocator, &rows, row.name, null, row, partial, options);
    }
    std.mem.sort(PlotDelta, rows.items, {}, plotDeltaGreaterThan);
    return rows;
}

fn appendPlotDelta(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(PlotDelta),
    name: []const u8,
    baseline: ?plot_mod.Summary,
    run: ?plot_mod.Summary,
    partial: bool,
    options: Options,
) !void {
    const row = plotDelta(name, baseline, run, partial);
    if (includePlot(row, options)) try rows.append(allocator, row);
}

fn plotSummaryNameLessThan(_: void, left: plot_mod.Summary, right: plot_mod.Summary) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn collectZoneDeltas(
    allocator: std.mem.Allocator,
    baseline: *summary.Analyzer,
    run: *summary.Analyzer,
    options: Options,
) !std.ArrayListUnmanaged(ZoneDelta) {
    var baseline_rows = try baseline.collectZones();
    defer baseline_rows.deinit(baseline.allocator);
    var run_rows = try run.collectZones();
    defer run_rows.deinit(run.allocator);
    std.mem.sort(summary.ZoneSummary, baseline_rows.items, {}, zoneSummaryNameLessThan);
    std.mem.sort(summary.ZoneSummary, run_rows.items, {}, zoneSummaryNameLessThan);
    return try correlateZoneDeltas(
        allocator,
        baseline_rows.items,
        run_rows.items,
        baseline.zoneDurationEvidence(),
        run.zoneDurationEvidence(),
        options,
    );
}

fn correlateZoneDeltas(
    allocator: std.mem.Allocator,
    baseline: []const summary.ZoneSummary,
    run: []const summary.ZoneSummary,
    baseline_evidence: []const u8,
    run_evidence: []const u8,
    options: Options,
) !std.ArrayListUnmanaged(ZoneDelta) {
    var rows: std.ArrayListUnmanaged(ZoneDelta) = .empty;
    errdefer rows.deinit(allocator);
    const indices = try appendOverlappingZoneDeltas(
        allocator,
        &rows,
        baseline,
        run,
        baseline_evidence,
        run_evidence,
        options,
    );
    for (baseline[indices.baseline..]) |row| try appendZoneDelta(
        allocator,
        &rows,
        row.name,
        row,
        null,
        baseline_evidence,
        run_evidence,
        options,
    );
    for (run[indices.run..]) |row| try appendZoneDelta(
        allocator,
        &rows,
        row.name,
        null,
        row,
        baseline_evidence,
        run_evidence,
        options,
    );
    std.mem.sort(ZoneDelta, rows.items, {}, zoneDeltaGreaterThan);
    return rows;
}

const ZoneIndices = struct {
    baseline: usize,
    run: usize,
};

fn appendOverlappingZoneDeltas(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(ZoneDelta),
    baseline: []const summary.ZoneSummary,
    run: []const summary.ZoneSummary,
    baseline_evidence: []const u8,
    run_evidence: []const u8,
    options: Options,
) !ZoneIndices {
    var baseline_index: usize = 0;
    var run_index: usize = 0;
    while (baseline_index < baseline.len and run_index < run.len) {
        const base_row = baseline[baseline_index];
        const run_row = run[run_index];
        if (std.mem.eql(u8, base_row.name, run_row.name)) {
            try appendZoneDelta(
                allocator,
                rows,
                base_row.name,
                base_row,
                run_row,
                baseline_evidence,
                run_evidence,
                options,
            );
            baseline_index += 1;
            run_index += 1;
        } else if (std.mem.lessThan(u8, base_row.name, run_row.name)) {
            try appendZoneDelta(
                allocator,
                rows,
                base_row.name,
                base_row,
                null,
                baseline_evidence,
                run_evidence,
                options,
            );
            baseline_index += 1;
        } else {
            try appendZoneDelta(
                allocator,
                rows,
                run_row.name,
                null,
                run_row,
                baseline_evidence,
                run_evidence,
                options,
            );
            run_index += 1;
        }
    }
    return .{ .baseline = baseline_index, .run = run_index };
}

fn appendZoneDelta(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(ZoneDelta),
    name: []const u8,
    baseline: ?summary.ZoneSummary,
    run: ?summary.ZoneSummary,
    baseline_evidence: []const u8,
    run_evidence: []const u8,
    options: Options,
) !void {
    const row = zoneDelta(name, baseline, run, baseline_evidence, run_evidence);
    if (includeZone(row, options)) try rows.append(allocator, row);
}

fn zoneSummaryNameLessThan(
    _: void,
    left: summary.ZoneSummary,
    right: summary.ZoneSummary,
) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn collectMemoryDeltas(
    allocator: std.mem.Allocator,
    baseline: []memory_mod.Summary,
    run: []memory_mod.Summary,
    baseline_evidence: []const u8,
    run_evidence: []const u8,
    options: Options,
) !std.ArrayListUnmanaged(MemoryDelta) {
    var rows: std.ArrayListUnmanaged(MemoryDelta) = .empty;
    errdefer rows.deinit(allocator);
    std.mem.sort(memory_mod.Summary, baseline, {}, memorySummaryNameLessThan);
    std.mem.sort(memory_mod.Summary, run, {}, memorySummaryNameLessThan);
    var base_index: usize = 0;
    var run_index: usize = 0;
    while (base_index < baseline.len and run_index < run.len) {
        const base_row = baseline[base_index];
        const run_row = run[run_index];
        if (std.mem.eql(u8, base_row.name, run_row.name)) {
            try appendMemoryDelta(
                allocator,
                &rows,
                base_row.name,
                base_row,
                run_row,
                baseline_evidence,
                run_evidence,
                options,
            );
            base_index += 1;
            run_index += 1;
        } else if (std.mem.lessThan(u8, base_row.name, run_row.name)) {
            try appendMemoryDelta(
                allocator,
                &rows,
                base_row.name,
                base_row,
                null,
                baseline_evidence,
                run_evidence,
                options,
            );
            base_index += 1;
        } else {
            try appendMemoryDelta(
                allocator,
                &rows,
                run_row.name,
                null,
                run_row,
                baseline_evidence,
                run_evidence,
                options,
            );
            run_index += 1;
        }
    }
    try appendMemoryTails(
        allocator,
        &rows,
        baseline[base_index..],
        run[run_index..],
        baseline_evidence,
        run_evidence,
        options,
    );
    std.mem.sort(MemoryDelta, rows.items, {}, memoryDeltaGreaterThan);
    return rows;
}

fn appendMemoryTails(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(MemoryDelta),
    baseline: []const memory_mod.Summary,
    run: []const memory_mod.Summary,
    baseline_evidence: []const u8,
    run_evidence: []const u8,
    options: Options,
) !void {
    for (baseline) |row| {
        try appendMemoryDelta(
            allocator,
            rows,
            row.name,
            row,
            null,
            baseline_evidence,
            run_evidence,
            options,
        );
    }
    for (run) |row| {
        try appendMemoryDelta(
            allocator,
            rows,
            row.name,
            null,
            row,
            baseline_evidence,
            run_evidence,
            options,
        );
    }
}

fn appendMemoryDelta(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(MemoryDelta),
    name: []const u8,
    baseline: ?memory_mod.Summary,
    run: ?memory_mod.Summary,
    baseline_evidence: []const u8,
    run_evidence: []const u8,
    options: Options,
) !void {
    const row = memoryDelta(name, baseline, run, baseline_evidence, run_evidence);
    if (includeMemory(row, options)) try rows.append(allocator, row);
}

fn memorySummaryNameLessThan(
    _: void,
    left: memory_mod.Summary,
    right: memory_mod.Summary,
) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn collectGpuDeltas(
    allocator: std.mem.Allocator,
    baseline: []gpu_mod.Summary,
    run: []gpu_mod.Summary,
    options: Options,
) !std.ArrayListUnmanaged(GpuDelta) {
    var rows: std.ArrayListUnmanaged(GpuDelta) = .empty;
    errdefer rows.deinit(allocator);
    std.mem.sort(gpu_mod.Summary, baseline, {}, gpuSummaryNameLessThan);
    std.mem.sort(gpu_mod.Summary, run, {}, gpuSummaryNameLessThan);
    var base_index: usize = 0;
    var run_index: usize = 0;
    while (base_index < baseline.len and run_index < run.len) {
        const base_row = baseline[base_index];
        const run_row = run[run_index];
        if (std.mem.eql(u8, base_row.label, run_row.label)) {
            try appendGpuDelta(allocator, &rows, base_row.label, base_row, run_row, options);
            base_index += 1;
            run_index += 1;
        } else if (std.mem.lessThan(u8, base_row.label, run_row.label)) {
            try appendGpuDelta(allocator, &rows, base_row.label, base_row, null, options);
            base_index += 1;
        } else {
            try appendGpuDelta(allocator, &rows, run_row.label, null, run_row, options);
            run_index += 1;
        }
    }
    while (base_index < baseline.len) : (base_index += 1) {
        const row = baseline[base_index];
        try appendGpuDelta(allocator, &rows, row.label, row, null, options);
    }
    while (run_index < run.len) : (run_index += 1) {
        const row = run[run_index];
        try appendGpuDelta(allocator, &rows, row.label, null, row, options);
    }
    std.mem.sort(GpuDelta, rows.items, {}, gpuDeltaGreaterThan);
    return rows;
}

fn appendGpuDelta(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(GpuDelta),
    name: []const u8,
    baseline: ?gpu_mod.Summary,
    run: ?gpu_mod.Summary,
    options: Options,
) !void {
    const row = gpuDelta(name, baseline, run);
    if (includeGpu(row, options)) try rows.append(allocator, row);
}

fn gpuSummaryNameLessThan(_: void, left: gpu_mod.Summary, right: gpu_mod.Summary) bool {
    return std.mem.lessThan(u8, left.label, right.label);
}

fn plotDelta(
    name: []const u8,
    baseline: ?plot_mod.Summary,
    run: ?plot_mod.Summary,
    capture_partial: bool,
) PlotDelta {
    var result = PlotDelta{
        .name = name,
        .status = .stable,
        .partial = capture_partial or plotConfigCaveat(baseline) or plotConfigCaveat(run),
        .compatibility = plotCompatibility(baseline, run),
        .baseline = baseline,
        .run = run,
    };
    result.status = plotStatusFor(result);
    return result;
}

fn plotCompatibility(
    baseline: ?plot_mod.Summary,
    run: ?plot_mod.Summary,
) PlotCompatibility {
    const base_row = baseline orelse return .not_applicable;
    const run_row = run orelse return .not_applicable;
    if (!base_row.configured or !run_row.configured) return .unknown;
    const base_unit = base_row.unit orelse return .unknown;
    const run_unit = run_row.unit orelse return .unknown;
    return if (std.mem.eql(u8, base_unit, run_unit)) .matching else .mismatch;
}

fn plotConfigCaveat(value: ?plot_mod.Summary) bool {
    const row = value orelse return false;
    if (!row.configured) return true;
    return row.configuration_conflicts != 0;
}

fn plotStatusFor(row: PlotDelta) Status {
    const baseline = row.baseline orelse return .new;
    const run = row.run orelse return .removed;
    if (!plotDefinitionEqual(baseline, run)) return .changed;
    if (!plotValuesEqual(baseline, run)) return .changed;
    return .stable;
}

fn plotDefinitionEqual(baseline: plot_mod.Summary, run: plot_mod.Summary) bool {
    if (!optionalStringEqual(baseline.kind, run.kind)) return false;
    if (!optionalStringEqual(baseline.unit, run.unit)) return false;
    if (baseline.configured != run.configured) return false;
    if (baseline.step != run.step) return false;
    if (baseline.fill != run.fill) return false;
    return baseline.color == run.color;
}

fn plotValuesEqual(baseline: plot_mod.Summary, run: plot_mod.Summary) bool {
    if (baseline.count != run.count) return false;
    if (baseline.threads != run.threads) return false;
    if (baseline.duration_ns != run.duration_ns) return false;
    inline for (std.meta.tags(PlotMetric)) |metric| {
        if (metric.value(baseline) != metric.value(run)) return false;
    }
    return true;
}

fn zoneDelta(
    name: []const u8,
    baseline: ?summary.ZoneSummary,
    run: ?summary.ZoneSummary,
    baseline_evidence: []const u8,
    run_evidence: []const u8,
) ZoneDelta {
    const baseline_values = ZoneValues.from(baseline);
    const run_values = ZoneValues.from(run);
    return .{
        .name = name,
        .status = zoneStatusFor(
            baseline_values,
            run_values,
            baseline != null,
            run != null,
        ),
        .baseline = baseline_values,
        .run = run_values,
        .baseline_evidence = baseline_evidence,
        .run_evidence = run_evidence,
    };
}

fn zoneStatusFor(
    baseline: ZoneValues,
    run: ZoneValues,
    has_baseline: bool,
    has_run: bool,
) Status {
    if (!has_baseline and has_run) return .new;
    if (has_baseline and !has_run) return .removed;
    if (std.meta.eql(baseline, run)) return .stable;
    return .changed;
}

fn memoryDelta(
    name: []const u8,
    baseline: ?memory_mod.Summary,
    run: ?memory_mod.Summary,
    baseline_evidence: []const u8,
    run_evidence: []const u8,
) MemoryDelta {
    const baseline_values = MemoryValues.from(baseline);
    const run_values = MemoryValues.from(run);
    return .{
        .name = name,
        .status = memoryStatusFor(
            baseline_values,
            run_values,
            baseline != null,
            run != null,
        ),
        .baseline = baseline_values,
        .run = run_values,
        .baseline_lifetime_evidence = baseline_evidence,
        .run_lifetime_evidence = run_evidence,
    };
}

fn memoryStatusFor(
    baseline: MemoryValues,
    run: MemoryValues,
    has_baseline: bool,
    has_run: bool,
) Status {
    if (!has_baseline and has_run) return .new;
    if (has_baseline and !has_run) return .removed;
    if (std.meta.eql(baseline, run)) return .stable;
    return .changed;
}

const FrameSide = enum {
    baseline,
    run,
};

fn frameDelta(
    name: []const u8,
    baseline: ?frame_mod.Summary,
    run: ?frame_mod.Summary,
    partial: bool,
    budget_ns: ?u64,
) FrameDelta {
    var result = FrameDelta{
        .name = name,
        .status = .stable,
        .partial = partial,
        .budget_ns = budget_ns,
    };
    if (baseline) |row| applyFrameSummary(&result, row, .baseline);
    if (run) |row| applyFrameSummary(&result, row, .run);
    result.status = frameStatusFor(baseline != null, run != null, result);
    return result;
}

fn applyFrameSummary(result: *FrameDelta, row: frame_mod.Summary, side: FrameSide) void {
    const budget = row.budget orelse frame_mod.BudgetSummary{
        .budget_ns = result.budget_ns orelse 1,
    };
    const over_budget_per_mille = perThousand(budget.over_budget_frames, row.frames);
    const missed_per_1000 = perThousand(budget.estimated_missed_intervals, row.frames);
    switch (side) {
        .baseline => {
            result.base_marks = row.marks;
            result.base_frames = row.frames;
            result.base_mean_ns = row.mean_ns;
            result.base_p50_ns = row.p50_ns;
            result.base_p90_ns = row.p90_ns;
            result.base_p99_ns = row.p99_ns;
            result.base_max_ns = row.max_ns;
            result.base_discrepancy_ns = row.frame_time_discrepancy_ns;
            result.base_over_budget_frames = budget.over_budget_frames;
            result.base_over_budget_per_mille = over_budget_per_mille;
            result.base_missed_intervals = budget.estimated_missed_intervals;
            result.base_missed_per_1000_frames = missed_per_1000;
            result.base_total_overrun_ns = budget.total_overrun_ns;
            result.base_max_overrun_ns = budget.max_overrun_ns;
            result.base_longest_overrun_streak = budget.longest_overrun_streak;
        },
        .run => {
            result.run_marks = row.marks;
            result.run_frames = row.frames;
            result.run_mean_ns = row.mean_ns;
            result.run_p50_ns = row.p50_ns;
            result.run_p90_ns = row.p90_ns;
            result.run_p99_ns = row.p99_ns;
            result.run_max_ns = row.max_ns;
            result.run_discrepancy_ns = row.frame_time_discrepancy_ns;
            result.run_over_budget_frames = budget.over_budget_frames;
            result.run_over_budget_per_mille = over_budget_per_mille;
            result.run_missed_intervals = budget.estimated_missed_intervals;
            result.run_missed_per_1000_frames = missed_per_1000;
            result.run_total_overrun_ns = budget.total_overrun_ns;
            result.run_max_overrun_ns = budget.max_overrun_ns;
            result.run_longest_overrun_streak = budget.longest_overrun_streak;
        },
    }
}

fn frameStatusFor(has_baseline: bool, has_run: bool, row: FrameDelta) Status {
    if (!has_baseline and has_run) return .new;
    if (has_baseline and !has_run) return .removed;
    if (row.populationChanged()) return .changed;
    if (row.magnitude() != 0) return .changed;
    if (row.budgetChanged()) return .changed;
    return .stable;
}

fn perThousand(numerator: u64, denominator: u64) u64 {
    if (denominator == 0) return 0;
    const value = (@as(u128, numerator) * 1_000) / denominator;
    return @intCast(@min(value, std.math.maxInt(u64)));
}

fn gpuDelta(
    name: []const u8,
    baseline: ?gpu_mod.Summary,
    run: ?gpu_mod.Summary,
) GpuDelta {
    const base_total = if (baseline) |row| row.gpu_ns else 0;
    const run_total = if (run) |row| row.gpu_ns else 0;
    const base_completed = if (baseline) |row| row.completed_zones else 0;
    const run_completed = if (run) |row| row.completed_zones else 0;
    const base_mean = meanCompleted(base_total, base_completed);
    const run_mean = meanCompleted(run_total, run_completed);
    return .{
        .name = name,
        .status = gpuStatusFor(baseline, run),
        .base_count = if (baseline) |row| row.count else 0,
        .run_count = if (run) |row| row.count else 0,
        .base_completed_zones = base_completed,
        .run_completed_zones = run_completed,
        .base_total_gpu_ns = base_total,
        .run_total_gpu_ns = run_total,
        .base_mean_gpu_ns = base_mean,
        .run_mean_gpu_ns = run_mean,
    };
}

fn gpuStatusFor(baseline: ?gpu_mod.Summary, run: ?gpu_mod.Summary) Status {
    const base_row = baseline orelse return .new;
    const run_row = run orelse return .removed;
    if (base_row.gpu_ns != run_row.gpu_ns) return .changed;
    if (base_row.count != run_row.count) return .changed;
    if (base_row.completed_zones != run_row.completed_zones) return .changed;
    if (meanCompleted(base_row.gpu_ns, base_row.completed_zones) !=
        meanCompleted(run_row.gpu_ns, run_row.completed_zones)) return .changed;
    return .stable;
}

fn meanCompleted(total: u64, completed: u64) u64 {
    if (completed == 0) return 0;
    return total / completed;
}

fn includeZone(row: ZoneDelta, options: Options) bool {
    if (!std.mem.eql(u8, row.evidence(), "complete")) return true;
    if (row.populationChanged()) return true;
    if (row.status == .stable) return options.include_stable;
    return row.magnitude() >= options.min_zone_delta_ns;
}

fn includeMemory(row: MemoryDelta, options: Options) bool {
    if (!std.mem.eql(u8, row.evidence(), "complete")) return true;
    if (row.populationChanged() or row.anomaliesChanged()) return true;
    if (row.status == .stable) return options.include_stable;
    const byte_changed = row.byteMagnitude() != 0 and
        row.byteMagnitude() >= options.min_memory_delta_bytes;
    const lifetime_changed = row.lifetimeMagnitude() != 0 and
        row.lifetimeMagnitude() >= options.min_memory_lifetime_delta_ns;
    return byte_changed or lifetime_changed;
}

fn includePlot(row: PlotDelta, options: Options) bool {
    if (row.partial) return true;
    if (row.compatibility == .mismatch or row.compatibility == .unknown) return true;
    return row.status != .stable or options.include_stable;
}

fn includeFrame(row: FrameDelta, options: Options) bool {
    if (row.partial) return true;
    if (row.status == .stable and !options.include_stable) return false;
    if (row.populationChanged()) return true;
    if (row.budgetChanged()) return true;
    return row.magnitude() >= options.min_frame_delta_ns;
}

fn includeGpu(row: GpuDelta, options: Options) bool {
    if (!std.mem.eql(u8, row.evidence(), "complete")) return true;
    if (row.status == .stable and !options.include_stable) return false;
    return row.magnitude() >= options.min_gpu_delta_ns;
}

fn countStatuses(rows: anytype) Counts {
    var counts: Counts = .{};
    for (rows) |row| counts.observe(row.status);
    return counts;
}

fn gpuPartialCount(rows: []const GpuDelta) u64 {
    var count: u64 = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.evidence(), "complete")) count += 1;
    }
    return count;
}

fn zonePartialCount(rows: []const ZoneDelta) u64 {
    var count: u64 = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.evidence(), "complete")) count += 1;
    }
    return count;
}

fn memoryPartialCount(rows: []const MemoryDelta) u64 {
    var count: u64 = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.evidence(), "complete")) count += 1;
    }
    return count;
}

fn plotPartialCount(rows: []const PlotDelta) u64 {
    var count: u64 = 0;
    for (rows) |row| count += @intFromBool(row.partial);
    return count;
}

fn plotCompatibilityCount(
    rows: []const PlotDelta,
    compatibility: PlotCompatibility,
) u64 {
    var count: u64 = 0;
    for (rows) |row| count += @intFromBool(row.compatibility == compatibility);
    return count;
}

fn framePartialCount(rows: []const FrameDelta) u64 {
    var count: u64 = 0;
    for (rows) |row| count += @intFromBool(row.partial);
    return count;
}

fn frameCapturePartial(analyzer: *frame_mod.Analyzer) bool {
    if (!std.mem.eql(u8, analyzer.captureIntegrity().status, "complete")) return true;
    return analyzer.counters.out_of_order_marks != 0;
}

fn plotCapturePartial(analyzer: *summary.Analyzer) bool {
    if (!std.mem.eql(u8, analyzer.plots.captureIntegrity().status, "complete")) return true;
    if (analyzer.plots.counters.ignored_missing_values != 0) return true;
    return analyzer.plots.counters.ignored_nonfinite != 0;
}

fn zoneDeltaGreaterThan(_: void, left: ZoneDelta, right: ZoneDelta) bool {
    const left_partial = !std.mem.eql(u8, left.evidence(), "complete");
    const right_partial = !std.mem.eql(u8, right.evidence(), "complete");
    if (left_partial != right_partial) return left_partial;
    if (left.magnitude() != right.magnitude()) return left.magnitude() > right.magnitude();
    if (left.run.p99_ns != right.run.p99_ns) return left.run.p99_ns > right.run.p99_ns;
    if (left.run.total_ns != right.run.total_ns) return left.run.total_ns > right.run.total_ns;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn memoryDeltaGreaterThan(_: void, left: MemoryDelta, right: MemoryDelta) bool {
    const left_partial = !std.mem.eql(u8, left.evidence(), "complete");
    const right_partial = !std.mem.eql(u8, right.evidence(), "complete");
    if (left_partial != right_partial) return left_partial;
    if (left.byteMagnitude() != right.byteMagnitude()) {
        return left.byteMagnitude() > right.byteMagnitude();
    }
    if (left.lifetimeMagnitude() != right.lifetimeMagnitude()) {
        return left.lifetimeMagnitude() > right.lifetimeMagnitude();
    }
    if (left.run.high_water_live_bytes != right.run.high_water_live_bytes) {
        return left.run.high_water_live_bytes > right.run.high_water_live_bytes;
    }
    if (left.run.p99_lifetime_ns != right.run.p99_lifetime_ns) {
        return left.run.p99_lifetime_ns > right.run.p99_lifetime_ns;
    }
    return std.mem.lessThan(u8, left.name, right.name);
}

fn plotDeltaGreaterThan(_: void, left: PlotDelta, right: PlotDelta) bool {
    const left_priority = plotPriority(left);
    const right_priority = plotPriority(right);
    if (left_priority != right_priority) return left_priority > right_priority;
    if (left.magnitude() != right.magnitude()) return left.magnitude() > right.magnitude();
    const left_samples = if (left.run) |plot| plot.count else 0;
    const right_samples = if (right.run) |plot| plot.count else 0;
    if (left_samples != right_samples) return left_samples > right_samples;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn plotPriority(row: PlotDelta) u8 {
    if (row.compatibility == .mismatch) return 3;
    if (row.partial) return 2;
    if (row.compatibility == .unknown) return 1;
    return 0;
}

fn frameDeltaGreaterThan(_: void, left: FrameDelta, right: FrameDelta) bool {
    if (left.magnitude() != right.magnitude()) return left.magnitude() > right.magnitude();
    if (left.run_p99_ns != right.run_p99_ns) return left.run_p99_ns > right.run_p99_ns;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn gpuDeltaGreaterThan(_: void, left: GpuDelta, right: GpuDelta) bool {
    if (left.magnitude() != right.magnitude()) return left.magnitude() > right.magnitude();
    if (left.run_total_gpu_ns != right.run_total_gpu_ns) {
        return left.run_total_gpu_ns > right.run_total_gpu_ns;
    }
    return std.mem.lessThan(u8, left.name, right.name);
}

fn signedDelta(base: u64, run: u64) i128 {
    return @as(i128, @intCast(run)) - @as(i128, @intCast(base));
}

fn absI128(value: i128) u128 {
    if (value < 0) return @intCast(-value);
    return @intCast(value);
}

fn absF64(value: f64) f64 {
    return if (value < 0) -value else value;
}

fn plotOrEmpty(value: ?plot_mod.Summary, name: []const u8) plot_mod.Summary {
    return value orelse .{ .name = name };
}

fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_text| {
        const right_text = right orelse return false;
        return std.mem.eql(u8, left_text, right_text);
    }
    return right == null;
}

fn writeOptionalStringText(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |actual| {
        try pretty_json.writeString(writer, actual);
    } else {
        try writer.writeAll("none");
    }
}

fn writeOptionalU32Text(writer: *std.Io.Writer, value: ?u32) !void {
    if (value) |actual| {
        try writer.print("{d}", .{actual});
    } else {
        try writer.writeAll("none");
    }
}

fn writeOptionalF64Text(writer: *std.Io.Writer, value: ?f64) !void {
    if (value) |actual| {
        try writer.print("{d}", .{actual});
    } else {
        try writer.writeAll("none");
    }
}

fn writeOptionalU64Text(writer: *std.Io.Writer, value: ?u64) !void {
    if (value) |actual| {
        try writer.print("{d}", .{actual});
    } else {
        try writer.writeAll("none");
    }
}

test "compare reports zone and memory deltas" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addZone(&baseline, "phase", 100);
    try addMemory(&baseline, "arena", 64);

    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addZoneTrace(&run, &.{
        .{ .name = "phase", .durations_ns = &.{150} },
        .{ .name = "new-phase", .durations_ns = &.{40} },
    }, false);
    try addMemory(&run, "arena", 128);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{ .top = 8 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "tracy compare zones") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "zone status=changed evidence=partial name=\"phase\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "delta_total_ns=50") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "zone status=new evidence=partial name=\"new-phase\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "memory status=changed name=\"arena\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "delta_high_water_live_bytes=64") != null);
}

test "compare preserves equal-total zone tails and population changes" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addZoneTrace(&baseline, &.{
        .{ .name = "tail", .durations_ns = &.{ 10, 10, 10, 10, 60 } },
        .{ .name = "population", .durations_ns = &.{50} },
    }, false);
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addZoneTrace(&run, &.{
        .{ .name = "tail", .durations_ns = &.{ 1, 1, 1, 47, 50 } },
        .{ .name = "population", .durations_ns = &.{ 25, 25 } },
    }, false);

    var text = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &text.writer, .{
        .min_zone_delta_ns = 20,
    });
    try expectContains(text.written(), "zones shared=2 changed=2 stable=0");
    try expectContains(text.written(), "partial=0 baseline_duration_evidence=complete");
    try expectContains(text.written(), "name=\"tail\" base_count=5 run_count=5");
    try expectContains(text.written(), "base_total_ns=100 run_total_ns=100 delta_total_ns=0");
    try expectContains(text.written(), "base_p99_ns=10 run_p99_ns=47 delta_p99_ns=37");
    try expectContains(text.written(), "name=\"population\" base_count=1 run_count=2");

    var json = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json.deinit();
    try writeJsonl(std.testing.allocator, &baseline, &run, &json.writer, .{});
    try std.testing.expectEqual(@as(usize, 3), try validJsonLineCount(json.written()));
    try expectContains(json.written(), "\"zone_partial\":0");
    try expectContains(json.written(), "\"base_p99_ns\":10,\"run_p99_ns\":47");
}

test "compare always surfaces partial zone duration evidence" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addZoneTrace(&baseline, &.{
        .{ .name = "invalid", .durations_ns = &.{ 10, 10 } },
        .{ .name = "stable", .durations_ns = &.{20} },
    }, false);
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addZoneTrace(&run, &.{
        .{ .name = "invalid", .durations_ns = &.{ 10, 10 }, .invalid_last = true },
        .{ .name = "stable", .durations_ns = &.{20} },
    }, true);

    var text = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &text.writer, .{
        .min_zone_delta_ns = std.math.maxInt(u64),
    });
    try expectContains(text.written(), "partial=2 baseline_duration_evidence=complete");
    try expectContains(text.written(), "run_duration_evidence=partial");
    try expectContains(text.written(), "run_timestamp_regressions=1");
    try expectContains(text.written(), "status=stable evidence=partial name=\"stable\"");
    try expectContains(text.written(), "name=\"invalid\" base_count=2 run_count=2");
    try expectContains(text.written(), "base_duration_samples=2 run_duration_samples=1");
}

test "compare preserves lifetime tails with equal high water" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addMemoryLifetimes(&baseline, "arena", 64, &.{ 10, 20, 30, 40, 50 }, .{});
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addMemoryLifetimes(&run, "arena", 64, &.{ 10, 20, 30, 40, 200 }, .{});

    var text = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &text.writer, .{
        .min_memory_delta_bytes = 1000,
    });
    try expectContains(text.written(), "memory status=changed name=\"arena\" evidence=complete");
    try expectContains(text.written(), "delta_high_water_live_bytes=0");
    try expectContains(text.written(), "base_p99_ns=50 run_p99_ns=200 delta_p99_ns=150");
    try expectContains(text.written(), "partial=0 baseline_lifetime_evidence=complete");

    var json = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json.deinit();
    try writeJsonl(std.testing.allocator, &baseline, &run, &json.writer, .{});
    try std.testing.expectEqual(@as(usize, 2), try validJsonLineCount(json.written()));
    try expectContains(json.written(), "\"memory_partial\":0");
    try expectContains(json.written(), "\"base_lifetime_p50_ns\":30");
    try expectContains(json.written(), "\"delta_lifetime_p99_ns\":150");

    var filtered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer filtered.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &filtered.writer, .{
        .min_memory_delta_bytes = 1000,
        .min_memory_lifetime_delta_ns = 151,
    });
    try std.testing.expect(std.mem.indexOf(u8, filtered.written(), "memory status=") == null);
}

test "compare retains right censored memory evidence through thresholds" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addMemoryLifetimes(&baseline, "arena", 64, &.{10}, .{});
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addMemoryLifetimes(&run, "arena", 64, &.{10}, .{ .right_censored = true });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{
        .min_memory_delta_bytes = std.math.maxInt(u64),
        .min_memory_lifetime_delta_ns = std.math.maxInt(u64),
    });
    try expectContains(out.written(), "memory status=changed name=\"arena\" evidence=partial");
    try expectContains(out.written(), "partial=1 baseline_lifetime_evidence=complete");
    try expectContains(out.written(), "run_lifetime_evidence=partial");
    try expectContains(out.written(), "base_right_censored=0 run_right_censored=1");
}

test "compare retains memory anomalies through thresholds" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addMemoryLifetimes(&baseline, "arena", 64, &.{10}, .{});
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addMemoryLifetimes(&run, "arena", 64, &.{10}, .{ .size_mismatch = true });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{
        .min_memory_delta_bytes = std.math.maxInt(u64),
        .min_memory_lifetime_delta_ns = std.math.maxInt(u64),
    });
    try expectContains(out.written(), "memory status=changed name=\"arena\" evidence=partial");
    try expectContains(out.written(), "delta_high_water_live_bytes=0");
    try expectContains(out.written(), "delta_p99_ns=0");
    try expectContains(out.written(), "base_size_mismatches=0 run_size_mismatches=1");
}

test "memory correlation preserves new removed and stable pools" {
    var baseline = [_]memory_mod.Summary{
        .{ .name = "removed", .allocations = 1 },
        .{ .name = "stable", .allocated_bytes = 64 },
    };
    var run = [_]memory_mod.Summary{
        .{ .name = "new", .allocations = 1 },
        .{ .name = "stable", .allocated_bytes = 64 },
    };
    var rows = try collectMemoryDeltas(
        std.testing.allocator,
        &baseline,
        &run,
        "complete",
        "complete",
        .{ .include_stable = true },
    );
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), rows.items.len);
    try expectMemoryStatus(rows.items, "new", .new);
    try expectMemoryStatus(rows.items, "removed", .removed);
    try expectMemoryStatus(rows.items, "stable", .stable);

    var hidden = try collectMemoryDeltas(
        std.testing.allocator,
        &baseline,
        &run,
        "complete",
        "complete",
        .{},
    );
    defer hidden.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), hidden.items.len);
}

test "compare jsonl emits machine-readable rows" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addZone(&baseline, "phase", 100);

    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addZone(&run, "phase", 60);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &baseline, &run, &out.writer, .{ .top = 4 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.compare/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"zone\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"delta_total_ns\":-40") != null);
}

test "compare correlates frame sets and preserves distribution tails" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addFrameTrace(&baseline, &.{
        .{ .name = "render", .durations_ns = &.{ 16, 16, 16 } },
        .{ .name = "removed", .durations_ns = &.{10} },
        .{ .name = "steady", .durations_ns = &.{5} },
    }, false);
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addFrameTrace(&run, &.{
        .{ .name = "render", .durations_ns = &.{ 16, 16, 48 } },
        .{ .name = "new", .durations_ns = &.{10} },
        .{ .name = "steady", .durations_ns = &.{5} },
    }, false);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{ .top = 8 });
    const text = out.written();
    try expectContains(
        text,
        "tracy compare frames shared=1 changed=1 stable=0 new=1 removed=1 partial=0",
    );
    try expectContains(text, "frame status=changed evidence=complete name=\"render\"");
    try expectContains(text, "base_p50_ns=16 run_p50_ns=16 delta_p50_ns=0");
    try expectContains(text, "base_p99_ns=16 run_p99_ns=48 delta_p99_ns=32");
    try expectContains(
        text,
        "base_discrepancy_ns=16 run_discrepancy_ns=48 delta_discrepancy_ns=32",
    );
    try expectContains(text, "frame status=new evidence=complete name=\"new\"");
    try expectContains(text, "frame status=removed evidence=complete name=\"removed\"");
    try std.testing.expect(std.mem.indexOf(u8, text, "name=\"steady\"") == null);
}

test "compare retains frame budget changes independently of time threshold" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addFrameTrace(
        &baseline,
        &.{.{ .name = "render", .durations_ns = &.{ 16, 16, 16 } }},
        false,
    );
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addFrameTrace(
        &run,
        &.{.{ .name = "render", .durations_ns = &.{ 16, 16, 48 } }},
        false,
    );

    var filtered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer filtered.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &filtered.writer, .{
        .min_frame_delta_ns = 1_000,
    });
    try std.testing.expect(std.mem.indexOf(u8, filtered.written(), "frame status=") == null);

    var budgeted = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer budgeted.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &budgeted.writer, .{
        .frame_budget_ns = 20,
        .min_frame_delta_ns = 1_000,
    });
    try expectContains(budgeted.written(), "frame status=changed evidence=complete");
    try expectContains(budgeted.written(), "delta_over_budget_per_mille=333");
    try expectContains(budgeted.written(), "delta_missed_intervals=2");
}

test "compare retains frame population changes independently of time threshold" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addFrameTrace(
        &baseline,
        &.{.{ .name = "render", .durations_ns = &.{ 16, 16 } }},
        false,
    );
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addFrameTrace(
        &run,
        &.{.{ .name = "render", .durations_ns = &.{16} }},
        false,
    );

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{
        .min_frame_delta_ns = 1_000,
    });
    try expectContains(out.written(), "frame status=changed evidence=complete");
    try expectContains(out.written(), "base_frames=2 run_frames=1 delta_frames=-1");
}

test "compare always surfaces partial frame evidence" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addFrameTrace(
        &baseline,
        &.{.{ .name = "render", .durations_ns = &.{ 16, 16 } }},
        false,
    );
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addFrameTrace(
        &run,
        &.{.{ .name = "render", .durations_ns = &.{ 16, 16 } }},
        true,
    );

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{
        .min_frame_delta_ns = 1_000,
    });
    try expectContains(out.written(), "run_integrity=sequence_gaps");
    try expectContains(out.written(), "stable=1 new=0 removed=0 partial=1");
    try expectContains(out.written(), "frame status=stable evidence=partial name=\"render\"");
}

test "compare always surfaces out-of-order frame evidence" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addOutOfOrderFrameTrace(&baseline);
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addOutOfOrderFrameTrace(&run);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{
        .min_frame_delta_ns = 1_000,
    });
    try expectContains(out.written(), "baseline_integrity=complete run_integrity=complete");
    try expectContains(
        out.written(),
        "partial=1 baseline_marks=3 run_marks=3 baseline_frames=1 run_frames=1 " ++
            "baseline_out_of_order_marks=1 run_out_of_order_marks=1",
    );
    try expectContains(out.written(), "frame status=stable evidence=partial name=\"render\"");
}

test "compare frame JSONL retains budget units and valid rows" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addFrameTrace(
        &baseline,
        &.{.{ .name = "render", .durations_ns = &.{ 16, 16, 16 } }},
        false,
    );
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addFrameTrace(
        &run,
        &.{.{ .name = "render", .durations_ns = &.{ 16, 16, 48 } }},
        false,
    );

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &baseline, &run, &out.writer, .{
        .frame_budget_ns = 20,
    });
    const text = out.written();
    try expectContains(text, "\"frame_budget_ns\":20");
    try expectContains(text, "\"kind\":\"frame\"");
    try expectContains(text, "\"delta_p99_ns\":32");
    try expectContains(text, "\"kind\":\"frame_budget\"");
    try expectContains(text, "\"delta_missed_per_1000_frames\":666");
    try std.testing.expectEqual(3, try validJsonLineCount(text));
}

test "compare rejects a zero frame budget" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(
        error.InvalidBudget,
        writeText(std.testing.allocator, &baseline, &run, &out.writer, .{
            .frame_budget_ns = 0,
        }),
    );
}

test "compare correlates named GPU zones and preserves completed means" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addGpuTrace(&baseline, &.{
        .{ .name = "draw", .gpu_ns = 30 },
        .{ .name = "draw", .gpu_ns = 30 },
        .{ .name = "removed", .gpu_ns = 20 },
        .{ .name = "steady", .gpu_ns = 10 },
    });
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addGpuTrace(&run, &.{
        .{ .name = "draw", .gpu_ns = 100 },
        .{ .name = "new", .gpu_ns = 30 },
        .{ .name = "steady", .gpu_ns = 10 },
    });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{ .top = 8 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "tracy compare capture baseline_integrity=complete run_integrity=complete",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "tracy compare gpu shared=1 changed=1 stable=0 new=1 removed=1 partial=0",
    ) != null);
    try expectContains(text, "gpu status=changed evidence=complete name=\"draw\"");
    try expectContains(
        text,
        "base_total_gpu_ns=60 run_total_gpu_ns=100 delta_total_gpu_ns=40",
    );
    try expectContains(
        text,
        "base_mean_gpu_ns=30 run_mean_gpu_ns=100 delta_mean_gpu_ns=70",
    );
    try expectContains(
        text,
        "base_count=2 run_count=1 base_completed_zones=2 run_completed_zones=1",
    );
    try expectContains(text, "gpu status=new evidence=complete name=\"new\"");
    try expectContains(text, "gpu status=removed evidence=complete name=\"removed\"");
    try std.testing.expect(std.mem.indexOf(u8, text, "name=\"steady\"") == null);
    const changed_index = std.mem.indexOf(u8, text, "gpu status=changed").?;
    const new_index = std.mem.indexOf(u8, text, "gpu status=new").?;
    const removed_index = std.mem.indexOf(u8, text, "gpu status=removed").?;
    try std.testing.expect(changed_index < new_index);
    try std.testing.expect(new_index < removed_index);
}

test "compare filters complete GPU deltas independently" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addGpuTrace(&baseline, &.{
        .{ .name = "draw", .gpu_ns = 60 },
        .{ .name = "steady", .gpu_ns = 10 },
    });
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addGpuTrace(&run, &.{
        .{ .name = "draw", .gpu_ns = 100 },
        .{ .name = "steady", .gpu_ns = 10 },
    });

    var filtered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer filtered.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &filtered.writer, .{
        .top = 8,
        .min_gpu_delta_ns = 50,
        .include_stable = true,
    });
    try std.testing.expect(std.mem.indexOf(u8, filtered.written(), "gpu status=") == null);

    var stable = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stable.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &stable.writer, .{
        .top = 8,
        .include_stable = true,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        stable.written(),
        "gpu status=stable evidence=complete name=\"steady\"",
    ) != null);
}

test "compare GPU threshold observes completed-zone mean changes" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addGpuTrace(&baseline, &.{
        .{ .name = "draw", .gpu_ns = 30 },
        .{ .name = "draw", .gpu_ns = 30 },
    });
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addGpuTrace(&run, &.{.{ .name = "draw", .gpu_ns = 60 }});

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{
        .top = 8,
        .min_gpu_delta_ns = 20,
    });
    const text = out.written();
    try expectContains(text, "gpu status=changed evidence=complete name=\"draw\"");
    try expectContains(text, "delta_total_gpu_ns=0");
    try expectContains(text, "base_mean_gpu_ns=30 run_mean_gpu_ns=60 delta_mean_gpu_ns=30");
}

test "compare always surfaces partial GPU evidence" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addGpuTrace(&baseline, &.{.{ .name = "draw", .gpu_ns = 20 }});
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addGpuTrace(&run, &.{.{ .name = "draw", .gpu_ns = 30, .complete = false }});

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{
        .top = 8,
        .min_gpu_delta_ns = 1_000,
    });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "run_integrity=unbalanced_events") != null);
    try expectContains(
        text,
        "partial=1 baseline_incomplete_zones=0 run_incomplete_zones=1",
    );
    try expectContains(text, "gpu status=changed evidence=partial name=\"draw\"");
    try expectContains(text, "base_completed_zones=1 run_completed_zones=0");
}

test "compare GPU JSONL retains integrity and units" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addGpuTrace(&baseline, &.{.{ .name = "draw", .gpu_ns = 60 }});
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addGpuTrace(&run, &.{.{ .name = "draw", .gpu_ns = 100 }});

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &baseline, &run, &out.writer, .{ .top = 4 });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"gpu_changed\":1") != null);
    try expectContains(text, "\"baseline_capture_integrity\":\"complete\"");
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"gpu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"delta_total_gpu_ns\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"delta_mean_gpu_ns\":40") != null);
    try std.testing.expectEqual(2, try validJsonLineCount(text));
}

test "compare correlates plot names and preserves distributions" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addPlotTrace(&baseline, &.{
        .{ .name = "latency", .unit = "nanoseconds", .values = &.{ 10, 20, 30 } },
        .{ .name = "removed", .unit = "count", .values = &.{1} },
        .{ .name = "steady", .unit = "count", .values = &.{5} },
    }, false);
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addPlotTrace(&run, &.{
        .{ .name = "latency", .unit = "nanoseconds", .values = &.{ 20, 40, 60 } },
        .{ .name = "new", .unit = "count", .values = &.{1} },
        .{ .name = "steady", .unit = "count", .values = &.{5} },
    }, false);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{ .top = 8 });
    const text = out.written();
    try expectContains(
        text,
        "tracy compare plots shared=1 changed=1 stable=0 new=1 removed=1 partial=0",
    );
    try expectContains(
        text,
        "plot status=changed evidence=complete unit_compatibility=matching name=\"latency\"",
    );
    try expectContains(text, "base_samples=3 run_samples=3 delta_samples=0");
    try expectContains(text, "base_p50=20 run_p50=40 delta_p50=20");
    try expectContains(text, "base_p99=30 run_p99=60 delta_p99=30");
    try expectContains(text, "base_mean=20 run_mean=40 delta_mean=20");
    try expectContains(
        text,
        "plot status=new evidence=complete unit_compatibility=not_applicable name=\"new\"",
    );
    try expectContains(
        text,
        "plot status=removed evidence=complete unit_compatibility=not_applicable " ++
            "name=\"removed\"",
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "name=\"steady\"") == null);
}

test "compare suppresses plot value deltas when units conflict" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addPlotTrace(
        &baseline,
        &.{.{ .name = "heap", .unit = "bytes", .values = &.{ 64, 96 } }},
        false,
    );
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addPlotTrace(
        &run,
        &.{.{ .name = "heap", .unit = "nanoseconds", .values = &.{ 64, 96 } }},
        false,
    );

    var text_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text_out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &text_out.writer, .{});
    try expectContains(text_out.written(), "unit_mismatch=1 unit_unknown=0");
    try expectContains(text_out.written(), "unit_compatibility=mismatch name=\"heap\"");
    try expectContains(text_out.written(), "base_mean=80 run_mean=80 delta_mean=none");

    var json_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json_out.deinit();
    try writeJsonl(std.testing.allocator, &baseline, &run, &json_out.writer, .{});
    const json = json_out.written();
    try expectContains(json, "\"plot_unit_mismatch\":1");
    try expectContains(json, "\"unit_compatibility\":\"mismatch\"");
    try expectContains(json, "\"base_unit\":\"bytes\",\"run_unit\":\"nanoseconds\"");
    try expectContains(json, "\"delta_mean\":null");
    try std.testing.expectEqual(2, try validJsonLineCount(json));
}

test "compare always surfaces incomplete plot evidence" {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addPlotTrace(&baseline, &.{
        .{
            .name = "heap",
            .unit = "bytes",
            .values = &.{64},
            .conflict = "nanoseconds",
            .missing_value = true,
        },
        .{ .name = "legacy", .values = &.{1} },
    }, false);
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addPlotTrace(&run, &.{
        .{ .name = "heap", .unit = "bytes", .values = &.{64} },
        .{ .name = "legacy", .values = &.{1} },
    }, true);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &baseline, &run, &out.writer, .{});
    const text = out.written();
    try expectContains(text, "run_integrity=sequence_gaps");
    try expectContains(
        text,
        "tracy compare plots shared=2 changed=0 stable=2 new=0 removed=0 partial=2",
    );
    try expectContains(text, "unit_mismatch=0 unit_unknown=1");
    try expectContains(text, "unit_compatibility=matching name=\"heap\"");
    try expectContains(
        text,
        "base_configuration_conflicts=1 run_configuration_conflicts=0",
    );
    try expectContains(text, "baseline_ignored_missing_values=1 run_ignored_missing_values=0");
    try expectContains(text, "unit_compatibility=unknown name=\"legacy\"");
}

test "compare releases assembled evidence on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        writeComparisonWithAllocator,
        .{},
    );
}

const TestGpuZone = struct {
    name: []const u8,
    gpu_ns: u64,
    complete: bool = true,
};

const TestZoneSet = struct {
    name: []const u8,
    durations_ns: []const u64,
    invalid_last: bool = false,
};

const TestFrameSet = struct {
    name: []const u8,
    durations_ns: []const u64,
};

const TestPlotSet = struct {
    name: []const u8,
    unit: ?[]const u8 = null,
    values: []const f64,
    conflict: ?[]const u8 = null,
    missing_value: bool = false,
};

fn expectContains(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
}

fn expectMemoryStatus(rows: []const MemoryDelta, name: []const u8, expected: Status) !void {
    for (rows) |row| {
        if (!std.mem.eql(u8, row.name, name)) continue;
        try std.testing.expectEqual(expected, row.status);
        return;
    }
    return error.TestExpectedEqual;
}

fn validJsonLineCount(text: []const u8) !usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            line,
            .{},
        );
        parsed.deinit();
        count += 1;
    }
    return count;
}

fn writeComparisonWithAllocator(allocator: std.mem.Allocator) !void {
    var baseline = Analyzer.init(std.testing.allocator);
    defer baseline.deinit();
    try addZone(&baseline, "phase", 10);
    try addMemory(&baseline, "arena", 16);
    try addGpuTrace(&baseline, &.{.{ .name = "draw", .gpu_ns = 20 }});
    try addPlotTrace(
        &baseline,
        &.{.{ .name = "latency", .unit = "nanoseconds", .values = &.{ 10, 20 } }},
        false,
    );
    try addFrameTrace(
        &baseline,
        &.{.{ .name = "render", .durations_ns = &.{ 10, 10 } }},
        false,
    );
    var run = Analyzer.init(std.testing.allocator);
    defer run.deinit();
    try addZone(&run, "phase", 20);
    try addMemory(&run, "arena", 32);
    try addGpuTrace(&run, &.{.{ .name = "draw", .gpu_ns = 40 }});
    try addPlotTrace(
        &run,
        &.{.{ .name = "latency", .unit = "nanoseconds", .values = &.{ 20, 40 } }},
        false,
    );
    try addFrameTrace(
        &run,
        &.{.{ .name = "render", .durations_ns = &.{ 10, 20 } }},
        false,
    );

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(allocator, &baseline, &run, &out.writer, .{});
}

fn addPlotTrace(
    analyzer: *Analyzer,
    sets: []const TestPlotSet,
    sequence_gap: bool,
) !void {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var sequence: u64 = 1;
    var time_ns: u64 = 100;
    try (event.TraceEvent{
        .seq = sequence,
        .kind = .start,
        .time_ns = time_ns,
        .thread = 1,
        .name = "plots",
    }).writeJsonLine(&trace.writer);
    sequence += 1;
    if (sequence_gap) sequence += 1;
    for (sets) |set| {
        try writeTestPlotSet(&trace.writer, &sequence, &time_ns, set);
    }
    time_ns += 10;
    try (event.TraceEvent{
        .seq = sequence,
        .kind = .stop,
        .time_ns = time_ns,
        .thread = 1,
    }).writeJsonLine(&trace.writer);
    try analyzer.ingestJsonlBytes(trace.written());
}

fn writeTestPlotSet(
    writer: *std.Io.Writer,
    sequence: *u64,
    time_ns: *u64,
    set: TestPlotSet,
) !void {
    if (set.unit) |unit| try writeTestPlotConfig(writer, sequence, time_ns, set.name, unit);
    if (set.conflict) |unit| {
        try writeTestPlotConfig(writer, sequence, time_ns, set.name, unit);
    }
    if (set.missing_value) {
        time_ns.* += 10;
        try (event.TraceEvent{
            .seq = sequence.*,
            .kind = .plot,
            .time_ns = time_ns.*,
            .thread = 1,
            .name = set.name,
        }).writeJsonLine(writer);
        sequence.* += 1;
    }
    for (set.values) |value| {
        time_ns.* += 10;
        try (event.TraceEvent{
            .seq = sequence.*,
            .kind = .plot,
            .time_ns = time_ns.*,
            .thread = 1,
            .name = set.name,
            .value_f64 = value,
            .plot_kind = "float",
        }).writeJsonLine(writer);
        sequence.* += 1;
    }
}

fn writeTestPlotConfig(
    writer: *std.Io.Writer,
    sequence: *u64,
    time_ns: *u64,
    name: []const u8,
    unit: []const u8,
) !void {
    time_ns.* += 10;
    try (event.TraceEvent{
        .seq = sequence.*,
        .kind = .plot_config,
        .time_ns = time_ns.*,
        .thread = 1,
        .name = name,
        .color = 7,
        .plot_unit = unit,
        .plot_step = true,
        .plot_fill = true,
    }).writeJsonLine(writer);
    sequence.* += 1;
}

fn addFrameTrace(
    analyzer: *Analyzer,
    sets: []const TestFrameSet,
    sequence_gap: bool,
) !void {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var sequence: u64 = 1;
    try (event.TraceEvent{
        .seq = sequence,
        .kind = .start,
        .time_ns = 1,
        .thread = 1,
        .name = "frames",
    }).writeJsonLine(&trace.writer);
    sequence += 1;
    if (sequence_gap) sequence += 1;
    var time_ns: u64 = 100;
    for (sets) |set| {
        try writeTestFrameMark(&trace.writer, &sequence, time_ns, set.name);
        for (set.durations_ns) |duration_ns| {
            time_ns += duration_ns;
            try writeTestFrameMark(&trace.writer, &sequence, time_ns, set.name);
        }
        time_ns += 10;
    }
    try (event.TraceEvent{
        .seq = sequence,
        .kind = .stop,
        .time_ns = time_ns + 10,
        .thread = 1,
    }).writeJsonLine(&trace.writer);
    try analyzer.ingestJsonlBytes(trace.written());
}

fn addOutOfOrderFrameTrace(analyzer: *Analyzer) !void {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{
        .seq = 1,
        .kind = .start,
        .time_ns = 1,
        .thread = 1,
        .name = "frames",
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 2,
        .kind = .frame,
        .time_ns = 100,
        .thread = 1,
        .name = "render",
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 3,
        .kind = .frame,
        .time_ns = 120,
        .thread = 1,
        .name = "render",
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 4,
        .kind = .frame,
        .time_ns = 110,
        .thread = 1,
        .name = "render",
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 5,
        .kind = .stop,
        .time_ns = 140,
        .thread = 1,
    }).writeJsonLine(&trace.writer);
    try analyzer.ingestJsonlBytes(trace.written());
}

fn writeTestFrameMark(
    writer: *std.Io.Writer,
    sequence: *u64,
    time_ns: u64,
    name: []const u8,
) !void {
    try (event.TraceEvent{
        .seq = sequence.*,
        .kind = .frame,
        .time_ns = time_ns,
        .thread = 1,
        .name = name,
    }).writeJsonLine(writer);
    sequence.* += 1;
}

fn addGpuTrace(analyzer: *Analyzer, zones: []const TestGpuZone) !void {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var sequence: u64 = 1;
    try (event.TraceEvent{
        .seq = sequence,
        .kind = .start,
        .time_ns = 900,
        .thread = 1,
        .name = "gpu",
    }).writeJsonLine(&trace.writer);
    sequence += 1;
    try (event.TraceEvent{
        .seq = sequence,
        .kind = .gpu_context,
        .time_ns = 1_000,
        .thread = 10,
        .name = "render",
        .gpu_context = 2,
        .gpu_time = 100,
        .gpu_period = 1,
        .gpu_context_type = "vulkan",
    }).writeJsonLine(&trace.writer);
    sequence += 1;
    var cpu_time: u64 = 1_010;
    var gpu_time: i64 = 110;
    for (zones, 0..) |zone, index| {
        const begin_query: u32 = @intCast(index * 2 + 1);
        const end_query = begin_query + 1;
        try writeTestGpuZone(
            &trace.writer,
            &sequence,
            &cpu_time,
            &gpu_time,
            begin_query,
            end_query,
            zone,
        );
    }
    try (event.TraceEvent{
        .seq = sequence,
        .kind = .stop,
        .time_ns = cpu_time + 10,
        .thread = 1,
    }).writeJsonLine(&trace.writer);
    try analyzer.ingestJsonlBytes(trace.written());
}

fn writeTestGpuZone(
    writer: *std.Io.Writer,
    sequence: *u64,
    cpu_time: *u64,
    gpu_time: *i64,
    begin_query: u32,
    end_query: u32,
    zone: TestGpuZone,
) !void {
    try (event.TraceEvent{
        .seq = sequence.*,
        .kind = .gpu_zone_begin,
        .time_ns = cpu_time.*,
        .thread = 10,
        .name = zone.name,
        .gpu_context = 2,
        .gpu_query = begin_query,
    }).writeJsonLine(writer);
    sequence.* += 1;
    try (event.TraceEvent{
        .seq = sequence.*,
        .kind = .gpu_zone_end,
        .time_ns = cpu_time.* + 10,
        .thread = 10,
        .gpu_context = 2,
        .gpu_query = end_query,
    }).writeJsonLine(writer);
    sequence.* += 1;
    try (event.TraceEvent{
        .seq = sequence.*,
        .kind = .gpu_time,
        .time_ns = cpu_time.* + 11,
        .thread = 10,
        .gpu_context = 2,
        .gpu_query = begin_query,
        .gpu_time = gpu_time.*,
    }).writeJsonLine(writer);
    sequence.* += 1;
    if (zone.complete) {
        try (event.TraceEvent{
            .seq = sequence.*,
            .kind = .gpu_time,
            .time_ns = cpu_time.* + 12,
            .thread = 10,
            .gpu_context = 2,
            .gpu_query = end_query,
            .gpu_time = gpu_time.* + @as(i64, @intCast(zone.gpu_ns)),
        }).writeJsonLine(writer);
        sequence.* += 1;
    }
    gpu_time.* += @intCast(zone.gpu_ns + 10);
    cpu_time.* += 20;
}

fn addZone(analyzer: *Analyzer, name: []const u8, duration_ns: u64) !void {
    const durations = [_]u64{duration_ns};
    return addZoneTrace(analyzer, &.{.{
        .name = name,
        .durations_ns = &durations,
    }}, false);
}

fn addZoneTrace(
    analyzer: *Analyzer,
    sets: []const TestZoneSet,
    sequence_gap: bool,
) !void {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var sequence: u64 = 1;
    var time_ns: u64 = 100;
    var zone_id: u64 = 1;
    try (event.TraceEvent{ .seq = sequence, .kind = .start, .time_ns = time_ns })
        .writeJsonLine(&trace.writer);
    sequence += 1;
    if (sequence_gap) sequence += 1;
    for (sets) |set| for (set.durations_ns, 0..) |duration_ns, duration_index| {
        time_ns += 10;
        try (event.TraceEvent{
            .seq = sequence,
            .kind = .zone_begin,
            .time_ns = time_ns,
            .thread = 1,
            .id = zone_id,
            .name = set.name,
        }).writeJsonLine(&trace.writer);
        sequence += 1;
        const invalid = set.invalid_last and duration_index + 1 == set.durations_ns.len;
        const end_ns = if (invalid) time_ns - 1 else time_ns + duration_ns;
        try (event.TraceEvent{
            .seq = sequence,
            .kind = .zone_end,
            .time_ns = end_ns,
            .thread = 1,
            .id = zone_id,
        }).writeJsonLine(&trace.writer);
        sequence += 1;
        zone_id += 1;
        if (!invalid) time_ns = end_ns;
    };
    time_ns += 10;
    try (event.TraceEvent{ .seq = sequence, .kind = .stop, .time_ns = time_ns })
        .writeJsonLine(&trace.writer);
    try analyzer.ingestJsonlBytes(trace.written());
}

fn addMemory(analyzer: *Analyzer, name: []const u8, high_water_bytes: u64) !void {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{
        .seq = 1,
        .kind = .alloc,
        .time_ns = 100,
        .thread = 1,
        .name = name,
        .address = 4096,
        .size = high_water_bytes,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 2,
        .kind = .free,
        .time_ns = 110,
        .thread = 1,
        .name = name,
        .address = 4096,
    }).writeJsonLine(&trace.writer);
    try analyzer.ingestJsonlBytes(trace.written());
}

const MemoryFixtureOptions = struct {
    right_censored: bool = false,
    size_mismatch: bool = false,
};

fn addMemoryLifetimes(
    analyzer: *Analyzer,
    name: []const u8,
    size: u64,
    lifetimes_ns: []const u64,
    options: MemoryFixtureOptions,
) !void {
    std.debug.assert(lifetimes_ns.len <= 16);
    std.debug.assert(size < std.math.maxInt(u64));
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var sequence: u64 = 1;
    var time_ns: u64 = 100;
    var address: u64 = 4096;
    try (event.TraceEvent{
        .seq = sequence,
        .kind = .start,
        .time_ns = time_ns,
        .thread = 1,
        .name = "memory-compare",
    }).writeJsonLine(&trace.writer);
    sequence += 1;
    for (lifetimes_ns, 0..) |lifetime_ns, index| {
        time_ns += 10;
        try writeTestAllocation(&trace.writer, sequence, time_ns, name, address, size);
        sequence += 1;
        time_ns += lifetime_ns;
        const reported_size = if (options.size_mismatch and index == 0) size + 1 else size;
        try writeTestFree(&trace.writer, sequence, time_ns, name, address, reported_size);
        sequence += 1;
        address += 4096;
    }
    if (options.right_censored) {
        time_ns += 10;
        try writeTestAllocation(&trace.writer, sequence, time_ns, name, address, size);
        sequence += 1;
    }
    time_ns += 10;
    try (event.TraceEvent{
        .seq = sequence,
        .kind = .stop,
        .time_ns = time_ns,
        .thread = 1,
        .name = "memory-compare",
    }).writeJsonLine(&trace.writer);
    try analyzer.ingestJsonlBytes(trace.written());
}

fn writeTestAllocation(
    writer: *std.Io.Writer,
    sequence: u64,
    time_ns: u64,
    name: []const u8,
    address: u64,
    size: u64,
) !void {
    try (event.TraceEvent{
        .seq = sequence,
        .kind = .alloc,
        .time_ns = time_ns,
        .thread = 1,
        .name = name,
        .address = address,
        .size = size,
    }).writeJsonLine(writer);
}

fn writeTestFree(
    writer: *std.Io.Writer,
    sequence: u64,
    time_ns: u64,
    name: []const u8,
    address: u64,
    size: u64,
) !void {
    try (event.TraceEvent{
        .seq = sequence,
        .kind = .free,
        .time_ns = time_ns,
        .thread = 1,
        .name = name,
        .address = address,
        .size = size,
    }).writeJsonLine(writer);
}
