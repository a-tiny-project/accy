const std = @import("std");
const pretty_json = @import("pretty").json;
const sys = @import("sys");
const capture_mod = @import("capture.zig");
const context_mod = @import("context.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");
const fiber_mod = @import("fiber.zig");
const gpu_mod = @import("gpu.zig");
const lock_mod = @import("lock.zig");
const memory_mod = @import("memory.zig");
const plot_mod = @import("plot.zig");
const sample_mod = @import("sample.zig");
const system_mod = @import("system.zig");
const transport = @import("transport.zig");

pub const Options = struct {
    top: usize = 20,
};

pub const Counters = struct {
    started_zones: u64 = 0,
    completed_zones: u64 = 0,
    zone_duration_samples: u64 = 0,
    zone_timestamp_regressions: u64 = 0,
    unmatched_zone_ends: u64 = 0,
    messages: u64 = 0,
    frames: u64 = 0,
    plots: u64 = 0,
    plot_configurations: u64 = 0,
    plot_configuration_conflicts: u64 = 0,
    app_infos: u64 = 0,
    thread_names: u64 = 0,
    samples: u64 = 0,
    sample_frames: u64 = 0,
    fiber_enters: u64 = 0,
    fiber_leaves: u64 = 0,
    fiber_names: u64 = 0,
    fiber_unmatched_leaves: u64 = 0,
    gpu_contexts: u64 = 0,
    gpu_zones: u64 = 0,
    gpu_completed_zones: u64 = 0,
    gpu_times: u64 = 0,
    gpu_annotations: u64 = 0,
    gpu_unmatched_ends: u64 = 0,
    gpu_unmatched_times: u64 = 0,
    gpu_duplicate_queries: u64 = 0,
    gpu_duplicate_times: u64 = 0,
    gpu_duration_samples: u64 = 0,
    gpu_cpu_duration_samples: u64 = 0,
    gpu_timestamp_regressions: u64 = 0,
    gpu_cpu_timestamp_regressions: u64 = 0,
    system_thread_contexts: u64 = 0,
    system_thread_pid_maps: u64 = 0,
    system_cpu_topology: u64 = 0,
    system_sys_time: u64 = 0,
    system_sys_power: u64 = 0,
    system_computed_power: u64 = 0,
    system_hw_samples: u64 = 0,
    context_switches: u64 = 0,
    thread_wakeups: u64 = 0,
    lock_events: u64 = 0,
};

pub const CaptureIntegrity = capture_mod.Integrity;

const ActiveZone = struct {
    name: []u8,
    file: ?[]u8 = null,
    function: ?[]u8 = null,
    line: u32 = 0,
    thread: u64 = 0,
    start_ns: u64 = 0,
    value: ?u64 = null,
    color: ?u32 = null,

    fn deinit(self: *ActiveZone, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.file) |file| allocator.free(file);
        if (self.function) |function| allocator.free(function);
        self.* = undefined;
    }
};

pub const ZoneSummary = struct {
    name: []const u8,
    file: ?[]const u8 = null,
    function: ?[]const u8 = null,
    line: u32 = 0,
    count: u64 = 0,
    duration_samples: u64 = 0,
    total_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    durations_ns: std.ArrayListUnmanaged(u64) = .empty,

    pub fn meanNs(self: ZoneSummary) u64 {
        if (self.duration_samples == 0) return 0;
        return self.total_ns / self.duration_samples;
    }

    pub fn percentileNs(self: ZoneSummary, percentile: u8) u64 {
        if (self.durations_ns.items.len == 0) return 0;
        const capped = @min(percentile, 100);
        const top_index = self.durations_ns.items.len - 1;
        const index = (top_index * capped) / 100;
        return self.durations_ns.items[index];
    }
};

pub const ZonePrefixSummary = struct {
    name: []const u8,
    count: u64 = 0,
    duration_samples: u64 = 0,
    total_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,

    pub fn meanNs(self: ZonePrefixSummary) u64 {
        if (self.duration_samples == 0) return 0;
        return self.total_ns / self.duration_samples;
    }
};

pub const ZoneThreadSummary = struct {
    thread: u64,
    name: ?[]const u8 = null,
    count: u64 = 0,
    duration_samples: u64 = 0,
    total_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,

    pub fn meanNs(self: ZoneThreadSummary) u64 {
        if (self.duration_samples == 0) return 0;
        return self.total_ns / self.duration_samples;
    }
};

