const std = @import("std");
const sys = @import("sys");
const pretty = @import("pretty");
const pretty_json = pretty.json;
const profile = @import("profile.zig");

pub const schema = "coz.analysis/v2";
pub const support_method = "within_run_experiment_counts";

pub const Options = struct {
    min_delta: u64 = 5,
    min_points: usize = 1,
};

pub const default_max_profile_bytes = 128 * 1024 * 1024;

pub const PointKind = enum {
    throughput,
    latency,
};

pub const SupportStatus = enum {
    point_only,
    unreplicated_curve,
    within_run_repeated_curve,
};

pub const Support = struct {
    status: SupportStatus,
    speedup_point_count: u64,
    experiment_count: u64,
    baseline_experiment_count: u64,
    minimum_experiments_per_point: u64,
};

pub const Measurement = struct {
    virtual_speedup: f64,
    program_speedup: f64,
    experiment_count: u64,
    selected_samples: u64,
    observations: u64,
    duration_ns: u64,
    value_ns: f64,
    throughput_delta: ?u64 = null,
    latency_arrivals: ?u64 = null,
    latency_departures: ?u64 = null,
    latency_outstanding: ?f64 = null,
};

pub const Result = struct {
    kind: PointKind,
    selected: profile.Location,
    progress_point: []const u8,
    baseline_virtual_speedup: f64,
    baseline_value_ns: f64,
    min_program_speedup: f64,
    max_program_speedup: f64,
    total_selected_samples: u64,
    slope: ?f64,
    support: Support,
    measurements: []Measurement,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.selected.file);
        allocator.free(self.progress_point);
        allocator.free(self.measurements);
        self.* = undefined;
    }
};

pub const CaptureIntegrity = struct {
    status: []const u8,
    method: []const u8,
    action: []const u8,
    message: ?[]const u8,
    record_count: u64,
    sample_record_count: u64,
    lost_record_count: u64,
    lost_event_count: u64,
    lost_samples_record_count: u64,
    lost_samples_count: u64,
    throttle_record_count: u64,
    unthrottle_record_count: u64,
    loss_counter_value: ?u64,
    terminal_status: []const u8,
};

pub const Summary = struct {
    capture_integrity: CaptureIntegrity,
    results: []Result,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        for (self.results) |*result| result.deinit(allocator);
        allocator.free(self.results);
        self.* = undefined;
    }

    pub fn writeJson(self: Summary, writer: *std.Io.Writer) !void {
        var stringify = pretty_json.Writer.init(writer, .minified);
        try stringify.beginObject();
        try stringify.objectField("schema");
        try stringify.write(schema);
        try stringify.objectField("capture_integrity");
        try writeCaptureIntegrity(&stringify, self.capture_integrity);
        try stringify.objectField("results");
        try stringify.beginArray();
        for (self.results) |result| {
            try writeResultJson(&stringify, result);
        }
        try stringify.endArray();
        try stringify.endObject();
        try writer.writeByte('\n');
    }

    pub fn writePretty(
        self: Summary,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        options: pretty.LayoutOptions,
    ) !void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const builder = pretty.Builder.init(arena_state.allocator());
        try pretty.write(writer, try summaryDocAlloc(builder, self), options);
    }
};

fn writeResultJson(stringify: *pretty_json.Writer, result: Result) !void {
    try stringify.beginObject();
    try stringify.objectField("selected");
    try writeLocation(stringify, result.selected);
    try writeStringField(stringify, "progress_point", result.progress_point);
    try writeStringField(stringify, "kind", kindName(result.kind));
    try writeStringField(stringify, "goal", goalName(result.kind));
    try writeStringField(stringify, "value_name", valueName(result.kind));
    try stringify.objectField("baseline_virtual_speedup");
    try stringify.write(result.baseline_virtual_speedup);
    try stringify.objectField("baseline_value_ns");
    try stringify.write(result.baseline_value_ns);
    try stringify.objectField(if (result.kind == .throughput)
        "baseline_period_ns"
    else
        "baseline_average_latency_ns");
    try stringify.write(result.baseline_value_ns);
    try stringify.objectField("min_program_speedup");
    try stringify.write(result.min_program_speedup);
    try stringify.objectField("max_program_speedup");
    try stringify.write(result.max_program_speedup);
    try writeU64Field(stringify, "total_selected_samples", result.total_selected_samples);
    try stringify.objectField("slope");
    try stringify.write(result.slope);
    try stringify.objectField("support");
    try writeSupportJson(stringify, result.support);
    try stringify.objectField("measurements");
    try stringify.beginArray();
    for (result.measurements) |measurement| try writeMeasurementJson(stringify, measurement);
    try stringify.endArray();
    try stringify.endObject();
}

fn writeMeasurementJson(stringify: *pretty_json.Writer, measurement: Measurement) !void {
    try stringify.beginObject();
    try stringify.objectField("virtual_speedup");
    try stringify.write(measurement.virtual_speedup);
    try stringify.objectField("program_speedup");
    try stringify.write(measurement.program_speedup);
    try writeU64Field(stringify, "experiment_count", measurement.experiment_count);
    try writeU64Field(stringify, "selected_samples", measurement.selected_samples);
    try writeU64Field(stringify, "observations", measurement.observations);
    try writeU64Field(stringify, "duration_ns", measurement.duration_ns);
    try stringify.objectField("value_ns");
    try stringify.write(measurement.value_ns);
    if (measurement.throughput_delta) |delta| {
        try writeU64Field(stringify, "delta", delta);
        try stringify.objectField("period_ns");
        try stringify.write(measurement.value_ns);
    }
    if (measurement.latency_arrivals) |arrivals| {
        try writeU64Field(stringify, "arrivals", arrivals);
        try stringify.objectField("average_latency_ns");
        try stringify.write(measurement.value_ns);
    }
    if (measurement.latency_departures) |departures| {
        try writeU64Field(stringify, "departures", departures);
    }
    if (measurement.latency_outstanding) |outstanding| {
        try stringify.objectField("outstanding");
        try stringify.write(outstanding);
    }
    try stringify.endObject();
}

fn writeSupportJson(stringify: *pretty_json.Writer, support: Support) !void {
    try stringify.beginObject();
    try writeStringField(stringify, "status", @tagName(support.status));
    try writeStringField(stringify, "method", support_method);
    try writeStringField(stringify, "action", supportAction(support.status));
    try writeU64Field(stringify, "speedup_point_count", support.speedup_point_count);
    try writeU64Field(stringify, "experiment_count", support.experiment_count);
    try writeU64Field(
        stringify,
        "baseline_experiment_count",
        support.baseline_experiment_count,
    );
    try writeU64Field(
        stringify,
        "minimum_experiments_per_point",
        support.minimum_experiments_per_point,
    );
    try stringify.endObject();
}

pub fn supportAction(status: SupportStatus) []const u8 {
    return switch (status) {
        .point_only => "collect_baseline_and_perturbed_points",
        .unreplicated_curve => "collect_repeated_experiments_per_point",
        .within_run_repeated_curve => "validate_with_independent_runs",
    };
}

