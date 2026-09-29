const std = @import("std");

pub const default_retained_frame_byte_count: usize = 3840 * 2160 * 4;

/// Configures storage bounds and time limits for presentation tracking and frame delivery. The pending
/// record capacity, N (`pending_feedback_count`, default 256), budgets simultaneously for staged frames
/// waiting on a compositor callback, active protocol requests, and expired tombstones. When these records
/// fill, subsequent frames are still accepted rather than refused, and each generates a counted `unknown`
/// outcome (`feedback_capacity_unknown_count`). The outcome queue capacity (`retained_outcome_count`) must
/// be at least 2N to guarantee burst retention.
///
/// The feedback deadline (`feedback_deadline_ns`, default one second) is evaluated while polling and uses
/// the monotonic awake clock. Protocol records that exceed this deadline expire into tombstones and report
/// an unknown outcome: each tombstone retains its slot until the compositor delivers its terminal event,
/// which is then consumed without emitting a duplicate outcome.
pub const Limits = struct {
    pending_feedback_count: usize = 256,
    retained_outcome_count: usize = 512,
    feedback_deadline_ns: u64 = std.time.ns_per_s,
    active_buffer_count: usize = 3,
    retired_buffer_count: usize = 3,
    retained_frame_byte_count: usize = default_retained_frame_byte_count,
};

pub const CapacityError = error{
    FrameStorageEmpty,
    CapacityOverflow,
};

pub const Capacity = struct {
    retained_frame_byte_count: usize,
    x11_packed_region_bytes: usize,
    wayland_pending_frame_bytes: usize,
    cocoa_frame_slot_count: usize,
    cocoa_frame_storage_bytes: usize,
    maximum_backend_frame_storage_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        if (limits.retained_frame_byte_count == 0) return error.FrameStorageEmpty;
        const cocoa_frame_slot_count = 2;
        const cocoa_frame_storage_bytes = std.math.mul(
            usize,
            limits.retained_frame_byte_count,
            cocoa_frame_slot_count,
        ) catch return error.CapacityOverflow;
        return .{
            .retained_frame_byte_count = limits.retained_frame_byte_count,
            .x11_packed_region_bytes = limits.retained_frame_byte_count,
            .wayland_pending_frame_bytes = limits.retained_frame_byte_count,
            .cocoa_frame_slot_count = cocoa_frame_slot_count,
            .cocoa_frame_storage_bytes = cocoa_frame_storage_bytes,
            .maximum_backend_frame_storage_bytes = cocoa_frame_storage_bytes,
        };
    }
};

pub const StorageStatus = struct {
    empty_region_fallback_count: u64 = 0,
    x11_pixmap_refusal_count: u64 = 0,
    x11_direct_frame_count: u64 = 0,
    feedback_capacity_unknown_count: u64 = 0,
    feedback_deadline_unknown_count: u64 = 0,
    feedback_clock_unknown_count: u64 = 0,
    feedback_protocol_unknown_count: u64 = 0,
    feedback_invalid_unknown_count: u64 = 0,
    feedback_dropped_outcome_count: u64 = 0,
    retired_buffer_capacity_rejection_count: u64 = 0,
    frame_capacity_rejection_count: u64 = 0,
    wayland_output_capacity_rejection_count: u64 = 0,
    /// The count of presents in which at least one accumulator ran out of room
    /// and fell back to a single covering rectangle. The Wayland backend raises
    /// the count in `Presenter.markRegions` by one per present, whatever the
    /// number of accumulators that collapsed within it. A present whose
    /// accumulator collapsed still reaches the compositor and still carries the
    /// right pixels, at the cost of sending more of them. The count stops at
    /// the largest value the field holds. A caller reads the field through the
    /// presentation storage status the window reports to know when the backend
    /// sent more pixels than the regions it reported cover.
    damage_capacity_collapse_count: u64 = 0,
};

pub const Status = enum {
    unavailable,
    active,
    failed,
};

pub const TimestampError = error{InvalidTimestamp};

pub const Timestamp = struct {
    seconds: u64,
    nanoseconds: u32,

    pub fn init(seconds: u64, nanoseconds: u32) TimestampError!Timestamp {
        if (nanoseconds >= std.time.ns_per_s) return error.InvalidTimestamp;
        return .{
            .seconds = seconds,
            .nanoseconds = nanoseconds,
        };
    }

    pub fn fromNanoseconds(nanoseconds: u64) Timestamp {
        return .{
            .seconds = nanoseconds / std.time.ns_per_s,
            .nanoseconds = @intCast(nanoseconds % std.time.ns_per_s),
        };
    }

    pub fn totalNanoseconds(self: Timestamp) u128 {
        return @as(u128, self.seconds) * std.time.ns_per_s + self.nanoseconds;
    }

    pub fn elapsedSince(self: Timestamp, earlier: Timestamp) ?u128 {
        const current = self.totalNanoseconds();
        const start = earlier.totalNanoseconds();
        return if (current >= start) current - start else null;
    }
};

