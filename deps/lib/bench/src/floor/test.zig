const std = @import("std");

const clock = @import("clock.zig");
const estimate = @import("estimate.zig");
const floor = @import("root.zig");
const row = @import("row.zig");
const rung = @import("rung.zig");
const term = @import("term.zig");

test "floor namespace" {
    _ = floor;
    std.testing.refAllDecls(clock);
    std.testing.refAllDecls(estimate);
    std.testing.refAllDecls(row);
    std.testing.refAllDecls(rung);
    std.testing.refAllDecls(term);
}

/// The clock this host was measured at while the file's expected values were
/// produced.
const observed = floor.Clock{ .kilohertz = 4_600_000 };

test "the simd scalar add row derives at floor with a dominant witness" {
    const element_count: u64 = 262_157;
    const entries = [_]floor.Entry{
        .{
            .origin = "lib/simd/dev/src/profiling/arithmetic.zig:27",
            .term = .{ .parallel = .{ .operations = element_count, .centicycles = 100 } },
        },
        .{
            .contaminant = .verify,
            .origin = "lib/simd/dev/src/profiling/arithmetic.zig:52",
            .term = .{ .serial = .{ .links = element_count, .link_cycles = 4 } },
        },
    };
    const derivation = floor.Derivation{
        .entries = &entries,
        .coverage = .complete,
        .rationale = "two loads and one store per element against the three " ++
            "memory operations per cycle the core issues, so one cycle per " ++
            "element; the witness is a serial exclusive-or and multiply the " ++
            "hardware cannot overlap, at four cycles per element; the L3 " ++
            "bandwidth bound for the 3.15 MB working set is below the issue " ++
            "bound and so does not appear",
    };
    const result = try derivation.estimate(observed);
    const measured_ns: u64 = 294_000;
    try std.testing.expectEqual(@as(u64, 1_031), try result.ratioMilli(measured_ns));
    try std.testing.expectEqual(@as(u64, 79), try result.contaminantPercent());
    try std.testing.expect(try result.subjectRatioMilli(measured_ns) > 5_000);
}

test "the simd vector add row is also at floor because traffic is unchanged" {
    const element_count: u64 = 262_157;
    const vector_count: u64 = 262_144 / 8;
    const entries = [_]floor.Entry{
        .{
            .origin = "lib/simd/dev/src/profiling/arithmetic.zig:38",
            .term = .{ .parallel = .{ .operations = vector_count, .centicycles = 150 } },
        },
        .{
            .contaminant = .verify,
            .origin = "lib/simd/dev/src/profiling/arithmetic.zig:52",
            .term = .{ .serial = .{ .links = element_count, .link_cycles = 4 } },
        },
    };
    const derivation = floor.Derivation{
        .entries = &entries,
        .coverage = .complete,
        .rationale = "the vector loop moves the same bytes as the scalar one, so " ++
            "vectorizing the arithmetic cannot reduce traffic; the witness is " ++
            "unchanged and dominates both rows",
    };
    const result = try derivation.estimate(observed);
    try std.testing.expect(try result.ratioMilli(252_000) < 1_200);
    try std.testing.expect(try result.contaminantPercent() > 90);
}

test "the software AES row misses its floor by more than a hundred times" {
    const block_count: u64 = 65_539;
    const output_bytes: u64 = block_count * 16;
    const entries = [_]floor.Entry{
        .{
            .origin = "lib/simd/dev/src/profiling/crypto.zig:36",
            .term = .{ .parallel = .{
                .operations = block_count * 4,
                .centicycles = 100,
            } },
        },
        .{
            .contaminant = .verify,
            .origin = "lib/simd/dev/src/profiling/crypto.zig:44",
            .term = .{ .serial = .{ .links = output_bytes, .link_cycles = 4 } },
        },
    };
    const derivation = floor.Derivation{
        .entries = &entries,
        .coverage = .complete,
        .rationale = "four AES rounds per block at one round per cycle, the " ++
            "documented throughput of the hardware instruction this host " ++
            "reports through its feature bits; the byte-at-a-time software " ++
            "implementation the package actually uses is not in the bound and " ++
            "is the whole of the ratio",
    };
    const result = try derivation.estimate(observed);
    const measured_ns: u64 = 191_165_000;
    try std.testing.expect(try result.ratioMilli(measured_ns) > 100_000);
}

test "a partial derivation names its gaps and stays a valid lower bound" {
    const gaps = [_][]const u8{
        "lowering visits and emissions: language/tree/lower.zig",
        "authorship traversal: language/core/program/authorship.zig",
    };
    const entries = [_]floor.Entry{.{
        .origin = "lib/chic/src/profiling/workloads/preparation.zig:9",
        .term = .{ .parallel = .{ .operations = 45_475, .centicycles = 200 } },
    }};
    const derivation = floor.Derivation{
        .entries = &entries,
        .coverage = .{ .partial = &gaps },
        .rationale = "verifier visits and publications only; the named internal " ++
            "work is unaccounted, so the bound holds but is not tight",
    };
    const result = try derivation.estimate(observed);
    try std.testing.expect(!result.complete);
    try std.testing.expectEqual(@as(u64, 0), result.contaminant_ns);
    try std.testing.expect(result.subject_ns > 0);
}

test "a hashing derivation converts blocks at the measured cycle cost" {
    const message_bytes: u64 = 33 + 64 * 16;
    const blocks = try floor.sha256Blocks(message_bytes);
    const entries = [_]floor.Entry{.{
        .origin = "lib/chic/src/profiling/workloads/turn.zig:32",
        .term = .{ .serial = .{
            .links = blocks,
            .link_cycles = @intCast(floor.sha256BlockCycles(.extended).value),
        } },
    }};
    const derivation = floor.Derivation{
        .entries = &entries,
        .coverage = .complete,
        .rationale = "one padded SHA-256 message over the frontier records, at " ++
            "the measured cycle cost of a compression block with the SHA " ++
            "extensions this host reports",
    };
    const result = try derivation.estimate(observed);
    try std.testing.expectEqual(@as(u64, 17), blocks);
    try std.testing.expect(result.subject_ns > 0);
    try std.testing.expect(result.complete);
}