fn writeCaptureIntegrity(
    stringify: *pretty_json.Writer,
    integrity: CaptureIntegrity,
) !void {
    try stringify.beginObject();
    try writeStringField(stringify, "status", integrity.status);
    try writeStringField(stringify, "method", integrity.method);
    try writeStringField(stringify, "action", integrity.action);
    try stringify.objectField("message");
    try stringify.write(integrity.message);
    try writeU64Field(stringify, "record_count", integrity.record_count);
    try writeU64Field(stringify, "sample_record_count", integrity.sample_record_count);
    try writeU64Field(stringify, "lost_record_count", integrity.lost_record_count);
    try writeU64Field(stringify, "lost_event_count", integrity.lost_event_count);
    try writeU64Field(
        stringify,
        "lost_samples_record_count",
        integrity.lost_samples_record_count,
    );
    try writeU64Field(stringify, "lost_samples_count", integrity.lost_samples_count);
    try writeU64Field(stringify, "throttle_record_count", integrity.throttle_record_count);
    try writeU64Field(
        stringify,
        "unthrottle_record_count",
        integrity.unthrottle_record_count,
    );
    try stringify.objectField("loss_counter_value");
    try stringify.write(integrity.loss_counter_value);
    try writeStringField(stringify, "terminal_status", integrity.terminal_status);
    try stringify.endObject();
}

fn writeStringField(
    stringify: *pretty_json.Writer,
    name: []const u8,
    value: []const u8,
) !void {
    try stringify.objectField(name);
    try stringify.write(value);
}

fn writeU64Field(stringify: *pretty_json.Writer, name: []const u8, value: u64) !void {
    try stringify.objectField(name);
    try stringify.write(value);
}

fn captureIntegrity(sampling_value: ?profile.Sampling) CaptureIntegrity {
    const sampling = sampling_value orelse return integrityResult(
        .{},
        "missing_sampling_summary",
        "sampling_summary_missing",
        "rerun_with_sampling_integrity_enabled",
        "profile has no sampling transport summary",
    );
    if (!samplingCountsValid(sampling)) return integrityResult(
        sampling,
        "invalid_sampling_summary",
        lossCounterMethod(sampling.loss_counter),
        "inspect_profile_artifact_and_rerun",
        "sampling record counts are internally inconsistent",
    );
    if (terminalIntegrity(sampling)) |integrity| return integrity;
    if (samplingLost(sampling)) return integrityResult(
        sampling,
        "sample_loss",
        lossCounterMethod(sampling.loss_counter),
        "repeat_with_lower_sample_rate_or_larger_ring",
        "perf reported lost sampling events",
    );
    if (sampling.throttle_record_count != 0 or sampling.unthrottle_record_count != 0) {
        return integrityResult(
            sampling,
            "sampling_throttled",
            lossCounterMethod(sampling.loss_counter),
            "repeat_with_lower_sample_rate",
            "perf throttled the sampling event",
        );
    }
    return switch (sampling.loss_counter) {
        .available => integrityResult(
            sampling,
            "complete",
            "perf_format_lost_and_record_audit",
            "use_profile",
            null,
        ),
        .unsupported => integrityResult(
            sampling,
            "loss_counter_unavailable",
            "perf_record_audit_without_terminal_counter",
            "treat_as_partial_or_rerun_on_linux_6_plus",
            "kernel did not provide a terminal cumulative loss counter",
        ),
        .read_failed => integrityResult(
            sampling,
            "loss_counter_read_failed",
            "perf_record_audit_after_counter_read_failure",
            "inspect_perf_event_and_rerun",
            "terminal cumulative loss counter could not be read",
        ),
    };
}

fn terminalIntegrity(sampling: profile.Sampling) ?CaptureIntegrity {
    return switch (sampling.terminal_status) {
        .complete => null,
        .not_started => integrityResult(
            sampling,
            "sampling_not_started",
            "sampling_terminal_state",
            "rerun_with_sampling_enabled",
            "profile runtime did not start a sampler",
        ),
        .stop_failed => integrityResult(
            sampling,
            "sampling_stop_failed",
            "sampling_terminal_state",
            "inspect_sampler_shutdown_and_rerun",
            "sampling event could not be stopped before the terminal audit",
        ),
        .drain_failed => integrityResult(
            sampling,
            "sampling_drain_failed",
            "sampling_terminal_state",
            "inspect_perf_ring_and_rerun",
            "perf ring could not be drained at shutdown",
        ),
    };
}

fn samplingCountsValid(sampling: profile.Sampling) bool {
    const known = @as(u128, sampling.sample_record_count) +
        sampling.lost_record_count + sampling.lost_samples_record_count +
        sampling.throttle_record_count + sampling.unthrottle_record_count;
    return known <= sampling.record_count;
}

fn samplingLost(sampling: profile.Sampling) bool {
    if (sampling.lost_record_count != 0 or sampling.lost_event_count != 0) return true;
    if (sampling.lost_samples_record_count != 0 or sampling.lost_samples_count != 0) return true;
    return switch (sampling.loss_counter) {
        .available => |value| value != 0,
        .unsupported, .read_failed => false,
    };
}

fn lossCounterMethod(counter: profile.LossCounter) []const u8 {
    return switch (counter) {
        .available => "perf_format_lost_and_record_audit",
        .unsupported => "perf_record_audit_without_terminal_counter",
        .read_failed => "perf_record_audit_after_counter_read_failure",
    };
}

fn integrityResult(
    sampling: profile.Sampling,
    status: []const u8,
    method: []const u8,
    action: []const u8,
    message: ?[]const u8,
) CaptureIntegrity {
    return .{
        .status = status,
        .method = method,
        .action = action,
        .message = message,
        .record_count = sampling.record_count,
        .sample_record_count = sampling.sample_record_count,
        .lost_record_count = sampling.lost_record_count,
        .lost_event_count = sampling.lost_event_count,
        .lost_samples_record_count = sampling.lost_samples_record_count,
        .lost_samples_count = sampling.lost_samples_count,
        .throttle_record_count = sampling.throttle_record_count,
        .unthrottle_record_count = sampling.unthrottle_record_count,
        .loss_counter_value = switch (sampling.loss_counter) {
            .available => |value| value,
            .unsupported, .read_failed => null,
        },
        .terminal_status = @tagName(sampling.terminal_status),
    };
}

