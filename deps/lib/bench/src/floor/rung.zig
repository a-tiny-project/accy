const std = @import("std");

/// Where a working set lives: L1, L2, L3, or DRAM. Moving through the rungs
/// changes streaming bandwidth by roughly five times and the cost of one random
/// line by roughly a hundred. A bytes count alone therefore leaves the cost
/// open, which is why a bytes term names its rung.
pub const Rung = enum(u3) {
    l1,
    l2,
    l3,
    dram,
};

/// How a term's addresses are produced. Under streaming access the prefetcher
/// runs ahead and covers the rung's latency, which leaves bandwidth as the
/// bound. Under random access every line costs the rung's full latency.
pub const Pattern = enum(u1) {
    streaming,
    random,
};

/// How strongly a coefficient is established.
pub const Provenance = enum(u2) {
    /// Measured on this host by a named witness program. A measured number
    /// establishes a bound over the captures taken so far, and nothing beyond
    /// them. The recorded number is the most extreme one the captures produced,
    /// rounded in whichever direction pulls the floor down: down for a latency,
    /// up for a rate. Its witness points at the row and at the capture the
    /// number came from. The comment sitting next to the number records how
    /// wide a range the captures covered. A later capture that goes past the
    /// number replaces both it and its witness in the commit that records the
    /// capture, while a capture inside the range widens only what the comment
    /// reports.
    measured,
    /// Copied out of a vendor optimization guide.
    quoted,
    /// A program that would isolate the value is named and has yet to run.
    specified,
};

/// One hardware number together with the evidence that fixes its value.
pub const Coefficient = struct {
    value: u32,
    provenance: Provenance,
    /// Where the value comes from: a source path, or a section of a
    /// vendor guide. For a measured value the same field also points at the row
    /// and the capture behind it.
    witness: []const u8,
};

/// One load-to-use latency, held in whichever unit fixes it.
pub const Latency = union(enum) {
    /// A count of core cycles, turned into nanoseconds at the clock the run
    /// observed.
    cycles: Coefficient,
    /// Nanoseconds, which hold at any clock. Memory timing sets most of a DRAM
    /// latency, which is why this unit carries it.
    nanoseconds: Coefficient,
};

/// The bytes one aligned cache line carries. Hardware moves a whole line for
/// any load or store, so a random term is charged by the line.
pub const line_bytes: u16 = 64;

const line_bytes_coefficient = Coefficient{
    .value = line_bytes,
    .provenance = .quoted,
    .witness = "AMD SOG 57647 rev 1.01 section 2.2",
};

/// The streaming bandwidth of one thread at a rung, in bytes per nanosecond.
pub fn streamingBytesPerNs(rung: Rung) Coefficient {
    return switch (rung) {
        .l1 => l1_stream,
        .l2 => l2_stream,
        .l3 => l3_stream,
        .dram => dram_stream,
    };
}

/// Capture 158779d6 of the bandwidth witness put its one-thread 16 KiB point at
/// 282.72 bytes per nanosecond. Over five captures that same point ranged from
/// 266.33 to 282.72 bytes per nanosecond.
const l1_stream = Coefficient{
    .value = 283,
    .provenance = .measured,
    .witness = "press/web/sympathy/tests/recorder/bandwidth.zig, the one-thread 16 KiB " ++
        "point in capture 158779d6",
};

/// Capture 28c02ee1 of the bandwidth witness put its one-thread 512 KiB point
/// at 155.57 bytes per nanosecond. Over five captures that same point ranged
/// from 139.86 to 155.57 bytes per nanosecond.
const l2_stream = Coefficient{
    .value = 156,
    .provenance = .measured,
    .witness = "press/web/sympathy/tests/recorder/bandwidth.zig, the one-thread 512 KiB " ++
        "point in capture 28c02ee1",
};

/// Capture 19edbd35 of the bandwidth witness put its one-thread 8 MiB point at
/// 125.31 bytes per nanosecond. Over five captures that same point ranged from
/// 115.61 to 125.50 bytes per nanosecond, and the value covers the 125.50 of
/// capture f721fc8e.
const l3_stream = Coefficient{
    .value = 126,
    .provenance = .measured,
    .witness = "press/web/sympathy/tests/recorder/bandwidth.zig, the one-thread 8 MiB " ++
        "point in capture 19edbd35",
};

/// Capture e6b270ac of the stride witness put its `stride_16b` row at 54.74
/// bytes per nanosecond out of DRAM. Over seven captures that row ranged from
/// 35.18 to 54.74 bytes per nanosecond. The bandwidth witness ran its
/// one-thread 256 MiB point between 34.62 and 45.96 bytes per nanosecond over
/// five captures.
const dram_stream = Coefficient{
    .value = 55,
    .provenance = .measured,
    .witness = "press/web/sympathy/tests/recorder/stride.zig, the stride_16b row in " ++
        "capture e6b270ac",
};

