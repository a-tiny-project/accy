const std = @import("std");

const clock_mod = @import("clock.zig");
const rung_mod = @import("rung.zig");

const Clock = clock_mod.Clock;

/// Classifies the five kinds of work a timed region can pay for while the
/// benchmark's name makes no claim about them. A term carrying one of these
/// classes counts toward the contaminant bound.
pub const Contaminant = enum(u3) {
    /// A checksum, a witness, a comparison, or an optimizer barrier run over a
    /// buffer.
    verify,
    /// Building a fixture or scratch space inside the timed function.
    setup,
    /// Printing, formatting, or serialization.
    format,
    /// Instrumentation past the opening and closing of a single scope.
    capture,
    /// Frees, arena resets, or deinitialization.
    teardown,
};

/// How fast a bytes term moves. The measured variant carries no defaults, so
/// leaving out the rung or the pattern is a compile error. Copy throughput
/// in one consumer was written at 20 bytes per nanosecond in more than one
/// place, at 10 in the journal workload, and at 32 bytes per cycle in the turn
/// workload: four coefficients for one operation, as much as seven times apart,
/// because every author had left the rung implicit and a byte count on its own
/// gives no way to recover it.
pub const Throughput = union(enum) {
    /// Priced from the measured coefficient for its rung and access pattern.
    measured: struct {
        rung: rung_mod.Rung,
        pattern: rung_mod.Pattern,
    },
    /// A bytes-per-nanosecond rate the caller fixes on its own, waiting to be
    /// reconciled against the measured table. Its provenance and witness put
    /// every unreconciled coefficient within reach of one search, which keeps
    /// it declared debt. The variant exists for bytes the measured table has no
    /// coefficient for yet, and does not exist to skip the choice of a rung.
    declared: rung_mod.Coefficient,
};

/// A count of bytes paired with the throughput that bounds moving them.
pub const Bytes = struct {
    count: u64,
    throughput: Throughput,

    /// Prices this term's bytes in nanoseconds. Zero bytes cost zero. For a
    /// streamed term and for a declared rate the byte count is divided by the
    /// rate, rounded up, and the clock goes unread. A random term is charged
    /// the rung's latency once per cache line it touches. Where the latency is
    /// stated in cycles the conversion needs the clock, and a caller that omits
    /// it gets `error.ClockRequired`. Where the latency is already in
    /// nanoseconds the clock goes unread.
    pub fn nanoseconds(self: Bytes, clock: ?Clock) error{ Overflow, ClockRequired }!u64 {
        if (self.count == 0) return 0;
        switch (self.throughput) {
            .declared => |coefficient| return self.atRate(coefficient.value),
            .measured => |access| switch (access.pattern) {
                .streaming => {
                    const rate = rung_mod.streamingBytesPerNs(access.rung).value;
                    return self.atRate(rate);
                },
                .random => switch (rung_mod.randomLineLatency(access.rung)) {
                    .cycles => |latency| {
                        const observed = clock orelse return error.ClockRequired;
                        const cycles = try self.perLine(latency.value);
                        return try observed.nanoseconds(cycles);
                    },
                    .nanoseconds => |latency| return try self.perLine(latency.value),
                },
            },
        }
    }

    /// Takes the cache lines this term reaches into and multiplies them by
    /// `each`.
    fn perLine(self: Bytes, each: u32) error{Overflow}!u64 {
        std.debug.assert(each > 0);
        std.debug.assert(self.count > 0);
        const lines = try rung_mod.lines(self.count);
        std.debug.assert(lines > 0);
        std.debug.assert(lines <= self.count);
        const result = try std.math.mul(u64, lines, each);
        std.debug.assert(result >= lines);
        return result;
    }

    fn atRate(self: Bytes, bytes_per_ns: u32) u64 {
        std.debug.assert(bytes_per_ns > 0);
        std.debug.assert(self.count > 0);
        const result = self.count / bytes_per_ns +
            @intFromBool(self.count % bytes_per_ns != 0);
        std.debug.assert(result <= self.count);
        std.debug.assert(result > 0);
        return result;
    }
};

