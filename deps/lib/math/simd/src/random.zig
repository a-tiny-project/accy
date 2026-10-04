const std = @import("std");
const crypto = @import("crypto/root.zig");
const rotate = @import("rotate.zig");
const shift = @import("shift.zig");
const tag = @import("tag.zig");

const jump_constants = [4]u64{
    0x180e_c6d3_3cfd_0aba,
    0xd5a6_1266_f0c9_392c,
    0xa958_2618_e03f_c9aa,
    0x39ab_dc45_29b1_661c,
};

const long_jump_constants = [4]u64{
    0x76e1_5d3e_fefd_cbbf,
    0xc500_4e44_1c52_2fb3,
    0x7771_0069_854e_e241,
    0x3910_9bb0_2acb_e635,
};

const uniform_scale: f64 = 0x1.0p-53;

pub const SplitMix64 = struct {
    state: u64,

    pub fn init(state: u64) SplitMix64 {
        return .{ .state = state };
    }

    pub fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9e37_79b9_7f4a_7c15;
        var value = self.state;
        value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
        value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
        return value ^ (value >> 31);
    }
};

pub const Xoshiro = struct {
    state: [4]u64,

    pub fn init(seed: u64) Xoshiro {
        var split = SplitMix64.init(seed);
        var state: [4]u64 = undefined;
        for (&state) |*value| value.* = split.next();
        return .{ .state = state };
    }

    pub fn initThread(seed: u64, thread_id: u64) Xoshiro {
        var result = init(seed);
        var stream: u64 = 0;
        while (stream < thread_id) : (stream += 1) result.jump();
        return result;
    }

    pub fn next(self: *Xoshiro) u64 {
        const result = std.math.rotl(u64, self.state[0] +% self.state[3], 23) +%
            self.state[0];
        const temporary = self.state[1] << 17;
        self.state[2] ^= self.state[0];
        self.state[3] ^= self.state[1];
        self.state[1] ^= self.state[2];
        self.state[0] ^= self.state[3];
        self.state[2] ^= temporary;
        self.state[3] = std.math.rotl(u64, self.state[3], 45);
        return result;
    }

    pub fn uniform(self: *Xoshiro) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) * uniform_scale;
    }

    pub fn getState(self: Xoshiro) [4]u64 {
        return self.state;
    }

    pub fn setState(self: *Xoshiro, state: [4]u64) void {
        self.state = state;
    }

    pub fn stateSize() usize {
        return 4;
    }

    pub fn jump(self: *Xoshiro) void {
        self.jumpWith(jump_constants);
    }

    pub fn longJump(self: *Xoshiro) void {
        self.jumpWith(long_jump_constants);
    }

    fn jumpWith(self: *Xoshiro, constants: [4]u64) void {
        var state: [4]u64 = @splat(0);
        for (constants) |bits| {
            for (0..64) |bit| {
                if (bits & (@as(u64, 1) << @intCast(bit)) != 0) {
                    inline for (0..4) |index| state[index] ^= self.state[index];
                }
                _ = self.next();
            }
        }
        self.state = state;
    }
};

