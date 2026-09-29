const std = @import("std");
const alloc_phase = @import("alloc_phase");

pub const storage_alignment: usize = @max(@alignOf(f64), @alignOf(u64));

pub const Limits = struct {
    max_samples_per_series: usize,
    max_bootstrap_iterations: u32,
};

pub const DeriveError = error{
    InvalidSampleLimit,
    SampleLimitTooLarge,
    InvalidBootstrapIterationLimit,
    CapacityOverflow,
};

pub const Capacity = struct {
    limits: Limits,
    effects_offset: usize,
    samples_offset: usize,
    counts_offset: usize,
    storage_bytes: usize,

    pub fn derive(limits: Limits) DeriveError!Capacity {
        if (limits.max_samples_per_series == 0) return error.InvalidSampleLimit;
        if (limits.max_samples_per_series > std.math.maxInt(u32)) {
            return error.SampleLimitTooLarge;
        }
        if (limits.max_bootstrap_iterations == 0) {
            return error.InvalidBootstrapIterationLimit;
        }
        const effects = try placed(f64, 0, limits.max_bootstrap_iterations);
        const samples = try placed(u64, effects.end, limits.max_samples_per_series);
        const counts = try placed(u32, samples.end, limits.max_samples_per_series);
        std.debug.assert(effects.start == 0);
        std.debug.assert(effects.end <= samples.start);
        std.debug.assert(samples.end <= counts.start);
        return .{
            .limits = limits,
            .effects_offset = effects.start,
            .samples_offset = samples.start,
            .counts_offset = counts.start,
            .storage_bytes = counts.end,
        };
    }
};

const Region = struct {
    start: usize,
    end: usize,
};

fn placed(comptime T: type, offset: usize, count: usize) DeriveError!Region {
    const mask: usize = @alignOf(T) - 1;
    const padded = std.math.add(usize, offset, mask) catch return error.CapacityOverflow;
    const start = padded & ~mask;
    const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return error.CapacityOverflow;
    return .{
        .start = start,
        .end = std.math.add(usize, start, bytes) catch return error.CapacityOverflow,
    };
}

fn modelCapacity(limits: Limits) DeriveError!Capacity {
    if (limits.max_samples_per_series == 0) return error.InvalidSampleLimit;
    if (limits.max_samples_per_series > std.math.maxInt(u32)) {
        return error.SampleLimitTooLarge;
    }
    if (limits.max_bootstrap_iterations == 0) {
        return error.InvalidBootstrapIterationLimit;
    }
    const iterations: u128 = limits.max_bootstrap_iterations;
    const samples: u128 = limits.max_samples_per_series;
    const effects_offset: u128 = 0;
    const samples_offset = effects_offset + iterations * @sizeOf(f64);
    const counts_offset = samples_offset + samples * @sizeOf(u64);
    const storage_bytes = counts_offset + samples * @sizeOf(u32);
    if (samples_offset > std.math.maxInt(usize) or
        counts_offset > std.math.maxInt(usize) or
        storage_bytes > std.math.maxInt(usize))
    {
        return error.CapacityOverflow;
    }
    return .{
        .limits = limits,
        .effects_offset = @intCast(effects_offset),
        .samples_offset = @intCast(samples_offset),
        .counts_offset = @intCast(counts_offset),
        .storage_bytes = @intCast(storage_bytes),
    };
}

test "comparison capacity matches an independent byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").ComparisonStorage, "bench_comparison_capacity"),
        );
    }

    const limits = Limits{
        .max_samples_per_series = 8,
        .max_bootstrap_iterations = 500,
    };
    try std.testing.expectEqual(try modelCapacity(limits), try Capacity.derive(limits));
    try std.testing.expectEqual(@as(usize, 4_096), (try Capacity.derive(limits)).storage_bytes);
}

test "comparison capacity rejects invalid and overflowing limits" {
    try std.testing.expectError(
        error.InvalidSampleLimit,
        Capacity.derive(.{ .max_samples_per_series = 0, .max_bootstrap_iterations = 1 }),
    );
    try std.testing.expectError(
        error.InvalidBootstrapIterationLimit,
        Capacity.derive(.{ .max_samples_per_series = 1, .max_bootstrap_iterations = 0 }),
    );
    const extreme_error = if (@bitSizeOf(usize) > @bitSizeOf(u32))
        error.SampleLimitTooLarge
    else
        error.CapacityOverflow;
    try std.testing.expectError(extreme_error, Capacity.derive(.{
        .max_samples_per_series = std.math.maxInt(usize),
        .max_bootstrap_iterations = 1,
    }));
}