pub const PlotSummary = plot_mod.Summary;
pub const MemorySummary = memory_mod.Summary;
pub const SampleSummary = sample_mod.Summary;
pub const LockSummary = lock_mod.Summary;
pub const ContextSummary = context_mod.Summary;
pub const FiberSummary = fiber_mod.Summary;
pub const GpuSummary = gpu_mod.Summary;
pub const SystemSummary = system_mod.Summary;

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    capture: capture_mod.Tracker = .{},
    active_zones: std.AutoHashMapUnmanaged(u64, ActiveZone) = .{},
    zone_summaries: std.StringHashMapUnmanaged(ZoneSummary) = .{},
    zone_prefix_summaries: std.StringHashMapUnmanaged(ZonePrefixSummary) = .{},
    zone_thread_summaries: std.AutoHashMapUnmanaged(u64, ZoneThreadSummary) = .{},
    plots: plot_mod.Analyzer,
    memory: memory_mod.Analyzer,
    samples: sample_mod.Analyzer,
    fibers: fiber_mod.Analyzer,
    gpu: gpu_mod.Analyzer,
    system: system_mod.Analyzer,
    context: context_mod.Analyzer,
    locks: lock_mod.Analyzer,
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{
            .allocator = allocator,
            .plots = plot_mod.Analyzer.init(allocator),
            .memory = memory_mod.Analyzer.init(allocator),
            .samples = sample_mod.Analyzer.init(allocator),
            .fibers = fiber_mod.Analyzer.init(allocator),
            .gpu = gpu_mod.Analyzer.init(allocator),
            .system = system_mod.Analyzer.init(allocator),
            .context = context_mod.Analyzer.init(allocator),
            .locks = lock_mod.Analyzer.init(allocator),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        var active_iter = self.active_zones.valueIterator();
        while (active_iter.next()) |zone| zone.deinit(self.allocator);
        self.active_zones.deinit(self.allocator);

        var zone_iter = self.zone_summaries.iterator();
        while (zone_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.file) |file| self.allocator.free(file);
            if (entry.value_ptr.function) |function| self.allocator.free(function);
            entry.value_ptr.durations_ns.deinit(self.allocator);
        }
        self.zone_summaries.deinit(self.allocator);

        var prefix_iter = self.zone_prefix_summaries.iterator();
        while (prefix_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.zone_prefix_summaries.deinit(self.allocator);

        var thread_iter = self.zone_thread_summaries.valueIterator();
        while (thread_iter.next()) |entry| {
            if (entry.name) |name| self.allocator.free(name);
        }
        self.zone_thread_summaries.deinit(self.allocator);

        self.plots.deinit();
        self.memory.deinit();
        self.samples.deinit();
        self.fibers.deinit();
        self.gpu.deinit();
        self.system.deinit();
        self.context.deinit();
        self.locks.deinit();
        self.* = undefined;
    }

    pub fn ingestJsonlBytes(self: *Analyzer, bytes: []const u8) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| try self.ingestJsonLine(line);
    }

    pub fn ingestJsonLine(self: *Analyzer, line: []const u8) !void {
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) return;
        var parsed = try record_mod.parseLine(self.allocator, text);
        defer parsed.deinit();
        switch (parsed) {
            .event => |value| try self.ingest(value),
            .flight => |report_value| {
                self.capture.recordFlightReport(report_value);
                self.plots.recordFlightReport(report_value);
                self.memory.recordFlightReport(report_value);
                self.context.recordFlightReport(report_value);
                self.locks.recordFlightReport(report_value);
            },
        }
    }

    pub fn ingest(self: *Analyzer, parsed: event.Parsed) !void {
        self.capture.record(parsed);
        try self.context.ingest(parsed);
        try self.plots.ingest(parsed);
        try self.memory.ingest(parsed);
        try self.locks.ingest(parsed);
        self.counters.plots = self.plots.counters.samples;
        self.counters.plot_configurations = self.plots.counters.configurations;
        self.counters.plot_configuration_conflicts =
            self.plots.counters.configuration_conflicts;
        if (self.start_ns == null and parsed.time_ns != 0) self.start_ns = parsed.time_ns;
        if (parsed.time_ns != 0) self.end_ns = parsed.time_ns;
        switch (parsed.kind) {
            .start => {
                if (parsed.time_ns != 0) self.start_ns = parsed.time_ns;
            },
            .stop => {
                if (parsed.time_ns != 0) self.end_ns = parsed.time_ns;
            },
            .zone_begin => try self.recordZoneBegin(parsed),
            .zone_end => try self.recordZoneEnd(parsed),
            .zone_name => try self.recordZoneName(parsed),
            .zone_color => self.recordZoneColor(parsed),
            .zone_value => self.recordZoneValue(parsed),
            .message => self.counters.messages += 1,
            .frame => self.counters.frames += 1,
            .plot, .plot_config => {},
            .app_info => self.counters.app_infos += 1,
            .thread_name => {
                self.counters.thread_names += 1;
                try self.recordThreadName(parsed);
                try self.fibers.ingest(parsed);
            },
            .fiber_name, .fiber_enter, .fiber_leave => {
                try self.fibers.ingest(parsed);
                self.counters.fiber_enters = self.fibers.counters.enters;
                self.counters.fiber_leaves = self.fibers.counters.leaves;
                self.counters.fiber_names = self.fibers.counters.names;
                self.counters.fiber_unmatched_leaves = self.fibers.counters.unmatched_leaves;
            },
            .gpu_context,
            .gpu_context_name,
            .gpu_zone_begin,
            .gpu_zone_end,
            .gpu_time,
            .gpu_calibration,
            .gpu_time_sync,
            .gpu_annotation,
            .gpu_annotation_name,
            => {
                try self.gpu.ingest(parsed);
                self.counters.gpu_contexts = @intCast(self.gpu.contexts.count());
                self.counters.gpu_zones = self.gpu.counters.zone_begins;
                self.counters.gpu_completed_zones = self.gpu.counters.completed_zones;
                self.counters.gpu_times = self.gpu.counters.gpu_times;
                self.counters.gpu_annotations = self.gpu.counters.annotations;
                self.counters.gpu_unmatched_ends = self.gpu.counters.unmatched_ends;
                self.counters.gpu_unmatched_times = self.gpu.counters.unmatched_times;
                self.counters.gpu_duplicate_queries = self.gpu.counters.duplicate_queries;
                self.counters.gpu_duplicate_times = self.gpu.counters.duplicate_times;
                self.counters.gpu_duration_samples = self.gpu.counters.gpu_duration_samples;
                self.counters.gpu_cpu_duration_samples = self.gpu.counters.cpu_duration_samples;
                self.counters.gpu_timestamp_regressions =
                    self.gpu.counters.gpu_timestamp_regressions;
                self.counters.gpu_cpu_timestamp_regressions =
                    self.gpu.counters.cpu_timestamp_regressions;
            },
            .thread_context,
            .thread_pid,
            .cpu_topology,
            .sys_time,
            .sys_power,
            .hw_sample,
            => {
                try self.system.ingest(parsed);
                self.counters.system_thread_contexts = self.system.counters.thread_contexts;
                self.counters.system_thread_pid_maps = self.system.counters.thread_pid_maps;
                self.counters.system_cpu_topology = self.system.counters.cpu_topology;
                self.counters.system_sys_time = self.system.counters.sys_time;
                self.counters.system_sys_power = self.system.counters.sys_power;
                self.counters.system_computed_power = self.system.counters.computed_power;
                self.counters.system_hw_samples = self.system.counters.hw_samples;
            },
            .sample, .sample_frame => {
                try self.samples.ingest(parsed);
                self.counters.samples = self.samples.counters.samples;
                self.counters.sample_frames = self.samples.counters.frames;
            },
            .context_switch, .thread_wakeup => {
                self.counters.context_switches = self.context.counters.switches;
                self.counters.thread_wakeups = self.context.counters.wakeups;
            },
            .alloc, .free => {},
            .lock_announce,
            .lock_terminate,
            .lock_wait,
            .lock_obtain,
            .lock_release,
            .lock_shared_wait,
            .lock_shared_obtain,
            .lock_shared_release,
            .lock_mark,
            .lock_name,
            => {
                self.counters.lock_events +|= 1;
            },
            .zone_text => {},
        }
    }

    pub fn captureIntegrity(self: *const Analyzer) CaptureIntegrity {
        return self.capture.integrity(self.unbalancedEventCount());
    }

    pub fn zoneDurationEvidence(self: *const Analyzer) []const u8 {
        if (!std.mem.eql(u8, self.captureIntegrity().status, "complete")) return "partial";
        if (self.counters.zone_timestamp_regressions != 0) return "partial";
        return "complete";
    }

    pub fn gpuDurationEvidence(self: *const Analyzer) []const u8 {
        if (!std.mem.eql(u8, self.captureIntegrity().status, "complete")) return "partial";
        return if (self.gpu.durationPairsComplete()) "complete" else "partial";
    }

    fn unbalancedEventCount(self: *const Analyzer) u64 {
        var count: u64 = @intCast(self.active_zones.count());
        count +|= self.counters.unmatched_zone_ends;
        count +|= self.fibers.counters.unmatched_leaves;
        count +|= self.fibers.activeCount();
        count +|= self.gpu.counters.unmatched_ends;
        count +|= self.gpu.counters.unmatched_times;
        count +|= self.gpu.incompleteZoneCount();
        count +|= self.memory.counters.unmatched_frees;
        count +|= self.locks.counters.unmatched_releases;
        count +|= @intCast(self.locks.pending_waits.count());
        count +|= @intCast(self.locks.pending_holds.count());
        return count;
    }

    pub fn writeSummary(self: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
        var zones = try self.collectZones();
        defer zones.deinit(self.allocator);
        var zone_prefixes = try self.collectZonePrefixes();
        defer zone_prefixes.deinit(self.allocator);
        var zone_threads = try self.collectZoneThreads();
        defer zone_threads.deinit(self.allocator);
        var plots = try self.collectPlots();
        defer plots.deinit(self.allocator);
        var memory = try self.collectMemory();
        defer memory.deinit(self.allocator);
        var samples = try self.collectSamples();
        defer sample_mod.deinitSummaries(self.allocator, &samples);
        var lock_rows = try self.collectLocks();
        defer lock_rows.deinit(self.allocator);
        var fiber_rows = try self.collectFibers();
        defer fiber_mod.deinitSummaries(self.allocator, &fiber_rows);
        var gpu_rows = try self.collectGpu();
        defer gpu_mod.deinitSummaries(self.allocator, &gpu_rows);
        var system_rows = try self.collectSystem();
        defer system_mod.deinitSummaries(self.allocator, &system_rows);
        var context_rows = try self.collectContext();
        defer context_mod.deinitSummaries(self.allocator, &context_rows);

        try writer.print(
            "tracy events={d} zones={d} zone_duration_samples={d} " ++
                "zone_timestamp_regressions={d} zone_duration_evidence={s} " ++
                "zone_prefixes={d} zone_threads={d} active_zones={d} " ++
                "messages={d} frames={d} plots={d} " ++
                "plot_configurations={d} plot_configuration_conflicts={d} " ++
                "samples={d} sample_frames={d} fiber_enters={d} fiber_leaves={d} " ++
                "fiber_names={d} context_switches={d} thread_wakeups={d} " ++
                "context_ready_latency_samples={d} context_redundant_wakeups={d} " ++
                "context_ready_time_regressions={d} context_pending_ready_intervals={d} " ++
                "context_ready_latency_evidence={s} duration_ns={d}\n",
            .{
                self.capture.counters.events,
                self.counters.completed_zones,
                self.counters.zone_duration_samples,
                self.counters.zone_timestamp_regressions,
                self.zoneDurationEvidence(),
                zone_prefixes.items.len,
                zone_threads.items.len,
                self.active_zones.count(),
                self.counters.messages,
                self.counters.frames,
                self.counters.plots,
                self.counters.plot_configurations,
                self.counters.plot_configuration_conflicts,
                self.counters.samples,
                self.counters.sample_frames,
                self.counters.fiber_enters,
                self.counters.fiber_leaves,
                self.counters.fiber_names,
                self.counters.context_switches,
                self.counters.thread_wakeups,
                self.context.counters.ready_latency_samples,
                self.context.counters.redundant_wakeups,
                self.context.counters.ready_time_regressions,
                self.context.pendingReadyIntervals(),
                self.context.readyLatencyEvidence(),
                self.durationNs(),
            },
        );
        try capture_mod.writeText(writer, self.captureIntegrity());
        const memory_counters = self.memory.counters;
        try writer.print(
            "tracy allocations={d} frees={d} completed_lifetimes={d} " ++
                "lifetime_samples={d} right_censored_allocations={d} live_bytes={d} " ++
                "high_water_live_bytes={d} allocated_bytes={d} freed_bytes={d} " ++
                "unmatched_frees={d} duplicate_allocations={d} " ++
                "timestamp_regressions={d} untracked_allocations={d} " ++
                "size_mismatches={d} lifetime_population=completed " ++
                "lifetime_evidence={s}\n",
            .{
                memory_counters.allocations,
                memory_counters.frees,
                memory_counters.completed_lifetimes,
                memory_counters.lifetime_samples,
                self.memory.active.count(),
                memory_counters.live_bytes,
                memory_counters.high_water_live_bytes,
                memory_counters.allocated_bytes,
                memory_counters.freed_bytes,
                memory_counters.unmatched_frees,
                memory_counters.duplicate_allocations,
                memory_counters.timestamp_regressions,
                memory_counters.untracked_allocations,
                memory_counters.size_mismatches,
                self.memory.lifetimeEvidence(),
            },
        );
        if (self.counters.unmatched_zone_ends != 0) {
            try writer.print("tracy anomalies unmatched_zone_ends={d}\n", .{self.counters.unmatched_zone_ends});
        }
        if (self.counters.fiber_unmatched_leaves != 0) {
            try writer.print("tracy fiber_anomalies unmatched_leaves={d}\n", .{self.counters.fiber_unmatched_leaves});
        }
        try writer.print(
            "tracy locks={d} lock_waits={d} lock_holds={d} lock_wait_samples={d} " ++
                "lock_hold_samples={d} pending_waits={d} pending_holds={d} " ++
                "duplicate_waits={d} duplicate_obtains={d} timestamp_regressions={d} " ++
                "unmatched_releases={d} lock_duration_evidence={s}\n",
            .{
                self.locks.locks.count(),
                self.locks.counters.completed_waits,
                self.locks.counters.completed_holds,
                self.locks.counters.wait_samples,
                self.locks.counters.hold_samples,
                self.locks.pending_waits.count(),
                self.locks.pending_holds.count(),
                self.locks.counters.duplicate_waits,
                self.locks.counters.duplicate_obtains,
                self.locks.counters.timestamp_regressions,
                self.locks.counters.unmatched_releases,
                self.locks.durationEvidence(),
            },
        );
        const lock_limit = @min(options.top, lock_rows.items.len);
        for (lock_rows.items[0..lock_limit]) |row| {
            try writer.print("lock id={d} name=", .{row.id});
            try pretty_json.writeString(writer, row.name);
            try lock_mod.writeSummaryDurationsText(writer, row);
            try writer.print(" threads={d} marks={d} last_event_ns={d}\n", .{
                row.thread_count,
                row.mark_count,
                row.last_event_ns,
            });
        }
        try writeGpuCaptureText(writer, self);
        try writer.print(
            "tracy system_thread_contexts={d} system_thread_pid_maps={d} system_cpu_topology={d} system_sys_time={d} system_sys_power={d} system_computed_power={d} system_hw_samples={d}\n",
            .{
                self.counters.system_thread_contexts,
                self.counters.system_thread_pid_maps,
                self.counters.system_cpu_topology,
                self.counters.system_sys_time,
                self.counters.system_sys_power,
                self.counters.system_computed_power,
                self.counters.system_hw_samples,
            },
        );
        const zone_limit = @min(options.top, zones.items.len);
        for (zones.items[0..zone_limit]) |zone| {
            try writer.print(
                "zone name=",
                .{},
            );
            try pretty_json.writeString(writer, zone.name);
            try writer.print(
                " count={d} duration_samples={d} total_ns={d} mean_ns={d} " ++
                    "min_ns={d} p50_ns={d} p90_ns={d} p99_ns={d} max_ns={d}",
                .{
                    zone.count,
                    zone.duration_samples,
                    zone.total_ns,
                    zone.meanNs(),
                    if (zone.min_ns == std.math.maxInt(u64)) 0 else zone.min_ns,
                    zone.percentileNs(50),
                    zone.percentileNs(90),
                    zone.percentileNs(99),
                    zone.max_ns,
                },
            );
            if (zone.file) |file| try writer.print(" file={s}:{d}", .{ file, zone.line });
            try writer.writeByte('\n');
        }
        const prefix_limit = @min(options.top, zone_prefixes.items.len);
        for (zone_prefixes.items[0..prefix_limit]) |prefix| {
            try writer.print("zone_prefix name=", .{});
            try pretty_json.writeString(writer, prefix.name);
            try writer.print(
                " count={d} duration_samples={d} total_ns={d} " ++
                    "mean_ns={d} min_ns={d} max_ns={d}\n",
                .{
                    prefix.count,
                    prefix.duration_samples,
                    prefix.total_ns,
                    prefix.meanNs(),
                    if (prefix.min_ns == std.math.maxInt(u64)) 0 else prefix.min_ns,
                    prefix.max_ns,
                },
            );
        }
        const thread_limit = @min(options.top, zone_threads.items.len);
        for (zone_threads.items[0..thread_limit]) |thread| {
            try writer.print("zone_thread thread={d}", .{thread.thread});
            if (thread.name) |name| {
                try writer.writeAll(" name=");
                try pretty_json.writeString(writer, name);
            }
            try writer.print(
                " count={d} duration_samples={d} total_ns={d} " ++
                    "mean_ns={d} min_ns={d} max_ns={d}\n",
                .{
                    thread.count,
                    thread.duration_samples,
                    thread.total_ns,
                    thread.meanNs(),
                    if (thread.min_ns == std.math.maxInt(u64)) 0 else thread.min_ns,
                    thread.max_ns,
                },
            );
        }
        const plot_limit = @min(options.top, plots.items.len);
        for (plots.items[0..plot_limit]) |plot| try writePlotSummaryText(writer, plot);
        const memory_limit = @min(options.top, memory.items.len);
        for (memory.items[0..memory_limit]) |item| try writeMemorySummaryText(writer, item);
        const sample_limit = @min(options.top, samples.items.len);
        for (samples.items[0..sample_limit]) |sample| {
            try writer.print("sample label=", .{});
            try pretty_json.writeString(writer, sample.label);
            try writer.print(" count={d} weight={d} first_ns={d} last_ns={d}", .{ sample.count, sample.weight, sample.first_ns, sample.last_ns });
            if (sample.kind) |kind| {
                try writer.writeAll(" kind=");
                try pretty_json.writeString(writer, kind);
            }
            if (sample.file) |file| try writer.print(" file={s}:{d}", .{ file, sample.line });
            try writer.writeByte('\n');
        }
        const fiber_limit = @min(options.top, fiber_rows.items.len);
        for (fiber_rows.items[0..fiber_limit]) |row| {
            try writer.print("fiber label=", .{});
            try pretty_json.writeString(writer, row.label);
            try writer.print(" count={d} running_ns={d} enters={d} leaves={d}", .{ row.count, row.running_ns, row.enters, row.leaves });
            if (row.fiber) |fiber| try writer.print(" fiber={d}", .{fiber});
            if (row.thread) |thread| try writer.print(" thread={d}", .{thread});
            if (row.group_hint) |group_hint| try writer.print(" group_hint={d}", .{group_hint});
            if (row.migrations != 0) try writer.print(" migrations={d}", .{row.migrations});
            if (row.unmatched_leaves != 0) try writer.print(" unmatched_leaves={d}", .{row.unmatched_leaves});
            if (row.active) try writer.writeAll(" active=true");
            try writer.writeByte('\n');
        }
        const gpu_limit = @min(options.top, gpu_rows.items.len);
        for (gpu_rows.items[0..gpu_limit]) |row| {
            try writeGpuSummaryText(writer, row);
        }
        const system_limit = @min(options.top, system_rows.items.len);
        for (system_rows.items[0..system_limit]) |row| {
            try writer.print("system label=", .{});
            try pretty_json.writeString(writer, row.label);
            try writer.print(" count={d}", .{row.count});
            try writeSystemSummaryTextFields(writer, row);
            try writer.writeByte('\n');
        }
        const context_limit = @min(options.top, context_rows.items.len);
        for (context_rows.items[0..context_limit]) |row| {
            try writer.print("context label=", .{});
            try pretty_json.writeString(writer, row.label);
            try writer.print(
                " count={d} running_ns={d} blocked_ns={d} ready_ns={d} " ++
                    "unknown_off_cpu_ns={d}",
                .{
                    row.count,
                    row.running_ns,
                    row.blocked_ns,
                    row.ready_ns,
                    row.unknown_off_cpu_ns,
                },
            );
            try writeContextLatencyText(writer, row);
            if (row.thread) |thread| try writer.print(" thread={d}", .{thread});
            if (row.cpu) |cpu| try writer.print(" cpu={d}", .{cpu});
            if (row.migrations != 0) try writer.print(" migrations={d}", .{row.migrations});
            try writer.writeByte('\n');
        }
    }

    pub fn writeSummaryJsonl(self: *Analyzer, writer: *std.Io.Writer, options: Options) !void {
        var zones = try self.collectZones();
        defer zones.deinit(self.allocator);
        var zone_prefixes = try self.collectZonePrefixes();
        defer zone_prefixes.deinit(self.allocator);
        var zone_threads = try self.collectZoneThreads();
        defer zone_threads.deinit(self.allocator);
        var plots = try self.collectPlots();
        defer plots.deinit(self.allocator);
        var memory = try self.collectMemory();
        defer memory.deinit(self.allocator);
        var samples = try self.collectSamples();
        defer sample_mod.deinitSummaries(self.allocator, &samples);
        var lock_rows = try self.collectLocks();
        defer lock_rows.deinit(self.allocator);
        var fiber_rows = try self.collectFibers();
        defer fiber_mod.deinitSummaries(self.allocator, &fiber_rows);
        var gpu_rows = try self.collectGpu();
        defer gpu_mod.deinitSummaries(self.allocator, &gpu_rows);
        var system_rows = try self.collectSystem();
        defer system_mod.deinitSummaries(self.allocator, &system_rows);
        var context_rows = try self.collectContext();
        defer context_mod.deinitSummaries(self.allocator, &context_rows);

        var summary_stream = pretty_json.Writer.init(writer, .minified);
        const summary = try summary_stream.object();
        try summary.field("kind", "summary");
        try writeCaptureFields(
            summary,
            self,
            zone_prefixes.items.len,
            zone_threads.items.len,
        );
        try writeGpuCaptureFields(summary, self);
        try writeSystemCaptureFields(summary, self);
        try writeContextCaptureFields(summary, self);
        try summary.field("duration_ns", self.durationNs());
        try writeMemoryCaptureFields(summary, self);
        try writeLockCaptureFields(summary, self);
        try summary.field("memory_lifetime_population", "completed");
        try summary.field("memory_lifetime_evidence", self.memory.lifetimeEvidence());
        try capture_mod.writeFields(summary, self.captureIntegrity());
        try summary.endLine();
        const lock_limit = @min(options.top, lock_rows.items.len);
        for (lock_rows.items[0..lock_limit]) |row| {
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("kind", "lock");
            try object.field("id", row.id);
            try object.field("name", row.name);
            try lock_mod.writeSummaryDurationFields(object, row);
            try object.field("threads", row.thread_count);
            try object.field("marks", row.mark_count);
            try object.field("last_event_ns", row.last_event_ns);
            try object.endLine();
        }
        const zone_limit = @min(options.top, zones.items.len);
        for (zones.items[0..zone_limit]) |zone| {
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("kind", "zone");
            try object.field("name", zone.name);
            try object.field("count", zone.count);
            try object.field("duration_samples", zone.duration_samples);
            try object.field("total_ns", zone.total_ns);
            try object.field("mean_ns", zone.meanNs());
            try object.field(
                "min_ns",
                if (zone.min_ns == std.math.maxInt(u64)) 0 else zone.min_ns,
            );
            try object.field("p50_ns", zone.percentileNs(50));
            try object.field("p90_ns", zone.percentileNs(90));
            try object.field("p99_ns", zone.percentileNs(99));
            try object.field("max_ns", zone.max_ns);
            if (zone.file) |file| {
                try object.field("file", file);
                try object.field("line", zone.line);
            }
            try object.endLine();
        }
        const prefix_limit = @min(options.top, zone_prefixes.items.len);
        for (zone_prefixes.items[0..prefix_limit]) |prefix| {
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("kind", "zone_prefix");
            try object.field("name", prefix.name);
            try object.field("count", prefix.count);
            try object.field("duration_samples", prefix.duration_samples);
            try object.field("total_ns", prefix.total_ns);
            try object.field("mean_ns", prefix.meanNs());
            try object.field(
                "min_ns",
                if (prefix.min_ns == std.math.maxInt(u64)) 0 else prefix.min_ns,
            );
            try object.field("max_ns", prefix.max_ns);
            try object.endLine();
        }
        const thread_limit = @min(options.top, zone_threads.items.len);
        for (zone_threads.items[0..thread_limit]) |thread| {
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("kind", "zone_thread");
            try object.field("thread", thread.thread);
            if (thread.name) |name| try object.field("name", name);
            try object.field("count", thread.count);
            try object.field("duration_samples", thread.duration_samples);
            try object.field("total_ns", thread.total_ns);
            try object.field("mean_ns", thread.meanNs());
            try object.field(
                "min_ns",
                if (thread.min_ns == std.math.maxInt(u64)) 0 else thread.min_ns,
            );
            try object.field("max_ns", thread.max_ns);
            try object.endLine();
        }
        const plot_limit = @min(options.top, plots.items.len);
        for (plots.items[0..plot_limit]) |plot| try writePlotSummaryJson(writer, plot);
        const memory_limit = @min(options.top, memory.items.len);
        for (memory.items[0..memory_limit]) |item| try writeMemorySummaryJson(writer, item);
        const sample_limit = @min(options.top, samples.items.len);
        for (samples.items[0..sample_limit]) |sample| {
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("kind", "sample");
            try object.field("label", sample.label);
            try object.field("count", sample.count);
            try object.field("weight", sample.weight);
            try object.field("first_ns", sample.first_ns);
            try object.field("last_ns", sample.last_ns);
            if (sample.kind) |kind| try object.field("sample_kind", kind);
            if (sample.file) |file| {
                try object.field("file", file);
                try object.field("line", sample.line);
            }
            try object.endLine();
        }
        const fiber_limit = @min(options.top, fiber_rows.items.len);
        for (fiber_rows.items[0..fiber_limit]) |row| {
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("kind", "fiber");
            try object.field("label", row.label);
            try object.field("count", row.count);
            try object.field("running_ns", row.running_ns);
            try object.field("enters", row.enters);
            try object.field("leaves", row.leaves);
            if (row.fiber) |fiber| try object.field("fiber", fiber);
            if (row.thread) |thread| try object.field("thread", thread);
            if (row.group_hint) |group_hint| try object.field("group_hint", group_hint);
            if (row.migrations != 0) try object.field("migrations", row.migrations);
            if (row.unmatched_leaves != 0) {
                try object.field("unmatched_leaves", row.unmatched_leaves);
            }
            if (row.active) try object.field("active", true);
            try object.endLine();
        }
        const gpu_limit = @min(options.top, gpu_rows.items.len);
        for (gpu_rows.items[0..gpu_limit]) |row| {
            try writeGpuSummaryJson(writer, row);
        }
        const system_limit = @min(options.top, system_rows.items.len);
        for (system_rows.items[0..system_limit]) |row| {
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("kind", "system");
            try object.field("label", row.label);
            try object.field("group", systemGroupTag(row.group));
            try object.field("count", row.count);
            try writeSystemSummaryFields(object, row);
            try object.endLine();
        }
        const context_limit = @min(options.top, context_rows.items.len);
        for (context_rows.items[0..context_limit]) |row| {
            var stream = pretty_json.Writer.init(writer, .minified);
            const object = try stream.object();
            try object.field("kind", "context");
            try object.field("label", row.label);
            try object.field("count", row.count);
            try object.field("running_ns", row.running_ns);
            try object.field("blocked_ns", row.blocked_ns);
            try object.field("ready_ns", row.ready_ns);
            try object.field("unknown_off_cpu_ns", row.unknown_off_cpu_ns);
            try writeContextLatencyFields(object, row);
            if (row.thread) |thread| try object.field("thread", thread);
            if (row.cpu) |cpu| try object.field("cpu", cpu);
            if (row.migrations != 0) try object.field("migrations", row.migrations);
            try object.endLine();
        }
    }

    fn recordZoneBegin(self: *Analyzer, parsed: event.Parsed) !void {
        if (parsed.id == 0) return;
        if (self.active_zones.fetchRemove(parsed.id)) |removed| {
            var old = removed.value;
            old.deinit(self.allocator);
        }
        const name = parsed.name orelse "<zone>";
        try self.active_zones.put(self.allocator, parsed.id, .{
            .name = try self.allocator.dupe(u8, name),
            .file = try dupeOptional(self.allocator, parsed.file),
            .function = try dupeOptional(self.allocator, parsed.function),
            .line = parsed.line,
            .thread = parsed.thread,
            .start_ns = parsed.time_ns,
            .color = parsed.color,
        });
        self.counters.started_zones += 1;
    }

    fn recordZoneEnd(self: *Analyzer, parsed: event.Parsed) !void {
        const removed = self.active_zones.fetchRemove(parsed.id) orelse {
            self.counters.unmatched_zone_ends += 1;
            return;
        };
        var zone = removed.value;
        defer zone.deinit(self.allocator);
        const duration = if (parsed.time_ns >= zone.start_ns)
            parsed.time_ns - zone.start_ns
        else
            null;
        const summary = try self.zoneSummary(zone.name, zone.file, zone.function, zone.line);
        summary.count += 1;
        if (duration) |valid| {
            try summary.durations_ns.append(self.allocator, valid);
            summary.duration_samples += 1;
            summary.total_ns +|= valid;
            summary.min_ns = @min(summary.min_ns, valid);
            summary.max_ns = @max(summary.max_ns, valid);
            self.counters.zone_duration_samples += 1;
        } else {
            self.counters.zone_timestamp_regressions += 1;
        }
        try self.recordZonePrefixes(zone.name, duration);
        try self.recordZoneThread(zone.thread, duration);
        self.counters.completed_zones += 1;
    }

    fn recordZoneName(self: *Analyzer, parsed: event.Parsed) !void {
        const name = parsed.name orelse return;
        const zone = self.active_zones.getPtr(parsed.id) orelse return;
        self.allocator.free(zone.name);
        zone.name = try self.allocator.dupe(u8, name);
    }

    fn recordZoneColor(self: *Analyzer, parsed: event.Parsed) void {
        const color = parsed.color orelse return;
        const zone = self.active_zones.getPtr(parsed.id) orelse return;
        zone.color = color;
    }

    fn recordZoneValue(self: *Analyzer, parsed: event.Parsed) void {
        const value = parsed.value_u64 orelse return;
        const zone = self.active_zones.getPtr(parsed.id) orelse return;
        zone.value = value;
    }

    fn recordThreadName(self: *Analyzer, parsed: event.Parsed) !void {
        const name = parsed.name orelse return;
        const summary = try self.zoneThreadSummary(parsed.thread);
        if (summary.name) |old| self.allocator.free(old);
        summary.name = try self.allocator.dupe(u8, name);
    }

    fn recordZonePrefixes(self: *Analyzer, name: []const u8, duration: ?u64) !void {
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, name, start, '.')) |dot| {
            if (dot != 0) {
                const summary = try self.zonePrefixSummary(name[0..dot]);
                summary.count += 1;
                if (duration) |valid| {
                    summary.duration_samples += 1;
                    summary.total_ns +|= valid;
                    summary.min_ns = @min(summary.min_ns, valid);
                    summary.max_ns = @max(summary.max_ns, valid);
                }
            }
            start = dot + 1;
        }
    }

    fn recordZoneThread(self: *Analyzer, thread: u64, duration: ?u64) !void {
        const summary = try self.zoneThreadSummary(thread);
        summary.count += 1;
        if (duration) |valid| {
            summary.duration_samples += 1;
            summary.total_ns +|= valid;
            summary.min_ns = @min(summary.min_ns, valid);
            summary.max_ns = @max(summary.max_ns, valid);
        }
    }

    fn zoneSummary(
        self: *Analyzer,
        name: []const u8,
        file: ?[]const u8,
        function: ?[]const u8,
        line: u32,
    ) !*ZoneSummary {
        const entry = try self.zone_summaries.getOrPut(self.allocator, name);
        if (!entry.found_existing) {
            const owned_name = try self.allocator.dupe(u8, name);
            entry.key_ptr.* = owned_name;
            entry.value_ptr.* = .{
                .name = owned_name,
                .file = try dupeOptional(self.allocator, file),
                .function = try dupeOptional(self.allocator, function),
                .line = line,
            };
        }
        return entry.value_ptr;
    }

    fn zonePrefixSummary(self: *Analyzer, name: []const u8) !*ZonePrefixSummary {
        const entry = try self.zone_prefix_summaries.getOrPut(self.allocator, name);
        if (!entry.found_existing) {
            const owned_name = try self.allocator.dupe(u8, name);
            entry.key_ptr.* = owned_name;
            entry.value_ptr.* = .{ .name = owned_name };
        }
        return entry.value_ptr;
    }

    fn zoneThreadSummary(self: *Analyzer, thread: u64) !*ZoneThreadSummary {
        const entry = try self.zone_thread_summaries.getOrPut(self.allocator, thread);
        if (!entry.found_existing) entry.value_ptr.* = .{ .thread = thread };
        return entry.value_ptr;
    }

    pub fn collectZones(self: *Analyzer) !std.ArrayListUnmanaged(ZoneSummary) {
        var zones: std.ArrayListUnmanaged(ZoneSummary) = .empty;
        var iter = self.zone_summaries.valueIterator();
        while (iter.next()) |zone| {
            std.mem.sort(u64, zone.durations_ns.items, {}, durationLessThan);
            try zones.append(self.allocator, zone.*);
        }
        std.mem.sort(ZoneSummary, zones.items, {}, zoneGreaterThan);
        return zones;
    }

    pub fn collectZonePrefixes(self: *Analyzer) !std.ArrayListUnmanaged(ZonePrefixSummary) {
        var prefixes: std.ArrayListUnmanaged(ZonePrefixSummary) = .empty;
        var iter = self.zone_prefix_summaries.valueIterator();
        while (iter.next()) |prefix| try prefixes.append(self.allocator, prefix.*);
        std.mem.sort(ZonePrefixSummary, prefixes.items, {}, zonePrefixGreaterThan);
        return prefixes;
    }

    pub fn collectZoneThreads(self: *Analyzer) !std.ArrayListUnmanaged(ZoneThreadSummary) {
        var threads: std.ArrayListUnmanaged(ZoneThreadSummary) = .empty;
        var iter = self.zone_thread_summaries.valueIterator();
        while (iter.next()) |thread| try threads.append(self.allocator, thread.*);
        std.mem.sort(ZoneThreadSummary, threads.items, {}, zoneThreadGreaterThan);
        return threads;
    }

    pub fn collectPlots(self: *Analyzer) !std.ArrayListUnmanaged(PlotSummary) {
        return try self.plots.collectSummaries(self.allocator, .{ .sort = .samples });
    }

    pub fn collectMemory(self: *Analyzer) !std.ArrayListUnmanaged(MemorySummary) {
        return try self.memory.collectSummaries(self.allocator, .{ .sort = .high_water });
    }

    pub fn collectSamples(self: *Analyzer) !std.ArrayListUnmanaged(SampleSummary) {
        return try self.samples.collectSummaries(self.allocator, .{ .sort = .samples });
    }

    pub fn collectLocks(self: *Analyzer) !std.ArrayListUnmanaged(LockSummary) {
        return try self.locks.collectRows(self.allocator, .{ .sort = .wait });
    }

    pub fn collectFibers(self: *Analyzer) !std.ArrayListUnmanaged(FiberSummary) {
        return try self.fibers.collectSummaries(self.allocator, .{ .sort = .running });
    }

    pub fn collectGpu(self: *Analyzer) !std.ArrayListUnmanaged(GpuSummary) {
        return try self.gpu.collectSummaries(self.allocator, .{ .sort = .gpu });
    }

    pub fn collectSystem(self: *Analyzer) !std.ArrayListUnmanaged(SystemSummary) {
        return try self.system.collectSummaries(self.allocator, .{ .sort = .count });
    }

    pub fn collectContext(self: *Analyzer) !std.ArrayListUnmanaged(ContextSummary) {
        return try self.context.collectSummaries(self.allocator, .{ .sort = .running });
    }

    pub fn durationNs(self: Analyzer) u64 {
        const start_ns = self.start_ns orelse return 0;
        const end_ns = self.end_ns orelse return 0;
        if (end_ns <= start_ns) return 0;
        return end_ns - start_ns;
    }
};