pub fn VectorXoshiro(comptime D: type) type {
    requireU64(D);
    return struct {
        state: [4]D.Vector,

        const Self = @This();
        const DF: type = D.rebind(f64);

        pub fn init(seed: u64) Self {
            return initThread(seed, 0);
        }

        pub fn initThread(seed: u64, thread_number: u64) Self {
            var scalar = Xoshiro.init(seed);
            var stream: u64 = 0;
            while (stream < thread_number) : (stream += 1) scalar.longJump();
            var state: [4]D.Vector = @splat(@splat(0));
            inline for (0..D.lane_count) |lane| {
                const scalar_state = scalar.getState();
                inline for (0..4) |index| state[index][lane] = scalar_state[index];
                scalar.jump();
            }
            return .{ .state = state };
        }

        pub fn next(self: *Self) D.Vector {
            return update(&self.state);
        }

        pub fn fill(self: *Self, output: []u64) void {
            var index: usize = 0;
            while (index + D.lane_count <= output.len) : (index += D.lane_count) {
                const value: [D.lane_count]u64 = self.next();
                @memcpy(output[index .. index + D.lane_count], &value);
            }
            if (index != output.len) {
                const value: [D.lane_count]u64 = self.next();
                @memcpy(output[index..], value[0 .. output.len - index]);
            }
        }

        pub fn uniform(self: *Self) DF.Vector {
            return toUniform(self.next());
        }

        pub fn fillUniform(self: *Self, output: []f64) void {
            var index: usize = 0;
            while (index + D.lane_count <= output.len) : (index += D.lane_count) {
                const value: [D.lane_count]f64 = self.uniform();
                @memcpy(output[index .. index + D.lane_count], &value);
            }
            if (index != output.len) {
                const value: [D.lane_count]f64 = self.uniform();
                @memcpy(output[index..], value[0 .. output.len - index]);
            }
        }

        pub fn getState(self: Self) [4]D.Vector {
            return self.state;
        }

        pub fn setState(self: *Self, state: [4]D.Vector) void {
            self.state = state;
        }

        pub fn stateSize() usize {
            return 4 * D.lane_count;
        }

        fn update(state: *[4]D.Vector) D.Vector {
            const result = rotate.rotateRightSame(D, state[0] +% state[3], 41) +% state[0];
            const temporary = shift.shiftLeft(D, 17, state[1]);
            state[2] ^= state[0];
            state[3] ^= state[1];
            state[1] ^= state[2];
            state[0] ^= state[3];
            state[2] ^= temporary;
            state[3] = rotate.rotateRightSame(D, state[3], 19);
            return result;
        }

        fn toUniform(value: D.Vector) DF.Vector {
            const bits = shift.shiftRight(D, 11, value);
            var result: DF.Vector = undefined;
            inline for (0..D.lane_count) |index| {
                result[index] = @as(f64, @floatFromInt(bits[index])) * uniform_scale;
            }
            return result;
        }
    };
}

pub fn CachedXoshiro(comptime D: type, comptime cache_size: usize) type {
    if (cache_size == 0 or !std.math.isPowerOfTwo(cache_size)) {
        @compileError("cached xoshiro size must be a nonzero power of two");
    }
    return struct {
        generator: Generator,
        cache: [cache_size]u64,
        index: usize,

        const Self = @This();
        const Generator: type = VectorXoshiro(D);

        pub fn init(seed: u64) Self {
            return initThread(seed, 0);
        }

        pub fn initThread(seed: u64, thread_number: u64) Self {
            var result = Self{
                .generator = Generator.initThread(seed, thread_number),
                .cache = undefined,
                .index = 0,
            };
            result.generator.fill(&result.cache);
            return result;
        }

        pub fn next(self: *Self) u64 {
            std.debug.assert(self.index <= cache_size);
            if (self.index == cache_size) {
                self.generator.fill(&self.cache);
                self.index = 0;
            }
            const result = self.cache[self.index];
            self.index += 1;
            return result;
        }

        pub fn minimum() u64 {
            return 0;
        }

        pub fn maximum() u64 {
            return std.math.maxInt(u64);
        }
    };
}

pub fn DefaultCachedXoshiro(comptime D: type) type {
    return CachedXoshiro(D, 1024);
}

pub const AesCtrEngine = struct {
    key: [2 * (1 + rounds)]u64,

    const rounds: usize = 5;
    const D: type = tag.Full128(u8);

    pub fn initDeterministic() AesCtrEngine {
        return initKey(.{ 0x243f_6a88_85a3_08d3, 0x1319_8a2e_0370_7344 });
    }

    pub fn initKey(seed: [2]u64) AesCtrEngine {
        var result: AesCtrEngine = undefined;
        result.key[0] = seed[0];
        result.key[1] = seed[1];
        inline for (0..rounds) |index| {
            result.key[2 + 2 * index] = result.key[2 * index + 1] +%
                0xa409_3822_299f_31d0;
            result.key[2 + 2 * index + 1] = result.key[2 * index] +%
                0x082e_fa98_ec4e_6c89;
        }
        return result;
    }

    pub fn initWithEntropy(entropy: anytype) !AesCtrEngine {
        var bytes: [16]u8 = undefined;
        try entropy.fill(&bytes);
        return initKey(@bitCast(bytes));
    }

    pub fn generate(self: *const AesCtrEngine, stream: u64, counter: u64) u64 {
        var state = blockOf(.{ counter, stream }) ^ blockOf(self.key[0..2].*);
        inline for (0..rounds) |index| {
            state = crypto.aesRound(D, state, blockOf(self.key[2 + 2 * index ..][0..2].*));
        }
        return std.mem.bytesAsValue([2]u64, std.mem.asBytes(&state))[0];
    }

    /// The block whose bytes are those of `pair` in memory order. The engine
    /// reinterprets memory, which compiles to register moves, because the
    /// pinned compiler lowers a `@bitCast` between u64 and u8 vectors one
    /// lane at a time.
    fn blockOf(pair: [2]u64) D.Vector {
        return std.mem.bytesToValue(D.Vector, std.mem.asBytes(&pair));
    }
};