test "a full row renders both the gate line and the structured summary" {
    const entries = [_]floor.Entry{.{
        .origin = "lib/chic/src/host/lifecycle/validate.zig:10",
        .term = .{ .parallel = .{ .operations = 600, .centicycles = 200 } },
    }};
    const derivation = floor.Derivation{
        .entries = &entries,
        .coverage = .complete,
        .rationale = "counted validation operations at two cycles each",
    };
    const rendered = floor.Row{
        .scope = "chic.host.lifecycle.validate",
        .estimate = try derivation.estimate(observed),
        .measured_ns = 24_921,
        .clock = observed,
    };
    var gate_buffer: [512]u8 = undefined;
    var gate_writer = std.Io.Writer.fixed(&gate_buffer);
    try rendered.writeGate(&gate_writer);
    try std.testing.expect(std.mem.startsWith(
        u8,
        gate_writer.buffered(),
        "profile gate chic.host.lifecycle.validate: floor=",
    ));
    var metric_buffer: [1024]u8 = undefined;
    var metric_writer = std.Io.Writer.fixed(&metric_buffer);
    try rendered.writeMetric(&metric_writer);
    try std.testing.expect(std.mem.indexOf(
        u8,
        metric_writer.buffered(),
        "\"aggregation\":\"fermi_derivation\"",
    ) != null);
}

test "declared terms reproduce the preparation floor chic pinned" {
    const source = "lib/chic/src/profiling/workloads/preparation.zig";
    const operation = floor.Coefficient{ .value = 2, .provenance = .specified, .witness = source };
    const publication = floor.Coefficient{ .value = 20, .provenance = .specified, .witness = source };
    const copy = floor.Coefficient{ .value = 20, .provenance = .specified, .witness = source };
    const blake3 = floor.Coefficient{ .value = 4, .provenance = .specified, .witness = source };
    const block = floor.Coefficient{ .value = 183, .provenance = .specified, .witness = source };
    const gaps = [_][]const u8{"lowering visits and emissions: language/tree/lower.zig"};

    const visits = [_]floor.Entry{.{
        .origin = source,
        .term = .{ .declared = .{ .count = 45_475, .each = operation } },
    }};
    const partial = try (floor.Derivation{
        .entries = &visits,
        .coverage = .{ .partial = &gaps },
        .rationale = "verifier visits only, at the flat operation price",
    }).estimate(null);
    try std.testing.expectEqual(@as(u64, 90_950), partial.subject_ns);
    try std.testing.expect(!partial.complete);

    const every_term = [_]floor.Entry{
        .{ .origin = source, .term = .{ .declared = .{ .count = 15, .each = operation } } },
        .{ .origin = source, .term = .{ .declared = .{ .count = 6, .each = publication } } },
        .{ .origin = source, .term = .{ .bytes = .{
            .count = 21,
            .throughput = .{ .declared = copy },
        } } },
        .{ .origin = source, .term = .{ .bytes = .{
            .count = 5,
            .throughput = .{ .declared = blake3 },
        } } },
        .{ .origin = source, .term = .{ .declared = .{ .count = 2, .each = block } } },
    };
    const complete = try (floor.Derivation{
        .entries = &every_term,
        .coverage = .complete,
        .rationale = "every term the preparation model prices, bytes rounded up",
    }).estimate(null);
    try std.testing.expectEqual(@as(u64, 520), complete.subject_ns);
    try std.testing.expect(complete.complete);
}

test "only terms that count cycles require the clock" {
    const serial = floor.Term{ .serial = .{ .links = 1, .link_cycles = 4 } };
    try std.testing.expectError(error.ClockRequired, serial.nanoseconds(null));
    const parallel = floor.Term{ .parallel = .{ .operations = 1, .centicycles = 100 } };
    try std.testing.expectError(error.ClockRequired, parallel.nanoseconds(null));
    const random = floor.Term{ .bytes = .{
        .count = 64,
        .throughput = .{ .measured = .{ .rung = .l1, .pattern = .random } },
    } };
    try std.testing.expectError(error.ClockRequired, random.nanoseconds(null));
    const streaming = floor.Term{ .bytes = .{
        .count = floor.streamingBytesPerNs(.l1).value,
        .throughput = .{ .measured = .{ .rung = .l1, .pattern = .streaming } },
    } };
    try std.testing.expectEqual(@as(u64, 1), try streaming.nanoseconds(null));
    try std.testing.expectEqual(@as(u64, 1), try random.nanoseconds(observed));
    const dram = floor.Term{ .bytes = .{
        .count = 64,
        .throughput = .{ .measured = .{ .rung = .dram, .pattern = .random } },
    } };
    const dram_latency = floor.randomLineLatency(.dram).nanoseconds.value;
    try std.testing.expectEqual(@as(u64, dram_latency), try dram.nanoseconds(null));
}

test "a declared price reports overflow instead of wrapping" {
    const price = floor.Declared{
        .count = std.math.maxInt(u64),
        .each = .{ .value = 2, .provenance = .specified, .witness = "overflow witness" },
    };
    try std.testing.expectError(error.Overflow, price.nanoseconds());
    const empty = floor.Declared{ .count = 0, .each = price.each };
    try std.testing.expectEqual(@as(u64, 0), try empty.nanoseconds());
}
