//! Adler-32, the check that ends a zlib stream (RFC 1950 section 9).
//!
//! Adler-32 keeps two sums modulo 65,521, the largest prime below 2^16, and
//! packs the second above the first. The first sum is one plus the bytes. The
//! second adds the first after each byte, so it weights each byte by its
//! distance from the end of the message, plus one.
//!
//! The sums need no reduction until they could pass 2^32, which zlib bounds
//! at 5,552 bytes from reduced sums. Within such a chunk, the vector kernel
//! reads the bytes in blocks of one vector. It adds each block into
//! per-lane column sums, and the column sums before each block into per-lane
//! prefix sums, in 16-bit lanes for at most 23 blocks at a time, then in
//! 32-bit lanes. Once per chunk it recovers both sums from the column and
//! prefix sums and reduces them. Targets without vectors, and the bytes after
//! the last whole block, take the scalar loop.

const std = @import("std");

const assert = std.debug.assert;

/// The modulus of both sums: the largest prime below 2^16.
pub const modulus: u32 = 65_521;

/// The most bytes that reduced sums can take in before either could pass
/// 2^32: zlib's NMAX, the largest n with 255n(n+1)/2 + (n+1)(modulus-1)
/// below 2^32.
pub const chunk_bytes_max: usize = 5_552;

comptime {
    assert(sumBound(chunk_bytes_max) <= std.math.maxInt(u32));
    assert(sumBound(chunk_bytes_max + 1) > std.math.maxInt(u32));
}

/// The largest second sum after `bytes` bytes from reduced sums: each sum
/// starts at most `modulus - 1`, and each byte is at most 255.
fn sumBound(bytes: u64) u64 {
    return 255 * bytes * (bytes + 1) / 2 + (bytes + 1) * (modulus - 1);
}

/// An Adler-32 over bytes that arrive in pieces.
pub const Adler32 = struct {
    /// The second sum in the high 16 bits and the first in the low 16 bits,
    /// each below `modulus`.
    value: u32,

    pub fn init() Adler32 {
        return .{ .value = 1 };
    }

    pub fn update(self: *Adler32, bytes: []const u8) void {
        self.value = advance(self.value, bytes);
    }

    pub fn final(self: Adler32) u32 {
        return self.value;
    }

    /// The Adler-32 of `bytes`.
    pub fn hash(bytes: []const u8) u32 {
        return advance(1, bytes);
    }
};

/// The two sums, each below `modulus` between chunks.
const Sums = struct {
    first: u32,
    second: u32,

    fn unpack(value: u32) Sums {
        const sums: Sums = .{ .first = value & 0xffff, .second = value >> 16 };
        assert(sums.first < modulus);
        assert(sums.second < modulus);
        return sums;
    }

    fn pack(self: Sums) u32 {
        assert(self.first < modulus);
        assert(self.second < modulus);
        return self.first | (self.second << 16);
    }
};

/// Bytes per block of the vector kernel: the vector of bytes the target
/// suggests, at most 64, or zero where it suggests none or fewer than 16.
const block_lanes: usize = lanes: {
    const suggested = std.simd.suggestVectorLength(u8) orelse break :lanes 0;
    break :lanes if (suggested < 16) 0 else @min(suggested, 64);
};

/// The sums after `bytes`, from `value`.
fn advance(value: u32, bytes: []const u8) u32 {
    var sums = Sums.unpack(value);
    var offset: usize = 0;
    if (comptime block_lanes != 0) {
        offset = advanceBlocks(block_lanes, &sums, bytes);
        assert(offset % block_lanes == 0);
        assert(bytes.len - offset < block_lanes);
    }
    scalar(&sums, bytes[offset..]);
    return sums.pack();
}

