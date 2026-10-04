const std = @import("std");
const sys = @import("sys");

const abi = @import("abi.zig");
const debug_info = @import("debug.zig");
const delay = @import("delay.zig");
const experiment = @import("experiment.zig");
const path_filter = @import("filter.zig");
const perf = sys.perf;
const profile = @import("profile.zig");
const progress_point = @import("point.zig");
const registry_mod = @import("registry.zig");
const sampler_mod = @import("sampler.zig");
const source_map = @import("map.zig");

pub const ExperimentRunOptions = struct {
    selected: *source_map.Line,
    plan: experiment.Plan,
    end_to_end: bool = false,
    running: ?*std.atomic.Value(bool) = null,
};

pub const ExperimentStepOptions = struct {
    fixed_line: ?*source_map.Line = null,
    fixed_speedup_percent: ?i32 = null,
    draw: experiment.Draw = .{ .value = 0 },
    end_to_end: bool = false,
    running: ?*std.atomic.Value(bool) = null,
};

pub const ExperimentStepResult = struct {
    selected: ?*source_map.Line = null,
    emitted: bool = false,
};

pub const SamplingSnapshot = struct {
    record_count: u64,
    sample_record_count: u64,
    lost_record_count: u64,
    lost_event_count: u64,
    lost_samples_record_count: u64,
    lost_samples_count: u64,
    throttle_record_count: u64,
    unthrottle_record_count: u64,
};

const SamplingCounters = struct {
    record_count: std.atomic.Value(u64) = .init(0),
    sample_record_count: std.atomic.Value(u64) = .init(0),
    lost_record_count: std.atomic.Value(u64) = .init(0),
    lost_event_count: std.atomic.Value(u64) = .init(0),
    lost_samples_record_count: std.atomic.Value(u64) = .init(0),
    lost_samples_count: std.atomic.Value(u64) = .init(0),
    throttle_record_count: std.atomic.Value(u64) = .init(0),
    unthrottle_record_count: std.atomic.Value(u64) = .init(0),
};

