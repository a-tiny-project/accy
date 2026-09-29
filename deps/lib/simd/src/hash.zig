const std = @import("std");
const arithmetic = @import("arithmetic.zig");
const random = @import("random.zig");
const shift = @import("shift.zig");
const tag = @import("tag.zig");

pub fn lemireMod(input: u32, range: u32) u32 {
    std.debug.assert(range != 0);
    const reduced: u32 = @truncate((@as(u64, input) * @as(u64, range)) >> 32);
    std.debug.assert(reduced < range);
    return reduced;
}

test "Highway Lemire reduction scales the full u32 domain into range" {
    try std.testing.expectEqual(@as(u32, 0), lemireMod(0, 37));
    try std.testing.expectEqual(@as(u32, 18), lemireMod(0x8000_0000, 37));
    try std.testing.expectEqual(@as(u32, 36), lemireMod(std.math.maxInt(u32), 37));
    try std.testing.expectEqual(@as(u32, 0), lemireMod(std.math.maxInt(u32), 1));
}

pub fn MaskedWeakTwoMul(comptime bits: usize) type {
    validateBits(u32, bits);
    return struct {
        key_value: u32 = 0,

        const Self = @This();
        pub const Lane: type = u32;
        pub const mask: u32 = maskValue(u32, bits);

        pub fn init() Self {
            return .{};
        }

        pub fn initKey(key_value: u32) Self {
            assertMasked(u32, bits, key_value);
            return .{ .key_value = key_value };
        }

        pub fn initSeed(engine: *const random.AesCtrEngine, seed: u64) Self {
            return .{ .key_value = maybeMask(u32, bits, @truncate(engine.generate(seed, 0))) };
        }

        pub fn hash(self: Self, input: u32) u32 {
            assertMasked(u32, bits, input);
            var result = input ^ self.key_value;
            result ^= result >> 16;
            result *%= 0x21f0_aaad;
            result = maybeMask(u32, bits, result);
            result ^= result >> 15;
            result *%= 0xf35a_2d97;
            result = maybeMask(u32, bits, result);
            result ^= result >> 15;
            assertMasked(u32, bits, result);
            return result;
        }

        pub fn oneVec(self: Self, comptime D: type, input: D.Vector) D.Vector {
            requireTag(D, u32);
            assertMaskedVector(D, bits, input);
            var result = input ^ @as(D.Vector, @splat(self.key_value));
            result ^= shift.shiftRight(D, 16, result);
            result = arithmetic.mul(D, result, @splat(0x21f0_aaad));
            result = maybeMaskVector(D, bits, result);
            result ^= shift.shiftRight(D, 15, result);
            result = arithmetic.mul(D, result, @splat(0xf35a_2d97));
            result = maybeMaskVector(D, bits, result);
            result ^= shift.shiftRight(D, 15, result);
            assertMaskedVector(D, bits, result);
            return result;
        }

        pub fn twoVec(self: Self, comptime D: type, first: *D.Vector, second: *D.Vector) void {
            first.* = self.oneVec(D, first.*);
            second.* = self.oneVec(D, second.*);
        }
    };
}

pub const WeakTwoMul = MaskedWeakTwoMul(32);