/// A chain of dependent steps that the hardware has no way to overlap. The
/// price adds every link's latency together. A checksum built this way can
/// therefore take over a benchmark whose subject runs fully in parallel.
pub const Serial = struct {
    links: u64,
    link_cycles: u16,

    pub fn nanoseconds(self: Serial, clock: Clock) error{Overflow}!u64 {
        if (self.links == 0 or self.link_cycles == 0) return 0;
        std.debug.assert(self.links > 0);
        std.debug.assert(self.link_cycles > 0);
        const cycles = try std.math.mul(u64, self.links, self.link_cycles);
        std.debug.assert(cycles >= self.links);
        return try clock.nanoseconds(cycles);
    }
};

/// Independent operations, bounded by how many the core issues per cycle.
pub const Parallel = struct {
    operations: u64,
    /// Cycles one operation costs when many are in flight, carried in
    /// hundredths. A value of 100 means one operation each cycle, and 34 stands
    /// for the 0.34 cycles per element measured for the load-and-add width. A
    /// run of SHA-256 blocks belongs in a serial term, because its blocks
    /// chain.
    centicycles: u32,

    pub fn nanoseconds(self: Parallel, clock: Clock) error{Overflow}!u64 {
        if (self.operations == 0 or self.centicycles == 0) return 0;
        std.debug.assert(self.operations > 0);
        std.debug.assert(self.centicycles > 0);
        const total = try std.math.mul(u64, self.operations, self.centicycles);
        std.debug.assert(total >= self.operations);
        const cycles = total / 100 + @intFromBool(total % 100 != 0);
        std.debug.assert(cycles > 0);
        return try clock.nanoseconds(cycles);
    }
};

/// Prices a count against a per-item coefficient given in nanoseconds. Its
/// nanoseconds are exactly the count times the coefficient, and a product
/// outside the range returns `error.Overflow`. The term exists for flat prices
/// that no measured witness backs yet, and does not exist to skip deriving a
/// cycle cost.
pub const Declared = struct {
    count: u64,
    /// Nanoseconds for one item.
    each: rung_mod.Coefficient,

    pub fn nanoseconds(self: Declared) error{Overflow}!u64 {
        if (self.count == 0) return 0;
        std.debug.assert(self.count > 0);
        const result = try std.math.mul(u64, self.count, self.each.value);
        std.debug.assert(result / self.count == self.each.value);
        return result;
    }
};

pub const Term = union(enum) {
    bytes: Bytes,
    serial: Serial,
    parallel: Parallel,
    declared: Declared,

    /// Prices any term in nanoseconds, handing the clock to the shape that
    /// needs it. Three shapes need the clock and return `error.ClockRequired`
    /// when a caller omits it: a serial term, a parallel term, and a random
    /// bytes term at a rung whose latency is counted in cycles. A declared term
    /// prices with no clock, and so does every other bytes term.
    pub fn nanoseconds(self: Term, clock: ?Clock) error{ Overflow, ClockRequired }!u64 {
        switch (self) {
            .bytes => |value| return try value.nanoseconds(clock),
            .declared => |value| return try value.nanoseconds(),
            .serial => |value| {
                const observed = clock orelse return error.ClockRequired;
                return try value.nanoseconds(observed);
            },
            .parallel => |value| {
                const observed = clock orelse return error.ClockRequired;
                return try value.nanoseconds(observed);
            },
        }
    }
};

/// One disjoint term of a floor. Two terms that cover the same work push the
/// bound past the true time, and what comes out stops being a floor, so terms
/// stay disjoint.
pub const Entry = struct {
    /// Null marks the subject. A value marks work the timed region pays for
    /// while the benchmark's name stays silent about it.
    contaminant: ?Contaminant = null,
    /// Where this term's count comes from, written as a repository path or as
    /// `file:line`. A term whose count traces back to nothing carries no
    /// evidence, and `estimate` asserts the origin is non-empty.
    origin: []const u8,
    term: Term,

    pub fn isSubject(self: Entry) bool {
        return self.contaminant == null;
    }
};

