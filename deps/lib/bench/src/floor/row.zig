const std = @import("std");

const clock_mod = @import("clock.zig");
const estimate_mod = @import("estimate.zig");

const Clock = clock_mod.Clock;
const Estimate = estimate_mod.Estimate;

/// A named cause and the owning Issue for a row whose ratio exceeds its
/// threshold.
pub const Gap = struct {
    cause: []const u8,
    issue: []const u8,
};

pub const metric_schema = "tiny.profiling.metric/v1";
pub const metric_aggregation = "fermi_derivation";

/// One measurement set beside the floor it is judged against, packaged as the
/// single line a profiling run emits. A caller formats it through `"{f}"`.
/// `format` sends one line to a `std.Io.Writer`, shaped
/// `profile gate <scope>: floor=<n>ns measured=<n>ns ratio=<n>`. Where `gap`
/// carries a value, the line continues with ` cause=<c> owner_issue=<i>`.
pub const Gate = struct {
    scope: []const u8,
    floor_ns: u64,
    measured_ns: u64,
    gap: ?Gap = null,

    /// Gives back `ceil(measured_ns / floor_ns)`, the number a threshold check
    /// reads.
    pub fn ratio(self: Gate) u64 {
        std.debug.assert(self.floor_ns > 0);
        return estimate_mod.ceilingRatio(self.measured_ns, self.floor_ns);
    }

    pub fn format(self: Gate, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        std.debug.assert(self.scope.len > 0);
        std.debug.assert(self.floor_ns > 0);
        const ratio_value = self.ratio();
        std.debug.assert(ratio_value <= self.measured_ns);
        if (self.gap) |finding| {
            try writer.print(
                "profile gate {s}: floor={d}ns measured={d}ns ratio={d} " ++
                    "cause={s} owner_issue={s}\n",
                .{
                    self.scope,
                    self.floor_ns,
                    self.measured_ns,
                    ratio_value,
                    finding.cause,
                    finding.issue,
                },
            );
            return;
        }
        try writer.print(
            "profile gate {s}: floor={d}ns measured={d}ns ratio={d}\n",
            .{ self.scope, self.floor_ns, self.measured_ns, ratio_value },
        );
    }
};

/// Three things held together: one floor estimate, the measured time it is
/// judged against, and the clock its cycle terms were converted at. Both
/// writers take the standard library's `*std.Io.Writer`.
pub const Row = struct {
    scope: []const u8,
    estimate: Estimate,
    measured_ns: u64,
    clock: Clock,
    gap: ?Gap = null,

    /// Writes a gate built from the full bound, the subject and the contaminant
    /// together.
    pub fn writeGate(self: Row, writer: *std.Io.Writer) !void {
        const gate = Gate{
            .scope = self.scope,
            .floor_ns = try self.estimate.totalNs(),
            .measured_ns = self.measured_ns,
            .gap = self.gap,
        };
        try gate.format(writer);
    }

    /// The structured summary of the row, written as one JSON record.
    /// `ratio_milli` carries the headline number, taken against the full bound.
    /// `subject_ratio_milli` reports what the same benchmark would show once
    /// its contaminants were taken out, so a caller reads `subject_ratio_milli`
    /// together with `contaminant_percent`.
    pub fn writeMetric(self: Row, writer: *std.Io.Writer) !void {
        std.debug.assert(self.scope.len > 0);
        std.debug.assert(self.clock.kilohertz > 0);
        std.debug.assert(try self.estimate.totalNs() > 0);
        try writer.print(
            "{{\"schema\":\"{s}\",\"event\":\"summary\",\"family\":\"timing\"," ++
                "\"metric\":\"floor_ns\",\"unit\":\"ns\",\"aggregation\":\"{s}\"," ++
                "\"name\":\"{s}\",\"observed_khz\":{d},\"complete\":{}," ++
                "\"subject_ns\":{d},\"contaminant_ns\":{d},\"contaminant_percent\":{d}," ++
                "\"floor\":{d},\"measured\":{d},\"ratio_milli\":{d}," ++
                "\"subject_ratio_milli\":{d}}}\n",
            .{
                metric_schema,
                metric_aggregation,
                self.scope,
                self.clock.kilohertz,
                self.estimate.complete,
                self.estimate.subject_ns,
                self.estimate.contaminant_ns,
                try self.estimate.contaminantPercent(),
                try self.estimate.totalNs(),
                self.measured_ns,
                try self.estimate.ratioMilli(self.measured_ns),
                try self.estimate.subjectRatioMilli(self.measured_ns),
            },
        );
    }
};

