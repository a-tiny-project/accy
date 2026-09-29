const std = @import("std");

const clock_mod = @import("clock.zig");
const term_mod = @import("term.zig");

const Clock = clock_mod.Clock;
const Entry = term_mod.Entry;

/// Records whether the terms of a derivation cover all of the required work.
/// Work a derivation leaves out can only push the real time up, so a partial
/// derivation is a valid lower bound all the same. It gives up tightness alone,
/// and the gaps it names say where the slack sits.
pub const Coverage = union(enum) {
    complete,
    /// Every entry here is a piece of work the derivation leaves out, named
    /// either by repository path or by a phrase together with the file that
    /// owns it. A derivation counts as partial once every missing piece is
    /// named here.
    partial: []const []const u8,

    pub fn isComplete(self: Coverage) bool {
        return self == .complete;
    }
};

/// The bound for the work the benchmark's name claims, and the bound for the
/// rest of the timed region. The measurement it is compared against arrives as
/// an argument to the ratio functions and is held by the row around it.
/// `complete` carries the coverage the derivation reported.
pub const Estimate = struct {
    /// The bound, in nanoseconds, for the work the benchmark's name claims to
    /// measure.
    subject_ns: u64,
    /// The bound, in nanoseconds, for the contaminant work of the timed region.
    contaminant_ns: u64,
    complete: bool,

    /// Adds the subject bound to the contaminant bound, which is the bound a
    /// measurement is compared against. A sum outside the `u64` range returns
    /// `error.Overflow`.
    pub fn totalNs(self: Estimate) error{Overflow}!u64 {
        const total = try std.math.add(u64, self.subject_ns, self.contaminant_ns);
        std.debug.assert(total >= self.subject_ns);
        std.debug.assert(total >= self.contaminant_ns);
        return total;
    }

    /// Reports the headline ratio of a profiling row in thousandths: the
    /// measured time over the full bound. A bound of zero returns
    /// `error.Overflow`.
    pub fn ratioMilli(self: Estimate, measured_ns: u64) error{Overflow}!u64 {
        return try ratio(measured_ns, try self.totalNs());
    }

    /// Reports thousandths of the ratio a benchmark with its contaminants
    /// removed would report: the measured time over the subject bound alone.
    /// The number holds only where the contaminants can be removed, so a caller
    /// reads it together with the contaminant classes.
    pub fn subjectRatioMilli(self: Estimate, measured_ns: u64) error{Overflow}!u64 {
        return try ratio(measured_ns, self.subject_ns);
    }

    /// Reports the whole-percent share of the bound that is contaminant. The
    /// division truncates, which holds the share at or below the true one. A
    /// high share prevents the row from supporting fine-grained claims about
    /// its subject. A bound of zero reports zero.
    pub fn contaminantPercent(self: Estimate) error{Overflow}!u64 {
        const total = try self.totalNs();
        if (total == 0) return 0;
        std.debug.assert(self.contaminant_ns <= total);
        const scaled = try std.math.mul(u64, self.contaminant_ns, 100);
        const percent = scaled / total;
        std.debug.assert(percent <= 100);
        return percent;
    }
};

/// The disjoint required operations of one floor, the evidence for each, and
/// the prose naming the machine facts composing them and the work left out.
pub const Derivation = struct {
    entries: []const Entry,
    coverage: Coverage,
    /// Prose naming the machine facts composed into the bound. This text also
    /// names the work left out of the bound, because the ratio shows that work.
    /// `estimate` asserts the prose is non-empty.
    rationale: []const u8,

    /// Sums a derivation into the bound a gate prints by adding every entry
    /// into the subject bound or the contaminant bound by the role the entry
    /// carries. A caller passes the clock observed in the measured run. A
    /// caller may pass `null` when every term prices with no clock: bytes at a
    /// streaming rung, declared rates, and random bytes at DRAM, whose latency
    /// is already in nanoseconds. `estimate` asserts that every entry names an
    /// origin. A term that needs the clock returns `error.ClockRequired` when
    /// `clock` is `null`, and a sum outside the `u64` range returns
    /// `error.Overflow`.
    pub fn estimate(
        self: Derivation,
        clock: ?Clock,
    ) error{ Overflow, ClockRequired }!Estimate {
        var subject_ns: u64 = 0;
        var contaminant_ns: u64 = 0;
        std.debug.assert(self.rationale.len > 0);
        for (self.entries) |entry| {
            std.debug.assert(entry.origin.len > 0);
            const nanoseconds = try entry.term.nanoseconds(clock);
            if (entry.isSubject()) {
                subject_ns = try std.math.add(u64, subject_ns, nanoseconds);
            } else {
                contaminant_ns = try std.math.add(u64, contaminant_ns, nanoseconds);
            }
        }
        return .{
            .subject_ns = subject_ns,
            .contaminant_ns = contaminant_ns,
            .complete = self.coverage.isComplete(),
        };
    }
};