pub const Accumulator = struct {
    current_experiment: ?ExperimentContext = null,
    curves: std.StringHashMapUnmanaged(Curve) = .empty,
    sampling: ?profile.Sampling = null,

    pub fn deinit(self: *Accumulator, allocator: std.mem.Allocator) void {
        self.clearCurrentExperiment(allocator);
        var iter = self.curves.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.curves.deinit(allocator);
        self.* = .{};
    }

    pub fn observe(self: *Accumulator, allocator: std.mem.Allocator, event: profile.Event) !void {
        switch (event) {
            .experiment => |experiment| {
                self.clearCurrentExperiment(allocator);
                const selected_file = try allocator.dupe(u8, experiment.selected.file);
                self.current_experiment = .{
                    .selected = .{
                        .file = selected_file,
                        .line = experiment.selected.line,
                    },
                    .virtual_speedup = experiment.virtual_speedup,
                    .duration_ns = experiment.duration_ns,
                    .selected_samples = experiment.selected_samples,
                };
            },
            .throughput => |throughput| {
                if (self.current_experiment) |experiment| {
                    try self.addThroughput(allocator, experiment, throughput);
                }
            },
            .latency => |latency| {
                if (self.current_experiment) |experiment| {
                    try self.addLatency(allocator, experiment, latency);
                }
            },
            .sampling => |sampling| {
                if (self.sampling != null) return error.DuplicateSamplingSummary;
                self.sampling = sampling;
            },
            .startup, .runtime, .sample => {},
        }
    }

    pub fn summarize(self: *const Accumulator, allocator: std.mem.Allocator, options: Options) !Summary {
        var results: std.ArrayListUnmanaged(Result) = .empty;
        errdefer {
            for (results.items) |*result| result.deinit(allocator);
            results.deinit(allocator);
        }

        var iter = self.curves.valueIterator();
        while (iter.next()) |curve| {
            if (try curve.result(allocator, options)) |result| {
                try results.append(allocator, result);
            }
        }

        std.mem.sort(Result, results.items, {}, resultLessThan);
        return .{
            .capture_integrity = captureIntegrity(self.sampling),
            .results = try results.toOwnedSlice(allocator),
        };
    }

    fn clearCurrentExperiment(self: *Accumulator, allocator: std.mem.Allocator) void {
        if (self.current_experiment) |experiment| {
            allocator.free(experiment.selected.file);
            self.current_experiment = null;
        }
    }

    fn addThroughput(
        self: *Accumulator,
        allocator: std.mem.Allocator,
        experiment: ExperimentContext,
        throughput: profile.Throughput,
    ) !void {
        const curve = try self.getCurve(allocator, .throughput, experiment.selected, throughput.name);
        try curve.addThroughput(
            allocator,
            experiment.virtual_speedup,
            experiment.duration_ns,
            experiment.selected_samples,
            throughput.delta,
        );
    }

    fn addLatency(
        self: *Accumulator,
        allocator: std.mem.Allocator,
        experiment: ExperimentContext,
        latency: profile.Latency,
    ) !void {
        const curve = try self.getCurve(allocator, .latency, experiment.selected, latency.name);
        try curve.addLatency(
            allocator,
            experiment.virtual_speedup,
            experiment.duration_ns,
            experiment.selected_samples,
            latency.arrivals,
            latency.departures,
            latency.outstanding,
        );
    }

    fn getCurve(
        self: *Accumulator,
        allocator: std.mem.Allocator,
        kind: PointKind,
        selected: profile.Location,
        progress_point: []const u8,
    ) !*Curve {
        const key = try std.fmt.allocPrint(
            allocator,
            "{s}\x1f{s}:{d}\x1f{s}",
            .{ kindName(kind), selected.file, selected.line, progress_point },
        );
        var owned_key: ?[]u8 = key;
        errdefer if (owned_key) |remaining| allocator.free(remaining);

        const entry = try self.curves.getOrPut(allocator, key);
        if (entry.found_existing) {
            allocator.free(key);
            owned_key = null;
        } else {
            owned_key = null;
            errdefer {
                if (self.curves.fetchRemove(key)) |removed| allocator.free(removed.key);
            }
            entry.value_ptr.* = try Curve.init(allocator, kind, selected, progress_point);
        }

        return entry.value_ptr;
    }
};

pub fn summarizeJsonLines(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: Options,
) !Summary {
    var accumulator: Accumulator = .{};
    defer accumulator.deinit(allocator);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var parsed = try profile.parseJsonLine(allocator, line);
        defer parsed.deinit(allocator);
        try accumulator.observe(allocator, parsed.event);
    }

    return try accumulator.summarize(allocator, options);
}

pub fn summarizeFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
    options: Options,
) !Summary {
    const bytes = try sys.fs.readFileAlloc(allocator, path, max_bytes);
    defer allocator.free(bytes);
    return try summarizeJsonLines(allocator, bytes, options);
}

const ExperimentContext = struct {
    selected: profile.Location,
    virtual_speedup: f64,
    duration_ns: u64,
    selected_samples: u64,
};

const SpeedupAggregate = struct {
    virtual_speedup: f64,
    experiment_count: u64,
    duration_ns: u64,
    selected_samples: u64,
    observations: u64,
    departures: u64 = 0,
    outstanding_duration_ns: f64 = 0,

    fn addThroughput(self: *SpeedupAggregate, duration_ns: u64, selected_samples: u64, delta: u64) void {
        self.experiment_count +|= 1;
        self.duration_ns += duration_ns;
        self.selected_samples += selected_samples;
        self.observations += delta;
    }

    fn addLatency(self: *SpeedupAggregate, duration_ns: u64, selected_samples: u64, arrivals: u64, departures: u64, outstanding: u64) void {
        self.experiment_count +|= 1;
        self.duration_ns += duration_ns;
        self.selected_samples += selected_samples;
        self.observations += arrivals;
        self.departures += departures;
        self.outstanding_duration_ns += @as(f64, @floatFromInt(outstanding)) * @as(f64, @floatFromInt(duration_ns));
    }

    fn valueNs(self: SpeedupAggregate, kind: PointKind) f64 {
        return switch (kind) {
            .throughput => @as(f64, @floatFromInt(self.duration_ns)) / @as(f64, @floatFromInt(self.observations)),
            .latency => self.outstanding_duration_ns / @as(f64, @floatFromInt(self.observations)),
        };
    }

    fn latencyOutstanding(self: SpeedupAggregate) f64 {
        if (self.duration_ns == 0) return 0;
        return self.outstanding_duration_ns / @as(f64, @floatFromInt(self.duration_ns));
    }
};