pub fn writeSummaryFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try ingestPath(&analyzer, path);
    try analyzer.writeSummary(writer, options);
}

pub fn writeSummaryJsonlFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try ingestPath(&analyzer, path);
    try analyzer.writeSummaryJsonl(writer, options);
}

pub fn ingestPath(analyzer: *Analyzer, path: []const u8) !void {
    var file = try sys.fs.cwd().openFile(sys.fs.debugIo(), path, .{});
    defer file.close(sys.fs.debugIo());

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(sys.fs.debugIo(), &buffer);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        const actual = line orelse break;
        try analyzer.ingestJsonLine(actual);
    }
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
}

fn writeCaptureFields(
    object: pretty_json.Object,
    analyzer: *const Analyzer,
    zone_prefixes: usize,
    zone_threads: usize,
) !void {
    try object.field("events", analyzer.capture.counters.events);
    try object.field("zones", analyzer.counters.completed_zones);
    try object.field("zone_duration_samples", analyzer.counters.zone_duration_samples);
    try object.field(
        "zone_timestamp_regressions",
        analyzer.counters.zone_timestamp_regressions,
    );
    try object.field("zone_duration_evidence", analyzer.zoneDurationEvidence());
    try object.field("zone_prefixes", zone_prefixes);
    try object.field("zone_threads", zone_threads);
    try object.field("active_zones", analyzer.active_zones.count());
    try object.field("messages", analyzer.counters.messages);
    try object.field("frames", analyzer.counters.frames);
    try object.field("plots", analyzer.counters.plots);
    try object.field("plot_configurations", analyzer.counters.plot_configurations);
    try object.field(
        "plot_configuration_conflicts",
        analyzer.counters.plot_configuration_conflicts,
    );
    try object.field("samples", analyzer.counters.samples);
    try object.field("sample_frames", analyzer.counters.sample_frames);
    try object.field("fiber_enters", analyzer.fibers.counters.enters);
    try object.field("fiber_leaves", analyzer.fibers.counters.leaves);
    try object.field("fiber_names", analyzer.fibers.counters.names);
    try object.field("fiber_running_ns", analyzer.fibers.runningNs());
    try object.field("fiber_unmatched_leaves", analyzer.fibers.counters.unmatched_leaves);
}

