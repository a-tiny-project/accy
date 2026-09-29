const std = @import("std");

pub const Bucket = enum {
    valid,
    invalid,
    boundary,
    large_state,
};

pub const Counts = struct {
    valid: u64 = 0,
    invalid: u64 = 0,
    boundary: u64 = 0,
    large_state: u64 = 0,

    pub fn get(self: Counts, bucket: Bucket) u64 {
        return switch (bucket) {
            .valid => self.valid,
            .invalid => self.invalid,
            .boundary => self.boundary,
            .large_state => self.large_state,
        };
    }
};

pub const Counters = struct {
    counts: Counts = .{},

    pub fn record(self: *Counters, bucket: Bucket) void {
        const counter = switch (bucket) {
            .valid => &self.counts.valid,
            .invalid => &self.counts.invalid,
            .boundary => &self.counts.boundary,
            .large_state => &self.counts.large_state,
        };
        std.debug.assert(counter.* < std.math.maxInt(u64));
        counter.* += 1;
    }

    pub fn snapshot(self: *const Counters) Counts {
        return self.counts;
    }

    pub fn meets(self: *const Counters, minimum: Counts) bool {
        for (std.meta.tags(Bucket)) |bucket| {
            if (self.counts.get(bucket) < minimum.get(bucket)) return false;
        }
        return true;
    }

    pub fn require(self: *const Counters, minimum: Counts) error{InsufficientCoverage}!void {
        if (!self.meets(minimum)) return error.InsufficientCoverage;
    }
};

test "coverage: independent generators retain reachability buckets" {
    var plans = Counters{};
    var values = Counters{};
    plans.record(.valid);
    plans.record(.boundary);
    values.record(.invalid);
    values.record(.large_state);

    try std.testing.expect(plans.meets(.{ .valid = 1, .boundary = 1 }));
    try std.testing.expect(values.meets(.{ .invalid = 1, .large_state = 1 }));
    try std.testing.expect(!plans.meets(.{ .large_state = 1 }));
    try std.testing.expectError(
        error.InsufficientCoverage,
        plans.require(.{ .large_state = 1 }),
    );
    try values.require(.{ .invalid = 1, .large_state = 1 });
    try std.testing.expectEqual(@as(u64, 0), values.snapshot().valid);
}
