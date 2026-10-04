const std = @import("std");

pub const sample_period_ns: u64 = 1_000_000;
pub const sample_batch_size: u64 = 10;
pub const speedup_divisions: u64 = 20;
pub const zero_speedup_weight: u64 = 7;
pub const experiment_min_time_ns: u64 = sample_period_ns * sample_batch_size * 50;
pub const experiment_cool_off_time_ns: u64 = sample_period_ns * sample_batch_size;
pub const experiment_target_delta: u64 = 5;
pub const experiment_max_time_ns: u64 = experiment_min_time_ns * 16;

pub const Draw = struct {
    value: u64,

    pub fn init(value: u64) !Draw {
        if (value > maxDraw()) return error.InvalidSpeedupDraw;
        return .{ .value = value };
    }

    pub fn maxDraw() u64 {
        return zero_speedup_weight + speedup_divisions;
    }
};

pub const Plan = struct {
    delay_size_ns: u64,
    virtual_speedup: f64,
    duration_ns: u64,
};

pub fn planFromDraw(draw: Draw, duration_ns: u64) Plan {
    const delay_size = delaySizeFromDraw(draw);
    return .{
        .delay_size_ns = delay_size,
        .virtual_speedup = virtualSpeedupFromDelay(delay_size),
        .duration_ns = duration_ns,
    };
}

pub fn delaySizeFromDraw(draw: Draw) u64 {
    if (draw.value <= zero_speedup_weight) return 0;
    return (draw.value - zero_speedup_weight) * sample_period_ns / speedup_divisions;
}

pub fn fixedDelaySize(speedup_percent: i32) ?u64 {
    if (speedup_percent < 0 or speedup_percent > 100) return null;
    return sample_period_ns * @as(u64, @intCast(speedup_percent)) / 100;
}

pub fn virtualSpeedupFromDelay(delay_size_ns: u64) f64 {
    return @as(f64, @floatFromInt(delay_size_ns)) / @as(f64, @floatFromInt(sample_period_ns));
}

pub fn adjustDuration(current_duration_ns: u64, min_delta: u64) u64 {
    if (min_delta < experiment_target_delta) {
        return @min(current_duration_ns * 2, experiment_max_time_ns);
    }
    if (min_delta > experiment_target_delta * 2 and current_duration_ns >= experiment_min_time_ns * 2) {
        return current_duration_ns / 2;
    }
    return current_duration_ns;
}

pub fn correctedDurationNs(elapsed_ns: u64, inserted_delay_ns: u64, overshoot_ns: u64) u64 {
    return elapsed_ns -| inserted_delay_ns -| overshoot_ns;
}

test "draw range matches upstream uniform distribution bounds" {
    try std.testing.expectEqual(@as(u64, 27), Draw.maxDraw());
    try std.testing.expectError(error.InvalidSpeedupDraw, Draw.init(28));
}

test "delay size from random draw preserves upstream weighting" {
    try std.testing.expectEqual(@as(u64, 0), delaySizeFromDraw(try Draw.init(0)));
    try std.testing.expectEqual(@as(u64, 0), delaySizeFromDraw(try Draw.init(7)));
    try std.testing.expectEqual(@as(u64, 50_000), delaySizeFromDraw(try Draw.init(8)));
    try std.testing.expectEqual(@as(u64, 500_000), delaySizeFromDraw(try Draw.init(17)));
    try std.testing.expectEqual(@as(u64, 1_000_000), delaySizeFromDraw(try Draw.init(27)));
}

test "fixed delay size accepts only percentage speedups" {
    try std.testing.expectEqual(@as(?u64, null), fixedDelaySize(-1));
    try std.testing.expectEqual(@as(?u64, null), fixedDelaySize(101));
    try std.testing.expectEqual(@as(?u64, 0), fixedDelaySize(0));
    try std.testing.expectEqual(@as(?u64, 250_000), fixedDelaySize(25));
    try std.testing.expectEqual(@as(?u64, 1_000_000), fixedDelaySize(100));
}

test "virtual speedup is delay size divided by sample period" {
    try std.testing.expectEqual(@as(f64, 0), virtualSpeedupFromDelay(0));
    try std.testing.expectEqual(@as(f64, 0.25), virtualSpeedupFromDelay(250_000));
    try std.testing.expectEqual(@as(f64, 1), virtualSpeedupFromDelay(sample_period_ns));
}

test "experiment duration adapts to progress-point deltas" {
    try std.testing.expectEqual(
        @as(u64, experiment_min_time_ns * 2),
        adjustDuration(experiment_min_time_ns, experiment_target_delta - 1),
    );
    try std.testing.expectEqual(
        @as(u64, experiment_max_time_ns),
        adjustDuration(experiment_max_time_ns, experiment_target_delta - 1),
    );
    try std.testing.expectEqual(
        @as(u64, experiment_min_time_ns),
        adjustDuration(experiment_min_time_ns * 2, experiment_target_delta * 2 + 1),
    );
    try std.testing.expectEqual(
        @as(u64, experiment_min_time_ns),
        adjustDuration(experiment_min_time_ns, experiment_target_delta * 2 + 1),
    );
    try std.testing.expectEqual(
        @as(u64, experiment_min_time_ns),
        adjustDuration(experiment_min_time_ns, experiment_target_delta),
    );
}

test "corrected duration removes inserted delay and overshoot" {
    try std.testing.expectEqual(@as(u64, 70), correctedDurationNs(100, 20, 10));
    try std.testing.expectEqual(@as(u64, 0), correctedDurationNs(100, 80, 30));
}

test "plan bundles delay speedup and duration" {
    const plan = planFromDraw(try Draw.init(12), experiment_min_time_ns);

    try std.testing.expectEqual(@as(u64, 250_000), plan.delay_size_ns);
    try std.testing.expectEqual(@as(f64, 0.25), plan.virtual_speedup);
    try std.testing.expectEqual(@as(u64, experiment_min_time_ns), plan.duration_ns);
}