/// How many compression blocks one SHA-256 message fills once its padding is
/// counted. Padding is applied to each message on its own, so a caller adds
/// these counts message by message. A message length near the top of the `u64`
/// range returns `error.Overflow`.
pub fn sha256Blocks(message_bytes: u64) error{Overflow}!u64 {
    const padded = try std.math.add(u64, message_bytes, 9);
    return padded / 64 + @intFromBool(padded % 64 != 0);
}

/// Which SHA-256 compression a build compiles. On the extensions a block
/// retires in less than a fifth of what the portable rounds spend, which is why
/// each path carries its own coefficient.
pub const Sha256Path = enum(u1) {
    /// Compiled with the x86 SHA extensions.
    extended,
    /// A build that leaves the SHA extensions out, so it uses the portable
    /// rounds.
    portable,
};

/// What one SHA-256 compression block costs in cycles on a given path. Each
/// block feeds its output state into the next, so a run of blocks forms one
/// serial chain whose links cost this many cycles.
pub fn sha256BlockCycles(path: Sha256Path) rung_mod.Coefficient {
    return switch (path) {
        .extended => sha256_block_extended,
        .portable => sha256_block_portable,
    };
}

/// The measuring row `chic.turn.floor` wraps a core-cycle count around two
/// hashes taken apart from each other: 48 bytes, which fills one padded
/// compression block, and 4,096 bytes, which fills 65. Taking the smaller count
/// away from the larger drops the setup and finish cost each hash pays once,
/// and the 64 blocks separating the two divide what is left. Capture 29c84a02
/// ran 42 times, and the quotient ahead of truncation fell between 131.812 and
/// 133.016: 131 cycles came out of 5 runs, 132 out of 35, and 133 out of 2. The
/// same witness had reached 131 in four earlier binaries too, over 168 more
/// runs.
const sha256_block_extended = rung_mod.Coefficient{
    .value = 131,
    .provenance = .measured,
    .witness = "lib/chic/src/profiling/workloads/turn.zig, the chic.turn.floor row " ++
        "in capture 29c84a02",
};

/// The `chic.turn.floor` witness targets `x86_64_v3`, which carries AVX2 and
/// leaves out the SHA extensions, so the library under measurement picks its
/// portable rounds. Over the 42 runs of capture 488c9afe the count reached 724
/// once and came out at 731 in 24 of them. The only place that capture parts
/// from the committed sources is this coefficient's own value, which the
/// measurement leaves unread, so the difference has no way to reach what was
/// measured. Capture 08eaa044 ran the same witness at the landed coefficient on
/// a shared machine and reached 728 over 60 runs, which leaves 724 standing.
const sha256_block_portable = rung_mod.Coefficient{
    .value = 724,
    .provenance = .measured,
    .witness = "lib/chic/src/profiling/workloads/turn.zig, the chic.turn.floor row " ++
        "in capture 488c9afe",
};

/// Cycles one dependent integer operation costs: an add, a logic operation, or
/// a shift or rotate by a constant whose input is the previous operation's
/// output. A count of such operations prices as a serial term whose links cost
/// this many cycles. Independent operations belong in a parallel term.
pub fn dependentOperationCycles() rung_mod.Coefficient {
    return dependent_operation;
}

/// The `chic.turn.coefficients` row counts cycles over a chain of 4,096
/// rotate-and-xor steps, whose every operation reads the one before, and divides
/// by the 8,192 operations in it. Capture ab1f4ef9 ran 40 times on the 16-lane
/// build and read 1.05 to 1.09 cycles, and capture 71f91de7 ran 40 times on the
/// `x86_64_v3` build and read 1.05 to 1.06.
const dependent_operation = rung_mod.Coefficient{
    .value = 1,
    .provenance = .measured,
    .witness = "lib/chic/src/profiling/workloads/turn.zig, the chic.turn.coefficients row " ++
        "in capture ab1f4ef9",
};

/// The bytes of one BLAKE3 chunk. The 64-byte blocks inside a chunk chain one
/// after another, while separate chunks hash side by side across vector lanes.
pub const blake3_chunk_bytes: u64 = 1_024;