pub fn MaskedTriple32(comptime bits: usize) type {
    validateBits(u32, bits);
    return struct {
        key_value: u32 = 0,

        const Self = @This();
        pub const Lane: type = u32;
        pub const mask: u32 = maskValue(u32, bits);

        pub fn init() Self {
            return .{};
        }

        pub fn initKey(key_value: u32) Self {
            assertMasked(u32, bits, key_value);
            return .{ .key_value = key_value };
        }

        pub fn initSeed(engine: *const random.AesCtrEngine, seed: u64) Self {
            return .{ .key_value = maybeMask(u32, bits, @truncate(engine.generate(seed, 0))) };
        }

        pub fn key(self: Self) u32 {
            return self.key_value;
        }

        pub fn hash(self: Self, input: u32) u32 {
            assertMasked(u32, bits, input);
            var result = input ^ self.key_value;
            result ^= result >> 17;
            result *%= 0xed5a_d4bb;
            result = maybeMask(u32, bits, result);
            result ^= result >> 11;
            result *%= 0xac4c_1b51;
            result = maybeMask(u32, bits, result);
            result ^= result >> 15;
            result *%= 0x3184_8bab;
            result = maybeMask(u32, bits, result);
            result ^= result >> 14;
            assertMasked(u32, bits, result);
            return result;
        }

        pub fn oneVec(self: Self, comptime D: type, input: D.Vector) D.Vector {
            requireTag(D, u32);
            assertMaskedVector(D, bits, input);
            var result = input ^ @as(D.Vector, @splat(self.key_value));
            result ^= shift.shiftRight(D, 17, result);
            result = arithmetic.mul(D, result, @splat(0xed5a_d4bb));
            result = maybeMaskVector(D, bits, result);
            result ^= shift.shiftRight(D, 11, result);
            result = arithmetic.mul(D, result, @splat(0xac4c_1b51));
            result = maybeMaskVector(D, bits, result);
            result ^= shift.shiftRight(D, 15, result);
            result = arithmetic.mul(D, result, @splat(0x3184_8bab));
            result = maybeMaskVector(D, bits, result);
            result ^= shift.shiftRight(D, 14, result);
            assertMaskedVector(D, bits, result);
            return result;
        }

        pub fn twoVec(self: Self, comptime D: type, first: *D.Vector, second: *D.Vector) void {
            first.* = self.oneVec(D, first.*);
            second.* = self.oneVec(D, second.*);
        }
    };
}

pub const Triple32 = MaskedTriple32(32);

pub fn MaskedMoremur(comptime bits: usize) type {
    validateBits(u64, bits);
    return struct {
        key_value: u64 = 0,

        const Self = @This();
        pub const Lane: type = u64;
        pub const mask: u64 = maskValue(u64, bits);

        pub fn init() Self {
            return .{};
        }

        pub fn initKey(key_value: u64) Self {
            assertMasked(u64, bits, key_value);
            return .{ .key_value = key_value };
        }

        pub fn initSeed(engine: *const random.AesCtrEngine, seed: u64) Self {
            return .{ .key_value = maybeMask(u64, bits, engine.generate(seed, 0)) };
        }

        pub fn key(self: Self) u64 {
            return self.key_value;
        }

        pub fn hash(self: Self, input: u64) u64 {
            assertMasked(u64, bits, input);
            var result = input ^ self.key_value;
            result ^= result >> 27;
            result *%= 0x3c79_ac49_2ba7_b653;
            result = maybeMask(u64, bits, result);
            result ^= result >> 33;
            result *%= 0x1c69_b3f7_4ac4_ae35;
            result = maybeMask(u64, bits, result);
            result ^= result >> 27;
            assertMasked(u64, bits, result);
            return result;
        }

        pub fn oneVec(self: Self, comptime D: type, input: D.Vector) D.Vector {
            requireTag(D, u64);
            assertMaskedVector(D, bits, input);
            var result = input ^ @as(D.Vector, @splat(self.key_value));
            result ^= shift.shiftRight(D, 27, result);
            result = arithmetic.mul(D, result, @splat(0x3c79_ac49_2ba7_b653));
            result = maybeMaskVector(D, bits, result);
            result ^= shift.shiftRight(D, 33, result);
            result = arithmetic.mul(D, result, @splat(0x1c69_b3f7_4ac4_ae35));
            result = maybeMaskVector(D, bits, result);
            result ^= shift.shiftRight(D, 27, result);
            assertMaskedVector(D, bits, result);
            return result;
        }

        pub fn twoVec(self: Self, comptime D: type, first: *D.Vector, second: *D.Vector) void {
            first.* = self.oneVec(D, first.*);
            second.* = self.oneVec(D, second.*);
        }
    };
}

pub const Moremur = MaskedMoremur(64);

