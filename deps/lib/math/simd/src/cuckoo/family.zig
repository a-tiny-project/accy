const std = @import("std");
const builder = @import("builder.zig");
const local = @import("local.zig");
const optimizer = @import("optimizer.zig");
const simd = @import("../root.zig");
const hash_mod = simd.hash;
const random = simd.random;
const tag = simd.tag;

pub const CuckooConfigError = error{
    CapacityExceeded,
    InvalidEpsilon,
};

pub const CuckooTableError = error{
    FingerprintSlotsTooSmall,
    FingerprintsRequireMinimumBuckets,
    FingerprintsRequireU32,
    FingerprintSlotsUnavailable,
    FullSlotsUnavailable,
    SlotsTooSmall,
};

pub const CuckooBuildAlgo = enum {
    hopcroft_karp,
    min_cost,
    local_search,
};

pub fn CuckooFamily(
    comptime HashType: type,
    comptime bucket_size_value: usize,
    comptime minimum_bucket_count_value: usize,
) type {
    if (bucket_size_value == 0 or !std.math.isPowerOfTwo(bucket_size_value)) {
        @compileError("Cuckoo bucket size must be a nonzero power of two");
    }
    if (minimum_bucket_count_value == 0 or
        !std.math.isPowerOfTwo(minimum_bucket_count_value))
    {
        @compileError("Cuckoo minimum bucket count must be a nonzero power of two");
    }
    const KeyType = HashType.Lane;
    const key_info = @typeInfo(KeyType);
    if (key_info != .int or key_info.int.signedness != .unsigned) {
        @compileError("Cuckoo hash lanes must be unsigned integers");
    }
    if (bucket_size_value > std.math.maxInt(KeyType) or
        bucket_size_value > std.math.maxInt(usize) / 2)
    {
        @compileError("Cuckoo bucket size exceeds the supported index range");
    }
    return struct {
        const Family = @This();

        pub const Hash = HashType;
        pub const Key = KeyType;
        pub const bucket_size = bucket_size_value;
        pub const log_bucket_size = std.math.log2_int(usize, bucket_size);
        pub const minimum_bucket_count = minimum_bucket_count_value;
        pub const empty_key = std.math.maxInt(Key);
        pub const empty_fingerprint: u16 = 0;
        pub const primary_tag: u16 = 0x4000;
        pub const secondary_tag: u16 = 0x8000;
        pub const minimum_fingerprint_bucket_count: usize = 262_144;
        pub const BuildPlan = builder.Plan(Family);
        pub const Builder = builder.Builder(Family);
        pub const OptimizedBuildPlan = optimizer.Plan(Family);
        pub const Optimizer = optimizer.Optimizer(Family);
        pub const LocalBuildPlan = local.Plan(Family);
        pub const LocalSearch = local.Search(Family);
        pub const BuildStats = builder.CuckooBuildStats;

        pub const Config = struct {
            num_keys: usize = 0,
            num_slots: usize = 0,
            num_buckets: usize = 0,
            bucket_bits: usize = 0,
            epsilon: f64 = 0,
            bucket_mask: Key = 0,

            const Self = @This();

            pub fn init(num_keys: usize, epsilon: f64) CuckooConfigError!Self {
                if (!std.math.isFinite(epsilon) or epsilon < 0) return error.InvalidEpsilon;
                if (num_keys > std.math.maxInt(u32)) return error.CapacityExceeded;
                const scaled = @as(f64, @floatFromInt(num_keys)) * (1 + epsilon);
                const maximum_exclusive: f64 = @floatFromInt(std.math.maxInt(usize));
                if (!std.math.isFinite(scaled) or scaled >= maximum_exclusive) {
                    return error.CapacityExceeded;
                }
                const raw_slots = @as(usize, @intFromFloat(scaled)) + 1;
                const required_buckets = std.math.divCeil(
                    usize,
                    raw_slots,
                    bucket_size,
                ) catch unreachable;
                const at_least = @max(minimum_bucket_count, required_buckets);
                const num_buckets = std.math.ceilPowerOfTwo(usize, at_least) catch
                    return error.CapacityExceeded;
                if (num_buckets - 1 > std.math.maxInt(Key)) return error.CapacityExceeded;
                const num_slots = std.math.mul(usize, num_buckets, bucket_size) catch
                    return error.CapacityExceeded;
                if (num_slots > std.math.maxInt(u32)) return error.CapacityExceeded;
                return .{
                    .num_keys = num_keys,
                    .num_slots = num_slots,
                    .num_buckets = num_buckets,
                    .bucket_bits = std.math.log2_int(usize, num_buckets),
                    .epsilon = epsilon,
                    .bucket_mask = @intCast(num_buckets - 1),
                };
            }
        };

        pub const LookupOne = struct {
            primary_hash: Key,
            secondary_hash: Key,
            primary_slot: usize,
            secondary_slot: usize,
        };

        pub fn LookupVectors(comptime D: type) type {
            requireTag(D);
            return struct {
                primary_slots: D.Vector,
                secondary_slots: D.Vector,
                primary_hashes: D.Vector,
            };
        }

        pub const Table = struct {
            config: Config,
            hash_primary: Hash,
            hash_secondary: Hash,
            full_slots: []Key,
            fingerprint_slots: []u16,
            num_primary: u32,

            const Self = @This();

            pub fn init(
                config: Config,
                hash_primary: Hash,
                hash_secondary: Hash,
                full_storage: []Key,
                num_primary: u32,
            ) CuckooTableError!Self {
                if (full_storage.len < config.num_slots) return error.SlotsTooSmall;
                std.debug.assert(num_primary <= config.num_keys);
                return .{
                    .config = config,
                    .hash_primary = hash_primary,
                    .hash_secondary = hash_secondary,
                    .full_slots = full_storage[0..config.num_slots],
                    .fingerprint_slots = emptySlice(u16),
                    .num_primary = num_primary,
                };
            }

            pub fn isEmpty(self: Self) bool {
                return self.config.num_keys == 0;
            }

            pub fn allocatedBytes(self: Self) usize {
                return self.full_slots.len * @sizeOf(Key) +
                    self.fingerprint_slots.len * @sizeOf(u16);
            }

            pub fn slots(self: Self) []const Key {
                return self.full_slots;
            }

            pub fn mutableSlots(self: *Self) []Key {
                return self.full_slots;
            }

            pub fn fingerprints(self: Self) []const u16 {
                return self.fingerprint_slots;
            }

            pub fn hasU16Slots(self: Self) bool {
                return self.fingerprint_slots.len != 0;
            }

            pub fn primaryBucketOffset(self: Self, key: Key) usize {
                return self.bucketOffset(self.hash_primary.hash(key));
            }

            pub fn secondaryBucketOffset(self: Self, key: Key) usize {
                return self.bucketOffset(self.hash_secondary.hash(key));
            }

            pub fn queryOne(self: Self, key: Key) bool {
                if (self.queryBucket(key, self.primaryBucketOffset(key))) return true;
                return self.queryBucket(key, self.secondaryBucketOffset(key));
            }

            pub fn queryBucket(self: Self, key: Key, offset: usize) bool {
                std.debug.assert(self.full_slots.len == self.config.num_slots);
                std.debug.assert(offset + bucket_size <= self.full_slots.len);
                const D = tag.CappedTag(Key, bucket_size);
                const needle: D.Vector = @splat(key);
                var index: usize = 0;
                while (index < bucket_size) : (index += D.lane_count) {
                    const values: D.Vector = self.full_slots[offset + index ..][0..D.lane_count].*;
                    if (@reduce(.Or, values == needle)) return true;
                }
                return false;
            }

            pub fn lookupOneSlot(self: Self, key: Key) LookupOne {
                const primary_hash = self.hash_primary.hash(key);
                const secondary_hash = self.hash_secondary.hash(key);
                return .{
                    .primary_hash = primary_hash,
                    .secondary_hash = secondary_hash,
                    .primary_slot = self.bucketOffset(primary_hash),
                    .secondary_slot = self.bucketOffset(secondary_hash),
                };
            }

            pub fn lookupSlotsAndHash(
                self: Self,
                comptime D: type,
                keys: D.Vector,
            ) LookupVectors(D) {
                requireTag(D);
                const mask: D.Vector = @splat(self.config.bucket_mask);
                const scale: D.Vector = @splat(@as(Key, @intCast(bucket_size)));
                const primary_hashes = self.hash_primary.oneVec(D, keys);
                const secondary_hashes = self.hash_secondary.oneVec(D, keys);
                return .{
                    .primary_slots = (primary_hashes & mask) *% scale,
                    .secondary_slots = (secondary_hashes & mask) *% scale,
                    .primary_hashes = primary_hashes,
                };
            }

            pub fn queryBatch(
                self: Self,
                comptime precompute_secondary: bool,
                comptime D: type,
                keys: D.Vector,
            ) D.Mask {
                if (comptime Key != u32) @compileError("Cuckoo batch queries require u32 keys");
                requireTag(D);
                const mask: D.Vector = @splat(self.config.bucket_mask);
                const scale: D.Vector = @splat(@as(u32, @intCast(bucket_size)));
                const primary_hashes = self.hash_primary.oneVec(D, keys);
                const primary_offsets = (primary_hashes & mask) *% scale;
                const secondary_offsets = if (precompute_secondary)
                    (self.hash_secondary.oneVec(D, keys) & mask) *% scale
                else
                    @as(D.Vector, @splat(0));
                var found: D.Mask = @splat(false);
                inline for (0..D.lane_count) |lane| {
                    found[lane] = self.queryBucket(keys[lane], primary_offsets[lane]);
                }
                inline for (0..D.lane_count) |lane| {
                    if (!found[lane]) {
                        const offset = if (precompute_secondary)
                            secondary_offsets[lane]
                        else
                            self.secondaryBucketOffset(keys[lane]);
                        found[lane] = self.queryBucket(keys[lane], offset);
                    }
                }
                return !found;
            }

            pub fn buildU16Slots(
                self: Self,
                output: []u16,
            ) CuckooTableError!Self {
                if (comptime Key != u32) return error.FingerprintsRequireU32;
                if (self.config.num_buckets < minimum_fingerprint_bucket_count) {
                    return error.FingerprintsRequireMinimumBuckets;
                }
                if (self.full_slots.len != self.config.num_slots) {
                    return error.FullSlotsUnavailable;
                }
                if (output.len < self.config.num_slots) {
                    return error.FingerprintSlotsTooSmall;
                }
                const fingerprint_storage = output[0..self.config.num_slots];
                @memset(fingerprint_storage, empty_fingerprint);
                for (self.full_slots, 0..) |key, slot| {
                    if (key == empty_key) continue;
                    const bucket = slot / bucket_size;
                    const primary_hash = self.hash_primary.hash(key);
                    if ((primary_hash & self.config.bucket_mask) == bucket) {
                        fingerprint_storage[slot] = fingerprintU16(primary_hash, primary_tag);
                    } else {
                        const secondary_hash = self.hash_secondary.hash(key);
                        std.debug.assert(
                            (secondary_hash & self.config.bucket_mask) == bucket,
                        );
                        fingerprint_storage[slot] = fingerprintU16(
                            secondary_hash,
                            secondary_tag,
                        );
                    }
                }
                return .{
                    .config = self.config,
                    .hash_primary = self.hash_primary,
                    .hash_secondary = self.hash_secondary,
                    .full_slots = emptySlice(Key),
                    .fingerprint_slots = fingerprint_storage,
                    .num_primary = self.num_primary,
                };
            }

            pub fn queryBucketU16(self: Self, fingerprint: u16, offset: usize) bool {
                if (self.fingerprint_slots.len != self.config.num_slots) return false;
                std.debug.assert(offset + bucket_size <= self.fingerprint_slots.len);
                const D = tag.CappedTag(u16, bucket_size);
                const needle: D.Vector = @splat(fingerprint);
                var index: usize = 0;
                while (index < bucket_size) : (index += D.lane_count) {
                    const remaining = self.fingerprint_slots[offset + index ..];
                    const values: D.Vector = remaining[0..D.lane_count].*;
                    if (@reduce(.Or, values == needle)) return true;
                }
                return false;
            }

            pub fn queryOneU16(self: Self, key: u32) CuckooTableError!bool {
                if (comptime Key != u32) return error.FingerprintsRequireU32;
                if (!self.hasU16Slots()) return error.FingerprintSlotsUnavailable;
                const primary_hash = self.hash_primary.hash(key);
                const primary = fingerprintU16(primary_hash, primary_tag);
                const primary_offset = self.bucketOffset(primary_hash);
                if (self.queryBucketU16(primary, primary_offset)) return true;
                const secondary_hash = self.hash_secondary.hash(key);
                const secondary = fingerprintU16(secondary_hash, secondary_tag);
                const secondary_offset = self.bucketOffset(secondary_hash);
                return self.queryBucketU16(secondary, secondary_offset);
            }

            pub fn queryBatchU16(
                self: Self,
                comptime precompute_secondary: bool,
                comptime D: type,
                keys: D.Vector,
            ) CuckooTableError!D.Mask {
                if (comptime Key != u32) return error.FingerprintsRequireU32;
                if (!self.hasU16Slots()) return error.FingerprintSlotsUnavailable;
                requireTag(D);
                const mask: D.Vector = @splat(self.config.bucket_mask);
                const scale: D.Vector = @splat(@as(u32, @intCast(bucket_size)));
                const primary_hashes = self.hash_primary.oneVec(D, keys);
                const primary_offsets = (primary_hashes & mask) *% scale;
                const secondary_hashes = if (precompute_secondary)
                    self.hash_secondary.oneVec(D, keys)
                else
                    @as(D.Vector, @splat(0));
                const secondary_offsets = (secondary_hashes & mask) *% scale;
                var found: D.Mask = @splat(false);
                inline for (0..D.lane_count) |lane| {
                    const fingerprint = fingerprintU16(primary_hashes[lane], primary_tag);
                    found[lane] = self.queryBucketU16(
                        fingerprint,
                        primary_offsets[lane],
                    );
                }
                inline for (0..D.lane_count) |lane| {
                    if (!found[lane]) {
                        const secondary_hash = if (precompute_secondary)
                            secondary_hashes[lane]
                        else
                            self.hash_secondary.hash(keys[lane]);
                        const offset = if (precompute_secondary)
                            secondary_offsets[lane]
                        else
                            self.bucketOffset(secondary_hash);
                        found[lane] = self.queryBucketU16(
                            fingerprintU16(secondary_hash, secondary_tag),
                            offset,
                        );
                    }
                }
                return !found;
            }

            fn bucketOffset(self: Self, hash: Key) usize {
                const bucket: usize = @intCast(hash & self.config.bucket_mask);
                return bucket * bucket_size;
            }
        };

        pub fn fingerprintU16(hash: u32, tag_value: u16) u16 {
            return @truncate((hash >> 18) | tag_value);
        }

        fn requireTag(comptime D: type) void {
            if (comptime D.Lane != Key) @compileError("Cuckoo tag lane type mismatch");
        }
    };
}