/// How many 64-byte compressions BLAKE3 spends on a message that fits in one
/// chunk. BLAKE3 pads nothing, and an empty message still compresses one
/// block. A longer message takes the wide path, which
/// `blake3StreamCenticycles` prices by the byte.
pub fn blake3ChunkBlocks(message_bytes: u64) u64 {
    std.debug.assert(message_bytes <= blake3_chunk_bytes);
    if (message_bytes == 0) return 1;
    return message_bytes / 64 + @intFromBool(message_bytes % 64 != 0);
}

/// Which BLAKE3 compression a build compiles. `std.crypto.hash.Blake3` sizes
/// its vectors from `std.simd.suggestVectorLength(u32)` at comptime, so the
/// price follows the build and not the host. A build with fewer than eight
/// lanes prices at the narrow coefficients, which stay lower bounds because
/// fewer lanes only add time.
pub const Blake3Path = enum(u1) {
    /// Sixteen 32-bit lanes and single-instruction rotates, from AVX-512.
    wide,
    /// Eight lanes or fewer.
    narrow,
};

/// Cycles one BLAKE3 compression costs inside a chunk. Each block feeds its
/// chaining value into the next, so the blocks of one chunk form a serial chain
/// whose links cost this many cycles. The price holds for incremental updates
/// too, because a hasher that buffers small updates still pays every
/// compression its message needs.
pub fn blake3BlockCycles(path: Blake3Path) rung_mod.Coefficient {
    return switch (path) {
        .wide => blake3_block_wide,
        .narrow => blake3_block_narrow,
    };
}

/// Hundredths of a cycle one input byte costs when whole chunks hash across the
/// vector lanes, the parent compressions between them included. It prices a
/// message longer than one chunk as a parallel term over its bytes. A message
/// that fills fewer lanes pays more per byte, and a chunk hashed on its own
/// pays the serial block price, so this is the lowest price BLAKE3 charges a
/// byte and a lower bound for bytes whose split into messages is unknown.
pub fn blake3StreamCenticycles(path: Blake3Path) rung_mod.Coefficient {
    return switch (path) {
        .wide => blake3_stream_wide,
        .narrow => blake3_stream_narrow,
    };
}

/// The term that bounds hashing one message of `message_bytes`: a serial chain
/// of compressions for a message that fits in one chunk, and a parallel term
/// over its bytes for a longer one.
pub fn blake3Term(message_bytes: u64, path: Blake3Path) Term {
    if (message_bytes <= blake3_chunk_bytes) return .{ .serial = .{
        .links = blake3ChunkBlocks(message_bytes),
        .link_cycles = @intCast(blake3BlockCycles(path).value),
    } };
    return .{ .parallel = .{
        .operations = message_bytes,
        .centicycles = blake3StreamCenticycles(path).value,
    } };
}

/// The `chic.turn.coefficients` row counts cycles over two one-shot hashes
/// taken apart from each other: 64 bytes, one compression that finalizes as the
/// root, and 1,024 bytes, sixteen chained compressions. The 15 compressions
/// separating them divide the difference, and the setup and finish each hash
/// pays cancel. Capture ab1f4ef9 ran the 16-lane build 40 times: the quotient
/// fell between 302.53 and 414.26, and 315 came out of 13 runs.
const blake3_block_wide = rung_mod.Coefficient{
    .value = 302,
    .provenance = .measured,
    .witness = "lib/chic/src/profiling/workloads/turn.zig, the chic.turn.coefficients row " ++
        "in capture ab1f4ef9",
};

/// The same witness built for `x86_64_v3`, which has AVX2 and eight lanes.
/// Capture 71f91de7 ran it 40 times: the quotient fell between 401.86 and
/// 622.20, and 411 came out of 15 runs.
const blake3_block_narrow = rung_mod.Coefficient{
    .value = 401,
    .provenance = .measured,
    .witness = "lib/chic/src/profiling/workloads/turn.zig, the chic.turn.coefficients row " ++
        "in capture 71f91de7",
};