pub fn hashArrayInPlace(comptime D: type, hash: anytype, inout: []D.Lane) void {
    hashArray(D, hash, inout, inout);
}

pub fn hashArray(
    comptime D: type,
    hash: anytype,
    input: []const D.Lane,
    output: []D.Lane,
) void {
    std.debug.assert(input.len == output.len);
    const lanes = D.lane_count;
    var index: usize = 0;
    var remaining = input.len;
    while (remaining >= 4 * lanes) : ({
        index += 4 * lanes;
        remaining -= 4 * lanes;
    }) {
        var first = loadVector(D, input[index + 0 * lanes ..]);
        var second = loadVector(D, input[index + 1 * lanes ..]);
        var third = loadVector(D, input[index + 2 * lanes ..]);
        var fourth = loadVector(D, input[index + 3 * lanes ..]);
        hash.twoVec(D, &first, &second);
        hash.twoVec(D, &third, &fourth);
        storeVector(D, first, output[index + 0 * lanes ..]);
        storeVector(D, second, output[index + 1 * lanes ..]);
        storeVector(D, third, output[index + 2 * lanes ..]);
        storeVector(D, fourth, output[index + 3 * lanes ..]);
    }
    while (remaining >= lanes) : ({
        index += lanes;
        remaining -= lanes;
    }) {
        const value = hash.oneVec(D, loadVector(D, input[index..]));
        storeVector(D, value, output[index..]);
    }
    if (remaining != 0) {
        var tail: [D.lane_count]D.Lane = @splat(0);
        @memcpy(tail[0..remaining], input[index..]);
        const value = hash.oneVec(D, @as(D.Vector, tail));
        const result: [D.lane_count]D.Lane = value;
        @memcpy(output[index..], result[0..remaining]);
    }
}

pub fn fillRandomDistinct(comptime T: type, key: u32, output: []T) void {
    requireDistinctLane(T);
    if (@bitSizeOf(usize) > 32) {
        std.debug.assert(output.len <= @as(usize, 1) << 32);
    }
    const permutation = Triple32.initKey(key);
    for (output, 0..) |*value, index| {
        value.* = @intCast(permutation.hash(@intCast(index)));
    }
}

fn loadVector(comptime D: type, input: []const D.Lane) D.Vector {
    std.debug.assert(input.len >= D.lane_count);
    var lanes: [D.lane_count]D.Lane = undefined;
    @memcpy(&lanes, input[0..D.lane_count]);
    return lanes;
}

fn storeVector(comptime D: type, value: D.Vector, output: []D.Lane) void {
    std.debug.assert(output.len >= D.lane_count);
    const lanes: [D.lane_count]D.Lane = value;
    @memcpy(output[0..D.lane_count], &lanes);
}

fn maskValue(comptime T: type, comptime bits: usize) T {
    return if (bits == 0)
        0
    else if (bits == @bitSizeOf(T))
        std.math.maxInt(T)
    else
        (@as(T, 1) << @intCast(bits)) - 1;
}

fn maybeMask(comptime T: type, comptime bits: usize, value: T) T {
    return if (bits == @bitSizeOf(T)) value else value & maskValue(T, bits);
}

fn maybeMaskVector(comptime D: type, comptime bits: usize, value: D.Vector) D.Vector {
    return if (bits == @bitSizeOf(D.Lane))
        value
    else
        value & @as(D.Vector, @splat(maskValue(D.Lane, bits)));
}

fn assertMasked(comptime T: type, comptime bits: usize, value: T) void {
    if (bits != @bitSizeOf(T)) std.debug.assert(value <= maskValue(T, bits));
}

fn assertMaskedVector(comptime D: type, comptime bits: usize, value: D.Vector) void {
    if (bits != @bitSizeOf(D.Lane)) {
        const mask: D.Vector = @splat(maskValue(D.Lane, bits));
        std.debug.assert(@reduce(.And, value <= mask));
    }
}

fn validateBits(comptime T: type, comptime bits: usize) void {
    if (bits > @bitSizeOf(T)) @compileError("masked hash bits exceed lane width");
}