pub const Kind = packed struct(u32) {
    vsync: bool = false,
    hw_clock: bool = false,
    hw_completion: bool = false,
    zero_copy: bool = false,
    _: u28 = 0,
};

pub const Submission = struct {
    id: u64,
    clock_id: u32,
    timestamp: Timestamp,
};

pub const Presented = struct {
    submission: Submission,
    timestamp: Timestamp,
    refresh_nanoseconds: u32,
    sequence: u64,
    kind: Kind,
    synchronized_outputs: u32,

    pub fn latencyNanoseconds(self: Presented) ?u128 {
        return self.timestamp.elapsedSince(self.submission.timestamp);
    }
};

pub const Discarded = struct {
    submission: Submission,
};

pub const UnknownCause = enum { capacity, deadline, clock, protocol, invalid };

/// Records an accepted presentation submission for which no physical display result will ever be
/// reported. The struct preserves the original submission identifier but sets all timing and clock values
/// to zero. Callers observe the underlying failure reason through
/// `cause`, which classifies the outcome as capacity exhaustion, deadline expiration, clock failure,
/// protocol error, or invalid event payload (`capacity`, `deadline`, `clock`, `protocol`, `invalid`).
pub const Unknown = struct {
    submission: Submission,
    cause: UnknownCause,
};

pub const Outcome = union(enum) {
    unknown: Unknown,
    presented: Presented,
    discarded: Discarded,

    pub fn submission(self: Outcome) Submission {
        return switch (self) {
            .presented => |value| value.submission,
            .discarded => |value| value.submission,
            .unknown => |value| value.submission,
        };
    }
};

pub fn rgba8ByteCount(width: u32, height: u32) ?usize {
    if (width == 0 or height == 0) return null;
    const pixels = std.math.mul(usize, width, height) catch return null;
    return std.math.mul(usize, pixels, 4) catch null;
}

test "presentation capacity derives exact backend frame storage" {
    const capacity = try Capacity.derive(.{ .retained_frame_byte_count = 13 });
    try std.testing.expectEqual(@as(usize, 13), capacity.retained_frame_byte_count);
    try std.testing.expectEqual(@as(usize, 13), capacity.x11_packed_region_bytes);
    try std.testing.expectEqual(@as(usize, 13), capacity.wayland_pending_frame_bytes);
    try std.testing.expectEqual(@as(usize, 2), capacity.cocoa_frame_slot_count);
    try std.testing.expectEqual(@as(usize, 26), capacity.cocoa_frame_storage_bytes);
    try std.testing.expectEqual(@as(usize, 26), capacity.maximum_backend_frame_storage_bytes);
    try std.testing.expectError(error.FrameStorageEmpty, Capacity.derive(.{
        .retained_frame_byte_count = 0,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .retained_frame_byte_count = std.math.maxInt(usize),
    }));
}

test "RGBA frame bytes reject empty and overflowing dimensions" {
    try std.testing.expectEqual(@as(?usize, 48), rgba8ByteCount(4, 3));
    try std.testing.expectEqual(@as(?usize, null), rgba8ByteCount(0, 3));
    try std.testing.expectEqual(
        @as(?usize, null),
        rgba8ByteCount(std.math.maxInt(u32), std.math.maxInt(u32)),
    );
}

test "timestamps validate their nanosecond component" {
    const timestamp = try Timestamp.init(0x0123_4567_89ab_cdef, 987_654_321);
    try std.testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), timestamp.seconds);
    try std.testing.expectEqual(@as(u32, 987_654_321), timestamp.nanoseconds);
    try std.testing.expectError(error.InvalidTimestamp, Timestamp.init(0, std.time.ns_per_s));
}

test "presented outcomes derive latency in the compositor clock domain" {
    const submitted = Timestamp.fromNanoseconds(4_000_000_005);
    const presented = Timestamp.fromNanoseconds(4_016_666_672);
    const outcome = Presented{
        .submission = .{ .id = 1, .clock_id = 7, .timestamp = submitted },
        .timestamp = presented,
        .refresh_nanoseconds = 16_666_667,
        .sequence = 3,
        .kind = .{ .vsync = true },
        .synchronized_outputs = 1,
    };
    try std.testing.expectEqual(@as(?u128, 16_666_667), outcome.latencyNanoseconds());
}