const Curve = struct {
    kind: PointKind,
    selected: profile.Location,
    progress_point: []u8,
    speedups: std.ArrayListUnmanaged(SpeedupAggregate) = .empty,

    fn init(allocator: std.mem.Allocator, kind: PointKind, selected: profile.Location, progress_point: []const u8) !Curve {
        const selected_file = try allocator.dupe(u8, selected.file);
        errdefer allocator.free(selected_file);

        const owned_progress_point = try allocator.dupe(u8, progress_point);

        return .{
            .kind = kind,
            .selected = .{
                .file = selected_file,
                .line = selected.line,
            },
            .progress_point = owned_progress_point,
        };
    }

    fn deinit(self: *Curve, allocator: std.mem.Allocator) void {
        allocator.free(self.selected.file);
        allocator.free(self.progress_point);
        self.speedups.deinit(allocator);
        self.* = undefined;
    }

    fn addThroughput(
        self: *Curve,
        allocator: std.mem.Allocator,
        virtual_speedup: f64,
        duration_ns: u64,
        selected_samples: u64,
        delta: u64,
    ) !void {
        std.debug.assert(self.kind == .throughput);
        for (self.speedups.items) |*aggregate| {
            if (aggregate.virtual_speedup == virtual_speedup) {
                aggregate.addThroughput(duration_ns, selected_samples, delta);
                return;
            }
        }

        var aggregate = SpeedupAggregate{
            .virtual_speedup = virtual_speedup,
            .experiment_count = 0,
            .duration_ns = 0,
            .selected_samples = 0,
            .observations = 0,
        };
        aggregate.addThroughput(duration_ns, selected_samples, delta);
        try self.speedups.append(allocator, aggregate);
    }

    fn addLatency(
        self: *Curve,
        allocator: std.mem.Allocator,
        virtual_speedup: f64,
        duration_ns: u64,
        selected_samples: u64,
        arrivals: u64,
        departures: u64,
        outstanding: u64,
    ) !void {
        std.debug.assert(self.kind == .latency);
        for (self.speedups.items) |*aggregate| {
            if (aggregate.virtual_speedup == virtual_speedup) {
                aggregate.addLatency(duration_ns, selected_samples, arrivals, departures, outstanding);
                return;
            }
        }

        var aggregate = SpeedupAggregate{
            .virtual_speedup = virtual_speedup,
            .experiment_count = 0,
            .duration_ns = 0,
            .selected_samples = 0,
            .observations = 0,
        };
        aggregate.addLatency(duration_ns, selected_samples, arrivals, departures, outstanding);
        try self.speedups.append(allocator, aggregate);
    }

    fn result(self: *const Curve, allocator: std.mem.Allocator, options: Options) !?Result {
        var valid: std.ArrayListUnmanaged(SpeedupAggregate) = .empty;
        defer valid.deinit(allocator);

        for (self.speedups.items) |aggregate| {
            if (aggregate.observations >= options.min_delta) try valid.append(allocator, aggregate);
        }
        if (valid.items.len < options.min_points) return null;

        std.mem.sort(SpeedupAggregate, valid.items, {}, speedupLessThan);
        const baseline = chooseBaseline(valid.items) orelse return null;
        const baseline_value_ns = baseline.valueNs(self.kind);
        if (!validDataPoint(baseline_value_ns) or baseline_value_ns == 0) return null;

        var data = try self.measurementsFor(allocator, valid.items, baseline_value_ns);
        defer data.measurements.deinit(allocator);
        if (data.measurements.items.len < options.min_points) return null;

        const owned_file = try allocator.dupe(u8, self.selected.file);
        errdefer allocator.free(owned_file);

        const owned_progress_point = try allocator.dupe(u8, self.progress_point);
        errdefer allocator.free(owned_progress_point);

        const result_slope = slope(data.measurements.items);
        const support = supportFor(data.measurements.items, baseline.virtual_speedup);
        const owned_measurements = try data.measurements.toOwnedSlice(allocator);
        errdefer allocator.free(owned_measurements);

        return .{
            .kind = self.kind,
            .selected = .{
                .file = owned_file,
                .line = self.selected.line,
            },
            .progress_point = owned_progress_point,
            .baseline_virtual_speedup = baseline.virtual_speedup,
            .baseline_value_ns = baseline_value_ns,
            .min_program_speedup = data.min_program_speedup,
            .max_program_speedup = data.max_program_speedup,
            .total_selected_samples = data.total_selected_samples,
            .slope = result_slope,
            .support = support,
            .measurements = owned_measurements,
        };
    }

    fn measurementsFor(
        self: *const Curve,
        allocator: std.mem.Allocator,
        aggregates: []const SpeedupAggregate,
        baseline_value_ns: f64,
    ) !CurveData {
        var data: CurveData = .{};
        errdefer data.measurements.deinit(allocator);
        for (aggregates) |aggregate| {
            const value_ns = aggregate.valueNs(self.kind);
            if (!validDataPoint(value_ns)) continue;
            var program_speedup = (baseline_value_ns - value_ns) / baseline_value_ns;
            if (self.kind == .latency) program_speedup = -program_speedup;
            if (program_speedup < -1 or program_speedup > 2) continue;
            data.max_program_speedup = @max(data.max_program_speedup, program_speedup);
            data.min_program_speedup = @min(data.min_program_speedup, program_speedup);
            data.total_selected_samples += aggregate.selected_samples;
            var measurement = Measurement{
                .virtual_speedup = aggregate.virtual_speedup,
                .program_speedup = program_speedup,
                .experiment_count = aggregate.experiment_count,
                .selected_samples = aggregate.selected_samples,
                .observations = aggregate.observations,
                .duration_ns = aggregate.duration_ns,
                .value_ns = value_ns,
            };
            switch (self.kind) {
                .throughput => measurement.throughput_delta = aggregate.observations,
                .latency => {
                    measurement.latency_arrivals = aggregate.observations;
                    measurement.latency_departures = aggregate.departures;
                    measurement.latency_outstanding = aggregate.latencyOutstanding();
                },
            }
            try data.measurements.append(allocator, measurement);
        }
        return data;
    }
};

const CurveData = struct {
    measurements: std.ArrayListUnmanaged(Measurement) = .empty,
    min_program_speedup: f64 = std.math.inf(f64),
    max_program_speedup: f64 = -std.math.inf(f64),
    total_selected_samples: u64 = 0,
};

fn supportFor(measurements: []const Measurement, baseline_virtual_speedup: f64) Support {
    std.debug.assert(measurements.len > 0);
    var experiment_count: u64 = 0;
    var baseline_experiment_count: u64 = 0;
    var minimum_experiments_per_point: u64 = std.math.maxInt(u64);
    for (measurements) |measurement| {
        experiment_count +|= measurement.experiment_count;
        minimum_experiments_per_point = @min(
            minimum_experiments_per_point,
            measurement.experiment_count,
        );
        if (measurement.virtual_speedup == baseline_virtual_speedup) {
            baseline_experiment_count = measurement.experiment_count;
        }
    }
    const status: SupportStatus = if (measurements.len < 2)
        .point_only
    else if (minimum_experiments_per_point < 2)
        .unreplicated_curve
    else
        .within_run_repeated_curve;
    return .{
        .status = status,
        .speedup_point_count = @intCast(measurements.len),
        .experiment_count = experiment_count,
        .baseline_experiment_count = baseline_experiment_count,
        .minimum_experiments_per_point = minimum_experiments_per_point,
    };
}

fn chooseBaseline(items: []const SpeedupAggregate) ?SpeedupAggregate {
    for (items) |item| {
        if (item.virtual_speedup == 0) return item;
    }
    return null;
}

fn validDataPoint(value: f64) bool {
    return std.math.isFinite(value) and !std.math.isNan(value);
}