pub const DefaultCuckoo = CuckooFamily(hash_mod.WeakTwoMul, 16, 1);
pub const CuckooConfig = DefaultCuckoo.Config;
pub const CuckooTable = DefaultCuckoo.Table;
pub const CuckooBuildPlan = DefaultCuckoo.BuildPlan;
pub const CuckooBuilder = DefaultCuckoo.Builder;
pub const CuckooOptimizedBuildPlan = DefaultCuckoo.OptimizedBuildPlan;
pub const CuckooOptimizer = DefaultCuckoo.Optimizer;
pub const CuckooLocalBuildPlan = DefaultCuckoo.LocalBuildPlan;
pub const CuckooLocalSearch = DefaultCuckoo.LocalSearch;

pub fn cuckooScratchLen(
    num_keys: usize,
    epsilon: f64,
    algorithm: CuckooBuildAlgo,
) builder.CuckooBuildError!usize {
    return switch (algorithm) {
        .hopcroft_karp => (try CuckooBuildPlan.inspect(num_keys, epsilon)).scratch_len,
        .min_cost => (try CuckooOptimizedBuildPlan.inspect(num_keys, epsilon)).scratch_len,
        .local_search => (try CuckooLocalBuildPlan.inspect(num_keys, epsilon)).scratch_len,
    };
}