fn requireTag(comptime D: type, comptime T: type) void {
    if (comptime D.Lane != T) @compileError("hash tag lane type mismatch");
}

fn requireDistinctLane(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.signedness != .unsigned or info.bits < 32) {
                @compileError("distinct hash outputs require unsigned lanes of at least 32 bits");
            }
        },
        else => @compileError("distinct hash outputs require unsigned integer lanes"),
    }
}

test "Highway hash scalar and vector paths agree lane by lane" {
    const engine = random.AesCtrEngine.initDeterministic();
    const D32 = tag.FixedTag(u32, 8);
    const D64 = tag.FixedTag(u64, 4);
    const triple = Triple32.initSeed(&engine, 7);
    const moremur = Moremur.initSeed(&engine, 9);
    const input32: D32.Vector = .{ 0, 1, 2, 3, 0x1234_5678, 0xffff_ffff, 77, 91 };
    const input64: D64.Vector = .{ 0, 1, 0x1234_5678_9abc_def0, 0xffff_ffff_ffff_ffff };
    const input32_lanes: [D32.lane_count]u32 = input32;
    const input64_lanes: [D64.lane_count]u64 = input64;
    const output32: [D32.lane_count]u32 = triple.oneVec(D32, input32);
    const output64: [D64.lane_count]u64 = moremur.oneVec(D64, input64);
    for (input32_lanes, output32) |input, output| {
        try std.testing.expectEqual(triple.hash(input), output);
    }
    for (input64_lanes, output64) |input, output| {
        try std.testing.expectEqual(moremur.hash(input), output);
    }
    var first = input32;
    var second = input32 +% @as(D32.Vector, @splat(11));
    const expected_first = triple.oneVec(D32, first);
    const expected_second = triple.oneVec(D32, second);
    triple.twoVec(D32, &first, &second);
    try std.testing.expect(@reduce(.And, first == expected_first));
    try std.testing.expect(@reduce(.And, second == expected_second));
}

test "Highway AVX2 keyed hash oracle matches exactly" {
    const engine = random.AesCtrEngine.initDeterministic();
    const weak = WeakTwoMul.initKey(0x1234_5678);
    const triple = Triple32.initKey(0x1234_5678);
    const moremur = Moremur.initSeed(&engine, 7);
    const input32 = [_]u32{ 0, 1, 2, 3, 0x1234_5678, 0xffff_ffff, 77, 91 };
    const input64 = [_]u64{ 0, 1, 0x1234_5678_9abc_def0, 0xffff_ffff_ffff_ffff };
    const weak_expected = [_]u32{
        0x96e6_76bd,
        0x2634_7ffd,
        0x2135_26e1,
        0xe0f5_ee5a,
        0,
        0x1f4b_2c03,
        0xe7b2_d7ae,
        0xf79d_2c26,
    };
    const triple_expected = [_]u32{
        0xfac9_70ff,
        0x603a_31eb,
        0x531f_8519,
        0xac2e_592d,
        0,
        0x8414_acc4,
        0xc6e3_2b94,
        0x00df_8b80,
    };
    const moremur_expected = [_]u64{
        0xd451_6cbf_6f1f_b72a,
        0x902e_cf3f_1199_340a,
        0x2e51_df48_8121_df97,
        0x5b31_dff9_dfb3_9f71,
    };
    try std.testing.expectEqual(@as(u64, 0xf0ea_ad2f_c4a2_c3e1), moremur.key());
    for (input32, weak_expected) |input, expected| {
        try std.testing.expectEqual(expected, weak.hash(input));
    }
    for (input32, triple_expected) |input, expected| {
        try std.testing.expectEqual(expected, triple.hash(input));
    }
    for (input64, moremur_expected) |input, expected| {
        try std.testing.expectEqual(expected, moremur.hash(input));
    }
    const masked_weak = MaskedWeakTwoMul(13).initSeed(&engine, 3);
    const masked_triple = MaskedTriple32(13).initSeed(&engine, 5);
    const masked_moremur = MaskedMoremur(47).initSeed(&engine, 9);
    try std.testing.expectEqual(@as(u32, 0x1e42), masked_triple.key());
    try std.testing.expectEqual(@as(u32, 0x10ed), masked_weak.hash(0x1234));
    try std.testing.expectEqual(@as(u32, 0x0b10), masked_triple.hash(0x1234));
    try std.testing.expectEqual(@as(u64, 0x1de5_1286_7cff), masked_moremur.hash(0x1234_5678_9ab));
    var tail = [_]u32{ 3, 20, 37, 54, 71, 88, 105, 122, 139, 156, 173, 190, 207 };
    hashArrayInPlace(tag.FixedTag(u32, 8), triple, &tail);
    try std.testing.expectEqual(
        [_]u32{
            0xac2e_592d,
            0xcd31_1a0a,
            0xdaa8_653e,
            0x7962_6834,
            0x612e_c03a,
            0x9412_7d8c,
            0x2a72_c1ed,
            0x6417_39d8,
            0xc56a_7ac6,
            0x4d0f_5ada,
            0x4e17_8eab,
            0x5473_f841,
            0x11fb_5ecd,
        },
        tail,
    );
}