/// The byte loop: each byte into the first sum and the first sum into the
/// second, reduced after each chunk.
fn scalar(sums: *Sums, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = offset + @min(bytes.len - offset, chunk_bytes_max);
        var first = sums.first;
        var second = sums.second;
        for (bytes[offset..end]) |byte| {
            first += byte;
            second += first;
        }
        assert(second <= sumBound(end - offset));
        sums.first = first % modulus;
        sums.second = second % modulus;
        offset = end;
    }
    assert(offset == bytes.len);
}

/// The reductions of one chunk's lane sums that move the two sums past it.
const ChunkTotals = struct {
    /// The bytes in the chunk.
    bytes: u64,
    /// The sum of the bytes.
    columns: u64,
    /// Each column sum times its lane's weight: the block's width less the
    /// lane's index.
    weighted: u64,
    /// The block's width times the sum over blocks of the bytes of every
    /// block before each.
    prefixes: u64,
};

/// Moves `sums` past a chunk and reduces them.
fn advanceChunk(sums: *Sums, totals: ChunkTotals) void {
    assert(totals.bytes <= chunk_bytes_max);
    assert(totals.columns <= 255 * totals.bytes);
    const first: u64 = sums.first;
    const second = sums.second + totals.bytes * first + totals.prefixes + totals.weighted;
    // The column sums recover what the byte loop would have summed, which
    // zlib's bound keeps below 2^32.
    assert(second <= sumBound(totals.bytes));
    sums.first = @intCast((first + totals.columns) % modulus);
    sums.second = @intCast(second % modulus);
}

/// Advances `sums` over the whole blocks of `lanes` bytes at the front of
/// `bytes`, a chunk at a time, and returns how many bytes they hold.
fn advanceBlocks(comptime lanes: usize, sums: *Sums, bytes: []const u8) usize {
    const Kernel = Columns(lanes);
    var offset: usize = 0;
    while (bytes.len - offset >= lanes) {
        const blocks = @min((bytes.len - offset) / lanes, Kernel.chunk_blocks);
        advanceChunk(sums, Kernel.chunk(bytes[offset..][0 .. blocks * lanes]));
        offset += blocks * lanes;
    }
    assert(bytes.len - offset < lanes);
    return offset;
}

/// The vector kernel over blocks of `lanes` bytes.
///
/// A chunk of k blocks, with b(j, i) the byte in lane i of block j, moves
/// the sums (a, b) to
///
///   a + C and b + kLa + L P + sum over i of (L - i) C(i),
///
/// where L is `lanes`, C(i) is the column sum of lane i over the chunk, C is
/// their sum, and P is the sum over lanes and blocks of the column sums of
/// the blocks before each. Groups of at most `group` blocks sum the columns
/// and the prefix sums within the group in 16-bit lanes. The partial group
/// goes first, so no columns precede it, and every later group weights the
/// columns before it by `group`.
fn Columns(comptime lanes: usize) type {
    return struct {
        const Bytes = @Vector(lanes, u8);
        const Halves = @Vector(lanes, u16);
        const Words = @Vector(lanes, u32);
        /// Blocks a group sums in 16-bit lanes. A lane of a group's prefix
        /// sums reaches 255 group (group - 1) / 2, which 16 bits must hold.
        const group = 23;
        const chunk_blocks = chunk_bytes_max / lanes;
        const weights: Words = weights: {
            var result: [lanes]u32 = undefined;
            for (&result, 0..) |*weight, lane| weight.* = lanes - lane;
            break :weights result;
        };

        comptime {
            assert(lanes >= 16);
            assert(255 * group * (group - 1) / 2 <= std.math.maxInt(u16));
            assert(chunk_blocks >= 1);
        }

        fn chunk(bytes: []const u8) ChunkTotals {
            assert(bytes.len % lanes == 0);
            assert(bytes.len <= chunk_bytes_max);
            const blocks = bytes.len / lanes;
            var columns: Words = @splat(0);
            // The columns before each whole group, and the prefix sums within
            // each group, summed over the groups.
            var before: Words = @splat(0);
            var within: Words = @splat(0);
            var start = blocks % group;
            if (start != 0) {
                const sums16 = groupSums(bytes[0 .. start * lanes]);
                within += sums16.prefixes;
                columns += sums16.columns;
            }
            while (start < blocks) : (start += group) {
                const sums16 = groupSums(bytes[start * lanes ..][0 .. group * lanes]);
                before += columns;
                within += sums16.prefixes;
                columns += sums16.columns;
            }
            const prefixes = group * @as(u64, @reduce(.Add, before)) + @reduce(.Add, within);
            return .{
                .bytes = bytes.len,
                .columns = @reduce(.Add, columns),
                .weighted = @reduce(.Add, columns * weights),
                .prefixes = lanes * prefixes,
            };
        }

        /// The column and prefix sums of at most `group` blocks, summed in
        /// 16-bit lanes and returned in 32-bit lanes.
        fn groupSums(bytes: []const u8) struct { columns: Words, prefixes: Words } {
            assert(bytes.len % lanes == 0);
            assert(bytes.len <= group * lanes);
            var columns: Halves = @splat(0);
            var prefixes: Halves = @splat(0);
            var offset: usize = 0;
            while (offset < bytes.len) : (offset += lanes) {
                const block: Bytes = bytes[offset..][0..lanes].*;
                prefixes += columns;
                columns += @as(Halves, block);
            }
            return .{ .columns = columns, .prefixes = prefixes };
        }
    };
}