fn slope(measurements: []const Measurement) ?f64 {
    if (measurements.len < 2) return null;

    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var sum_xy: f64 = 0;
    var sum_x2: f64 = 0;
    for (measurements) |measurement| {
        const x = measurement.virtual_speedup;
        const y = measurement.program_speedup;
        sum_x += x;
        sum_y += y;
        sum_xy += x * y;
        sum_x2 += x * x;
    }

    const n: f64 = @floatFromInt(measurements.len);
    const denominator = n * sum_x2 - sum_x * sum_x;
    if (denominator == 0) return null;
    return (n * sum_xy - sum_x * sum_y) / denominator;
}

fn speedupLessThan(_: void, lhs: SpeedupAggregate, rhs: SpeedupAggregate) bool {
    return lhs.virtual_speedup < rhs.virtual_speedup;
}

fn resultLessThan(_: void, lhs: Result, rhs: Result) bool {
    const file_order = std.mem.order(u8, lhs.selected.file, rhs.selected.file);
    if (file_order != .eq) return file_order == .lt;
    if (lhs.selected.line != rhs.selected.line) return lhs.selected.line < rhs.selected.line;
    if (lhs.kind != rhs.kind) return @backingInt(lhs.kind) < @backingInt(rhs.kind);
    return std.mem.lessThan(u8, lhs.progress_point, rhs.progress_point);
}

fn kindName(kind: PointKind) []const u8 {
    return switch (kind) {
        .throughput => "throughput",
        .latency => "latency",
    };
}

fn goalName(kind: PointKind) []const u8 {
    return switch (kind) {
        .throughput => "maximize",
        .latency => "minimize",
    };
}

fn valueName(kind: PointKind) []const u8 {
    return switch (kind) {
        .throughput => "period_ns",
        .latency => "average_latency_ns",
    };
}

fn baselineValueLabel(kind: PointKind) []const u8 {
    return switch (kind) {
        .throughput => "baseline_period",
        .latency => "baseline_average_latency",
    };
}

fn measurementObservationLabel(measurement: Measurement) []const u8 {
    if (measurement.throughput_delta != null) return "delta";
    return "arrivals";
}

fn measurementValueLabel(measurement: Measurement) []const u8 {
    if (measurement.throughput_delta != null) return "period";
    return "average_latency";
}

fn writeLocation(stringify: *pretty_json.Writer, location: profile.Location) !void {
    try stringify.beginObject();
    try stringify.objectField("file");
    try stringify.write(location.file);
    try stringify.objectField("line");
    try stringify.write(location.line);
    try stringify.endObject();
}

fn summaryDocAlloc(builder: pretty.Builder, summary: Summary) !pretty.Doc {
    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    defer parts.deinit(builder.allocator);

    try parts.append(builder.allocator, try summaryHeaderDocAlloc(builder, summary));
    for (summary.results) |result| {
        try parts.append(builder.allocator, try resultDocAlloc(builder, result));
    }
    return try builder.concat(parts.items);
}

fn summaryHeaderDocAlloc(builder: pretty.Builder, summary: Summary) !pretty.Doc {
    return try builder.concat(&.{
        try builder.styledText(.title, "coz profiler"),
        try builder.punct(":"),
        builder.text(" "),
        try builder.styledText(.attribute, "integrity"),
        try builder.punct("="),
        try builder.styledText(
            if (std.mem.eql(u8, summary.capture_integrity.status, "complete")) .value else .warning,
            summary.capture_integrity.status,
        ),
        try builder.punct(";"),
        builder.text(" "),
        try builder.styledText(.attribute, "results"),
        try builder.punct("="),
        try builder.styledFmt(.number, "{d}", .{summary.results.len}),
        pretty.hardline,
    });
}

fn resultDocAlloc(builder: pretty.Builder, result: Result) !pretty.Doc {
    const fields = [_]pretty.Doc{
        try metricDocAlloc(builder, "kind", try builder.styledText(.attribute, kindName(result.kind))),
        try metricDocAlloc(
            builder,
            "support",
            try builder.styledText(
                supportStyle(result.support.status),
                @tagName(result.support.status),
            ),
        ),
        try u64MetricDocAlloc(
            builder,
            "speedup_points",
            result.support.speedup_point_count,
            .number,
        ),
        try u64MetricDocAlloc(
            builder,
            "experiments",
            result.support.experiment_count,
            .number,
        ),
        try u64MetricDocAlloc(
            builder,
            "baseline_experiments",
            result.support.baseline_experiment_count,
            .number,
        ),
        try u64MetricDocAlloc(
            builder,
            "minimum_experiments_per_point",
            result.support.minimum_experiments_per_point,
            .number,
        ),
        try percentMetricDocAlloc(builder, "baseline_virtual_speedup", result.baseline_virtual_speedup, .number),
        try floatNsMetricDocAlloc(builder, baselineValueLabel(result.kind), result.baseline_value_ns, .number),
        try percentMetricDocAlloc(builder, "max_program_speedup", result.max_program_speedup, speedupStyle(result.max_program_speedup)),
        try u64MetricDocAlloc(builder, "total_selected_samples", result.total_selected_samples, .number),
        try optionalFloatMetricDocAlloc(builder, "slope", result.slope),
    };

    var parts: std.ArrayListUnmanaged(pretty.Doc) = .empty;
    defer parts.deinit(builder.allocator);

    try parts.append(builder.allocator, try builder.concat(&.{
        try builder.spaces(2),
        try locationDocAlloc(builder, result.selected),
        builder.text(" "),
        try builder.punct("->"),
        builder.text(" "),
        try builder.styledText(.name, result.progress_point),
        try builder.punct(":"),
        builder.text(" "),
        try builder.nest(4, try builder.group(try builder.join(&fields, try metricSeparatorDocAlloc(builder)))),
        pretty.hardline,
    }));

    for (result.measurements, 0..) |measurement, index| {
        try parts.append(builder.allocator, try measurementDocAlloc(builder, measurement, index + 1));
    }

    return try builder.concat(parts.items);
}

fn locationDocAlloc(builder: pretty.Builder, location: profile.Location) !pretty.Doc {
    return try builder.concat(&.{
        try builder.styledText(.source, location.file),
        try builder.punct(":"),
        try builder.styledFmt(.number, "{d}", .{location.line}),
    });
}

fn measurementDocAlloc(builder: pretty.Builder, measurement: Measurement, index: usize) !pretty.Doc {
    const fields = [_]pretty.Doc{
        try percentMetricDocAlloc(builder, "virtual_speedup", measurement.virtual_speedup, .number),
        try percentMetricDocAlloc(builder, "program_speedup", measurement.program_speedup, speedupStyle(measurement.program_speedup)),
        try u64MetricDocAlloc(builder, "experiments", measurement.experiment_count, .number),
        try u64MetricDocAlloc(builder, "selected_samples", measurement.selected_samples, .number),
        try u64MetricDocAlloc(builder, measurementObservationLabel(measurement), measurement.observations, .number),
        try u64NsMetricDocAlloc(builder, "duration", measurement.duration_ns, .number),
        try floatNsMetricDocAlloc(builder, measurementValueLabel(measurement), measurement.value_ns, .number),
    };

    return try builder.concat(&.{
        try builder.spaces(4),
        try builder.styledFmt(.number, "{d}", .{index}),
        try builder.punct("."),
        builder.text(" "),
        try builder.nest(4, try builder.group(try builder.join(&fields, try metricSeparatorDocAlloc(builder)))),
        pretty.hardline,
    });
}

