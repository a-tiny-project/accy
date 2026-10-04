const std = @import("std");
const builtin = @import("builtin");
const hash_mod = @import("hash.zig");
const multiply = @import("multiply.zig");
const random = @import("random.zig");
const shift = @import("shift.zig");
const table = @import("table.zig");

pub const bucket_count: usize = 16;
pub const feistel_candidate_count: usize = 9;
pub const max_attempts_per_bucket: usize = 150_000;

pub const ShardMulData = struct {
    table: [bucket_count]u32 = @splat(0),
    keys: [4]u32 = @splat(0),
    attempts: [bucket_count]u32 = @splat(0),
};

pub const ShardMul = struct {
    table: [bucket_count]u32,
    rounds: [4]hash_mod.WeakTwoMul,

    const Self = @This();

    pub const FeistelPair = struct {
        left: u32,
        right: u32,
    };

    pub fn init(data: ShardMulData) Self {
        return .{
            .table = data.table,
            .rounds = .{
                hash_mod.WeakTwoMul.initKey(data.keys[0]),
                hash_mod.WeakTwoMul.initKey(data.keys[1]),
                hash_mod.WeakTwoMul.initKey(data.keys[2]),
                hash_mod.WeakTwoMul.initKey(data.keys[3]),
            },
        };
    }

    pub fn isEmpty(self: Self) bool {
        if (self.table[0] == 0) return true;
        for (self.table) |entry| {
            if (entry == 0) @panic("ShardMul table contains a zero multiplier");
        }
        return false;
    }

    pub fn feistel(self: Self, input: u64) FeistelPair {
        var left: u32 = @truncate(input);
        var right: u32 = @truncate(input >> 32);
        left ^= self.rounds[0].hash(right);
        right ^= self.rounds[1].hash(left);
        left ^= self.rounds[2].hash(right);
        right ^= self.rounds[3].hash(left);
        return .{ .left = left, .right = right };
    }

    pub fn bucketIndex(left: u32) u32 {
        return left >> 28;
    }

    pub fn lookupMul(self: Self, bucket: u32) u32 {
        std.debug.assert(bucket < bucket_count);
        return self.table[bucket];
    }

    pub fn hash(self: Self, input: u64) u32 {
        std.debug.assert(!self.isEmpty());
        const pair = self.feistel(input);
        return mulAndXorScalar(pair.left, pair.right, self.lookupMul(bucketIndex(pair.left)));
    }

    pub fn oneVec(self: Self, comptime D64: type, input: D64.Vector) D64.rebind(u32).Vector {
        requireTag(D64, u64);
        std.debug.assert(!self.isEmpty());
        const D32 = D64.rebind(u32);
        var left: D32.Vector = undefined;
        var right: D32.Vector = undefined;
        inline for (0..D64.lane_count) |lane| {
            left[lane] = @truncate(input[lane]);
            right[lane] = @truncate(input[lane] >> 32);
        }
        return self.resultFromFeistel(D32, self.feistelVector(D32, left, right));
    }

    pub fn twoVec(
        self: Self,
        comptime D32: type,
        first: D32.repartition(u64).Vector,
        second: D32.repartition(u64).Vector,
    ) D32.Vector {
        requireTag(D32, u32);
        if (D32.lane_count < 2) @compileError("ShardMul twoVec requires at least two u32 lanes");
        std.debug.assert(!self.isEmpty());
        const D64 = D32.repartition(u64);
        var left: D32.Vector = undefined;
        var right: D32.Vector = undefined;
        inline for (0..D64.lane_count) |lane| {
            left[lane] = @truncate(first[lane]);
            right[lane] = @truncate(first[lane] >> 32);
            left[D64.lane_count + lane] = @truncate(second[lane]);
            right[D64.lane_count + lane] = @truncate(second[lane] >> 32);
        }
        return self.resultFromFeistel(D32, self.feistelVector(D32, left, right));
    }

    pub fn mulAndXor(
        comptime D32: type,
        left: D32.Vector,
        right: D32.Vector,
        muls: D32.Vector,
    ) D32.Vector {
        requireTag(D32, u32);
        const D16 = D32.repartition(u16);
        const products = multiply.mulHigh(
            D16,
            @as(D16.Vector, @bitCast(right)),
            @as(D16.Vector, @bitCast(muls)),
        );
        const mixed: D32.Vector = @bitCast(products);
        return left ^ (mixed & @as(D32.Vector, @splat(0x0fff_ffff)));
    }

    fn feistelVector(
        self: Self,
        comptime D32: type,
        initial_left: D32.Vector,
        initial_right: D32.Vector,
    ) VectorPair(D32) {
        var left = initial_left;
        var right = initial_right;
        left ^= self.rounds[0].oneVec(D32, right);
        right ^= self.rounds[1].oneVec(D32, left);
        left ^= self.rounds[2].oneVec(D32, right);
        right ^= self.rounds[3].oneVec(D32, left);
        return .{ .left = left, .right = right };
    }

    fn resultFromFeistel(self: Self, comptime D32: type, pair: VectorPair(D32)) D32.Vector {
        const buckets = shift.shiftRight(D32, 28, pair.left);
        const muls = table.lookup16(D32, &self.table, buckets);
        return mulAndXor(D32, pair.left, pair.right, muls);
    }
};