pub fn cuckooSlotsLen(num_keys: usize, epsilon: f64) builder.CuckooBuildError!usize {
    return (try CuckooBuildPlan.inspect(num_keys, epsilon)).slots_len;
}

pub fn cuckooOptimizedScratchLen(
    num_keys: usize,
    epsilon: f64,
) builder.CuckooBuildError!usize {
    return (try CuckooOptimizedBuildPlan.inspect(num_keys, epsilon)).scratch_len;
}

pub fn cuckooLocalScratchLen(
    num_keys: usize,
    epsilon: f64,
) builder.CuckooBuildError!usize {
    return (try CuckooLocalBuildPlan.inspect(num_keys, epsilon)).scratch_len;
}

pub fn buildCuckoo(
    scratch: []u32,
    slots: []u32,
    keys: []const u32,
    epsilon: f64,
    max_attempts: u32,
    algorithm: CuckooBuildAlgo,
    stats: ?*builder.CuckooBuildStats,
) builder.CuckooBuildError!CuckooTable {
    return switch (algorithm) {
        .hopcroft_karp => blk: {
            const plan = try CuckooBuildPlan.inspect(keys.len, epsilon);
            break :blk plan.build(scratch, slots, keys, max_attempts, stats);
        },
        .min_cost => blk: {
            const plan = try CuckooOptimizedBuildPlan.inspect(keys.len, epsilon);
            break :blk plan.build(scratch, slots, keys, max_attempts, stats);
        },
        .local_search => blk: {
            const plan = try CuckooLocalBuildPlan.inspect(keys.len, epsilon);
            break :blk plan.build(scratch, slots, keys, max_attempts, stats);
        },
    };
}