pub const RngStream = struct {
    engine: *const AesCtrEngine,
    stream: u64,
    counter: u64 = 0,

    pub fn init(engine: *const AesCtrEngine, stream: u64) RngStream {
        return .{ .engine = engine, .stream = stream };
    }

    pub fn next(self: *RngStream) u64 {
        const result = self.engine.generate(self.stream, self.counter);
        self.counter +%= 1;
        return result;
    }

    pub fn minimum() u64 {
        return 0;
    }

    pub fn maximum() u64 {
        return std.math.maxInt(u64);
    }
};

pub fn randomNormalizedFloat(stream: *RngStream) f32 {
    const exponent = @as(u32, @bitCast(@as(f32, 1)));
    const mantissa = @as(u32, @truncate(stream.next())) & 0x007f_ffff;
    const value: f32 = @bitCast(exponent | mantissa);
    std.debug.assert(value >= 1);
    std.debug.assert(value < 2);
    const result = (2 * (value - 1)) - 1;
    std.debug.assert(result >= -1);
    std.debug.assert(result < 1);
    return result;
}

pub fn fillRandom(comptime T: type, engine: *const AesCtrEngine, stream_id: u64, output: []T) void {
    var stream = RngStream.init(engine, stream_id);
    for (output) |*value| value.* = castRandom(T, stream.next());
}

fn castRandom(comptime T: type, value: u64) T {
    return switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .unsigned)
            @truncate(value)
        else blk: {
            const U = @Int(.unsigned, info.bits);
            break :blk @bitCast(@as(U, @truncate(value)));
        },
        .float => @floatFromInt(value),
        else => @compileError("fillRandom requires integer or floating-point outputs"),
    };
}

fn requireU64(comptime D: type) void {
    if (comptime D.Lane != u64) @compileError("vector xoshiro requires u64 lanes");
}

const TestEntropy = struct {
    offset: u8,

    fn fill(self: *@This(), output: []u8) !void {
        for (output, 0..) |*byte, index| byte.* = @intCast(index * 7 + self.offset);
    }
};

test "Highway scalar xoshiro state replay and stream jumps are deterministic" {
    var generator = Xoshiro.init(123);
    const state = generator.getState();
    const first = generator.next();
    const second = generator.next();
    try std.testing.expect(first != second);
    generator.setState(state);
    try std.testing.expectEqual(first, generator.next());
    try std.testing.expectEqual(second, generator.next());
    var jumped = Xoshiro.initThread(123, 1);
    var reference = Xoshiro.init(123);
    reference.jump();
    try std.testing.expectEqual(reference.getState(), jumped.getState());
    try std.testing.expectEqual(@as(usize, 4), Xoshiro.stateSize());
}