pub const ShardMulBuildError = error{
    CapacityExceeded,
    PlanMismatch,
    ScratchTooSmall,
};

pub const ShardMulPlan = struct {
    best_seed: u64,
    key_counts: [bucket_count]usize,
    extra_counts: [bucket_count]usize,
    offsets: [bucket_count + 1]usize,
    slot_count: usize,
    scratch_len: usize,

    const Self = @This();

    pub fn inspect(keys: []const u64, extra_outputs: []const u32) ShardMulBuildError!Self {
        const total = std.math.add(usize, keys.len, extra_outputs.len) catch
            return error.CapacityExceeded;
        if (total > std.math.maxInt(u32)) return error.CapacityExceeded;
        const engine = random.AesCtrEngine.initDeterministic();
        var extra_counts: [bucket_count]usize = @splat(0);
        for (extra_outputs) |value| extra_counts[value >> 28] += 1;

        var best_seed: u64 = feistel_candidate_count;
        var best_ratio: f32 = std.math.inf(f32);
        for (0..feistel_candidate_count) |candidate| {
            const candidate_seed: u64 = @intCast(candidate);
            const shard = ShardMul.init(.{ .keys = makeFeistelKeys(&engine, candidate_seed) });
            var counts = extra_counts;
            for (keys) |key| counts[ShardMul.bucketIndex(shard.feistel(key).left)] += 1;
            var minimum = counts[0];
            var maximum = counts[0];
            for (counts[1..]) |count| {
                minimum = @min(minimum, count);
                maximum = @max(maximum, count);
            }
            if (minimum == 0) continue;
            const ratio = @as(f32, @floatFromInt(maximum)) /
                @as(f32, @floatFromInt(minimum));
            if (ratio < best_ratio) {
                best_ratio = ratio;
                best_seed = candidate_seed;
            }
        }

        const shard = ShardMul.init(.{ .keys = makeFeistelKeys(&engine, best_seed) });
        var key_counts: [bucket_count]usize = @splat(0);
        for (keys) |key| key_counts[ShardMul.bucketIndex(shard.feistel(key).left)] += 1;
        var offsets: [bucket_count + 1]usize = @splat(0);
        var maximum_bucket_size: usize = 0;
        for (0..bucket_count) |bucket| {
            const bucket_size = std.math.add(
                usize,
                key_counts[bucket],
                extra_counts[bucket],
            ) catch return error.CapacityExceeded;
            if (bucket_size > @as(usize, 1) << 28) return error.CapacityExceeded;
            maximum_bucket_size = @max(maximum_bucket_size, bucket_size);
            offsets[bucket + 1] = std.math.add(usize, offsets[bucket], bucket_size) catch
                return error.CapacityExceeded;
        }
        std.debug.assert(offsets[bucket_count] == total);
        const slot_count = try slotsFor(maximum_bucket_size);
        const slot_u64 = std.math.divCeil(usize, slot_count, 2) catch unreachable;
        const scratch_len = std.math.add(usize, total, slot_u64) catch
            return error.CapacityExceeded;
        return .{
            .best_seed = best_seed,
            .key_counts = key_counts,
            .extra_counts = extra_counts,
            .offsets = offsets,
            .slot_count = slot_count,
            .scratch_len = scratch_len,
        };
    }

    pub fn build(
        self: Self,
        scratch: []u64,
        keys: []const u64,
        extra_outputs: []const u32,
    ) ShardMulBuildError!ShardMulData {
        if (scratch.len < self.scratch_len) return error.ScratchTooSmall;
        const total = std.math.add(usize, keys.len, extra_outputs.len) catch
            return error.CapacityExceeded;
        if (total != self.offsets[bucket_count]) return error.PlanMismatch;
        const engine = random.AesCtrEngine.initDeterministic();
        const feistel_keys = makeFeistelKeys(&engine, self.best_seed);
        const shard = ShardMul.init(.{ .keys = feistel_keys });
        const records = scratch[0..total];
        const slot_bytes = std.mem.sliceAsBytes(scratch[total..self.scratch_len]);
        const all_slots = std.mem.bytesAsSlice(u32, slot_bytes)[0..self.slot_count];
        var key_cursor = self.offsets[0..bucket_count].*;
        var extra_cursor: [bucket_count]usize = undefined;
        for (0..bucket_count) |bucket| {
            extra_cursor[bucket] = self.offsets[bucket] + self.key_counts[bucket];
        }
        for (keys) |key| {
            const pair = shard.feistel(key);
            const bucket = ShardMul.bucketIndex(pair.left);
            if (key_cursor[bucket] >= self.offsets[bucket] + self.key_counts[bucket]) {
                return error.PlanMismatch;
            }
            records[key_cursor[bucket]] = encodePair(pair);
            key_cursor[bucket] += 1;
        }
        for (extra_outputs) |value| {
            const bucket = value >> 28;
            if (extra_cursor[bucket] >= self.offsets[bucket + 1]) return error.PlanMismatch;
            records[extra_cursor[bucket]] = value;
            extra_cursor[bucket] += 1;
        }
        for (0..bucket_count) |bucket| {
            if (key_cursor[bucket] != self.offsets[bucket] + self.key_counts[bucket] or
                extra_cursor[bucket] != self.offsets[bucket + 1])
            {
                return error.PlanMismatch;
            }
        }

        var data = ShardMulData{ .keys = feistel_keys };
        for (0..bucket_count) |bucket| {
            const bucket_size = self.key_counts[bucket] + self.extra_counts[bucket];
            const slots = all_slots[0..try slotsFor(bucket_size)];
            const first = self.offsets[bucket];
            const key_records = records[first .. first + self.key_counts[bucket]];
            const extras = records[first + self.key_counts[bucket] .. self.offsets[bucket + 1]];
            for (0..max_attempts_per_bucket) |attempt| {
                @memset(slots, 0);
                var stream = random.RngStream.init(
                    &engine,
                    multiplierSeed(self.best_seed, bucket, attempt),
                );
                const muls = makeMultiplierPair(&stream);
                var collision = false;
                for (key_records) |encoded| {
                    const pair = decodePair(encoded);
                    const output = mulAndXorScalar(pair.left, pair.right, muls);
                    if (!insertUnique(slots, output)) {
                        collision = true;
                        break;
                    }
                }
                if (!collision) {
                    for (extras) |encoded| {
                        if (!insertUnique(slots, @truncate(encoded))) {
                            collision = true;
                            break;
                        }
                    }
                }
                if (!collision) {
                    data.table[bucket] = muls;
                    data.attempts[bucket] = @intCast(attempt + 1);
                    break;
                }
            }
            if (data.table[bucket] == 0) return .{};
        }
        return data;
    }
};