pub const Profiler = struct {
    registry: registry_mod.Registry = .{},
    sources: source_map.Index = .{},
    source_mutex: std.atomic.Mutex = .unlocked,
    delays: delay.Coordinator = .{},
    selected_line_address: std.atomic.Value(usize) = .init(0),
    next_line_address: std.atomic.Value(usize) = .init(0),
    sampling: SamplingCounters = .{},
    experiment_duration_ns: u64 = experiment.experiment_min_time_ns,

    pub fn deinit(self: *Profiler, allocator: std.mem.Allocator) void {
        self.registry.deinit(allocator);
        self.sources.deinit(allocator);
        self.delays = .{};
        self.selected_line_address.store(0, .release);
        self.next_line_address.store(0, .release);
        self.sampling = .{};
        self.experiment_duration_ns = experiment.experiment_min_time_ns;
    }

    pub fn getCounter(
        self: *Profiler,
        allocator: std.mem.Allocator,
        kind: abi.CounterKind,
        name: []const u8,
    ) !*abi.Counter {
        return self.registry.getCounter(allocator, kind, name);
    }

    pub fn preBlock(self: *Profiler, thread: *delay.ThreadState) void {
        self.delays.preBlock(thread);
    }

    pub fn catchUp(self: *Profiler, thread: *delay.ThreadState, wait: anytype) u64 {
        return self.delays.addDelays(thread, wait);
    }

    pub fn postBlock(self: *Profiler, thread: *delay.ThreadState, skip_delays: bool) void {
        self.delays.postBlock(thread, skip_delays);
    }

    pub fn creditSelectedHit(self: *Profiler, thread: *delay.ThreadState) void {
        self.delays.creditSelectedHit(thread);
    }

    pub fn addSourceRange(
        self: *Profiler,
        allocator: std.mem.Allocator,
        filename: []const u8,
        line_no: u64,
        range: source_map.Interval,
    ) !*source_map.Line {
        lockMutex(&self.source_mutex);
        defer self.source_mutex.unlock();

        return self.sources.addRange(allocator, filename, line_no, range);
    }

    pub fn selectLine(self: *Profiler, line: ?*source_map.Line) void {
        self.selected_line_address.store(lineAddress(line), .release);
        self.clearNextLine();
    }

    pub fn selectedLine(self: *const Profiler) ?*source_map.Line {
        return addressLine(self.selected_line_address.load(.acquire));
    }

    pub fn clearNextLine(self: *Profiler) void {
        self.next_line_address.store(0, .release);
    }

    pub fn nextLine(self: *const Profiler) ?*source_map.Line {
        return addressLine(self.next_line_address.load(.acquire));
    }

    pub fn observeSample(self: *Profiler, thread: *delay.ThreadState, sample: source_map.Sample) source_map.Match {
        if (!self.source_mutex.tryLock()) return .{};
        defer self.source_mutex.unlock();
        return self.observeSampleLocked(thread, sample);
    }

    fn observeSampleLocked(self: *Profiler, thread: *delay.ThreadState, sample: source_map.Sample) source_map.Match {
        const matched = self.sources.matchSample(sample, self.selectedLine());
        if (matched.line) |line| {
            line.addSample();
            if (self.delays.active()) {
                if (matched.selected_hit) self.creditSelectedHit(thread);
            } else if (!path_filter.isCozHeader(line.file.name)) {
                _ = self.next_line_address.cmpxchgStrong(0, lineAddress(line), .acq_rel, .acquire);
            }
        }
        return matched;
    }

    pub fn observeResolvedSample(
        self: *Profiler,
        allocator: std.mem.Allocator,
        thread: *delay.ThreadState,
        sample: source_map.Sample,
        scope: debug_info.Scope,
    ) !source_map.Match {
        lockMutex(&self.source_mutex);
        defer self.source_mutex.unlock();

        try debug_info.resolveSample(allocator, &self.sources, sample, scope);
        return self.observeSampleLocked(thread, sample);
    }

    pub fn observePerfRecord(
        self: *Profiler,
        thread: *delay.ThreadState,
        record: perf.Record,
        callchain_scratch: []usize,
    ) !source_map.Match {
        try self.observePerfRecordKind(record);
        const sample = try sampleFromPerfRecord(record, callchain_scratch) orelse return .{};
        return self.observeSample(thread, sample);
    }

    pub fn observeResolvedPerfRecord(
        self: *Profiler,
        allocator: std.mem.Allocator,
        thread: *delay.ThreadState,
        record: perf.Record,
        callchain_scratch: []usize,
        scope: debug_info.Scope,
    ) !source_map.Match {
        try self.observePerfRecordKind(record);
        const sample = try sampleFromPerfRecord(record, callchain_scratch) orelse return .{};

        lockMutex(&self.source_mutex);
        defer self.source_mutex.unlock();

        _ = debug_info.resolveSelfAddress(allocator, &self.sources, sample.ip, scope) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };

        return self.observeSampleLocked(thread, sample);
    }

    pub fn samplingSnapshot(self: *const Profiler) SamplingSnapshot {
        return .{
            .record_count = self.sampling.record_count.load(.acquire),
            .sample_record_count = self.sampling.sample_record_count.load(.acquire),
            .lost_record_count = self.sampling.lost_record_count.load(.acquire),
            .lost_event_count = self.sampling.lost_event_count.load(.acquire),
            .lost_samples_record_count = self.sampling.lost_samples_record_count.load(.acquire),
            .lost_samples_count = self.sampling.lost_samples_count.load(.acquire),
            .throttle_record_count = self.sampling.throttle_record_count.load(.acquire),
            .unthrottle_record_count = self.sampling.unthrottle_record_count.load(.acquire),
        };
    }

    fn observePerfRecordKind(self: *Profiler, record: perf.Record) !void {
        addAtomic(&self.sampling.record_count, 1);
        switch (record.recordType()) {
            .sample => addAtomic(&self.sampling.sample_record_count, 1),
            .lost => {
                addAtomic(&self.sampling.lost_record_count, 1);
                addAtomic(&self.sampling.lost_event_count, try record.getLostCount());
            },
            .lost_samples => {
                addAtomic(&self.sampling.lost_samples_record_count, 1);
                addAtomic(&self.sampling.lost_samples_count, try record.getLostCount());
            },
            .throttle => addAtomic(&self.sampling.throttle_record_count, 1),
            .unthrottle => addAtomic(&self.sampling.unthrottle_record_count, 1),
            else => {},
        }
    }

    pub fn drainPerfRing(
        self: *Profiler,
        thread: *delay.ThreadState,
        reader: *perf.RingReader,
        record_scratch: []u8,
        callchain_scratch: []usize,
    ) !usize {
        var records: usize = 0;
        while (try reader.next(record_scratch)) |record| {
            _ = try self.observePerfRecord(thread, record, callchain_scratch);
            records += 1;
        }
        return records;
    }

    pub fn drainResolvedPerfRing(
        self: *Profiler,
        allocator: std.mem.Allocator,
        thread: *delay.ThreadState,
        reader: *perf.RingReader,
        record_scratch: []u8,
        callchain_scratch: []usize,
        scope: debug_info.Scope,
    ) !usize {
        var records: usize = 0;
        while (try reader.next(record_scratch)) |record| {
            _ = try self.observeResolvedPerfRecord(allocator, thread, record, callchain_scratch, scope);
            records += 1;
        }
        return records;
    }

    pub fn processPerfRing(
        self: *Profiler,
        thread: *delay.ThreadState,
        reader: *perf.RingReader,
        record_scratch: []u8,
        callchain_scratch: []usize,
        wait: anytype,
    ) !usize {
        const records = try self.drainPerfRing(thread, reader, record_scratch, callchain_scratch);
        _ = self.catchUp(thread, wait);
        return records;
    }

    pub fn drainPerfEvent(
        self: *Profiler,
        thread: *delay.ThreadState,
        event: *perf.Event,
        record_scratch: []u8,
        callchain_scratch: []usize,
    ) !usize {
        var reader = event.ringReader() orelse return 0;
        const records = try self.drainPerfRing(thread, &reader, record_scratch, callchain_scratch);
        event.commitReader(reader);
        return records;
    }

    pub fn processPerfEvent(
        self: *Profiler,
        thread: *delay.ThreadState,
        event: *perf.Event,
        record_scratch: []u8,
        callchain_scratch: []usize,
        wait: anytype,
    ) !usize {
        var reader = event.ringReader() orelse {
            _ = self.catchUp(thread, wait);
            return 0;
        };
        const records = try self.processPerfRing(thread, &reader, record_scratch, callchain_scratch, wait);
        event.commitReader(reader);
        return records;
    }

    pub fn drainSampler(
        self: *Profiler,
        thread: *delay.ThreadState,
        sampler: *sampler_mod.Sampler,
        record_scratch: []u8,
        callchain_scratch: []usize,
    ) !usize {
        var reader = sampler.ringReader() orelse return 0;
        const records = try self.drainPerfRing(thread, &reader, record_scratch, callchain_scratch);
        sampler.commitReader(reader);
        return records;
    }

    pub fn drainResolvedSampler(
        self: *Profiler,
        allocator: std.mem.Allocator,
        thread: *delay.ThreadState,
        sampler: *sampler_mod.Sampler,
        record_scratch: []u8,
        callchain_scratch: []usize,
        scope: debug_info.Scope,
    ) !usize {
        var reader = sampler.ringReader() orelse return 0;
        const records = try self.drainResolvedPerfRing(allocator, thread, &reader, record_scratch, callchain_scratch, scope);
        sampler.commitReader(reader);
        return records;
    }

    pub fn processSampler(
        self: *Profiler,
        thread: *delay.ThreadState,
        sampler: *sampler_mod.Sampler,
        record_scratch: []u8,
        callchain_scratch: []usize,
        wait: sampler_mod.WaitFn,
    ) !usize {
        const paused_wait = sampler.pausingWait(wait);
        var reader = sampler.ringReader() orelse {
            _ = self.catchUp(thread, paused_wait);
            return 0;
        };
        const records = try self.processPerfRing(thread, &reader, record_scratch, callchain_scratch, paused_wait);
        sampler.commitReader(reader);
        return records;
    }

    pub fn beginExperiment(
        self: *Profiler,
        allocator: std.mem.Allocator,
        selected: profile.Location,
        virtual_speedup: f64,
    ) !Run {
        const selected_file = try allocator.dupe(u8, selected.file);
        errdefer allocator.free(selected_file);

        const throughput_snapshots = try self.registry.saveThroughputSnapshots(allocator);
        errdefer allocator.free(throughput_snapshots);

        const latency_snapshots = try self.registry.saveLatencySnapshots(allocator);
        errdefer allocator.free(latency_snapshots);

        return .{
            .selected = .{
                .file = selected_file,
                .line = selected.line,
            },
            .virtual_speedup = virtual_speedup,
            .throughput_snapshots = throughput_snapshots,
            .latency_snapshots = latency_snapshots,
        };
    }

    pub fn finishExperiment(
        self: *Profiler,
        writer: *std.Io.Writer,
        run: Run,
        duration_ns: u64,
        selected_samples: u64,
    ) !bool {
        const min_delta = run.minDelta();
        self.experiment_duration_ns = experiment.adjustDuration(self.experiment_duration_ns, min_delta);
        if (min_delta < experiment.experiment_target_delta) return false;

        try run.writeEvents(writer, duration_ns, selected_samples);
        return true;
    }

    pub fn runExperiment(
        self: *Profiler,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        options: ExperimentRunOptions,
        wait_fn: sampler_mod.WaitFn,
    ) !bool {
        var run = try self.beginExperiment(
            allocator,
            options.selected.location(),
            options.plan.virtual_speedup,
        );
        defer run.deinit(allocator);

        const starting_samples = options.selected.sampleCount();
        const starting_delay_ns = self.delays.globalDelay();

        self.selectLine(options.selected);
        self.delays.startExperiment(options.plan.delay_size_ns);
        const elapsed_ns = waitForExperiment(options.plan.duration_ns, options.end_to_end, options.running, wait_fn);
        self.delays.finishExperiment();
        self.selectLine(null);

        const inserted_delay_ns = self.delays.globalDelay() -| starting_delay_ns;
        const selected_samples = options.selected.sampleCount() -| starting_samples;
        const duration_ns = experiment.correctedDurationNs(elapsed_ns, inserted_delay_ns, self.delays.overshoot());

        return self.finishExperiment(writer, run, duration_ns, selected_samples);
    }

    pub fn runExperimentStep(
        self: *Profiler,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        options: ExperimentStepOptions,
        wait_fn: sampler_mod.WaitFn,
    ) !ExperimentStepResult {
        const selected = options.fixed_line orelse self.nextLine() orelse return .{};
        const plan = try self.stepPlan(options);
        const emitted = try self.runExperiment(
            allocator,
            writer,
            .{
                .selected = selected,
                .plan = plan,
                .end_to_end = options.end_to_end,
                .running = options.running,
            },
            wait_fn,
        );
        return .{ .selected = selected, .emitted = emitted };
    }

    fn stepPlan(self: *const Profiler, options: ExperimentStepOptions) !experiment.Plan {
        const delay_size_ns = if (options.fixed_speedup_percent) |percent|
            experiment.fixedDelaySize(percent) orelse return error.InvalidFixedSpeedup
        else blk: {
            const draw = try experiment.Draw.init(options.draw.value);
            break :blk experiment.delaySizeFromDraw(draw);
        };

        return .{
            .delay_size_ns = delay_size_ns,
            .virtual_speedup = experiment.virtualSpeedupFromDelay(delay_size_ns),
            .duration_ns = self.experiment_duration_ns,
        };
    }

    pub fn writeStartup(_: *Profiler, writer: *std.Io.Writer, timestamp_ns: u64) !void {
        try (profile.Event{ .startup = .{ .timestamp_ns = timestamp_ns } }).writeJsonLine(writer);
    }

    pub fn writeRuntime(_: *Profiler, writer: *std.Io.Writer, duration_ns: u64) !void {
        try (profile.Event{ .runtime = .{ .duration_ns = duration_ns } }).writeJsonLine(writer);
    }

    pub fn writeSample(_: *Profiler, writer: *std.Io.Writer, location: profile.Location, count: u64) !void {
        try (profile.Event{ .sample = .{ .location = location, .count = count } }).writeJsonLine(writer);
    }

    pub fn writeRuntimeAndSamples(
        self: *Profiler,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        duration_ns: u64,
        loss_counter: profile.LossCounter,
        terminal_status: profile.TerminalStatus,
    ) !void {
        const sample_lines = try self.collectSampleLines(allocator);
        defer allocator.free(sample_lines);

        try self.writeRuntime(writer, duration_ns);
        try (profile.Event{ .sampling = self.profileSampling(
            loss_counter,
            terminal_status,
        ) }).writeJsonLine(writer);
        for (sample_lines) |line| {
            try self.writeSample(writer, line.location(), line.sampleCount());
        }
    }

    fn profileSampling(
        self: *const Profiler,
        loss_counter: profile.LossCounter,
        terminal_status: profile.TerminalStatus,
    ) profile.Sampling {
        const snapshot = self.samplingSnapshot();
        return .{
            .record_count = snapshot.record_count,
            .sample_record_count = snapshot.sample_record_count,
            .lost_record_count = snapshot.lost_record_count,
            .lost_event_count = snapshot.lost_event_count,
            .lost_samples_record_count = snapshot.lost_samples_record_count,
            .lost_samples_count = snapshot.lost_samples_count,
            .throttle_record_count = snapshot.throttle_record_count,
            .unthrottle_record_count = snapshot.unthrottle_record_count,
            .loss_counter = loss_counter,
            .terminal_status = terminal_status,
        };
    }

    fn collectSampleLines(self: *Profiler, allocator: std.mem.Allocator) ![]*source_map.Line {
        var sample_lines: std.ArrayListUnmanaged(*source_map.Line) = .empty;
        errdefer sample_lines.deinit(allocator);

        lockMutex(&self.source_mutex);
        defer self.source_mutex.unlock();

        var file_iter = self.sources.files.valueIterator();
        while (file_iter.next()) |file| {
            var line_iter = file.*.lines.valueIterator();
            while (line_iter.next()) |line| {
                if (line.*.sampleCount() != 0) try sample_lines.append(allocator, line.*);
            }
        }

        std.mem.sort(*source_map.Line, sample_lines.items, {}, sampleLineLessThan);
        return try sample_lines.toOwnedSlice(allocator);
    }
};