/// What one random line costs at a rung, timed from load to use. For L1, L2,
/// and L3 the number is the vendor's own load-to-use figure, in cycles. The L3
/// quote is an average, so one L3-filled hop falls outside what it bounds. DRAM
/// carries a measured nanosecond latency, because the vendor guide quotes none
/// for it.
pub fn randomLineLatency(rung: Rung) Latency {
    return switch (rung) {
        .l1 => .{ .cycles = .{
            .value = 4,
            .provenance = .quoted,
            .witness = "AMD SOG 57647 rev 1.01 section 2.6.2",
        } },
        .l2 => .{ .cycles = .{
            .value = 14,
            .provenance = .quoted,
            .witness = "AMD SOG 57647 rev 1.01 section 2.6.3",
        } },
        .l3 => .{ .cycles = .{
            .value = 50,
            .provenance = .quoted,
            .witness = "AMD SOG 57647 rev 1.01 section 2.6.4",
        } },
        .dram => .{ .nanoseconds = dram_hop },
    };
}

/// Of the captured chase rows that run past L3, the one whose average
/// DRAM-filled hop is lowest, rounded down. Computing a row's average bills 50
/// cycles to every L3 fill and 14 to every L2 fill, splits what remains across
/// the row's DRAM fills, and converts the result at the clock that row
/// observed. In capture be10ba8b the pages witness ran its `chase_256mib_thp`
/// row on huge pages and averaged 98.05 nanoseconds. Seven captures of that row
/// averaged between 98.05 and 106.66 nanoseconds wherever dTLB misses stayed at
/// or below 42.63 percent of hops, and 117.03 nanoseconds in the capture where
/// misses reached 95.67 percent.
const dram_hop = Coefficient{
    .value = 98,
    .provenance = .measured,
    .witness = "press/web/sympathy/tests/recorder/pages.zig, the chase_256mib_thp row in " ++
        "capture be10ba8b",
};

/// How many lines a byte count reaches into, with a partly used line counted
/// whole. Zero bytes touch no lines. A byte count near the top of the `u64`
/// range returns `error.Overflow`.
pub fn lines(bytes: u64) error{Overflow}!u64 {
    std.debug.assert(line_bytes > 0);
    if (bytes == 0) return 0;
    const rounded = try std.math.add(u64, bytes, line_bytes - 1);
    const result = rounded / line_bytes;
    std.debug.assert(result > 0);
    std.debug.assert(result <= bytes);
    return result;
}

test "line coefficient carries its quoted provenance" {
    try std.testing.expectEqual(@as(u32, 64), line_bytes_coefficient.value);
    try std.testing.expectEqual(Provenance.quoted, line_bytes_coefficient.provenance);
}

test "streaming bandwidth falls monotonically from L1 to DRAM" {
    var previous: u32 = std.math.maxInt(u32);
    for ([_]Rung{ .l1, .l2, .l3, .dram }) |rung| {
        const coefficient = streamingBytesPerNs(rung);
        try std.testing.expect(coefficient.value < previous);
        try std.testing.expectEqual(Provenance.measured, coefficient.provenance);
        previous = coefficient.value;
    }
}

test "cache line latency rises monotonically from L1 to L3" {
    var previous: u32 = 0;
    for ([_]Rung{ .l1, .l2, .l3 }) |rung| {
        const coefficient = randomLineLatency(rung).cycles;
        try std.testing.expect(coefficient.value > previous);
        previous = coefficient.value;
    }
}

test "cache rungs quote cycles and DRAM measures nanoseconds" {
    for ([_]Rung{ .l1, .l2, .l3 }, [_]u32{ 4, 14, 50 }) |rung, cycles| {
        const coefficient = randomLineLatency(rung).cycles;
        try std.testing.expectEqual(cycles, coefficient.value);
        try std.testing.expectEqual(Provenance.quoted, coefficient.provenance);
    }
    const dram = randomLineLatency(.dram).nanoseconds;
    try std.testing.expectEqual(@as(u32, 98), dram.value);
    try std.testing.expectEqual(Provenance.measured, dram.provenance);
}

test "every measured coefficient names the capture that set it" {
    for ([_]Rung{ .l1, .l2, .l3, .dram }) |rung| {
        try expectCaptureNamed(streamingBytesPerNs(rung));
        switch (randomLineLatency(rung)) {
            .cycles, .nanoseconds => |coefficient| try expectCaptureNamed(coefficient),
        }
    }
}

fn expectCaptureNamed(coefficient: Coefficient) !void {
    if (coefficient.provenance != .measured) return;
    try std.testing.expect(std.mem.indexOf(u8, coefficient.witness, " in capture ") != null);
}

test "lines count a partial line as a whole line" {
    try std.testing.expectEqual(@as(u64, 0), try lines(0));
    try std.testing.expectEqual(@as(u64, 1), try lines(1));
    try std.testing.expectEqual(@as(u64, 1), try lines(64));
    try std.testing.expectEqual(@as(u64, 2), try lines(65));
    try std.testing.expectError(error.Overflow, lines(std.math.maxInt(u64)));
}