fn supportStyle(status: SupportStatus) pretty.Style {
    return switch (status) {
        .point_only, .unreplicated_curve => .warning,
        .within_run_repeated_curve => .value,
    };
}

fn metricSeparatorDocAlloc(builder: pretty.Builder) !pretty.Doc {
    return try builder.concat(&.{
        try builder.punct(";"),
        pretty.softline,
    });
}

fn percentMetricDocAlloc(
    builder: pretty.Builder,
    label: []const u8,
    value: f64,
    value_style: pretty.Style,
) !pretty.Doc {
    return try metricDocAlloc(
        builder,
        label,
        try builder.styledFmt(value_style, "{d:.2}%", .{value * 100.0}),
    );
}

fn floatNsMetricDocAlloc(
    builder: pretty.Builder,
    label: []const u8,
    value: f64,
    value_style: pretty.Style,
) !pretty.Doc {
    return try metricDocAlloc(
        builder,
        label,
        try builder.styledFmt(value_style, "{d:.2} ns", .{value}),
    );
}

fn u64NsMetricDocAlloc(
    builder: pretty.Builder,
    label: []const u8,
    value: u64,
    value_style: pretty.Style,
) !pretty.Doc {
    return try metricDocAlloc(
        builder,
        label,
        try builder.styledFmt(value_style, "{d} ns", .{value}),
    );
}

fn u64MetricDocAlloc(
    builder: pretty.Builder,
    label: []const u8,
    value: u64,
    value_style: pretty.Style,
) !pretty.Doc {
    return try metricDocAlloc(
        builder,
        label,
        try builder.styledFmt(value_style, "{d}", .{value}),
    );
}

fn optionalFloatMetricDocAlloc(builder: pretty.Builder, label: []const u8, value: ?f64) !pretty.Doc {
    if (value) |actual| {
        return try metricDocAlloc(builder, label, try builder.styledFmt(.number, "{d:.4}", .{actual}));
    }
    return try metricDocAlloc(builder, label, try builder.styledText(.muted, "n/a"));
}

fn metricDocAlloc(builder: pretty.Builder, label: []const u8, value_doc: pretty.Doc) !pretty.Doc {
    return try builder.concat(&.{
        try builder.styledText(.attribute, label),
        try builder.punct("="),
        value_doc,
    });
}

fn speedupStyle(value: f64) pretty.Style {
    if (value < 0) return .danger;
    if (value > 0) return .value;
    return .number;
}

test "accumulator experiment replacement survives allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkExperimentReplacementAllocationFailures,
        .{},
    );
}

fn checkExperimentReplacementAllocationFailures(allocator: std.mem.Allocator) !void {
    var accumulator: Accumulator = .{};
    defer accumulator.deinit(allocator);

    try accumulator.observe(allocator, .{ .experiment = .{
        .selected = .{ .file = "src/first.zig", .line = 10 },
        .virtual_speedup = 0,
        .duration_ns = 100,
        .selected_samples = 1,
    } });
    try accumulator.observe(allocator, .{ .experiment = .{
        .selected = .{ .file = "src/second.zig", .line = 20 },
        .virtual_speedup = 0.5,
        .duration_ns = 80,
        .selected_samples = 2,
    } });

    try std.testing.expectEqualStrings(
        "src/second.zig",
        accumulator.current_experiment.?.selected.file,
    );
}

test "accumulator computes program speedup from throughput periods" {
    var accumulator: Accumulator = .{};
    defer accumulator.deinit(std.testing.allocator);

    try accumulator.observe(std.testing.allocator, .{ .experiment = .{
        .selected = .{ .file = "src/work.zig", .line = 10 },
        .virtual_speedup = 0,
        .duration_ns = 100,
        .selected_samples = 2,
    } });
    try accumulator.observe(std.testing.allocator, .{ .throughput = .{
        .name = "items",
        .delta = 10,
    } });
    try accumulator.observe(std.testing.allocator, .{ .experiment = .{
        .selected = .{ .file = "src/work.zig", .line = 10 },
        .virtual_speedup = 0.5,
        .duration_ns = 80,
        .selected_samples = 3,
    } });
    try accumulator.observe(std.testing.allocator, .{ .throughput = .{
        .name = "items",
        .delta = 10,
    } });

    var summary = try accumulator.summarize(std.testing.allocator, .{ .min_delta = 1, .min_points = 2 });
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), summary.results.len);
    const result = summary.results[0];
    try std.testing.expectEqual(PointKind.throughput, result.kind);
    try std.testing.expectEqualStrings("src/work.zig", result.selected.file);
    try std.testing.expectEqual(@as(u64, 10), result.selected.line);
    try std.testing.expectEqualStrings("items", result.progress_point);
    try std.testing.expectEqual(@as(f64, 10), result.baseline_value_ns);
    try std.testing.expectEqual(@as(f64, 0), result.min_program_speedup);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), result.max_program_speedup, 0.000001);
    try std.testing.expectEqual(@as(u64, 5), result.total_selected_samples);
    try std.testing.expectEqual(@as(usize, 2), result.measurements.len);
    try std.testing.expectEqual(SupportStatus.unreplicated_curve, result.support.status);
    try std.testing.expectEqual(@as(u64, 2), result.support.experiment_count);
    try std.testing.expectEqual(@as(u64, 1), result.support.baseline_experiment_count);
    try std.testing.expectEqual(@as(u64, 1), result.support.minimum_experiments_per_point);
    try std.testing.expectEqual(@as(u64, 1), result.measurements[0].experiment_count);
    try std.testing.expectEqual(@as(u64, 2), result.measurements[0].selected_samples);
    try std.testing.expectEqual(@as(u64, 3), result.measurements[1].selected_samples);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), result.slope.?, 0.000001);
}