test "Highway masked hashes remain bijections on a small complete domain" {
    const engine = random.AesCtrEngine.initDeterministic();
    try expectBijection13(MaskedWeakTwoMul(13).initSeed(&engine, 3));
    try expectBijection13(MaskedTriple32(13).initSeed(&engine, 5));
    try expectBijection13(MaskedMoremur(13).initSeed(&engine, 7));
}

test "Highway masked hashes retain their declared ranges" {
    const engine = random.AesCtrEngine.initDeterministic();
    try expectMaskedSamples(MaskedWeakTwoMul(1).initSeed(&engine, 1), &engine);
    try expectMaskedSamples(MaskedWeakTwoMul(31).initSeed(&engine, 2), &engine);
    try expectMaskedSamples(MaskedTriple32(7).initSeed(&engine, 3), &engine);
    try expectMaskedSamples(MaskedTriple32(31).initSeed(&engine, 4), &engine);
    try expectMaskedSamples(MaskedMoremur(1).initSeed(&engine, 5), &engine);
    try expectMaskedSamples(MaskedMoremur(63).initSeed(&engine, 6), &engine);
}

test "Highway hash arrays preserve scalar order through full vectors and tails" {
    const engine = random.AesCtrEngine.initDeterministic();
    const D32 = tag.FixedTag(u32, 8);
    const D64 = tag.FixedTag(u64, 4);
    const triple = Triple32.initSeed(&engine, 11);
    const moremur = Moremur.initSeed(&engine, 13);
    var input32: [73]u32 = undefined;
    var output32: [73]u32 = undefined;
    for (&input32, 0..) |*value, index| value.* = @intCast(index * 17 + 3);
    hashArray(D32, triple, &input32, &output32);
    for (input32, output32) |input, output| try std.testing.expectEqual(triple.hash(input), output);
    hashArrayInPlace(D32, triple, &input32);
    try std.testing.expectEqualSlices(u32, &output32, &input32);
    var input64: [39]u64 = undefined;
    var output64: [39]u64 = undefined;
    for (&input64, 0..) |*value, index| {
        value.* = @as(u64, @intCast(index)) * 0x1_0000_0001 + 9;
    }
    hashArray(D64, moremur, &input64, &output64);
    for (input64, output64) |input, output| {
        try std.testing.expectEqual(moremur.hash(input), output);
    }
}

