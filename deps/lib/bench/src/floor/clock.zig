const std = @import("std");

/// The core clock rate a cycle count converts at, held in kilohertz. Firmware
/// picks the core clock per run over a wide range, so a floor stated in
/// nanoseconds carries meaning only next to the clock that produced it. A
/// caller builds one from the same run that produced the measurement, and
/// reaches for no nominal or maximum figure.
pub const Clock = struct {
    kilohertz: u32,

    /// Derives the clock a measured interval achieved from the cycles it spent
    /// and the nanoseconds it took. A zero on either side returns
    /// `error.NoInterval`. A rate below one kilohertz returns
    /// `error.BelowResolution`, and one above the `u32` range returns
    /// `error.Overflow`.
    pub fn observed(
        elapsed_cycles: u64,
        elapsed_ns: u64,
    ) error{ Overflow, NoInterval, BelowResolution }!Clock {
        if (elapsed_ns == 0 or elapsed_cycles == 0) return error.NoInterval;
        std.debug.assert(elapsed_cycles > 0);
        std.debug.assert(elapsed_ns > 0);
        const scaled = try std.math.mul(u64, elapsed_cycles, std.time.us_per_s);
        std.debug.assert(scaled >= elapsed_cycles);
        const kilohertz = scaled / elapsed_ns;
        if (kilohertz == 0) return error.BelowResolution;
        if (kilohertz > std.math.maxInt(u32)) return error.Overflow;
        return .{ .kilohertz = @intCast(kilohertz) };
    }

    /// The nanoseconds a cycle count occupies at this clock. Zero cycles cost
    /// zero nanoseconds. The result rounds up, which holds the bound it belongs
    /// to at or above the true time. A product outside the `u64` range returns
    /// `error.Overflow`.
    pub fn nanoseconds(self: Clock, cycle_count: u64) error{Overflow}!u64 {
        std.debug.assert(self.kilohertz > 0);
        if (cycle_count == 0) return 0;
        const scaled = try std.math.mul(u64, cycle_count, std.time.us_per_s);
        std.debug.assert(scaled >= cycle_count);
        const result = scaled / self.kilohertz +
            @intFromBool(scaled % self.kilohertz != 0);
        std.debug.assert(result > 0);
        std.debug.assert(result <= scaled);
        return result;
    }

    /// The cycles a nanosecond floor spans at this clock. Some owners state
    /// their floors in cycles. The result rounds up the way `nanoseconds` does,
    /// so one rounding rule governs both directions. The call returns a number
    /// and changes nothing: the clock is left as it was, and pricing a term
    /// goes through `nanoseconds`. A floor this function reads back after
    /// `nanoseconds` produced it can come out as much as
    /// `ceil(kilohertz / 1,000,000)` cycles above the count that went in,
    /// because the nanosecond figure was itself lifted to a whole nanosecond.
    /// The count coming back is at least the count that went in, and the two
    /// agree exactly at 1,000,000 kilohertz. A product outside the `u64` range
    /// returns `error.Overflow`.
    pub fn cycles(self: Clock, floor_ns: u64) error{Overflow}!u64 {
        std.debug.assert(self.kilohertz > 0);
        if (floor_ns == 0) return 0;
        const scaled = try std.math.mul(u64, floor_ns, self.kilohertz);
        std.debug.assert(scaled >= floor_ns);
        const result = scaled / std.time.us_per_s +
            @intFromBool(scaled % std.time.us_per_s != 0);
        std.debug.assert(result > 0);
        std.debug.assert(result <= scaled);
        return result;
    }
};

test "observed clock derives kilohertz from a measured interval" {
    const clock = try Clock.observed(4_600_000_000, std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 4_600_000), clock.kilohertz);
}

test "observed clock refuses an empty interval" {
    try std.testing.expectError(error.NoInterval, Clock.observed(0, 1));
    try std.testing.expectError(error.NoInterval, Clock.observed(1, 0));
}

test "observed clock refuses a clock outside the kilohertz range" {
    try std.testing.expectError(error.BelowResolution, Clock.observed(1, std.time.ns_per_s));
    const above = @as(u64, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(error.Overflow, Clock.observed(above, std.time.ns_per_ms));
}

test "nanoseconds rounds up so a floor never understates" {
    const clock = Clock{ .kilohertz = 4_600_000 };
    try std.testing.expectEqual(@as(u64, 0), try clock.nanoseconds(0));
    try std.testing.expectEqual(@as(u64, 1), try clock.nanoseconds(1));
    try std.testing.expectEqual(@as(u64, 1_000_000), try clock.nanoseconds(4_600_000));
    try std.testing.expectEqual(@as(u64, 1_000_001), try clock.nanoseconds(4_600_001));
}

test "nanoseconds reports overflow instead of wrapping" {
    const clock = Clock{ .kilohertz = 1 };
    try std.testing.expectError(error.Overflow, clock.nanoseconds(std.math.maxInt(u64)));
}

test "a faster clock never produces a larger nanosecond bound" {
    const slow = Clock{ .kilohertz = 2_500_000 };
    const fast = Clock{ .kilohertz = 4_850_000 };
    const cycles: u64 = 262_156;
    try std.testing.expect(try fast.nanoseconds(cycles) < try slow.nanoseconds(cycles));
}

test "cycles reads a nanosecond floor back rounded up" {
    const clock = Clock{ .kilohertz = 4_600_000 };
    try std.testing.expectEqual(@as(u64, 0), try clock.cycles(0));
    try std.testing.expectEqual(@as(u64, 5), try clock.cycles(1));
    try std.testing.expectEqual(@as(u64, 4_600_000), try clock.cycles(1_000_000));
    try std.testing.expectEqual(@as(u64, 911_806), try clock.nanoseconds(4_194_304));
    try std.testing.expectEqual(@as(u64, 4_194_308), try clock.cycles(911_806));
}

test "a round trip never understates and overstates by at most one nanosecond of cycles" {
    const clocks = [_]u32{ 999_999, 1_000_000, 2_500_000, 4_600_000, 5_700_000 };
    const bounds = [_]u64{ 1, 1, 3, 5, 6 };
    for (clocks, bounds) |kilohertz, bound| {
        const clock = Clock{ .kilohertz = kilohertz };
        var count: u64 = 1;
        while (count <= 20_000) : (count += 1) {
            const read_back = try clock.cycles(try clock.nanoseconds(count));
            try std.testing.expect(read_back >= count);
            try std.testing.expect(read_back - count <= bound);
            if (kilohertz == std.time.us_per_s) try std.testing.expectEqual(count, read_back);
        }
        std.debug.assert(count == 20_001);
    }
}

test "cycles reports overflow instead of wrapping" {
    const clock = Clock{ .kilohertz = 2 };
    try std.testing.expectError(error.Overflow, clock.cycles(std.math.maxInt(u64)));
}