test "accumulator computes latency speedups with upstream Little's Law metric" {
    var accumulator: Accumulator = .{};
    defer accumulator.deinit(std.testing.allocator);

    try accumulator.observe(std.testing.allocator, .{ .experiment = .{
        .selected = .{ .file = "src/work.zig", .line = 10 },
        .virtual_speedup = 0,
        .duration_ns = 100,
        .selected_samples = 2,
    } });
    try accumulator.observe(std.testing.allocator, .{ .latency = .{
        .name = "request",
        .arrivals = 10,
        .departures = 9,
        .outstanding = 5,
    } });
    try accumulator.observe(std.testing.allocator, .{ .experiment = .{
        .selected = .{ .file = "src/work.zig", .line = 10 },
        .virtual_speedup = 0.5,
        .duration_ns = 80,
        .selected_samples = 3,
    } });
    try accumulator.observe(std.testing.allocator, .{ .latency = .{
        .name = "request",
        .arrivals = 10,
        .departures = 10,
        .outstanding = 4,
    } });

    var summary = try accumulator.summarize(std.testing.allocator, .{ .min_delta = 1, .min_points = 2 });
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), summary.results.len);
    const result = summary.results[0];
    try std.testing.expectEqual(PointKind.latency, result.kind);
    try std.testing.expectEqualStrings("request", result.progress_point);
    try std.testing.expectEqual(@as(f64, 50), result.baseline_value_ns);
    try std.testing.expectApproxEqAbs(@as(f64, -0.36), result.min_program_speedup, 0.000001);
    try std.testing.expectEqual(@as(f64, 0), result.max_program_speedup);
    try std.testing.expectEqual(@as(u64, 5), result.total_selected_samples);
    try std.testing.expectEqual(@as(usize, 2), result.measurements.len);
    try std.testing.expectEqual(@as(u64, 2), result.measurements[0].selected_samples);
    try std.testing.expectEqual(@as(u64, 3), result.measurements[1].selected_samples);
    try std.testing.expectEqual(@as(u64, 10), result.measurements[1].observations);
    try std.testing.expectEqual(@as(u64, 10), result.measurements[1].latency_arrivals.?);
    try std.testing.expectEqual(@as(u64, 10), result.measurements[1].latency_departures.?);
    try std.testing.expectEqual(@as(f64, 4), result.measurements[1].latency_outstanding.?);
    try std.testing.expectApproxEqAbs(@as(f64, 32), result.measurements[1].value_ns, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, -0.36), result.measurements[1].program_speedup, 0.000001);
}

test "accumulator merges repeated speedups and reports repeated curve support" {
    var accumulator: Accumulator = .{};
    defer accumulator.deinit(std.testing.allocator);

    for ([_]f64{ 0, 0.5 }) |virtual_speedup| {
        for (0..2) |_| {
            try accumulator.observe(std.testing.allocator, .{ .experiment = .{
                .selected = .{ .file = "src/work.zig", .line = 10 },
                .virtual_speedup = virtual_speedup,
                .duration_ns = if (virtual_speedup == 0) 100 else 80,
                .selected_samples = 1,
            } });
            try accumulator.observe(std.testing.allocator, .{ .throughput = .{
                .name = "items",
                .delta = 10,
            } });
        }
    }

    var summary = try accumulator.summarize(
        std.testing.allocator,
        .{ .min_delta = 1, .min_points = 2 },
    );
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), summary.results.len);
    try std.testing.expectEqual(@as(u64, 4), summary.results[0].total_selected_samples);
    try std.testing.expectEqual(
        SupportStatus.within_run_repeated_curve,
        summary.results[0].support.status,
    );
    try std.testing.expectEqual(@as(u64, 2), summary.results[0].support.speedup_point_count);
    try std.testing.expectEqual(@as(u64, 4), summary.results[0].support.experiment_count);
    try std.testing.expectEqual(@as(u64, 2), summary.results[0].support.baseline_experiment_count);
    try std.testing.expectEqual(
        @as(u64, 2),
        summary.results[0].support.minimum_experiments_per_point,
    );
    const measurement = summary.results[0].measurements[0];
    try std.testing.expectEqual(@as(u64, 2), measurement.experiment_count);
    try std.testing.expectEqual(@as(u64, 2), measurement.selected_samples);
    try std.testing.expectEqual(@as(u64, 20), measurement.observations);
    try std.testing.expectEqual(@as(u64, 20), measurement.throughput_delta.?);
    try std.testing.expectEqual(@as(u64, 200), measurement.duration_ns);
    try std.testing.expectEqual(@as(f64, 10), measurement.value_ns);
}

test "accumulator requires a zero-speedup baseline after low-delta filtering" {
    var accumulator: Accumulator = .{};
    defer accumulator.deinit(std.testing.allocator);

    try accumulator.observe(std.testing.allocator, .{ .experiment = .{
        .selected = .{ .file = "src/work.zig", .line = 10 },
        .virtual_speedup = 0,
        .duration_ns = 100,
        .selected_samples = 1,
    } });
    try accumulator.observe(std.testing.allocator, .{ .throughput = .{ .name = "items", .delta = 1 } });
    try accumulator.observe(std.testing.allocator, .{ .experiment = .{
        .selected = .{ .file = "src/work.zig", .line = 10 },
        .virtual_speedup = 0.25,
        .duration_ns = 90,
        .selected_samples = 2,
    } });
    try accumulator.observe(std.testing.allocator, .{ .throughput = .{ .name = "items", .delta = 10 } });
    try accumulator.observe(std.testing.allocator, .{ .experiment = .{
        .selected = .{ .file = "src/work.zig", .line = 10 },
        .virtual_speedup = 0.5,
        .duration_ns = 80,
        .selected_samples = 3,
    } });
    try accumulator.observe(std.testing.allocator, .{ .throughput = .{ .name = "items", .delta = 10 } });

    var summary = try accumulator.summarize(std.testing.allocator, .{ .min_delta = 5, .min_points = 2 });
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), summary.results.len);
}

test "summary JSON exposes agent-friendly result fields" {
    var accumulator: Accumulator = .{};
    defer accumulator.deinit(std.testing.allocator);

    try accumulator.observe(std.testing.allocator, .{ .experiment = .{
        .selected = .{ .file = "src/work.zig", .line = 10 },
        .virtual_speedup = 0,
        .duration_ns = 100,
        .selected_samples = 1,
    } });
    try accumulator.observe(std.testing.allocator, .{ .throughput = .{ .name = "items", .delta = 10 } });

    var summary = try accumulator.summarize(std.testing.allocator, .{ .min_delta = 1, .min_points = 1 });
    defer summary.deinit(std.testing.allocator);

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try summary.writeJson(&writer);
    const json = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\":\"coz.analysis/v2\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"status\":\"missing_sampling_summary\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"progress_point\":\"items\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"throughput\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"goal\":\"maximize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"baseline_value_ns\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"baseline_period_ns\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_selected_samples\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"point_only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"experiment_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"action\":\"collect_baseline_and_perturbed_points\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"selected_samples\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"measurements\"") != null);
}

test "summary JSON exposes latency-specific agent fields" {
    var accumulator: Accumulator = .{};
    defer accumulator.deinit(std.testing.allocator);

    try accumulator.observe(std.testing.allocator, .{ .experiment = .{
        .selected = .{ .file = "src/work.zig", .line = 10 },
        .virtual_speedup = 0,
        .duration_ns = 100,
        .selected_samples = 1,
    } });
    try accumulator.observe(std.testing.allocator, .{ .latency = .{
        .name = "request",
        .arrivals = 10,
        .departures = 8,
        .outstanding = 4,
    } });

    var summary = try accumulator.summarize(std.testing.allocator, .{ .min_delta = 1, .min_points = 1 });
    defer summary.deinit(std.testing.allocator);

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try summary.writeJson(&writer);
    const json = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"latency\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"goal\":\"minimize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"value_name\":\"average_latency_ns\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"arrivals\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"departures\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"average_latency_ns\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_selected_samples\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"selected_samples\":1") != null);
}