pub fn shardMulScratchLen(
    keys: []const u64,
    extra_outputs: []const u32,
) ShardMulBuildError!usize {
    return (try ShardMulPlan.inspect(keys, extra_outputs)).scratch_len;
}

pub fn buildShardMul(
    scratch: []u64,
    keys: []const u64,
    extra_outputs: []const u32,
) ShardMulBuildError!ShardMulData {
    const plan = try ShardMulPlan.inspect(keys, extra_outputs);
    return plan.build(scratch, keys, extra_outputs);
}

pub fn makeShardMul(
    scratch: []u64,
    keys: []const u64,
    extra_outputs: []const u32,
) ShardMulBuildError!ShardMul {
    return ShardMul.init(try buildShardMul(scratch, keys, extra_outputs));
}

fn VectorPair(comptime D: type) type {
    return struct {
        left: D.Vector,
        right: D.Vector,
    };
}

fn mulAndXorScalar(left: u32, right: u32, muls: u32) u32 {
    const mul0 = muls & 0xffff;
    const mul1 = muls >> 16;
    const x0 = right & 0xffff;
    const x1 = right >> 16;
    const r0 = (x0 * mul0) >> 16;
    const r1 = (x1 * mul1) >> 16;
    return left ^ (((r1 & 0x0fff) << 16) | r0);
}