fn writeGpuCaptureFields(object: pretty_json.Object, analyzer: *const Analyzer) !void {
    const counters = analyzer.gpu.counters;
    try object.field("gpu_contexts", analyzer.gpu.contexts.count());
    try object.field("gpu_zones", counters.zone_begins);
    try object.field("gpu_completed_zones", counters.completed_zones);
    try object.field("gpu_duration_samples", counters.gpu_duration_samples);
    try object.field("gpu_cpu_duration_samples", counters.cpu_duration_samples);
    try object.field("gpu_times", counters.gpu_times);
    try object.field("gpu_annotations", counters.annotations);
    try object.field("gpu_ns", analyzer.gpu.gpuNs());
    try object.field("gpu_cpu_ns", analyzer.gpu.cpuNs());
    try object.field("gpu_unmatched_ends", counters.unmatched_ends);
    try object.field("gpu_unmatched_times", counters.unmatched_times);
    try object.field("gpu_duplicate_queries", counters.duplicate_queries);
    try object.field("gpu_duplicate_times", counters.duplicate_times);
    try object.field("gpu_timestamp_regressions", counters.gpu_timestamp_regressions);
    try object.field(
        "gpu_cpu_timestamp_regressions",
        counters.cpu_timestamp_regressions,
    );
    try object.field("gpu_duration_population", "completed_valid_pairs");
    try object.field("gpu_duration_evidence", analyzer.gpuDurationEvidence());
}

