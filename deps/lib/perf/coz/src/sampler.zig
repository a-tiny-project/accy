const std = @import("std");
const sys = @import("sys");

const experiment = @import("experiment.zig");
const perf = sys.perf;
const timer = sys.timer;

pub const default_sample_batch_size: u32 = @intCast(experiment.sample_batch_size);
pub const WaitFn = *const fn (u64) u64;

pub const LossCounter = union(enum) {
    available: u64,
    unsupported,
    read_failed,
};

pub const Options = struct {
    sample_period_ns: u64 = experiment.sample_period_ns,
    sample_batch_size: u32 = default_sample_batch_size,
    signal: timer.Signal = timer.sample_signal,
    sample_type: u64 = perf.default_sample_type,
    read_format: u64 = 0,
    exclude_kernel: bool = true,
    exclude_idle: bool = true,

    pub fn perfOptions(self: Options) perf.SamplerOptions {
        return .{
            .sample_period_ns = self.sample_period_ns,
            .sample_batch_size = self.sample_batch_size,
            .sample_type = self.sample_type,
            .read_format = self.read_format,
            .exclude_kernel = self.exclude_kernel,
            .exclude_idle = self.exclude_idle,
        };
    }
};

pub const Sampler = struct {
    event: perf.Event = .{},
    wake_timer: timer.Timer = .{},
    wake_interval_ns: u64 = 0,
    loss_counter_supported: bool = false,

    pub fn openCurrentThread(options: Options) !Sampler {
        try validateOptions(options);
        const interval_ns = try wakeIntervalNs(options);

        var opened = try openPerfEvent(options);
        errdefer opened.event.close();

        var wake_timer = try timer.Timer.createForCurrentThread(options.signal);
        errdefer wake_timer.close();

        return .{
            .event = opened.event,
            .wake_timer = wake_timer,
            .wake_interval_ns = interval_ns,
            .loss_counter_supported = opened.loss_counter_supported,
        };
    }

    pub fn close(self: *Sampler) void {
        self.wake_timer.close();
        self.event.close();
        self.wake_interval_ns = 0;
        self.loss_counter_supported = false;
    }

    pub fn start(self: *Sampler) !void {
        try self.event.start();
        errdefer self.event.stop() catch {};
        try self.wake_timer.startInterval(self.wake_interval_ns);
    }

    pub fn stop(self: *Sampler) !void {
        var first_error: ?anyerror = null;
        self.wake_timer.stop() catch |err| rememberError(&first_error, err);
        self.event.stop() catch |err| rememberError(&first_error, err);
        if (first_error) |err| return err;
    }

    pub fn ringReader(self: *Sampler) ?perf.RingReader {
        return self.event.ringReader();
    }

    pub fn commitReader(self: *Sampler, reader: perf.RingReader) void {
        self.event.commitReader(reader);
    }

    pub fn readLossCounter(self: *Sampler) LossCounter {
        if (!self.loss_counter_supported) return .unsupported;
        const result = self.event.countResult() catch return .read_failed;
        return .{ .available = result.lost orelse return .read_failed };
    }

    pub fn pausingWait(self: *Sampler, wait_fn: WaitFn) PausingWait {
        return .{ .sampler = self, .wait_fn = wait_fn };
    }
};

const OpenedPerfEvent = struct {
    event: perf.Event,
    loss_counter_supported: bool,
};

fn openPerfEvent(options: Options) !OpenedPerfEvent {
    if (comptime !perf.supported) return error.UnsupportedPlatform;
    var perf_options = options.perfOptions();
    if (perf_options.read_format & perf.ReadFormat.group != 0) {
        return .{
            .event = try perf.Event.openTaskClockSampler(perf_options),
            .loss_counter_supported = false,
        };
    }

    perf_options.read_format |= perf.ReadFormat.lost;
    const event = perf.Event.openTaskClockSampler(perf_options) catch |err| switch (err) {
        error.InvalidPerfEventOptions => fallback: {
            perf_options.read_format &= ~perf.ReadFormat.lost;
            break :fallback try perf.Event.openTaskClockSampler(perf_options);
        },
        else => return err,
    };
    return .{
        .event = event,
        .loss_counter_supported = event.config.read_format & perf.ReadFormat.lost != 0,
    };
}

pub const PausingWait = struct {
    sampler: *Sampler,
    wait_fn: WaitFn,

    pub fn wait(self: PausingWait, ns: u64) u64 {
        self.sampler.stop() catch {};
        defer self.sampler.start() catch {};
        return self.wait_fn(ns);
    }
};

pub fn validateOptions(options: Options) !void {
    if (options.sample_period_ns == 0) return error.InvalidSamplePeriod;
    if (options.sample_batch_size == 0) return error.InvalidSampleBatchSize;
    _ = try wakeIntervalNs(options);
}

pub fn wakeIntervalNs(options: Options) !u64 {
    return std.math.mul(u64, options.sample_period_ns, @as(u64, options.sample_batch_size));
}

pub fn unavailable(err: anyerror) bool {
    return switch (err) {
        error.UnsupportedPlatform,
        error.PermissionDenied,
        error.DeviceBusy,
        error.ProcessResources,
        error.EventRequiresUnsupportedCpuFeature,
        error.TooManyBreakpoints,
        error.SampleStackNotSupported,
        error.EventNotSupported,
        error.SampleMaxStackOverflow,
        error.ProcessNotFound,
        error.SystemResources,
        error.TooBig,
        => true,
        else => false,
    };
}

fn rememberError(first_error: *?anyerror, err: anyerror) void {
    if (first_error.* == null) first_error.* = err;
}

var test_wait_calls: std.atomic.Value(u32) = .init(0);

fn countedWait(ns: u64) u64 {
    _ = test_wait_calls.fetchAdd(1, .monotonic);
    return ns + 1;
}