/// The `chic.turn.coefficients` row counts cycles over one-shot hashes of 16 KiB
/// and 64 KiB, which both take the wide path whole. The 48 KiB separating them
/// divide the difference, which holds 48 chunks and their parent compressions.
/// Capture ab1f4ef9 ran the 16-lane build 40 times: the price fell between 0.61
/// and 0.79 cycles per byte, and 0.69 came out of 25 runs.
const blake3_stream_wide = rung_mod.Coefficient{
    .value = 61,
    .provenance = .measured,
    .witness = "lib/chic/src/profiling/workloads/turn.zig, the chic.turn.coefficients row " ++
        "in capture ab1f4ef9",
};

/// The same witness built for `x86_64_v3`. Capture 71f91de7 ran it 40 times:
/// the price fell between 1.14 and 1.17 cycles per byte, and 1.14 came out of 35.
const blake3_stream_narrow = rung_mod.Coefficient{
    .value = 114,
    .provenance = .measured,
    .witness = "lib/chic/src/profiling/workloads/turn.zig, the chic.turn.coefficients row " ++
        "in capture 71f91de7",
};

test "a streamed term converts through bandwidth and ignores the clock" {
    const term = Bytes{
        .count = 3_145_884,
        .throughput = .{ .measured = .{ .rung = .l3, .pattern = .streaming } },
    };
    const slow = try term.nanoseconds(.{ .kilohertz = 2_500_000 });
    const fast = try term.nanoseconds(.{ .kilohertz = 4_850_000 });
    try std.testing.expectEqual(slow, fast);
    try std.testing.expectEqual(@as(u64, 24_968), slow);
}

test "a random cache term pays cycles per line and scales with the clock" {
    const term = Bytes{
        .count = 640,
        .throughput = .{ .measured = .{ .rung = .l3, .pattern = .random } },
    };
    const slow = try term.nanoseconds(.{ .kilohertz = 2_500_000 });
    const fast = try term.nanoseconds(.{ .kilohertz = 4_600_000 });
    try std.testing.expectEqual(@as(u64, 200), slow);
    try std.testing.expectEqual(@as(u64, 109), fast);
    try std.testing.expectError(error.ClockRequired, term.nanoseconds(null));
}

test "a random DRAM term pays nanoseconds per line and ignores the clock" {
    const term = Bytes{
        .count = 640,
        .throughput = .{ .measured = .{ .rung = .dram, .pattern = .random } },
    };
    const slow = try term.nanoseconds(.{ .kilohertz = 2_500_000 });
    const fast = try term.nanoseconds(.{ .kilohertz = 4_850_000 });
    try std.testing.expectEqual(@as(u64, 980), try term.nanoseconds(null));
    try std.testing.expectEqual(slow, fast);
    try std.testing.expectEqual(@as(u64, 980), slow);
}

test "an empty term costs nothing in every shape" {
    const clock = clock_mod.Clock{ .kilohertz = 4_600_000 };
    const empty_bytes = Bytes{
        .count = 0,
        .throughput = .{ .measured = .{ .rung = .l1, .pattern = .random } },
    };
    try std.testing.expectEqual(@as(u64, 0), try empty_bytes.nanoseconds(clock));
    try std.testing.expectEqual(
        @as(u64, 0),
        try (Serial{ .links = 0, .link_cycles = 4 }).nanoseconds(clock),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        try (Parallel{ .operations = 0, .centicycles = 100 }).nanoseconds(clock),
    );
}

test "the serial witness chain reproduces the measured simd add contaminant" {
    const clock = clock_mod.Clock{ .kilohertz = 4_600_000 };
    const witness = Serial{ .links = 262_157, .link_cycles = 4 };
    const nanoseconds = try witness.nanoseconds(clock);
    try std.testing.expect(nanoseconds > 227_000);
    try std.testing.expect(nanoseconds < 229_000);
}

test "parallel throughput below one per cycle costs less than the count" {
    const clock = clock_mod.Clock{ .kilohertz = 4_600_000 };
    const width_bound = Parallel{ .operations = 262_157, .centicycles = 34 };
    const one_per_cycle = Parallel{ .operations = 262_157, .centicycles = 100 };
    try std.testing.expect(
        try width_bound.nanoseconds(clock) < try one_per_cycle.nanoseconds(clock),
    );
}