test "summary can be built from profile JSON lines" {
    const text =
        \\{"schema":"coz.profile/v1","event":"startup","timestamp_ns":1}
        \\{"schema":"coz.profile/v1","event":"experiment","selected":{"file":"src/work.zig","line":10},"virtual_speedup":0,"duration_ns":100,"selected_samples":1}
        \\{"schema":"coz.profile/v1","event":"throughput","name":"items","delta":10}
        \\{"schema":"coz.profile/v1","event":"experiment","selected":{"file":"src/work.zig","line":10},"virtual_speedup":0.5,"duration_ns":80,"selected_samples":2}
        \\{"schema":"coz.profile/v1","event":"throughput","name":"items","delta":10}
        \\{"schema":"coz.profile/v1","event":"runtime","duration_ns":200}
        \\
    ;

    var summary = try summarizeJsonLines(std.testing.allocator, text, .{ .min_delta = 1, .min_points = 2 });
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), summary.results.len);
    try std.testing.expectEqualStrings("src/work.zig", summary.results[0].selected.file);
    try std.testing.expectEqualStrings("items", summary.results[0].progress_point);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), summary.results[0].max_program_speedup, 0.000001);
    try std.testing.expectEqualStrings(
        "missing_sampling_summary",
        summary.capture_integrity.status,
    );
}

test "capture integrity distinguishes complete loss throttle and counter gaps" {
    const complete = captureIntegrity(.{
        .record_count = 20,
        .sample_record_count = 20,
        .loss_counter = .{ .available = 0 },
        .terminal_status = .complete,
    });
    const loss = captureIntegrity(.{
        .record_count = 21,
        .sample_record_count = 20,
        .lost_record_count = 1,
        .lost_event_count = 3,
        .loss_counter = .{ .available = 3 },
        .terminal_status = .complete,
    });
    const throttled = captureIntegrity(.{
        .record_count = 22,
        .sample_record_count = 20,
        .throttle_record_count = 1,
        .unthrottle_record_count = 1,
        .loss_counter = .{ .available = 0 },
        .terminal_status = .complete,
    });
    const unsupported = captureIntegrity(.{
        .record_count = 20,
        .sample_record_count = 20,
        .loss_counter = .unsupported,
        .terminal_status = .complete,
    });
    const failed = captureIntegrity(.{
        .record_count = 20,
        .sample_record_count = 20,
        .loss_counter = .read_failed,
        .terminal_status = .complete,
    });
    const drain_failed = captureIntegrity(.{
        .loss_counter = .{ .available = 0 },
        .terminal_status = .drain_failed,
    });

    try std.testing.expectEqualStrings("complete", complete.status);
    try std.testing.expectEqualStrings("sample_loss", loss.status);
    try std.testing.expectEqual(@as(?u64, 3), loss.loss_counter_value);
    try std.testing.expectEqualStrings("sampling_throttled", throttled.status);
    try std.testing.expectEqualStrings("loss_counter_unavailable", unsupported.status);
    try std.testing.expectEqualStrings("loss_counter_read_failed", failed.status);
    try std.testing.expectEqualStrings("sampling_drain_failed", drain_failed.status);
}

test "capture integrity rejects inconsistent and duplicate sampling summaries" {
    const invalid = captureIntegrity(.{
        .record_count = 1,
        .sample_record_count = 2,
        .loss_counter = .{ .available = 0 },
        .terminal_status = .complete,
    });
    try std.testing.expectEqualStrings("invalid_sampling_summary", invalid.status);

    var accumulator: Accumulator = .{};
    defer accumulator.deinit(std.testing.allocator);
    const sampling = profile.Event{ .sampling = .{
        .loss_counter = .{ .available = 0 },
        .terminal_status = .complete,
    } };
    try accumulator.observe(std.testing.allocator, sampling);
    try std.testing.expectError(
        error.DuplicateSamplingSummary,
        accumulator.observe(std.testing.allocator, sampling),
    );
}

test "summary pretty report renders profiler analysis with grouped metrics" {
    var summary = try sampleSummary(std.testing.allocator);
    defer summary.deinit(std.testing.allocator);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try summary.writePretty(std.testing.allocator, &writer, .{ .width = 360 });

    try std.testing.expectEqualStrings(
        "coz profiler: integrity=complete; results=1\n" ++
            "  src/work.zig:10 -> items: kind=throughput; " ++
            "support=unreplicated_curve; speedup_points=2; experiments=2; " ++
            "baseline_experiments=1; " ++
            "minimum_experiments_per_point=1; baseline_virtual_speedup=0.00%; " ++
            "baseline_period=10.00 ns; max_program_speedup=20.00%; " ++
            "total_selected_samples=5; slope=0.4000\n" ++
            "    1. virtual_speedup=0.00%; program_speedup=0.00%; " ++
            "experiments=1; selected_samples=2; delta=10; duration=100 ns; " ++
            "period=10.00 ns\n" ++
            "    2. virtual_speedup=50.00%; program_speedup=20.00%; " ++
            "experiments=1; selected_samples=3; delta=10; duration=80 ns; " ++
            "period=8.00 ns\n",
        writer.buffered(),
    );
}

test "summary pretty report breaks metric groups under narrow widths" {
    var summary = try sampleSummary(std.testing.allocator);
    defer summary.deinit(std.testing.allocator);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try summary.writePretty(std.testing.allocator, &writer, .{ .width = 48 });
    const text = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, text, "\n    baseline_period=10.00 ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n    program_speedup=20.00%") != null);
}

fn sampleSummary(allocator: std.mem.Allocator) !Summary {
    var accumulator: Accumulator = .{};
    defer accumulator.deinit(allocator);

    try accumulator.observe(allocator, .{ .experiment = .{
        .selected = .{ .file = "src/work.zig", .line = 10 },
        .virtual_speedup = 0,
        .duration_ns = 100,
        .selected_samples = 2,
    } });
    try accumulator.observe(allocator, .{ .throughput = .{
        .name = "items",
        .delta = 10,
    } });
    try accumulator.observe(allocator, .{ .experiment = .{
        .selected = .{ .file = "src/work.zig", .line = 10 },
        .virtual_speedup = 0.5,
        .duration_ns = 80,
        .selected_samples = 3,
    } });
    try accumulator.observe(allocator, .{ .throughput = .{
        .name = "items",
        .delta = 10,
    } });
    try accumulator.observe(allocator, .{ .sampling = .{
        .loss_counter = .{ .available = 0 },
        .terminal_status = .complete,
    } });

    return try accumulator.summarize(allocator, .{ .min_delta = 1, .min_points = 2 });
}