/// The sums after `bytes` with each reduced after every byte: the
/// definition.
fn bytewise(value: u32, bytes: []const u8) u32 {
    var first = value & 0xffff;
    var second = value >> 16;
    assert(first < modulus);
    assert(second < modulus);
    for (bytes) |byte| {
        first = (first + byte) % modulus;
        second = (second + first) % modulus;
    }
    return first | (second << 16);
}

test "Adler-32 matches RFC 1950 check values" {
    try std.testing.expectEqual(@as(u32, 0x0000_0001), Adler32.hash(""));
    try std.testing.expectEqual(@as(u32, 0x0062_0062), Adler32.hash("a"));
    try std.testing.expectEqual(@as(u32, 0x11e6_0398), Adler32.hash("Wikipedia"));
}

test "every vector width and the scalar loop follow the bytewise definition" {
    var prng = std.Random.DefaultPrng.init(0x6164_6c65_7233_3200);
    const random = prng.random();
    var bytes: [3 * chunk_bytes_max + 77]u8 = undefined;
    random.bytes(&bytes);
    var saturated: [bytes.len]u8 = undefined;
    @memset(&saturated, 0xff);
    const lengths = [_]usize{
        0,    1,    15,   16,   17,   63,   64,   65,    367,   368,       369,
        1471, 1472, 5503, 5504, 5551, 5552, 5553, 11104, 11105, bytes.len,
    };
    // The largest reduced sums, so that every chunk starts at its bound.
    const extreme: u32 = (modulus - 1) | ((modulus - 1) << 16);
    inline for (.{ 16, 32, 64 }) |lanes| {
        for ([_][]const u8{ &bytes, &saturated }) |source| {
            for (lengths) |len| {
                const drawn = random.uintLessThan(u32, modulus) |
                    (random.uintLessThan(u32, modulus) << 16);
                for ([_]u32{ 1, extreme, drawn }) |value| {
                    var sums = Sums.unpack(value);
                    const consumed = advanceBlocks(lanes, &sums, source[0..len]);
                    scalar(&sums, source[consumed..len]);
                    try std.testing.expectEqual(bytewise(value, source[0..len]), sums.pack());
                }
            }
        }
    }
    for (lengths) |len| {
        var sums = Sums.unpack(extreme);
        scalar(&sums, saturated[0..len]);
        try std.testing.expectEqual(bytewise(extreme, saturated[0..len]), sums.pack());
    }
}