test "SHA-256 blocks pad each message separately" {
    try std.testing.expectEqual(@as(u64, 1), try sha256Blocks(0));
    try std.testing.expectEqual(@as(u64, 1), try sha256Blocks(55));
    try std.testing.expectEqual(@as(u64, 2), try sha256Blocks(56));
    try std.testing.expectEqual(@as(u64, 2), try sha256Blocks(64));
    const separate = try sha256Blocks(1) + try sha256Blocks(1);
    try std.testing.expectEqual(@as(u64, 2), separate);
    try std.testing.expectError(error.Overflow, sha256Blocks(std.math.maxInt(u64)));
}

test "an entry without a contaminant class is the subject" {
    const subject = Entry{
        .origin = "lib/simd/dev/src/profiling/arithmetic.zig:24",
        .term = .{ .parallel = .{ .operations = 262_157, .centicycles = 100 } },
    };
    try std.testing.expect(subject.isSubject());
    const witness = Entry{
        .contaminant = .verify,
        .origin = "lib/simd/dev/src/profiling/arithmetic.zig:51",
        .term = .{ .serial = .{ .links = 262_157, .link_cycles = 4 } },
    };
    try std.testing.expect(!witness.isSubject());
}

test "a declared rate reproduces an unreconciled coefficient exactly" {
    const chic_flat_copy = Bytes{
        .count = 3_145_884,
        .throughput = .{ .declared = .{
            .value = 20,
            .provenance = .specified,
            .witness = "lib/chic/src/profiling/workloads/preparation.zig",
        } },
    };
    const nanoseconds = try chic_flat_copy.nanoseconds(.{ .kilohertz = 4_600_000 });
    try std.testing.expectEqual(@as(u64, 157_295), nanoseconds);
}

test "a declared rate ignores the clock exactly as a measured stream does" {
    const term = Bytes{
        .count = 1_000,
        .throughput = .{ .declared = .{
            .value = 20,
            .provenance = .specified,
            .witness = "migration fidelity",
        } },
    };
    const slow = try term.nanoseconds(.{ .kilohertz = 2_500_000 });
    const fast = try term.nanoseconds(.{ .kilohertz = 4_850_000 });
    try std.testing.expectEqual(slow, fast);
    try std.testing.expectEqual(@as(u64, 50), slow);
}

test "no measured rung equals the flat copy rate chic declares" {
    for ([_]rung_mod.Rung{ .l1, .l2, .l3, .dram }) |rung| {
        try std.testing.expect(rung_mod.streamingBytesPerNs(rung).value != 20);
    }
}

test "BLAKE3 counts one compression per started block and pads nothing" {
    try std.testing.expectEqual(@as(u64, 1), blake3ChunkBlocks(0));
    try std.testing.expectEqual(@as(u64, 1), blake3ChunkBlocks(64));
    try std.testing.expectEqual(@as(u64, 2), blake3ChunkBlocks(65));
    try std.testing.expectEqual(@as(u64, 16), blake3ChunkBlocks(blake3_chunk_bytes));
}

test "a BLAKE3 message within one chunk chains and a longer one streams" {
    for ([_]Blake3Path{ .wide, .narrow }) |path| {
        const short = blake3Term(blake3_chunk_bytes, path);
        try std.testing.expectEqual(@as(u64, 16), short.serial.links);
        try std.testing.expectEqual(blake3BlockCycles(path).value, short.serial.link_cycles);
        const long = blake3Term(blake3_chunk_bytes + 1, path);
        try std.testing.expectEqual(blake3_chunk_bytes + 1, long.parallel.operations);
        try std.testing.expectEqual(
            blake3StreamCenticycles(path).value,
            long.parallel.centicycles,
        );
    }
}

test "a streamed BLAKE3 byte costs less than a chained one" {
    for ([_]Blake3Path{ .wide, .narrow }) |path| {
        const chained = blake3BlockCycles(path).value * 100;
        try std.testing.expect(blake3StreamCenticycles(path).value * 64 < chained);
    }
}