fn writeSystemCaptureFields(object: pretty_json.Object, analyzer: *const Analyzer) !void {
    try object.field("system_thread_contexts", analyzer.counters.system_thread_contexts);
    try object.field("system_thread_pid_maps", analyzer.counters.system_thread_pid_maps);
    try object.field("system_cpu_topology", analyzer.counters.system_cpu_topology);
    try object.field("system_sys_time", analyzer.counters.system_sys_time);
    try object.field("system_sys_power", analyzer.counters.system_sys_power);
    try object.field("system_computed_power", analyzer.counters.system_computed_power);
    try object.field("system_hw_samples", analyzer.counters.system_hw_samples);
}

fn writeContextCaptureFields(object: pretty_json.Object, analyzer: *const Analyzer) !void {
    const counters = analyzer.context.counters;
    try object.field("context_switches", counters.switches);
    try object.field("thread_wakeups", counters.wakeups);
    try object.field("context_running_ns", analyzer.context.runningNs());
    try object.field("context_blocked_ns", analyzer.context.blockedNs());
    try object.field("context_ready_ns", analyzer.context.readyNs());
    try object.field("context_unknown_off_cpu_ns", analyzer.context.unknownOffCpuNs());
    try object.field("context_ready_latency_samples", counters.ready_latency_samples);
    try object.field("context_redundant_wakeups", counters.redundant_wakeups);
    try object.field("context_ready_time_regressions", counters.ready_time_regressions);
    try object.field(
        "context_pending_ready_intervals",
        analyzer.context.pendingReadyIntervals(),
    );
    try object.field("context_ready_latency_evidence", analyzer.context.readyLatencyEvidence());
}

fn writeMemoryCaptureFields(object: pretty_json.Object, analyzer: *const Analyzer) !void {
    const counters = analyzer.memory.counters;
    try object.field("allocations", counters.allocations);
    try object.field("frees", counters.frees);
    try object.field("live_bytes", counters.live_bytes);
    try object.field("high_water_live_bytes", counters.high_water_live_bytes);
    try object.field("allocated_bytes", counters.allocated_bytes);
    try object.field("freed_bytes", counters.freed_bytes);
    try object.field("completed_lifetimes", counters.completed_lifetimes);
    try object.field("lifetime_samples", counters.lifetime_samples);
    try object.field("right_censored_allocations", analyzer.memory.active.count());
    try object.field("unmatched_frees", counters.unmatched_frees);
    try object.field("duplicate_allocations", counters.duplicate_allocations);
    try object.field("memory_timestamp_regressions", counters.timestamp_regressions);
    try object.field("untracked_allocations", counters.untracked_allocations);
    try object.field("size_mismatches", counters.size_mismatches);
    try object.field("unmatched_zone_ends", analyzer.counters.unmatched_zone_ends);
}

fn writeLockCaptureFields(object: pretty_json.Object, analyzer: *const Analyzer) !void {
    const counters = analyzer.locks.counters;
    try object.field("locks", analyzer.locks.locks.count());
    try object.field("lock_waits", counters.completed_waits);
    try object.field("lock_holds", counters.completed_holds);
    try object.field("lock_wait_samples", counters.wait_samples);
    try object.field("lock_hold_samples", counters.hold_samples);
    try object.field("lock_pending_waits", analyzer.locks.pending_waits.count());
    try object.field("lock_pending_holds", analyzer.locks.pending_holds.count());
    try object.field("lock_duplicate_waits", counters.duplicate_waits);
    try object.field("lock_duplicate_obtains", counters.duplicate_obtains);
    try object.field("lock_timestamp_regressions", counters.timestamp_regressions);
    try object.field("lock_unmatched_releases", counters.unmatched_releases);
    try object.field("lock_duration_evidence", analyzer.locks.durationEvidence());
}

fn writePlotSummaryText(writer: *std.Io.Writer, plot: PlotSummary) !void {
    try writer.writeAll("plot name=");
    try pretty_json.writeString(writer, plot.name);
    try writer.print(
        " count={d} min={d} max={d} last={d} mean={d} configured={} " ++
            "configurations={d} configuration_conflicts={d}",
        .{
            plot.count,
            plot.min,
            plot.max,
            plot.last,
            plot.mean,
            plot.configured,
            plot.configurations,
            plot.configuration_conflicts,
        },
    );
    if (plot.kind) |kind| {
        try writer.writeAll(" kind=");
        try pretty_json.writeString(writer, kind);
    }
    if (plot.unit) |unit| {
        try writer.writeAll(" unit=");
        try pretty_json.writeString(writer, unit);
    }
    try writer.print(" step={} fill={}", .{ plot.step, plot.fill });
    if (plot.color) |color| try writer.print(" color={d}", .{color});
    try writer.writeByte('\n');
}