fn expectGate(row: Row, expected: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try row.writeGate(&writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

const sample = Row{
    .scope = "chic.host.lifecycle.validate",
    .estimate = .{ .subject_ns = 11_700, .contaminant_ns = 0, .complete = true },
    .measured_ns = 24_921,
    .clock = .{ .kilohertz = 4_600_000 },
};

test "the gate line matches the shape the existing chic gates emit" {
    try expectGate(
        sample,
        "profile gate chic.host.lifecycle.validate: floor=11700ns " ++
            "measured=24921ns ratio=3\n",
    );
}

test "a gap adds the cause and owner issue without changing the prefix" {
    var row = sample;
    row.gap = .{ .cause = "bounded-owner-validation", .issue = "tiny-" ++ "7mvyiag5" };
    try expectGate(
        row,
        "profile gate chic.host.lifecycle.validate: floor=11700ns " ++
            "measured=24921ns ratio=3 cause=bounded-owner-validation " ++
            "owner_issue=tiny-" ++ "7mvyiag5\n",
    );
}

test "a gate formats through {f} into the bytes the row writes" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const gate = Gate{
        .scope = sample.scope,
        .floor_ns = sample.estimate.subject_ns,
        .measured_ns = sample.measured_ns,
    };
    try writer.print("{f}", .{gate});
    try std.testing.expectEqualStrings(
        "profile gate chic.host.lifecycle.validate: floor=11700ns " ++
            "measured=24921ns ratio=3\n",
        writer.buffered(),
    );
    try std.testing.expectEqual(@as(u64, 3), gate.ratio());
}

test "gates reproduce lines recorded from a chic lifecycle run" {
    const Recorded = struct { gate: Gate, line: []const u8 };
    const owner = "tiny-" ++ "7mvyiag5";
    const recorded = [_]Recorded{
        .{
            .gate = .{
                .scope = "chic.host.lifecycle.stamp",
                .floor_ns = 1_281,
                .measured_ns = 2_199,
            },
            .line = "profile gate chic.host.lifecycle.stamp: floor=1281ns " ++
                "measured=2199ns ratio=2\n",
        },
        .{
            .gate = .{
                .scope = "chic.host.lifecycle.revoke",
                .floor_ns = 1_100,
                .measured_ns = 4_676,
            },
            .line = "profile gate chic.host.lifecycle.revoke: floor=1100ns " ++
                "measured=4676ns ratio=5\n",
        },
        .{
            .gate = .{
                .scope = "chic.host.lifecycle.activate",
                .floor_ns = 50,
                .measured_ns = 3_387_037,
                .gap = .{
                    .cause = "checkpoint-validation-hashing-restoration-and-durable-commit",
                    .issue = owner,
                },
            },
            .line = "profile gate chic.host.lifecycle.activate: floor=50ns " ++
                "measured=3387037ns ratio=67741 " ++
                "cause=checkpoint-validation-hashing-restoration-and-durable-commit " ++
                "owner_issue=tiny-" ++ "7mvyiag5\n",
        },
        .{
            .gate = .{
                .scope = "chic.host.activation.admit",
                .floor_ns = 30,
                .measured_ns = 351,
                .gap = .{
                    .cause = "bounded-projection-walk-and-invariant-checks",
                    .issue = owner,
                },
            },
            .line = "profile gate chic.host.activation.admit: floor=30ns " ++
                "measured=351ns ratio=12 " ++
                "cause=bounded-projection-walk-and-invariant-checks " ++
                "owner_issue=tiny-" ++ "7mvyiag5\n",
        },
    };
    for (recorded) |entry| {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writer.print("{f}", .{entry.gate});
        try std.testing.expectEqualStrings(entry.line, writer.buffered());
    }
}

test "a contaminated row reports both ratios and the contaminant share" {
    var row = sample;
    row.scope = "simd.add.scalar.u32";
    row.estimate = .{ .subject_ns = 56_991, .contaminant_ns = 227_963, .complete = true };
    row.measured_ns = 294_000;
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try row.writeMetric(&writer);
    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"ratio_milli\":1031") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"subject_ratio_milli\":5158") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"contaminant_percent\":79") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"floor\":284954") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"observed_khz\":4600000") != null);
}