pub const Run = struct {
    selected: profile.Location,
    virtual_speedup: f64,
    throughput_snapshots: []progress_point.ThroughputSnapshot,
    latency_snapshots: []progress_point.LatencySnapshot,

    pub fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        allocator.free(self.selected.file);
        allocator.free(self.throughput_snapshots);
        allocator.free(self.latency_snapshots);
        self.* = undefined;
    }

    pub fn minDelta(self: Run) u64 {
        var result: u64 = std.math.maxInt(u64);
        var found = false;

        for (self.throughput_snapshots) |snapshot| {
            applyDelta(countToU64(snapshot.getDelta()), &found, &result);
        }
        for (self.latency_snapshots) |snapshot| {
            const arrivals = countToU64(snapshot.getBeginDelta());
            const departures = countToU64(snapshot.getEndDelta());
            if (arrivals != 0 and departures != 0) {
                applyDelta(@min(arrivals, departures), &found, &result);
            }
        }

        return if (found) result else 0;
    }

    pub fn writeEvents(
        self: Run,
        writer: *std.Io.Writer,
        duration_ns: u64,
        selected_samples: u64,
    ) !void {
        try (profile.Event{ .experiment = .{
            .selected = self.selected,
            .virtual_speedup = self.virtual_speedup,
            .duration_ns = duration_ns,
            .selected_samples = selected_samples,
        } }).writeJsonLine(writer);

        for (self.throughput_snapshots) |snapshot| {
            const delta = countToU64(snapshot.getDelta());
            if (delta == 0) continue;
            try (profile.Event{ .throughput = .{
                .name = snapshot.getName(),
                .delta = delta,
            } }).writeJsonLine(writer);
        }

        for (self.latency_snapshots) |snapshot| {
            const arrivals = countToU64(snapshot.getBeginDelta());
            const departures = countToU64(snapshot.getEndDelta());
            if (arrivals == 0 or departures == 0) continue;
            try (profile.Event{ .latency = .{
                .name = snapshot.getName(),
                .arrivals = arrivals,
                .departures = departures,
                .outstanding = countToU64(snapshot.getDifference()),
            } }).writeJsonLine(writer);
        }
    }
};