fn writePlotSummaryJson(writer: *std.Io.Writer, plot: PlotSummary) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("kind", "plot");
    try object.field("name", plot.name);
    if (plot.kind) |kind| try object.field("plot_kind", kind);
    try object.field("unit", plot.unit);
    try object.field("configured", plot.configured);
    try object.field("step", plot.step);
    try object.field("fill", plot.fill);
    try object.field("color", plot.color);
    try object.field("configurations", plot.configurations);
    try object.field("configuration_conflicts", plot.configuration_conflicts);
    try object.field("count", plot.count);
    try object.field("min", plot.min);
    try object.field("max", plot.max);
    try object.field("last", plot.last);
    try object.field("mean", plot.mean);
    try object.endLine();
}

fn writeGpuCaptureText(writer: *std.Io.Writer, analyzer: *const Analyzer) !void {
    const counters = analyzer.gpu.counters;
    try writer.print(
        "tracy gpu_contexts={d} gpu_zones={d} gpu_completed_zones={d} " ++
            "gpu_duration_samples={d} gpu_cpu_duration_samples={d} gpu_times={d} " ++
            "gpu_annotations={d} gpu_ns={d} gpu_cpu_ns={d} gpu_unmatched_ends={d} " ++
            "gpu_unmatched_times={d} gpu_duplicate_queries={d} gpu_duplicate_times={d} " ++
            "gpu_timestamp_regressions={d} gpu_cpu_timestamp_regressions={d} " ++
            "gpu_duration_population=completed_valid_pairs gpu_duration_evidence={s}\n",
        .{
            analyzer.gpu.contexts.count(),      counters.zone_begins,
            counters.completed_zones,           counters.gpu_duration_samples,
            counters.cpu_duration_samples,      counters.gpu_times,
            counters.annotations,               analyzer.gpu.gpuNs(),
            analyzer.gpu.cpuNs(),               counters.unmatched_ends,
            counters.unmatched_times,           counters.duplicate_queries,
            counters.duplicate_times,           counters.gpu_timestamp_regressions,
            counters.cpu_timestamp_regressions, analyzer.gpuDurationEvidence(),
        },
    );
}

fn writeGpuSummaryText(writer: *std.Io.Writer, row: GpuSummary) !void {
    try writer.writeAll("gpu label=");
    try pretty_json.writeString(writer, row.label);
    try writer.print(
        " count={d} gpu_ns={d} cpu_ns={d} zones={d} completed_zones={d}",
        .{ row.count, row.gpu_ns, row.cpu_ns, row.zones, row.completed_zones },
    );
    try gpu_mod.writeDurationFieldsText(writer, row);
    if (row.context) |context| try writer.print(" context={d}", .{context});
    if (row.thread) |thread| try writer.print(" thread={d}", .{thread});
    if (row.annotations != 0) try writer.print(" annotations={d}", .{row.annotations});
    try writer.writeByte('\n');
}

fn writeGpuSummaryJson(writer: *std.Io.Writer, row: GpuSummary) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("kind", "gpu");
    try object.field("label", row.label);
    try object.field("count", row.count);
    try object.field("gpu_ns", row.gpu_ns);
    try object.field("cpu_ns", row.cpu_ns);
    try object.field("zones", row.zones);
    try object.field("completed_zones", row.completed_zones);
    try gpu_mod.writeDurationFields(object, row);
    if (row.context) |context| try object.field("context", context);
    if (row.thread) |thread| try object.field("thread", thread);
    if (row.annotations != 0) try object.field("annotations", row.annotations);
    try object.endLine();
}

fn writeMemorySummaryText(writer: *std.Io.Writer, item: MemorySummary) !void {
    try writer.writeAll("memory name=");
    try pretty_json.writeString(writer, item.name);
    try writer.print(
        " live_bytes={d} high_water_live_bytes={d} allocated_bytes={d} " ++
            "freed_bytes={d} allocations={d} frees={d} " ++
            "right_censored_allocations={d} completed_lifetimes={d} " ++
            "lifetime_samples={d} lifetime_mean_ns={d} lifetime_min_ns={d} " ++
            "lifetime_p50_ns={d} lifetime_p90_ns={d} lifetime_p99_ns={d} " ++
            "lifetime_max_ns={d}\n",
        .{
            item.live_bytes,         item.high_water_live_bytes,
            item.allocated_bytes,    item.freed_bytes,
            item.allocations,        item.frees,
            item.active_allocations, item.completed_lifetimes,
            item.lifetime_samples,   item.meanLifetimeNs(),
            item.min_lifetime_ns,    item.p50_lifetime_ns,
            item.p90_lifetime_ns,    item.p99_lifetime_ns,
            item.max_lifetime_ns,
        },
    );
}

fn writeMemorySummaryJson(writer: *std.Io.Writer, item: MemorySummary) !void {
    var stream = pretty_json.Writer.init(writer, .minified);
    const object = try stream.object();
    try object.field("kind", "memory");
    try object.field("name", item.name);
    try object.field("live_bytes", item.live_bytes);
    try object.field("high_water_live_bytes", item.high_water_live_bytes);
    try object.field("allocated_bytes", item.allocated_bytes);
    try object.field("freed_bytes", item.freed_bytes);
    try object.field("allocations", item.allocations);
    try object.field("frees", item.frees);
    try object.field("right_censored_allocations", item.active_allocations);
    try object.field("completed_lifetimes", item.completed_lifetimes);
    try object.field("lifetime_samples", item.lifetime_samples);
    try object.field("lifetime_mean_ns", item.meanLifetimeNs());
    try object.field("lifetime_min_ns", item.min_lifetime_ns);
    try object.field("lifetime_p50_ns", item.p50_lifetime_ns);
    try object.field("lifetime_p90_ns", item.p90_lifetime_ns);
    try object.field("lifetime_p99_ns", item.p99_lifetime_ns);
    try object.field("lifetime_max_ns", item.max_lifetime_ns);
    try object.endLine();
}

fn writeContextLatencyText(writer: *std.Io.Writer, row: context_mod.Summary) !void {
    if (row.ready_latency_samples == 0) return;
    try writer.print(
        " ready_latency_samples={d} ready_latency_mean_ns={d} " ++
            "ready_latency_min_ns={d} ready_latency_p50_ns={d} " ++
            "ready_latency_p90_ns={d} ready_latency_p99_ns={d} " ++
            "ready_latency_max_ns={d}",
        .{
            row.ready_latency_samples,
            row.ready_latency_mean_ns,
            row.ready_latency_min_ns,
            row.ready_latency_p50_ns,
            row.ready_latency_p90_ns,
            row.ready_latency_p99_ns,
            row.ready_latency_max_ns,
        },
    );
}

fn writeContextLatencyFields(object: pretty_json.Object, row: context_mod.Summary) !void {
    if (row.ready_latency_samples == 0) return;
    try object.field("ready_latency_samples", row.ready_latency_samples);
    try object.field("ready_latency_mean_ns", row.ready_latency_mean_ns);
    try object.field("ready_latency_min_ns", row.ready_latency_min_ns);
    try object.field("ready_latency_p50_ns", row.ready_latency_p50_ns);
    try object.field("ready_latency_p90_ns", row.ready_latency_p90_ns);
    try object.field("ready_latency_p99_ns", row.ready_latency_p99_ns);
    try object.field("ready_latency_max_ns", row.ready_latency_max_ns);
}

fn systemGroupTag(group: system_mod.Group) []const u8 {
    return switch (group) {
        .kind => "kind",
        .thread => "thread",
        .cpu => "cpu",
        .address => "address",
        .topology => "topology",
        .name => "name",
        .none => "none",
    };
}

fn writeSystemSummaryTextFields(writer: *std.Io.Writer, row: SystemSummary) !void {
    if (row.kind) |kind| {
        try writer.writeAll(" kind=");
        try pretty_json.writeString(writer, kind);
    }
    if (row.thread) |thread| try writer.print(" thread={d}", .{thread});
    if (row.pid) |pid| try writer.print(" pid={d}", .{pid});
    if (row.cpu) |cpu| try writer.print(" cpu={d}", .{cpu});
    if (row.cpu_package) |package| try writer.print(" cpu_package={d}", .{package});
    if (row.cpu_die) |die| try writer.print(" cpu_die={d}", .{die});
    if (row.cpu_core) |core| try writer.print(" cpu_core={d}", .{core});
    if (row.address) |address| try writer.print(" address=0x{x}", .{address});
    if (row.value_count != 0) {
        try writer.print(
            " values={d} value_min={d} value_max={d} value_mean={d}",
            .{ row.value_count, row.value_min, row.value_max, row.valueMean() },
        );
    }
    if (row.value_last) |value| try writer.print(" value_last={d}", .{value});
    if (row.power_delta_uj != 0) try writer.print(" power_delta_uj={d}", .{row.power_delta_uj});
    if (row.first_ns != 0) try writer.print(" first_ns={d}", .{row.first_ns});
    if (row.last_ns != 0) try writer.print(" last_ns={d}", .{row.last_ns});
}

fn writeSystemSummaryFields(object: pretty_json.Object, row: SystemSummary) !void {
    if (row.kind) |kind| try object.field("system_kind", kind);
    if (row.thread) |thread| try object.field("thread", thread);
    if (row.pid) |pid| try object.field("pid", pid);
    if (row.cpu) |cpu| try object.field("cpu", cpu);
    if (row.cpu_package) |package| try object.field("cpu_package", package);
    if (row.cpu_die) |die| try object.field("cpu_die", die);
    if (row.cpu_core) |core| try object.field("cpu_core", core);
    if (row.address) |address| try object.field("address", address);
    if (row.value_count != 0) {
        try object.field("values", row.value_count);
        try object.field("value_min", row.value_min);
        try object.field("value_max", row.value_max);
        try object.field("value_mean", row.valueMean());
    }
    if (row.value_last) |value| try object.field("value_last", value);
    if (row.power_delta_uj != 0) try object.field("power_delta_uj", row.power_delta_uj);
    if (row.first_ns != 0) try object.field("first_ns", row.first_ns);
    if (row.last_ns != 0) try object.field("last_ns", row.last_ns);
}