fn emptySlice(comptime T: type) []T {
    return @constCast((&[_]T{})[0..]);
}

fn fixtureTable(
    comptime Family: type,
    keys: []const Family.Key,
    epsilon: f64,
    slots: []Family.Key,
) !Family.Table {
    const config = try Family.Config.init(keys.len, epsilon);
    if (slots.len < config.num_slots) return error.FixtureSlotsTooSmall;
    const used = slots[0..config.num_slots];
    @memset(used, Family.empty_key);
    const engine = random.AesCtrEngine.initDeterministic();
    const primary = Family.Hash.initSeed(&engine, 0);
    const secondary = Family.Hash.initSeed(&engine, 1);
    var num_primary: u32 = 0;
    for (keys) |key| {
        const primary_bucket: usize = @intCast(primary.hash(key) & config.bucket_mask);
        const primary_offset = primary_bucket * Family.bucket_size;
        if (firstEmpty(Family, used, primary_offset)) |slot| {
            used[slot] = key;
            num_primary += 1;
            continue;
        }
        const secondary_bucket: usize = @intCast(secondary.hash(key) & config.bucket_mask);
        const secondary_offset = secondary_bucket * Family.bucket_size;
        if (firstEmpty(Family, used, secondary_offset)) |slot| {
            used[slot] = key;
            continue;
        }
        return error.FixtureBuildFailed;
    }
    return Family.Table.init(config, primary, secondary, used, num_primary);
}

fn firstEmpty(comptime Family: type, slots: []const Family.Key, offset: usize) ?usize {
    for (slots[offset .. offset + Family.bucket_size], 0..) |slot, index| {
        if (slot == Family.empty_key) return offset + index;
    }
    return null;
}
