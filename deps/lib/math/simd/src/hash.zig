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