fn zoneGreaterThan(_: void, left: ZoneSummary, right: ZoneSummary) bool {
    if (left.total_ns != right.total_ns) return left.total_ns > right.total_ns;
    if (left.count != right.count) return left.count > right.count;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn zonePrefixGreaterThan(_: void, left: ZonePrefixSummary, right: ZonePrefixSummary) bool {
    if (left.total_ns != right.total_ns) return left.total_ns > right.total_ns;
    if (left.count != right.count) return left.count > right.count;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn zoneThreadGreaterThan(_: void, left: ZoneThreadSummary, right: ZoneThreadSummary) bool {
    if (left.total_ns != right.total_ns) return left.total_ns > right.total_ns;
    if (left.count != right.count) return left.count > right.count;
    return left.thread < right.thread;
}

fn durationLessThan(_: void, left: u64, right: u64) bool {
    return left < right;
}

test "capture integrity accepts one contiguous trace lifecycle" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .message }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .stop }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    const integrity = analyzer.captureIntegrity();
    try std.testing.expectEqualStrings("complete", integrity.status);
    try std.testing.expect(integrity.message == null);
    try std.testing.expectEqual(@as(u64, 3), integrity.sequenced_event_count);
    try std.testing.expectEqual(@as(?u64, 1), integrity.first_sequence);
    try std.testing.expectEqual(@as(?u64, 3), integrity.last_sequence);
    try std.testing.expectEqualStrings("complete", analyzer.context.captureIntegrity().status);
}

test "summary preserves context ready latency evidence" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 10 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 2,
        .kind = .thread_wakeup,
        .time_ns = 20,
        .target_thread = 7,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 3,
        .kind = .context_switch,
        .time_ns = 70,
        .prev_thread = 8,
        .next_thread = 7,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .stop, .time_ns = 80 })
        .writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqualStrings("complete", analyzer.context.readyLatencyEvidence());
    try std.testing.expectEqual(@as(u64, 1), analyzer.context.counters.ready_latency_samples);

    var text = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text.deinit();
    try analyzer.writeSummary(&text.writer, .{});
    try std.testing.expect(std.mem.indexOf(
        u8,
        text.written(),
        "context_ready_latency_evidence=complete",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text.written(),
        "ready_latency_p99_ns=50",
    ) != null);

    var jsonl = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer jsonl.deinit();
    try analyzer.writeSummaryJsonl(&jsonl.writer, .{});
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl.written(),
        "\"context_ready_latency_evidence\":\"complete\"",
    ) != null);
}

test "summary preserves lock duration evidence" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 10 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 2,
        .kind = .lock_announce,
        .time_ns = 15,
        .thread = 7,
        .id = 9,
        .name = "queue",
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .lock_wait, .time_ns = 20, .thread = 7, .id = 9 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .lock_obtain, .time_ns = 70, .thread = 7, .id = 9 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .lock_release, .time_ns = 100, .thread = 7, .id = 9 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .stop, .time_ns = 110 })
        .writeJsonLine(&trace.writer);
    const flight_report = summaryLockFlightReport();
    try flight_report.writeJsonl(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqualStrings("complete", analyzer.locks.durationEvidence());
    try std.testing.expectEqualDeep(
        flight_report,
        analyzer.locks.captureIntegrity().flight_report.?,
    );
    try std.testing.expectEqualDeep(
        flight_report,
        analyzer.memory.captureIntegrity().flight_report.?,
    );
    try std.testing.expectEqual(@as(u64, 1), analyzer.locks.counters.wait_samples);
    try std.testing.expectEqual(@as(u64, 1), analyzer.locks.counters.hold_samples);
    var rows = try analyzer.collectLocks();
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 50), rows.items[0].wait_p99_ns);
    try std.testing.expectEqual(@as(u64, 30), rows.items[0].hold_p99_ns);

    var text = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text.deinit();
    try analyzer.writeSummary(&text.writer, .{});
    try std.testing.expect(std.mem.indexOf(
        u8,
        text.written(),
        "lock_duration_evidence=complete",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "wait_p99_ns=50") != null);

    var jsonl = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer jsonl.deinit();
    try analyzer.writeSummaryJsonl(&jsonl.writer, .{});
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl.written(),
        "\"lock_duration_evidence\":\"complete\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl.written(), "\"hold_p99_ns\":30") != null);
}

fn summaryLockFlightReport() transport.Report {
    return .{
        .policy = .overwrite_oldest,
        .state = .accepting,
        .capacity_bytes = 64,
        .retained_bytes = 32,
        .event_capacity_bytes = 16,
        .writer_capacity_bytes = 8,
        .observed_events = 6,
        .stored_events = 6,
        .retained_events = 6,
        .overwritten_events = 0,
        .dropped_events = 0,
        .oversized_events = 0,
        .partial_event_bytes = 0,
        .discarding_oversized_event = false,
    };
}

test "capture integrity counts sequence gaps as lower bound missing rows" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .message }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .stop }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    const integrity = analyzer.captureIntegrity();
    try std.testing.expectEqualStrings("sequence_gaps", integrity.status);
    try std.testing.expectEqual(@as(u64, 2), integrity.sequence_gap_count);
    try std.testing.expectEqual(@as(u64, 4), integrity.missing_sequence_event_count);

    var jsonl = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer jsonl.deinit();
    try analyzer.writeSummaryJsonl(&jsonl.writer, .{});
    var lines = std.mem.splitScalar(u8, jsonl.written(), '\n');
    const summary_line = lines.next().?;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        summary_line,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl.written(),
        "\"capture_integrity\":{\"method\":\"tracy_event_sequence_and_lifecycle_v1\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl.written(),
        "\"missing_sequence_event_count\":4",
    ) != null);

    var text = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text.deinit();
    try analyzer.writeSummary(&text.writer, .{});
    try std.testing.expect(std.mem.indexOf(
        u8,
        text.written(),
        "capture_integrity=sequence_gaps",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "first_sequence=1") != null);
}

test "capture integrity classifies metadata lifecycle and balance failures" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try std.testing.expectEqualStrings("no_events", analyzer.captureIntegrity().status);

    analyzer.capture.counters.events = 2;
    analyzer.capture.counters.unsequenced_events = 2;
    try std.testing.expectEqualStrings(
        "missing_sequence_metadata",
        analyzer.captureIntegrity().status,
    );

    analyzer.capture.counters.unsequenced_events = 0;
    analyzer.capture.counters.sequenced_events = 2;
    analyzer.capture.first_sequence = 1;
    analyzer.capture.last_sequence = 2;
    analyzer.capture.counters.start_events = 1;
    analyzer.capture.start_sequence = 1;
    try std.testing.expectEqualStrings("missing_stop_event", analyzer.captureIntegrity().status);

    analyzer.capture.counters.stop_events = 1;
    analyzer.capture.stop_sequence = 2;
    analyzer.counters.unmatched_zone_ends = 1;
    try std.testing.expectEqualStrings("unbalanced_events", analyzer.captureIntegrity().status);

    analyzer.capture.stop_sequence = 1;
    try std.testing.expectEqualStrings("lifecycle_not_bounded", analyzer.captureIntegrity().status);

    analyzer.capture.counters.sequence_regressions = 1;
    try std.testing.expectEqualStrings(
        "non_monotonic_sequence",
        analyzer.captureIntegrity().status,
    );
}

test "capture integrity rejects active fiber and gpu lifecycles" {
    var fiber_trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer fiber_trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start }).writeJsonLine(&fiber_trace.writer);
    try (event.TraceEvent{
        .seq = 2,
        .kind = .fiber_enter,
        .thread = 1,
        .id = 7,
    }).writeJsonLine(&fiber_trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .stop }).writeJsonLine(&fiber_trace.writer);
    var fiber_analyzer = Analyzer.init(std.testing.allocator);
    defer fiber_analyzer.deinit();
    try fiber_analyzer.ingestJsonlBytes(fiber_trace.written());
    try std.testing.expectEqualStrings(
        "unbalanced_events",
        fiber_analyzer.captureIntegrity().status,
    );

    var gpu_trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer gpu_trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start }).writeJsonLine(&gpu_trace.writer);
    try (event.TraceEvent{
        .seq = 2,
        .kind = .gpu_zone_begin,
        .thread = 1,
        .gpu_context = 1,
        .gpu_query = 2,
    }).writeJsonLine(&gpu_trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .stop }).writeJsonLine(&gpu_trace.writer);
    var gpu_analyzer = Analyzer.init(std.testing.allocator);
    defer gpu_analyzer.deinit();
    try gpu_analyzer.ingestJsonlBytes(gpu_trace.written());
    try std.testing.expectEqualStrings(
        "unbalanced_events",
        gpu_analyzer.captureIntegrity().status,
    );
}

test "summary excludes regressed zone timestamps from duration samples" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    const rows = [_]event.TraceEvent{
        .{ .seq = 1, .kind = .start, .time_ns = 10 },
        .{
            .seq = 2,
            .kind = .zone_begin,
            .time_ns = 100,
            .thread = 7,
            .id = 1,
            .name = "agent.phase",
        },
        .{ .seq = 3, .kind = .zone_end, .time_ns = 90, .thread = 7, .id = 1 },
        .{ .seq = 4, .kind = .stop, .time_ns = 110 },
    };
    for (rows) |row| try row.writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    const zone = analyzer.zone_summaries.get("agent.phase").?;
    try std.testing.expectEqual(@as(u64, 1), zone.count);
    try std.testing.expectEqual(@as(u64, 0), zone.duration_samples);
    try std.testing.expectEqual(@as(u64, 0), zone.total_ns);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.zone_timestamp_regressions);
    try std.testing.expectEqualStrings("complete", analyzer.captureIntegrity().status);
    try std.testing.expectEqualStrings("partial", analyzer.zoneDurationEvidence());

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try analyzer.writeSummaryJsonl(&output.writer, .{});
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "\"zone_duration_evidence\":\"partial\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "\"count\":1,\"duration_samples\":0") != null,
    );
}