fn applyDelta(delta: u64, found: *bool, result: *u64) void {
    if (delta == 0) return;
    found.* = true;
    result.* = @min(result.*, delta);
}

fn countToU64(count: usize) u64 {
    return @intCast(count);
}

fn addAtomic(counter: *std.atomic.Value(u64), delta: u64) void {
    var current = counter.load(.monotonic);
    while (true) {
        const next = current +| delta;
        if (counter.cmpxchgWeak(current, next, .monotonic, .monotonic)) |observed| {
            current = observed;
        } else {
            return;
        }
    }
}

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn lineAddress(line: ?*source_map.Line) usize {
    return if (line) |selected| @intFromPtr(selected) else 0;
}

fn addressLine(address: usize) ?*source_map.Line {
    if (address == 0) return null;
    return @ptrFromInt(address);
}

fn sampleFromPerfRecord(record: perf.Record, callchain_scratch: []usize) !?source_map.Sample {
    if (!record.isSample()) return null;

    const ip = try addressToUsize(try record.getIp());
    var callchain_len: usize = 0;
    if (record.config.isSampling(.callchain)) {
        const callchain = try record.getCallchain();
        if (callchain.len() > callchain_scratch.len) return error.CallchainScratchTooSmall;
        while (callchain_len < callchain.len()) : (callchain_len += 1) {
            callchain_scratch[callchain_len] = try addressToUsize(callchain.at(callchain_len));
        }
    }

    return .{ .ip = ip, .callchain = callchain_scratch[0..callchain_len] };
}