fn ratio(measured_ns: u64, bound_ns: u64) error{Overflow}!u64 {
    if (bound_ns == 0) return error.Overflow;
    std.debug.assert(bound_ns > 0);
    const scaled = try std.math.mul(u64, measured_ns, 1_000);
    const result = scaled / bound_ns;
    std.debug.assert(result <= scaled);
    return result;
}

/// Computes the ratio of a measurement to a bound as a whole number, rounded
/// up. This calculation keeps the shape that consumer gates compare against.
/// Reporting uses `ratioMilli`.
pub fn ceilingRatio(measured_ns: u64, bound_ns: u64) u64 {
    std.debug.assert(bound_ns > 0);
    const result = measured_ns / bound_ns + @intFromBool(measured_ns % bound_ns != 0);
    std.debug.assert(result <= measured_ns);
    return result;
}

test "coverage names what is missing or declares itself complete" {
    const complete: Coverage = .complete;
    try std.testing.expect(complete.isComplete());
    const gaps = [_][]const u8{"lowering visits: language/tree/lower.zig"};
    const partial = Coverage{ .partial = &gaps };
    try std.testing.expect(!partial.isComplete());
    try std.testing.expectEqual(@as(usize, 1), partial.partial.len);
}

test "subject and contaminant terms accumulate separately" {
    const entries = [_]Entry{
        .{
            .origin = "lib/simd/dev/src/profiling/arithmetic.zig:27",
            .term = .{ .parallel = .{ .operations = 262_157, .centicycles = 100 } },
        },
        .{
            .contaminant = .verify,
            .origin = "lib/simd/dev/src/profiling/arithmetic.zig:52",
            .term = .{ .serial = .{ .links = 262_157, .link_cycles = 4 } },
        },
    };
    const derivation = Derivation{
        .entries = &entries,
        .coverage = .complete,
        .rationale = "M2 issue width for the add loop; the witness chain is a " ++
            "serial xor and multiply the hardware cannot overlap",
    };
    const result = try derivation.estimate(.{ .kilohertz = 4_600_000 });
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(u64, 56_991), result.subject_ns);
    try std.testing.expectEqual(@as(u64, 227_963), result.contaminant_ns);
    try std.testing.expectEqual(@as(u64, 284_954), try result.totalNs());
}

test "the contaminant share truncates rather than rounding 79.9996 up" {
    const estimate = Estimate{
        .subject_ns = 56_991,
        .contaminant_ns = 227_963,
        .complete = true,
    };
    try std.testing.expectEqual(@as(u64, 1_031), try estimate.ratioMilli(294_000));
    try std.testing.expectEqual(@as(u64, 5_158), try estimate.subjectRatioMilli(294_000));
    try std.testing.expectEqual(@as(u64, 79), try estimate.contaminantPercent());
}

test "a clean row reports no contaminant share" {
    const estimate = Estimate{ .subject_ns = 1_000, .contaminant_ns = 0, .complete = true };
    try std.testing.expectEqual(@as(u64, 0), try estimate.contaminantPercent());
    try std.testing.expectEqual(
        try estimate.ratioMilli(2_000),
        try estimate.subjectRatioMilli(2_000),
    );
}

test "a zero bound reports overflow rather than dividing" {
    const empty = Estimate{ .subject_ns = 0, .contaminant_ns = 0, .complete = false };
    try std.testing.expectError(error.Overflow, empty.ratioMilli(100));
    try std.testing.expectEqual(@as(u64, 0), try empty.contaminantPercent());
}

test "ceiling ratio preserves the existing gate shape" {
    try std.testing.expectEqual(@as(u64, 1), ceilingRatio(100, 100));
    try std.testing.expectEqual(@as(u64, 2), ceilingRatio(101, 100));
    try std.testing.expectEqual(@as(u64, 3), ceilingRatio(24_921, 11_700));
    try std.testing.expectEqual(@as(u64, 21), ceilingRatio(24_921, 1_200));
}