test "Highway hash edge cases remain nontrivial and seed separated" {
    const engine = random.AesCtrEngine.initDeterministic();
    const triple = Triple32.initSeed(&engine, 0);
    const other_triple = Triple32.initSeed(&engine, 1);
    const moremur = Moremur.initSeed(&engine, 0);
    const other_moremur = Moremur.initSeed(&engine, 1);
    try std.testing.expect(triple.hash(0) != 0);
    try std.testing.expect(triple.hash(0) != triple.hash(1));
    try std.testing.expect(triple.hash(0xffff_ffff) != 0);
    try std.testing.expect(triple.hash(42) != other_triple.hash(42));
    try std.testing.expect(moremur.hash(0) != 0);
    try std.testing.expect(moremur.hash(0) != moremur.hash(1));
    try std.testing.expect(moremur.hash(0xffff_ffff_ffff_ffff) != 0);
    try std.testing.expect(moremur.hash(42) != other_moremur.hash(42));
    for (0..1000) |input| {
        const value: u32 = @intCast(input);
        try std.testing.expect(triple.hash(value) != triple.hash(value + 1));
        const large = @as(u64, 1) << 40;
        try std.testing.expect(moremur.hash(large + input) != moremur.hash(large + input + 1));
    }
    try std.testing.expectEqual(@as(u32, 0), MaskedTriple32(0).initKey(0).hash(0));
    try std.testing.expectEqual(@as(u64, 0), MaskedMoremur(0).initKey(0).hash(0));
}

test "Highway Triple32 avalanche and output bits remain balanced" {
    const engine = random.AesCtrEngine.initDeterministic();
    const hash = Triple32.initSeed(&engine, 0);
    var generator = random.Xoshiro.init(0x4841_5348_5445_5354);
    const avalanche_trials: u32 = 2000;
    var flip_counts: [32][32]u32 = @splat(@splat(0));
    for (0..avalanche_trials) |_| {
        const input: u32 = @truncate(generator.next());
        const baseline = hash.hash(input);
        for (0..32) |input_bit| {
            const changed = hash.hash(input ^ (@as(u32, 1) << @intCast(input_bit)));
            const difference = baseline ^ changed;
            for (0..32) |output_bit| {
                if (difference & (@as(u32, 1) << @intCast(output_bit)) != 0) {
                    flip_counts[input_bit][output_bit] += 1;
                }
            }
        }
    }
    for (flip_counts) |row| {
        for (row) |count| {
            try std.testing.expect(count >= avalanche_trials * 35 / 100);
            try std.testing.expect(count <= avalanche_trials * 65 / 100);
        }
    }
    const bias_trials: u32 = 20_000;
    var one_counts: [32]u32 = @splat(0);
    for (0..bias_trials) |_| {
        const output = hash.hash(@truncate(generator.next()));
        for (0..32) |bit| {
            if (output & (@as(u32, 1) << @intCast(bit)) != 0) one_counts[bit] += 1;
        }
    }
    for (one_counts) |count| {
        try std.testing.expect(count >= bias_trials * 48 / 100);
        try std.testing.expect(count <= bias_trials * 52 / 100);
    }
}

test "Highway distinct counter fill widens the same Triple32 permutation" {
    var narrow: [257]u32 = undefined;
    var wide: [257]u64 = undefined;
    fillRandomDistinct(u32, 0x1234_5678, &narrow);
    fillRandomDistinct(u64, 0x1234_5678, &wide);
    for (narrow, wide, 0..) |value, widened, index| {
        try std.testing.expectEqual(@as(u64, value), widened);
        for (narrow[0..index]) |prior| try std.testing.expect(value != prior);
    }
}

fn expectBijection13(hash: anytype) !void {
    var seen: [1 << 13]bool = @splat(false);
    for (0..seen.len) |input| {
        const output: usize = @intCast(hash.hash(@intCast(input)));
        try std.testing.expect(output < seen.len);
        try std.testing.expect(!seen[output]);
        seen[output] = true;
    }
    for (seen) |value| try std.testing.expect(value);
}

fn expectMaskedSamples(hash: anytype, engine: *const random.AesCtrEngine) !void {
    const Hash = @TypeOf(hash);
    var stream = random.RngStream.init(engine, 101);
    for (0..1000) |_| {
        const input: Hash.Lane = @truncate(stream.next() & Hash.mask);
        try std.testing.expect(hash.hash(input) <= Hash.mask);
    }
}