fn addressToUsize(address: u64) !usize {
    return std.math.cast(usize, address) orelse error.AddressTooLarge;
}

fn waitForExperiment(
    duration_ns: u64,
    end_to_end: bool,
    running: ?*std.atomic.Value(bool),
    wait_fn: sampler_mod.WaitFn,
) u64 {
    const running_flag = running orelse return wait_fn(duration_ns);

    if (end_to_end) {
        var elapsed_ns: u64 = 0;
        const interval_ns = experiment.experiment_cool_off_time_ns;
        while (running_flag.load(.acquire)) {
            elapsed_ns +|= wait_fn(interval_ns);
        }
        return elapsed_ns;
    }

    return waitDurationWhileRunning(duration_ns, running_flag, wait_fn);
}

fn waitDurationWhileRunning(
    duration_ns: u64,
    running: *std.atomic.Value(bool),
    wait_fn: sampler_mod.WaitFn,
) u64 {
    var elapsed_ns: u64 = 0;
    while (elapsed_ns < duration_ns and running.load(.acquire)) {
        const remaining_ns = duration_ns - elapsed_ns;
        const interval_ns = @min(remaining_ns, experiment.experiment_cool_off_time_ns);
        const waited_ns = wait_fn(interval_ns);
        elapsed_ns +|= if (waited_ns == 0 and interval_ns != 0) interval_ns else waited_ns;
    }
    return elapsed_ns;
}