test "summary aggregates zones, plots, and allocation pressure" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 100, .thread = 1, .name = "test" }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .thread_name, .time_ns = 105, .thread = 1, .name = "main" }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_begin, .time_ns = 110, .thread = 1, .id = 7, .name = "agent.phase", .file = "phase.zig", .line = 9 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .zone_end, .time_ns = 160, .thread = 1, .id = 7 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .plot, .time_ns = 170, .thread = 1, .name = "sample.ns", .value_i64 = 12, .plot_kind = "int" }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .alloc, .time_ns = 180, .thread = 1, .name = "arena", .address = 4096, .size = 64 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .free, .time_ns = 190, .thread = 1, .name = "arena", .address = 4096 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .sample, .time_ns = 195, .thread = 1, .id = 3, .name = "tick", .file = "phase.zig", .line = 9, .sample_kind = "cpu" }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 8, .kind = .sample_frame, .time_ns = 195, .thread = 1, .id = 3, .name = "tick", .file = "phase.zig", .line = 9, .sample_kind = "cpu" }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 9, .kind = .context_switch, .time_ns = 196, .thread = 1, .cpu = 0, .next_thread = 10 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 10, .kind = .thread_wakeup, .time_ns = 197, .thread = 1, .target_thread = 10, .cpu = 0 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 11, .kind = .gpu_context, .time_ns = 198, .thread = 1, .gpu_context = 1, .gpu_period = 1.0 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 12, .kind = .gpu_zone_begin, .time_ns = 199, .thread = 1, .gpu_context = 1, .gpu_query = 10, .name = "draw" }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 13, .kind = .gpu_zone_end, .time_ns = 210, .thread = 1, .gpu_context = 1, .gpu_query = 11 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 14, .kind = .gpu_time, .time_ns = 211, .thread = 1, .gpu_context = 1, .gpu_query = 10, .gpu_time = 100 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 15, .kind = .gpu_time, .time_ns = 212, .thread = 1, .gpu_context = 1, .gpu_query = 11, .gpu_time = 140 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 16, .kind = .thread_pid, .time_ns = 213, .thread = 10, .pid = 900 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 17, .kind = .cpu_topology, .time_ns = 214, .thread = 1, .cpu = 0, .cpu_package = 1, .cpu_die = 0, .cpu_core = 2 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 18, .kind = .sys_time, .time_ns = 215, .thread = 1, .value_f64 = 0.25 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 19, .kind = .sys_power, .time_ns = 216, .thread = 1, .name = "package", .power_delta_uj = 100 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 20, .kind = .hw_sample, .time_ns = 217, .thread = 10, .cpu = 0, .address = 0x1234, .hw_sample_kind = "cache-miss" }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 21, .kind = .lock_announce, .time_ns = 218, .thread = 1, .id = 44, .name = "scheduler-lock", .lock_kind = "lock" }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 22, .kind = .lock_wait, .time_ns = 219, .thread = 1, .id = 44 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 23, .kind = .lock_obtain, .time_ns = 229, .thread = 1, .id = 44 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 24, .kind = .lock_release, .time_ns = 245, .thread = 1, .id = 44 }).writeJsonLine(&out.writer);
    try (event.TraceEvent{ .seq = 25, .kind = .stop, .time_ns = 250, .thread = 1 }).writeJsonLine(&out.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(out.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.completed_zones);
    try std.testing.expectEqual(@as(u64, 50), analyzer.zone_summaries.get("agent.phase").?.total_ns);
    try std.testing.expectEqual(@as(u64, 50), analyzer.zone_summaries.get("agent.phase").?.percentileNs(50));
    try std.testing.expectEqual(@as(u64, 50), analyzer.zone_prefix_summaries.get("agent").?.total_ns);
    try std.testing.expectEqual(@as(u64, 50), analyzer.zone_thread_summaries.get(1).?.total_ns);
    try std.testing.expectEqualStrings("main", analyzer.zone_thread_summaries.get(1).?.name.?);
    try std.testing.expectEqual(@as(u64, 64), analyzer.memory.counters.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 64), analyzer.memory.counters.freed_bytes);
    try std.testing.expectEqual(@as(u64, 0), analyzer.memory.counters.live_bytes);
    try std.testing.expectEqual(@as(u64, 64), analyzer.memory.summaries.get("arena").?.high_water_live_bytes);
    try std.testing.expectEqual(@as(u64, 1), analyzer.samples.counters.samples);
    try std.testing.expectEqual(@as(u64, 1), analyzer.samples.counters.frames);
    try std.testing.expectEqual(@as(u64, 1), analyzer.context.counters.switches);
    try std.testing.expectEqual(@as(u64, 1), analyzer.context.counters.wakeups);
    try std.testing.expectEqual(@as(u64, 1), analyzer.gpu.counters.completed_zones);
    try std.testing.expectEqual(@as(u64, 40), analyzer.gpu.gpuNs());
    try std.testing.expectEqual(@as(u64, 1), analyzer.system.counters.thread_pid_maps);
    try std.testing.expectEqual(@as(u64, 1), analyzer.system.counters.cpu_topology);
    try std.testing.expectEqual(@as(u64, 1), analyzer.system.counters.sys_time);
    try std.testing.expectEqual(@as(u64, 1), analyzer.system.counters.sys_power);
    try std.testing.expectEqual(@as(u64, 1), analyzer.system.counters.hw_samples);
    try std.testing.expectEqual(@as(u64, 1), analyzer.locks.counters.completed_waits);
    try std.testing.expectEqual(@as(u64, 1), analyzer.locks.counters.completed_holds);

    var jsonl = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer jsonl.deinit();
    try analyzer.writeSummaryJsonl(&jsonl.writer, .{ .top = 4 });
    const text = jsonl.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"zone\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"p50_ns\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"zone_prefix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"zone_thread\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"sample\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"lock\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"context\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"lock_waits\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"context_switches\":1") != null);
}

test "summary preserves completed GPU duration tails" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 1 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 2,
        .kind = .gpu_zone_begin,
        .time_ns = 100,
        .thread = 1,
        .name = "draw",
        .gpu_context = 1,
        .gpu_query = 10,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 3,
        .kind = .gpu_zone_end,
        .time_ns = 120,
        .thread = 1,
        .gpu_context = 1,
        .gpu_query = 11,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 4,
        .kind = .gpu_time,
        .time_ns = 121,
        .gpu_context = 1,
        .gpu_query = 10,
        .gpu_time = 100,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 5,
        .kind = .gpu_time,
        .time_ns = 122,
        .gpu_context = 1,
        .gpu_query = 11,
        .gpu_time = 140,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .stop, .time_ns = 130 })
        .writeJsonLine(&trace.writer);
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqualStrings("complete", analyzer.gpuDurationEvidence());

    var text = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text.deinit();
    try analyzer.writeSummary(&text.writer, .{});
    try expectSummaryContains(text.written(), "gpu_duration_evidence=complete");
    try expectSummaryContains(text.written(), "gpu_p99_ns=40");
    var jsonl = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer jsonl.deinit();
    try analyzer.writeSummaryJsonl(&jsonl.writer, .{});
    try expectSummaryContains(jsonl.written(), "\"gpu_duration_evidence\":\"complete\"");
    try expectSummaryContains(jsonl.written(), "\"gpu_p99_ns\":40");
}

test "summary marks sized frees without prior allocation unmatched" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .free, .time_ns = 100, .thread = 1, .name = "external", .address = 4096, .size = 96 }).writeJsonLine(&out.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(out.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.memory.counters.frees);
    try std.testing.expectEqual(@as(u64, 96), analyzer.memory.counters.freed_bytes);
    try std.testing.expectEqual(@as(u64, 1), analyzer.memory.counters.unmatched_frees);
    try std.testing.expectEqual(@as(u64, 96), analyzer.memory.summaries.get("external").?.freed_bytes);
}

test "summary preserves completed memory lifetime evidence" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 1 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .message, .time_ns = 10, .text = "load" })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 3,
        .kind = .alloc,
        .time_ns = 100,
        .thread = 1,
        .name = "arena",
        .address = 4096,
        .size = 64,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 4,
        .kind = .free,
        .time_ns = 180,
        .thread = 2,
        .name = "arena",
        .address = 4096,
        .size = 64,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .stop, .time_ns = 200 })
        .writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 5), analyzer.memory.capture.counters.events);
    try std.testing.expectEqualStrings("complete", analyzer.memory.lifetimeEvidence());
    var rows = try analyzer.collectMemory();
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), rows.items[0].lifetime_samples);
    try std.testing.expectEqual(@as(u64, 80), rows.items[0].p99_lifetime_ns);

    var jsonl = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer jsonl.deinit();
    try analyzer.writeSummaryJsonl(&jsonl.writer, .{});
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl.written(),
        "\"memory_lifetime_evidence\":\"complete\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        jsonl.written(),
        "\"lifetime_p99_ns\":80",
    ) != null);
}

test "summary retains plot configuration metadata" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 2,
        .kind = .plot_config,
        .name = "queue.depth",
        .color = 12,
        .plot_unit = "count",
        .plot_step = true,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 3,
        .kind = .plot,
        .name = "queue.depth",
        .value_i64 = 4,
        .plot_kind = "int",
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .stop }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    var jsonl = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer jsonl.deinit();
    try analyzer.writeSummaryJsonl(&jsonl.writer, .{});
    const text = jsonl.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"plot_configurations\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"queue.depth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"unit\":\"count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"configured\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"step\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"color\":12") != null);
}

fn expectSummaryContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