test "Highway AVX2 scalar and vector xoshiro oracle matches exactly" {
    var scalar = Xoshiro.init(123);
    try std.testing.expectEqual(
        [4]u64{
            0xb4dc_9bd4_62de_412b,
            0xfa02_3ce9_f06f_b77c,
            0xdc12_d311_d371_cbe8,
            0xafd2_040c_9098_81ff,
        },
        scalar.getState(),
    );
    for ([_]u64{
        0xa556_5735_f810_987a,
        0xd691_4642_e58d_662e,
        0xaa75_21fe_b709_887f,
        0x863c_d15c_558d_6bfb,
    }) |expected| try std.testing.expectEqual(expected, scalar.next());
    var jumped = Xoshiro.init(123);
    jumped.jump();
    try std.testing.expectEqual(
        [4]u64{
            0xed6f_8f0b_3989_38af,
            0x17c5_be01_9e09_5507,
            0x05a0_a7d3_71bf_d778,
            0xbc77_948a_a522_4033,
        },
        jumped.getState(),
    );
    var long_jumped = Xoshiro.init(123);
    long_jumped.longJump();
    try std.testing.expectEqual(
        [4]u64{
            0xf98f_04cb_080b_8942,
            0xd884_97e0_e599_e6f1,
            0x3b4f_07f1_f6d2_6dd4,
            0x5d3e_2cd5_d040_18c1,
        },
        long_jumped.getState(),
    );
    const D = tag.FixedTag(u64, 4);
    const Generator = VectorXoshiro(D);
    var vector = Generator.init(456);
    try std.testing.expect(@reduce(.And, vector.next() == @as(D.Vector, .{
        0xa901_0f72_89ae_bac2,
        0x6990_d4cc_67a1_47d7,
        0x76bd_c3fa_db67_4b7c,
        0x6580_3fd8_b3a1_a35d,
    })));
    try std.testing.expect(@reduce(.And, vector.next() == @as(D.Vector, .{
        0x5fcc_d4ec_4e33_71f4,
        0x5321_fc38_a086_1200,
        0x0bce_898c_528d_1264,
        0xf716_df28_1d99_3979,
    })));
    var uniform = Generator.init(456);
    const real: [4]f64 = uniform.uniform();
    try std.testing.expectEqual(
        [4]u64{
            0x3fe5_2021_ee51_35d7,
            0x3fda_6435_3319_e850,
            0x3fdd_af70_feb6_d9d2,
            0x3fd9_600f_f62c_e868,
        },
        @as([4]u64, @bitCast(real)),
    );
}

test "Highway vector xoshiro interleaves jump-separated scalar streams" {
    const D = tag.FixedTag(u64, 4);
    const Generator = VectorXoshiro(D);
    var generator = Generator.init(456);
    var streams: [D.lane_count]Xoshiro = undefined;
    streams[0] = Xoshiro.init(456);
    for (1..D.lane_count) |index| {
        streams[index] = streams[index - 1];
        streams[index].jump();
    }
    for (0..7) |_| {
        const actual: [D.lane_count]u64 = generator.next();
        for (&streams, 0..) |*stream, lane| {
            try std.testing.expectEqual(stream.next(), actual[lane]);
        }
    }
    try std.testing.expectEqual(@as(usize, 16), Generator.stateSize());
}

test "Highway vector xoshiro thread streams begin at long-jump partitions" {
    const D = tag.FixedTag(u64, 4);
    const Generator = VectorXoshiro(D);
    var generator = Generator.initThread(654, 3);
    var reference = Xoshiro.init(654);
    for (0..3) |_| reference.longJump();
    const state = generator.getState();
    inline for (0..D.lane_count) |lane| {
        const scalar_state = reference.getState();
        inline for (0..4) |index| {
            try std.testing.expectEqual(scalar_state[index], state[index][lane]);
        }
        reference.jump();
    }
}

test "Highway vector xoshiro fills awkward tails and uniform doubles" {
    const D = tag.FixedTag(u64, 4);
    const Generator = VectorXoshiro(D);
    var integers = Generator.init(789);
    var expected = Generator.init(789);
    var output: [13]u64 = undefined;
    integers.fill(&output);
    for (0..4) |block| {
        const values: [D.lane_count]u64 = expected.next();
        const begin = block * D.lane_count;
        const count = @min(D.lane_count, output.len - begin);
        for (0..count) |lane| try std.testing.expectEqual(values[lane], output[begin + lane]);
    }
    var uniforms = Generator.init(789);
    var real: [13]f64 = undefined;
    uniforms.fillUniform(&real);
    for (real) |value| try std.testing.expect(value >= 0 and value < 1);
}