fn sampleLineLessThan(_: void, lhs: *source_map.Line, rhs: *source_map.Line) bool {
    const file_order = std.mem.order(u8, lhs.file.name, rhs.file.name);
    if (file_order != .eq) return file_order == .lt;
    return lhs.number < rhs.number;
}

fn exactWait(ns: u64) u64 {
    return ns;
}

var experiment_test_counter: ?*abi.Counter = null;
var experiment_test_running: ?*std.atomic.Value(bool) = null;
var experiment_test_waits: std.atomic.Value(u32) = .init(0);

fn progressWait(ns: u64) u64 {
    if (experiment_test_counter) |counter| {
        _ = @atomicRmw(usize, &counter.count, .Add, 6, .monotonic);
    }
    return ns;
}

fn stoppingWait(ns: u64) u64 {
    const waits = experiment_test_waits.fetchAdd(1, .monotonic);
    if (waits == 1) {
        if (experiment_test_running) |running| running.store(false, .release);
    }
    return ns;
}

fn writePerfU64(bytes: []u8, offset: *usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset.*..][0..@sizeOf(u64)], value, .native);
    offset.* += @sizeOf(u64);
}

fn finishPerfRecord(bytes: []u8, len: usize, record_type: perf.RecordType) []const u8 {
    std.mem.writeInt(u32, bytes[0..4], @backingInt(record_type), .native);
    std.mem.writeInt(u16, bytes[4..6], 0, .native);
    std.mem.writeInt(u16, bytes[6..8], @intCast(len), .native);
    return bytes[0..len];
}

fn finishPerfSample(bytes: []u8, len: usize) []const u8 {
    return finishPerfRecord(bytes, len, .sample);
}

fn writeRingBytes(data: []u8, index: u64, bytes: []const u8) void {
    const ring_len: u64 = @intCast(data.len);
    for (bytes, 0..) |byte, offset| {
        const ring_index: usize = @intCast((index + @as(u64, @intCast(offset))) % ring_len);
        data[ring_index] = byte;
    }
}
