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
