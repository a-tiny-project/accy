const std = @import("std");
const alloc_phase = @import("alloc_phase");

pub const storage_alignment: usize = @max(@alignOf(u64), @alignOf(f64));

pub const Limits = struct {
    samples: usize,
    bootstrap_iterations: u32 = @import("model.zig").default_bootstrap_iterations,
};

pub const DeriveError = error{
    InvalidSampleLimit,
    SampleLimitTooLarge,
    CapacityOverflow,
};

pub const Capacity = struct {
    limits: Limits,
    sorted_offset: usize,
    means_offset: usize,
    medians_offset: usize,
    p75s_offset: usize,
    p95s_offset: usize,
    p99s_offset: usize,
    counts_offset: usize,
    storage_bytes: usize,

    pub fn derive(limits: Limits) DeriveError!Capacity {
        if (limits.samples == 0) return error.InvalidSampleLimit;
        if (limits.samples > std.math.maxInt(u32)) return error.SampleLimitTooLarge;

        const sorted = try placed(u64, 0, limits.samples);
        const means = try placed(f64, sorted.end, limits.bootstrap_iterations);
        const medians = try placed(f64, means.end, limits.bootstrap_iterations);
        const p75s = try placed(f64, medians.end, limits.bootstrap_iterations);
        const p95s = try placed(f64, p75s.end, limits.bootstrap_iterations);
        const p99s = try placed(f64, p95s.end, limits.bootstrap_iterations);
        const counts = try placed(u32, p99s.end, limits.samples);
        std.debug.assert(sorted.start == 0);
        std.debug.assert(sorted.end <= means.start);
        std.debug.assert(means.end <= medians.start);
        std.debug.assert(medians.end <= p75s.start);
        std.debug.assert(p75s.end <= p95s.start);
        std.debug.assert(p95s.end <= p99s.start);
        std.debug.assert(p99s.end <= counts.start);
        return .{
            .limits = limits,
            .sorted_offset = sorted.start,
            .means_offset = means.start,
            .medians_offset = medians.start,
            .p75s_offset = p75s.start,
            .p95s_offset = p95s.start,
            .p99s_offset = p99s.start,
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
    if (limits.samples == 0) return error.InvalidSampleLimit;
    if (limits.samples > std.math.maxInt(u32)) return error.SampleLimitTooLarge;
    const samples: u128 = limits.samples;
    const iterations: u128 = limits.bootstrap_iterations;
    const sorted_offset: u128 = 0;
    const means_offset = sorted_offset + samples * @sizeOf(u64);
    const medians_offset = means_offset + iterations * @sizeOf(f64);
    const p75s_offset = medians_offset + iterations * @sizeOf(f64);
    const p95s_offset = p75s_offset + iterations * @sizeOf(f64);
    const p99s_offset = p95s_offset + iterations * @sizeOf(f64);
    const counts_offset = p99s_offset + iterations * @sizeOf(f64);
    const storage_bytes = counts_offset + samples * @sizeOf(u32);
    const values = [_]u128{
        means_offset,
        medians_offset,
        p75s_offset,
        p95s_offset,
        p99s_offset,
        counts_offset,
        storage_bytes,
    };
    for (values) |value| {
        if (value > std.math.maxInt(usize)) return error.CapacityOverflow;
    }
    return .{
        .limits = limits,
        .sorted_offset = @intCast(sorted_offset),
        .means_offset = @intCast(means_offset),
        .medians_offset = @intCast(medians_offset),
        .p75s_offset = @intCast(p75s_offset),
        .p95s_offset = @intCast(p95s_offset),
        .p99s_offset = @intCast(p99s_offset),
        .counts_offset = @intCast(counts_offset),
        .storage_bytes = @intCast(storage_bytes),
    };
}

test "statistics capacity matches an independent byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "bench_statistics_capacity"),
        );
    }

    const limits = Limits{ .samples = 13, .bootstrap_iterations = 1000 };
    try std.testing.expectEqual(try modelCapacity(limits), try Capacity.derive(limits));
    try std.testing.expectEqual(@as(usize, 40_156), (try Capacity.derive(limits)).storage_bytes);
}

test "statistics capacity rejects invalid and overflowing limits" {
    try std.testing.expectError(error.InvalidSampleLimit, Capacity.derive(.{ .samples = 0 }));
    if (std.math.maxInt(usize) > std.math.maxInt(u32)) {
        try std.testing.expectError(
            error.SampleLimitTooLarge,
            Capacity.derive(.{ .samples = @as(usize, std.math.maxInt(u32)) + 1 }),
        );
    }
    if (@bitSizeOf(usize) == 32) {
        try std.testing.expectError(
            error.CapacityOverflow,
            Capacity.derive(.{
                .samples = std.math.maxInt(u32),
                .bootstrap_iterations = std.math.maxInt(u32),
            }),
        );
    }
}