test "Highway cached xoshiro refills without changing stream order" {
    const D = tag.FixedTag(u64, 4);
    const Cached = CachedXoshiro(D, 8);
    const Generator = VectorXoshiro(D);
    var cached = Cached.init(987);
    var vector = Generator.init(987);
    var expected: [24]u64 = undefined;
    vector.fill(&expected);
    for (expected) |value| try std.testing.expectEqual(value, cached.next());
    try std.testing.expectEqual(@as(u64, 0), Cached.minimum());
    try std.testing.expectEqual(std.math.maxInt(u64), Cached.maximum());
}

test "Highway AES counter streams are deterministic and independently addressed" {
    const engine = AesCtrEngine.initDeterministic();
    var first = RngStream.init(&engine, 7);
    var replay = RngStream.init(&engine, 7);
    var other = RngStream.init(&engine, 8);
    for (0..16) |_| {
        try std.testing.expectEqual(first.next(), replay.next());
        try std.testing.expect(first.counter == replay.counter);
    }
    try std.testing.expect(engine.generate(7, 0) != other.next());
}

test "Highway AVX2 AES counter and normalized float oracle matches exactly" {
    const engine = AesCtrEngine.initDeterministic();
    try std.testing.expectEqual(@as(u64, 0xf0ea_ad2f_c4a2_c3e1), engine.generate(7, 0));
    try std.testing.expectEqual(@as(u64, 0xbf34_0afe_30f5_275d), engine.generate(7, 1));
    try std.testing.expectEqual(@as(u64, 0x0797_7286_13ce_fc88), engine.generate(8, 0));
    var stream = RngStream.init(&engine, 0);
    for ([_]u32{ 0xbed6_6698, 0x3e46_f1b0, 0x3f17_03d4 }) |bits| {
        try std.testing.expectEqual(bits, @as(u32, @bitCast(randomNormalizedFloat(&stream))));
    }
}

test "Highway AES counter accepts caller entropy and fills typed buffers" {
    var entropy = TestEntropy{ .offset = 3 };
    const engine = try AesCtrEngine.initWithEntropy(&entropy);
    var other_entropy = TestEntropy{ .offset = 11 };
    const other_engine = try AesCtrEngine.initWithEntropy(&other_entropy);
    try std.testing.expect(engine.generate(0, 0) != other_engine.generate(0, 0));
    var actual: [17]u16 = undefined;
    fillRandom(u16, &engine, 91, &actual);
    var stream = RngStream.init(&engine, 91);
    for (actual) |value| try std.testing.expectEqual(@as(u16, @truncate(stream.next())), value);
}

test "Highway normalized float spans the half-open signed unit interval" {
    const engine = AesCtrEngine.initDeterministic();
    var stream = RngStream.init(&engine, 0);
    var sum: f64 = 0;
    for (0..20_000) |_| {
        const value = randomNormalizedFloat(&stream);
        try std.testing.expect(value >= -1 and value < 1);
        sum += value;
    }
    try std.testing.expect(@abs(sum / 20_000) < 0.02);
}

test "Highway AES counter bit and byte distributions remain balanced" {
    const engine = AesCtrEngine.initDeterministic();
    var stream = RngStream.init(&engine, 0);
    const count: usize = 20_000;
    var one_bits: u64 = 0;
    for (0..count) |_| one_bits += @popCount(stream.next());
    const bit_ratio = @as(f64, @floatFromInt(one_bits)) /
        @as(f64, @floatFromInt(count * 64));
    try std.testing.expect(bit_ratio >= 0.49 and bit_ratio <= 0.51);
    for (0..8) |byte_index| {
        var counts: [256]u32 = @splat(0);
        const amount: u6 = @intCast(byte_index * 8);
        for (0..count) |_| counts[@as(u8, @truncate(stream.next() >> amount))] += 1;
        const expected = @as(f64, @floatFromInt(count)) / 256;
        var chi_squared: f64 = 0;
        for (counts) |observed| {
            const difference = @as(f64, @floatFromInt(observed)) - expected;
            chi_squared += difference * difference / expected;
        }
        try std.testing.expect(chi_squared >= 170 and chi_squared <= 340);
    }
}