fn makeFeistelKeys(engine: *const random.AesCtrEngine, seed: u64) [4]u32 {
    var keys: [4]u32 = undefined;
    for (&keys, 0..) |*key, index| {
        key.* = @truncate(engine.generate(4 * seed + index, 0));
    }
    return keys;
}

fn makeMultiplierPair(stream: *random.RngStream) u32 {
    const initial: u32 = @truncate(stream.next());
    const mul0 = (initial & 0xffff) | 0x8001;
    var mul1 = (initial >> 16) | 0x8001;
    while (mul1 == mul0) mul1 = @as(u32, @truncate(stream.next())) & 0xffff | 0x8001;
    std.debug.assert(mul0 != mul1);
    return (mul1 << 16) | mul0;
}

fn multiplierSeed(best_seed: u64, bucket: usize, attempt: usize) u64 {
    return best_seed * bucket_count * max_attempts_per_bucket +
        bucket * max_attempts_per_bucket + attempt + 0x9e37_79b9;
}

fn slotsFor(count: usize) ShardMulBuildError!usize {
    if (count == 0) return 1;
    const doubled = std.math.mul(usize, count, 2) catch return error.CapacityExceeded;
    return std.math.ceilPowerOfTwo(usize, doubled) catch error.CapacityExceeded;
}

fn insertUnique(slots: []u32, value: u32) bool {
    std.debug.assert(std.math.isPowerOfTwo(slots.len));
    const payload = value & 0x0fff_ffff;
    const marker = payload + 1;
    var index: usize = @intCast((payload *% 0x9e37_79b1) & @as(u32, @intCast(slots.len - 1)));
    for (0..slots.len) |_| {
        if (slots[index] == 0) {
            slots[index] = marker;
            return true;
        }
        if (slots[index] == marker) return false;
        index = (index + 1) & (slots.len - 1);
    }
    unreachable;
}

fn encodePair(pair: ShardMul.FeistelPair) u64 {
    return @as(u64, pair.right) << 32 | pair.left;
}

fn decodePair(encoded: u64) ShardMul.FeistelPair {
    return .{ .left = @truncate(encoded), .right = @truncate(encoded >> 32) };
}

fn requireTag(comptime D: type, comptime T: type) void {
    if (comptime D.Lane != T) @compileError("ShardMul tag lane type mismatch");
}

fn fillClusteredKeys(output: []u64, candidates: []u64) !void {
    std.debug.assert(candidates.len >= output.len * 3 / 2);
    const patterns = [4]u64{
        0x4865_6c6c_6f20_576f,
        0x7468_655f_6b65_795f,
        0xc3a9_c3a0_c3bc_e282,
        0x6162_6364_6566_6747,
    };
    const engine = random.AesCtrEngine.initDeterministic();
    var stream = random.RngStream.init(&engine, 0);
    for (candidates, 0..) |*candidate, index| {
        var bytes: [8]u8 = @bitCast(patterns[index % patterns.len]);
        const mutation_count: usize = @intCast(1 + stream.next() % 5);
        for (0..mutation_count) |_| {
            const position: usize = @intCast(stream.next() % bytes.len);
            bytes[position] = @intCast(0x20 + stream.next() % 213);
        }
        var key: u64 = @bitCast(bytes);
        if (stream.next() % 4 == 0) key >>= 8;
        candidate.* = key;
    }
    std.mem.sort(u64, candidates, {}, std.sort.asc(u64));
    const distinct = uniquePrefixLen(u64, candidates);
    try std.testing.expect(distinct >= output.len);
    @memcpy(output, candidates[0..output.len]);
}

fn uniquePrefixLen(comptime T: type, values: []T) usize {
    if (values.len == 0) return 0;
    var count: usize = 1;
    for (values[1..]) |value| {
        if (value != values[count - 1]) {
            values[count] = value;
            count += 1;
        }
    }
    return count;
}
