const std = @import("std");
const simd = @import("../root.zig");
const family = @import("family.zig");
const compact = simd.compact;
const construct = simd.construct;
const hash_mod = simd.hash;
const indexed = simd.indexed;
const random = simd.random;
const shift = simd.shift;
const tag = simd.tag;

pub const max_attempts: usize = 512;
pub const max_hashes_per_bucket: usize = 32;
pub const max_swaps: usize = 20;
pub const scan_window: usize = 50_000;
pub const seed_count: usize = 256;
pub const max_config_count: usize = 28;

const headroom_percents = [_]usize{ 1, 2, 3, 4, 10, 15, 20 };
const insertion_threshold: usize = 16;
const failed_seed: u32 = std.math.maxInt(u32);
const PositionTag = tag.FixedTag(u32, 8);
const SortFrame = struct {
    first: usize,
    last: usize,
    depth: usize,
};

pub const Plan = struct {
    num_keys: usize,
    payload_bytes: usize,
    configs: [max_config_count]family.Config,
    config_count: usize,
    max_num_slots: usize,
    max_num_buckets: usize,
    scratch_len: usize,
    seeds_len: usize,

    const Self = @This();

    pub fn inspect(num_keys: usize, payload_bytes: usize) family.PhastError!Self {
        if (num_keys == 0) {
            return .{
                .num_keys = 0,
                .payload_bytes = payload_bytes,
                .configs = @splat(.{}),
                .config_count = 0,
                .max_num_slots = 0,
                .max_num_buckets = 0,
                .scratch_len = 0,
                .seeds_len = 0,
            };
        }
        if (num_keys > std.math.maxInt(u32)) return error.CapacityExceeded;
        var configs: [max_config_count]family.Config = @splat(.{});
        const config_count = try enumerateConfigs(num_keys, configs[0..]);
        var max_num_slots: usize = 0;
        var max_num_buckets: usize = 0;
        for (configs[0..config_count]) |config| {
            _ = try config.allocatedBytes(payload_bytes);
            max_num_slots = @max(max_num_slots, config.num_slots);
            max_num_buckets = @max(max_num_buckets, config.numBuckets());
        }
        sortConfigs(configs[0..config_count], payload_bytes);
        return .{
            .num_keys = num_keys,
            .payload_bytes = payload_bytes,
            .configs = configs,
            .config_count = config_count,
            .max_num_slots = max_num_slots,
            .max_num_buckets = max_num_buckets,
            .scratch_len = try scratchLength(num_keys, max_num_slots, max_num_buckets),
            .seeds_len = family.seedWordLength(max_num_buckets),
        };
    }

    pub fn build(
        self: Self,
        scratch: []u32,
        seed_words: []u32,
        keys: []const u32,
    ) family.PhastError!family.Data {
        try self.validateBuffers(scratch, seed_words, keys);
        if (self.num_keys == 0) return .{};
        var builder = try Builder.init(self, scratch, seed_words);
        try builder.validateDistinct(keys);
        const engine = random.AesCtrEngine.initDeterministic();
        for (self.configs[0..self.config_count], 0..) |config, config_index| {
            for (0..max_attempts) |attempt_index| {
                const stream = @as(u64, config.hash_key) + attempt_index;
                const hash_key: u32 = @truncate(engine.generate(stream, 0));
                if (!builder.maybeBuild(keys, config, hash_key)) continue;
                return builder.take(config_index, attempt_index);
            }
        }
        @memset(seed_words[0..self.seeds_len], 0);
        return error.BuildFailed;
    }

    fn validateBuffers(
        self: Self,
        scratch: []u32,
        seed_words: []u32,
        keys: []const u32,
    ) family.PhastError!void {
        if (keys.len != self.num_keys) return error.PlanMismatch;
        if (scratch.len < self.scratch_len) return error.ScratchTooSmall;
        if (seed_words.len < self.seeds_len) return error.SeedsTooSmall;
        if (storageOverlaps(u32, scratch, u32, seed_words) or
            storageOverlaps(u32, scratch, u32, keys) or
            storageOverlaps(u32, seed_words, u32, keys))
        {
            return error.InputOutputOverlap;
        }
    }
};

const Builder = struct {
    plan: Plan,
    hashes: []u32,
    all_positions: []u32,
    key_indices: []u32,
    occupancy: []u32,
    committed_seeds: []u8,
    bucket_sizes: []u8,
    bucket_offsets: []u32,
    bucket_order: []u32,
    write_positions: []u32,
    seed_candidates: []u32,
    seed_words: []u32,
    config: family.Config = .{},
    hash: hash_mod.Triple32 = .{},
    bucket_size_histogram: [max_hashes_per_bucket + 1]u32 = @splat(0),
    succeeded: bool = false,

    const Self = @This();

    fn init(plan: Plan, scratch: []u32, seed_words: []u32) family.PhastError!Self {
        if (scratch.len < plan.scratch_len) return error.ScratchTooSmall;
        if (seed_words.len < plan.seeds_len) return error.SeedsTooSmall;
        var offset: usize = 0;
        const hashes = takeWords(scratch, &offset, plan.num_keys);
        const all_positions = takeWords(
            scratch,
            &offset,
            max_hashes_per_bucket * seed_count,
        );
        const key_indices = takeWords(scratch, &offset, plan.num_keys);
        const occupancy = takeWords(
            scratch,
            &offset,
            occupancyWordLength(plan.max_num_slots),
        );
        const committed_words = takeWords(
            scratch,
            &offset,
            byteWordLength(plan.max_num_buckets),
        );
        const bucket_size_words = takeWords(
            scratch,
            &offset,
            byteWordLength(plan.max_num_buckets),
        );
        const bucket_offsets = takeWords(
            scratch,
            &offset,
            plan.max_num_buckets + 1,
        );
        const bucket_order = takeWords(scratch, &offset, plan.max_num_buckets);
        const write_positions = takeWords(scratch, &offset, plan.max_num_buckets);
        const seed_candidates = takeWords(scratch, &offset, seed_count);
        std.debug.assert(offset == plan.scratch_len);
        return .{
            .plan = plan,
            .hashes = hashes,
            .all_positions = all_positions,
            .key_indices = key_indices,
            .occupancy = occupancy,
            .committed_seeds = std.mem.sliceAsBytes(committed_words)[0..plan.max_num_buckets],
            .bucket_sizes = std.mem.sliceAsBytes(bucket_size_words)[0..plan.max_num_buckets],
            .bucket_offsets = bucket_offsets,
            .bucket_order = bucket_order,
            .write_positions = write_positions,
            .seed_candidates = seed_candidates,
            .seed_words = seed_words[0..plan.seeds_len],
        };
    }

    fn validateDistinct(self: *Self, keys: []const u32) family.PhastError!void {
        const engine = random.AesCtrEngine.initDeterministic();
        const permutation = hash_mod.Triple32.initSeed(&engine, 0);
        for (keys, self.hashes) |key, *hash| hash.* = permutation.hash(key);
        std.mem.sort(u32, self.hashes, {}, std.sort.asc(u32));
        for (self.hashes[1..], self.hashes[0 .. self.hashes.len - 1]) |right, left| {
            if (left == right) return error.DuplicateKey;
        }
    }

    fn maybeBuild(
        self: *Self,
        keys: []const u32,
        base_config: family.Config,
        hash_key: u32,
    ) bool {
        std.debug.assert(keys.len == self.plan.num_keys);
        self.config = base_config;
        self.config.hash_key = hash_key;
        self.hash = hash_mod.Triple32.initKey(hash_key);
        self.succeeded = false;
        const num_buckets = self.config.numBuckets();
        const occupancy_words = occupancyWordLength(self.config.num_slots);
        @memset(self.occupancy[0..occupancy_words], 0);
        @memset(self.seed_words[0..self.config.seedWordsLen()], 0);
        @memset(self.committed_seeds[0..num_buckets], 0);
        @memset(self.bucket_sizes[0..num_buckets], 0);
        for (keys, self.hashes) |key, *hash| hash.* = self.hash.hash(key);
        if (!self.populateBuckets()) return false;
        const nonempty_count = num_buckets - self.bucket_size_histogram[0];
        for (0..nonempty_count) |rank| {
            const seed = self.tryPlaceBucket(@intCast(rank), failed_seed);
            if (seed != failed_seed) {
                self.committed_seeds[rank] = @truncate(seed);
                continue;
            }
            if (!self.tryCuckooSwap(@intCast(rank))) return false;
        }
        self.succeeded = true;
        return true;
    }

    fn take(self: Self, config_index: usize, attempt_index: usize) family.Data {
        std.debug.assert(self.succeeded);
        std.debug.assert(self.config.hash_key == self.hash.key());
        return .{
            .config = self.config,
            .seeds = .{ .words = self.seed_words[0..self.config.seedWordsLen()] },
            .config_index = config_index,
            .attempt_index = attempt_index,
        };
    }

    fn populateBuckets(self: *Self) bool {
        const num_buckets = self.config.numBuckets();
        for (self.hashes) |hash| {
            const bucket: usize = hash & self.config.bucket_mask;
            if (self.bucket_sizes[bucket] + 1 >= max_hashes_per_bucket) return false;
            self.bucket_sizes[bucket] += 1;
        }
        @memset(&self.bucket_size_histogram, 0);
        var maximum_size: usize = 0;
        for (self.bucket_sizes[0..num_buckets]) |size| {
            maximum_size = @max(maximum_size, size);
            self.bucket_size_histogram[size] += 1;
        }
        self.bucket_offsets[0] = 0;
        for (self.bucket_sizes[0..num_buckets], 0..) |size, bucket| {
            self.bucket_offsets[bucket + 1] = self.bucket_offsets[bucket] + size;
        }
        @memcpy(
            self.write_positions[0..num_buckets],
            self.bucket_offsets[0..num_buckets],
        );
        for (self.hashes, 0..) |hash, key_index| {
            const bucket: usize = hash & self.config.bucket_mask;
            self.key_indices[self.write_positions[bucket]] = @intCast(key_index);
            self.write_positions[bucket] += 1;
        }
        var order_begin: [max_hashes_per_bucket + 1]u32 = @splat(0);
        order_begin[maximum_size] = 0;
        var size = maximum_size;
        while (size > 0) {
            order_begin[size - 1] = order_begin[size] + self.bucket_size_histogram[size];
            size -= 1;
        }
        for (self.bucket_sizes[0..num_buckets], 0..) |bucket_size, bucket| {
            const position = order_begin[bucket_size];
            self.bucket_order[position] = @intCast(bucket);
            order_begin[bucket_size] += 1;
        }
        return true;
    }

    fn tryCuckooSwap(self: *Self, rank: u32) bool {
        const scan_start = if (rank > scan_window) rank - scan_window else 0;
        const failed_bucket_size = self.computeBucketPositions(rank);
        const positions_to_find = failed_bucket_size * seed_count;
        var overlap_ranks: [max_swaps]u32 = undefined;
        var original_seeds: [max_swaps]u8 = undefined;
        var overlap_count: usize = 0;
        var scan_position = rank;
        while (scan_position > scan_start and overlap_count < max_swaps) {
            const scan_rank = scan_position - 1;
            const bucket = self.bucket_order[scan_rank];
            const seed = self.committed_seeds[scan_rank];
            const begin = self.bucket_offsets[bucket];
            const size = self.bucket_sizes[bucket];
            var matches = false;
            for (begin..begin + size) |bucket_position| {
                const position = self.computeOnePosition(bucket_position, seed);
                if (contains(self.all_positions[0..positions_to_find], position)) {
                    matches = true;
                    break;
                }
            }
            if (matches) {
                overlap_ranks[overlap_count] = scan_rank;
                original_seeds[overlap_count] = seed;
                overlap_count += 1;
            }
            scan_position -= 1;
        }
        for (overlap_ranks[0..overlap_count], original_seeds[0..overlap_count]) |
            blocker_rank,
            blocker_seed,
        | {
            self.undoBucket(blocker_rank, blocker_seed);
            const failed_bucket_seed = self.tryPlaceBucket(rank, failed_seed);
            if (failed_bucket_seed != failed_seed) {
                self.committed_seeds[rank] = @truncate(failed_bucket_seed);
                const new_blocker_seed = self.tryPlaceBucket(blocker_rank, blocker_seed);
                if (new_blocker_seed != failed_seed) {
                    self.committed_seeds[blocker_rank] = @truncate(new_blocker_seed);
                    return true;
                }
                self.undoBucket(rank, failed_bucket_seed);
            }
            self.forcePlaceBucket(blocker_rank, blocker_seed);
            self.committed_seeds[blocker_rank] = blocker_seed;
        }
        return false;
    }

    fn computeOnePosition(self: Self, bucket_position: usize, seed: u32) u32 {
        const key_index = self.key_indices[bucket_position];
        return family.positionFromHashAndSeed(
            self.config.placement,
            self.hashes[key_index],
            seed,
        );
    }

    fn computeBucketPositions(self: *Self, rank: u32) usize {
        const bucket = self.bucket_order[rank];
        const begin = self.bucket_offsets[bucket];
        const size = self.bucket_sizes[bucket];
        for (0..size) |local_index| {
            const key_index = self.key_indices[begin + local_index];
            const hash = self.hashes[key_index];
            const hashes: PositionTag.Vector = @splat(hash);
            var seed: usize = 0;
            while (seed < seed_count) : (seed += 2 * PositionTag.lane_count) {
                const first_seeds = construct.iota(PositionTag, @intCast(seed));
                const second_seeds = construct.iota(
                    PositionTag,
                    @intCast(seed + PositionTag.lane_count),
                );
                const positions = family.positionPairFromHashesAndSeeds(
                    self.config.placement,
                    PositionTag,
                    hashes,
                    hashes,
                    first_seeds,
                    second_seeds,
                );
                const first: [PositionTag.lane_count]u32 = positions.first;
                const second: [PositionTag.lane_count]u32 = positions.second;
                const output = self.all_positions[local_index * seed_count + seed ..];
                @memcpy(output[0..PositionTag.lane_count], &first);
                @memcpy(
                    output[PositionTag.lane_count .. 2 * PositionTag.lane_count],
                    &second,
                );
            }
        }
        return size;
    }

    fn tryPlaceBucket(self: *Self, rank: u32, excluded_seed: u32) u32 {
        const bucket_size = self.computeBucketPositions(rank);
        const candidate_count = self.writeSeedCandidates(bucket_size);
        var best_seed: u32 = 0;
        var best_cost: u32 = std.math.maxInt(u32);
        for (self.seed_candidates[0..candidate_count]) |seed| {
            if (seed == excluded_seed) continue;
            if (bucket_size >= 2) {
                if (self.hasPairCollision(bucket_size, seed)) continue;
                var cost: u32 = 0;
                for (0..bucket_size) |local_index| {
                    const position = self.all_positions[local_index * seed_count + seed];
                    cost += @popCount(self.occupancy[position >> 5]);
                }
                if (cost >= best_cost) continue;
                best_cost = cost;
                best_seed = seed;
                if (bucket_size <= 2 and cost == 0) break;
            } else {
                best_cost = 0;
                best_seed = seed;
                break;
            }
        }
        if (best_cost == std.math.maxInt(u32)) return failed_seed;
        for (0..bucket_size) |local_index| {
            self.setOccupied(self.all_positions[local_index * seed_count + best_seed]);
        }
        self.setSeed(self.bucket_order[rank], best_seed);
        return best_seed;
    }

    fn writeSeedCandidates(self: *Self, bucket_size: usize) usize {
        var candidate_count: usize = 0;
        var seed: usize = 0;
        while (seed < seed_count) : (seed += 2 * PositionTag.lane_count) {
            const first_seeds = construct.iota(PositionTag, @intCast(seed));
            const second_seeds = construct.iota(
                PositionTag,
                @intCast(seed + PositionTag.lane_count),
            );
            var first_available: PositionTag.Mask = @splat(true);
            var second_available: PositionTag.Mask = @splat(true);
            for (0..bucket_size) |local_index| {
                const positions = self.all_positions[local_index * seed_count + seed ..];
                const first_positions: PositionTag.Vector =
                    positions[0..PositionTag.lane_count].*;
                const second_positions: PositionTag.Vector =
                    positions[PositionTag.lane_count .. 2 * PositionTag.lane_count].*;
                first_available &= self.unoccupied(first_positions);
                second_available &= self.unoccupied(second_positions);
            }
            candidate_count += compact.compressStore(
                PositionTag,
                first_seeds,
                first_available,
                self.seed_candidates[candidate_count..],
            );
            candidate_count += compact.compressStore(
                PositionTag,
                second_seeds,
                second_available,
                self.seed_candidates[candidate_count..],
            );
        }
        return candidate_count;
    }

    fn unoccupied(self: Self, positions: PositionTag.Vector) PositionTag.Mask {
        const word_indices = shift.shiftRight(PositionTag, 5, positions);
        const words = indexed.gatherIndex(PositionTag, self.occupancy, word_indices);
        const bit_indices = positions & @as(PositionTag.Vector, @splat(31));
        const bit_masks = shift.shl(PositionTag, @splat(1), bit_indices);
        return words & bit_masks == @as(PositionTag.Vector, @splat(0));
    }

    fn hasPairCollision(self: Self, bucket_size: usize, seed: u32) bool {
        for (0..bucket_size) |left| {
            const left_position = self.all_positions[left * seed_count + seed];
            for (left + 1..bucket_size) |right| {
                if (left_position == self.all_positions[right * seed_count + seed]) {
                    return true;
                }
            }
        }
        return false;
    }

    fn undoBucket(self: *Self, rank: u32, seed: u32) void {
        const bucket = self.bucket_order[rank];
        const begin = self.bucket_offsets[bucket];
        const size = self.bucket_sizes[bucket];
        std.debug.assert(size > 0);
        std.debug.assert(seed < seed_count);
        for (begin..begin + size) |position| {
            self.clearOccupied(self.computeOnePosition(position, seed));
        }
        self.clearSeed(bucket);
    }

    fn forcePlaceBucket(self: *Self, rank: u32, seed: u32) void {
        const bucket = self.bucket_order[rank];
        const begin = self.bucket_offsets[bucket];
        const size = self.bucket_sizes[bucket];
        std.debug.assert(size > 0);
        std.debug.assert(seed < seed_count);
        for (begin..begin + size) |position| {
            self.setOccupied(self.computeOnePosition(position, seed));
        }
        self.setSeed(bucket, seed);
    }

    fn isOccupied(self: Self, position: u32) bool {
        return self.occupancy[position >> 5] & (@as(u32, 1) << @intCast(position & 31)) != 0;
    }

    fn setOccupied(self: *Self, position: u32) void {
        std.debug.assert(!self.isOccupied(position));
        self.occupancy[position >> 5] |= @as(u32, 1) << @intCast(position & 31);
    }

    fn clearOccupied(self: *Self, position: u32) void {
        std.debug.assert(self.isOccupied(position));
        self.occupancy[position >> 5] &= ~(@as(u32, 1) << @intCast(position & 31));
    }

    fn setSeed(self: *Self, bucket: u32, seed: u32) void {
        const bit_index = (bucket & 3) * 8;
        self.seed_words[bucket >> 2] |= seed << @intCast(bit_index);
    }

    fn clearSeed(self: *Self, bucket: u32) void {
        const bit_index = (bucket & 3) * 8;
        self.seed_words[bucket >> 2] &= ~(@as(u32, 0xff) << @intCast(bit_index));
    }
};

pub fn scratchLength(
    num_keys: usize,
    max_num_slots: usize,
    max_num_buckets: usize,
) family.PhastError!usize {
    var words: usize = 0;
    try addWords(&words, num_keys);
    try addWords(&words, max_hashes_per_bucket * seed_count);
    try addWords(&words, num_keys);
    try addWords(&words, occupancyWordLength(max_num_slots));
    try addWords(&words, byteWordLength(max_num_buckets));
    try addWords(&words, byteWordLength(max_num_buckets));
    const offsets = std.math.add(usize, max_num_buckets, 1) catch
        return error.CapacityExceeded;
    try addWords(&words, offsets);
    try addWords(&words, max_num_buckets);
    try addWords(&words, max_num_buckets);
    try addWords(&words, seed_count);
    return words;
}

fn enumerateConfigs(
    num_keys: usize,
    output: []family.Config,
) family.PhastError!usize {
    const minimum_slice = minimumSliceLength(num_keys);
    if (minimum_slice > num_keys) return error.CapacityExceeded;
    const previous_power = roundDownPowerOfTwo(num_keys);
    const ratio = @as(f64, @floatFromInt(num_keys)) /
        @as(f64, @floatFromInt(previous_power));
    const keys_per_bucket = if (ratio < 1.3)
        [_]usize{ 3, 0 }
    else if (ratio > 1.7)
        [_]usize{ 2, 0 }
    else
        [_]usize{ 3, 2 };
    var count: usize = 0;
    var permutation_index: usize = 0;
    for (keys_per_bucket) |bucket_divisor| {
        if (bucket_divisor == 0) continue;
        for (headroom_percents) |headroom| {
            for (0..2) |slice_shift| {
                if (count >= output.len) return error.CapacityExceeded;
                const slice_length = minimum_slice << @intCast(slice_shift);
                const seed_base = std.math.mul(usize, permutation_index, max_attempts) catch
                    return error.CapacityExceeded;
                output[count] = try makeConfig(
                    num_keys,
                    headroom,
                    bucket_divisor,
                    slice_length,
                    @intCast(seed_base),
                );
                count += 1;
                permutation_index += 1;
            }
        }
    }
    return count;
}

fn makeConfig(
    num_keys: usize,
    headroom_percent: usize,
    keys_per_bucket: usize,
    slice_length: usize,
    seed: u32,
) family.PhastError!family.Config {
    const scaled = std.math.mul(usize, num_keys, 100 + headroom_percent) catch
        return error.CapacityExceeded;
    const rounded = std.math.add(usize, scaled / 100, 1) catch
        return error.CapacityExceeded;
    const num_slots = @max(rounded, slice_length);
    if (num_slots > std.math.maxInt(u32)) return error.CapacityExceeded;
    const raw_buckets = num_keys / keys_per_bucket;
    const num_buckets = roundUpPowerOfTwo(raw_buckets) catch
        return error.CapacityExceeded;
    if (num_buckets == 0 or num_buckets - 1 > std.math.maxInt(u32)) {
        return error.CapacityExceeded;
    }
    return .{
        .num_slots = num_slots,
        .hash_key = seed,
        .bucket_mask = @intCast(num_buckets - 1),
        .placement = try family.Placement.init(num_slots, slice_length),
    };
}

fn minimumSliceLength(num_keys: usize) usize {
    std.debug.assert(num_keys >= 1);
    if (num_keys < 64) return roundDownPowerOfTwo(num_keys / 2);
    if (num_keys < 1_300) return 64;
    if (num_keys < 9_500) return 128;
    if (num_keys < 12_000) return 256;
    if (num_keys < 140_000) return 512;
    return 2_048;
}

fn sortConfigs(configs: []family.Config, payload_bytes: usize) void {
    if (configs.len == 0) return;
    introsort(configs, 0, configs.len, 2 * std.math.log2_int(usize, configs.len), payload_bytes);
    finalInsertionSort(configs, payload_bytes);
}

fn introsort(
    configs: []family.Config,
    initial_first: usize,
    initial_last: usize,
    initial_depth: usize,
    payload_bytes: usize,
) void {
    var frames: [max_config_count]SortFrame = undefined;
    var frame_count: usize = 1;
    frames[0] = .{
        .first = initial_first,
        .last = initial_last,
        .depth = initial_depth,
    };
    while (frame_count != 0) {
        frame_count -= 1;
        var first = frames[frame_count].first;
        const last = frames[frame_count].last;
        var depth = frames[frame_count].depth;
        while (last - first > insertion_threshold) {
            if (depth == 0) {
                std.sort.heap(
                    family.Config,
                    configs[first..last],
                    payload_bytes,
                    lessConfig,
                );
                break;
            }
            depth -= 1;
            const cut = partitionPivot(configs, first, last, payload_bytes);
            std.debug.assert(frame_count < frames.len);
            frames[frame_count] = .{ .first = first, .last = cut, .depth = depth };
            frame_count += 1;
            first = cut;
        }
    }
}

fn partitionPivot(
    configs: []family.Config,
    first: usize,
    last: usize,
    payload_bytes: usize,
) usize {
    const middle = first + (last - first) / 2;
    moveMedianToFirst(configs, first, first + 1, middle, last - 1, payload_bytes);
    var left = first + 1;
    var right = last;
    while (true) {
        while (configLess(configs[left], configs[first], payload_bytes)) left += 1;
        right -= 1;
        while (configLess(configs[first], configs[right], payload_bytes)) right -= 1;
        if (left >= right) return left;
        std.mem.swap(family.Config, &configs[left], &configs[right]);
        left += 1;
    }
}

fn moveMedianToFirst(
    configs: []family.Config,
    result: usize,
    left: usize,
    middle: usize,
    right: usize,
    payload_bytes: usize,
) void {
    const swap_index = if (configLess(configs[left], configs[middle], payload_bytes))
        if (configLess(configs[middle], configs[right], payload_bytes))
            middle
        else if (configLess(configs[left], configs[right], payload_bytes))
            right
        else
            left
    else if (configLess(configs[left], configs[right], payload_bytes))
        left
    else if (configLess(configs[middle], configs[right], payload_bytes))
        right
    else
        middle;
    std.mem.swap(family.Config, &configs[result], &configs[swap_index]);
}

fn finalInsertionSort(configs: []family.Config, payload_bytes: usize) void {
    if (configs.len > insertion_threshold) {
        insertionSort(configs[0..insertion_threshold], payload_bytes);
        for (insertion_threshold..configs.len) |index| {
            unguardedLinearInsert(configs, index, payload_bytes);
        }
    } else {
        insertionSort(configs, payload_bytes);
    }
}

fn insertionSort(configs: []family.Config, payload_bytes: usize) void {
    if (configs.len == 0) return;
    for (1..configs.len) |index| {
        const value = configs[index];
        if (configLess(value, configs[0], payload_bytes)) {
            var move = index;
            while (move > 0) : (move -= 1) configs[move] = configs[move - 1];
            configs[0] = value;
        } else {
            unguardedLinearInsert(configs, index, payload_bytes);
        }
    }
}

fn unguardedLinearInsert(
    configs: []family.Config,
    initial_index: usize,
    payload_bytes: usize,
) void {
    const value = configs[initial_index];
    var index = initial_index;
    var previous = index - 1;
    while (configLess(value, configs[previous], payload_bytes)) {
        configs[index] = configs[previous];
        index = previous;
        std.debug.assert(previous > 0);
        previous -= 1;
    }
    configs[index] = value;
}

fn configLess(left: family.Config, right: family.Config, payload_bytes: usize) bool {
    return (left.allocatedBytes(payload_bytes) catch unreachable) <
        (right.allocatedBytes(payload_bytes) catch unreachable);
}

fn lessConfig(payload_bytes: usize, left: family.Config, right: family.Config) bool {
    return configLess(left, right, payload_bytes);
}

fn roundDownPowerOfTwo(value: usize) usize {
    if (value <= 1) return 1;
    return @as(usize, 1) << std.math.log2_int(usize, value);
}

fn roundUpPowerOfTwo(value: usize) error{Overflow}!usize {
    if (value <= 1) return 1;
    return std.math.ceilPowerOfTwo(usize, value);
}

fn occupancyWordLength(num_slots: usize) usize {
    return std.math.divCeil(usize, num_slots, @bitSizeOf(u32)) catch unreachable;
}

fn byteWordLength(byte_count: usize) usize {
    return std.math.divCeil(usize, byte_count, @sizeOf(u32)) catch unreachable;
}

fn addWords(words: *usize, additional: usize) family.PhastError!void {
    words.* = std.math.add(usize, words.*, additional) catch
        return error.CapacityExceeded;
}

fn takeWords(storage: []u32, offset: *usize, length: usize) []u32 {
    const begin = offset.*;
    const end = begin + length;
    offset.* = end;
    return storage[begin..end];
}

fn contains(values: []const u32, target: u32) bool {
    for (values) |value| if (value == target) return true;
    return false;
}

fn storageOverlaps(
    comptime Left: type,
    left: []const Left,
    comptime Right: type,
    right: []const Right,
) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_begin = @intFromPtr(left.ptr);
    const right_begin = @intFromPtr(right.ptr);
    const left_bytes = std.math.mul(usize, left.len, @sizeOf(Left)) catch return true;
    const right_bytes = std.math.mul(usize, right.len, @sizeOf(Right)) catch return true;
    const left_end = std.math.add(usize, left_begin, left_bytes) catch return true;
    const right_end = std.math.add(usize, right_begin, right_bytes) catch return true;
    return left_begin < right_end and right_begin < left_end;
}

pub fn phastScratchLen(num_keys: usize, payload_bytes: usize) family.PhastError!usize {
    return (try Plan.inspect(num_keys, payload_bytes)).scratch_len;
}

pub fn phastSeedsLen(num_keys: usize, payload_bytes: usize) family.PhastError!usize {
    return (try Plan.inspect(num_keys, payload_bytes)).seeds_len;
}

pub fn buildPhast(
    scratch: []u32,
    seed_words: []u32,
    keys: []const u32,
    payload_bytes: usize,
) family.PhastError!family.Data {
    const plan = try Plan.inspect(keys.len, payload_bytes);
    return plan.build(scratch, seed_words, keys);
}

fn fixtureKeys(comptime count: usize, key: u32) [count]u32 {
    const permutation = hash_mod.Triple32.initKey(key);
    var keys: [count]u32 = undefined;
    for (&keys, 0..) |*value, index| value.* = permutation.hash(@intCast(index));
    return keys;
}

fn digest(comptime T: type, values: []const T) u64 {
    var result: u64 = 1_469_598_103_934_665_603;
    for (values) |value| result = (result ^ @as(u64, value)) *% 1_099_511_628_211;
    return result;
}

fn expectSliceLengths(num_keys: usize, first: usize, second: usize) !void {
    const plan = try Plan.inspect(num_keys, 0);
    var found_first = false;
    var found_second = false;
    for (plan.configs[0..plan.config_count]) |config| {
        const slice_length = config.placement.sliceLength();
        try std.testing.expect(slice_length == first or slice_length == second);
        found_first = found_first or slice_length == first;
        found_second = found_second or slice_length == second;
    }
    try std.testing.expect(found_first);
    try std.testing.expect(found_second);
}

test "Highway PHAST one-key table image matches the pinned builder" {
    const keys = fixtureKeys(1, 0);
    const plan = try Plan.inspect(keys.len, 0);
    try std.testing.expectEqual(@as(usize, 8_457), plan.scratch_len);
    try std.testing.expectEqual(@as(usize, 1), plan.seeds_len);
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u32, plan.scratch_len);
    defer allocator.free(scratch);
    const seed_words = try allocator.alloc(u32, plan.seeds_len);
    defer allocator.free(seed_words);
    const data = try plan.build(scratch, seed_words, &keys);
    try std.testing.expectEqual(@as(usize, 2), data.config.num_slots);
    try std.testing.expectEqual(@as(usize, 1), data.config.numBuckets());
    try std.testing.expectEqual(@as(u32, 0x7aa5_332d), data.config.hash_key);
    try std.testing.expectEqual(@as(u32, 2), data.config.placement.num_slice_offsets);
    try std.testing.expectEqual(@as(u32, 0), data.config.placement.slice_mask);
    try std.testing.expectEqual(@as(usize, 0), data.config_index);
    try std.testing.expectEqual(@as(usize, 0), data.attempt_index);
    try std.testing.expectEqualSlices(u32, &.{0}, data.seeds.words);
    try std.testing.expectEqual(@as(u32, 0), (try family.Phast.init(data)).index(keys[0]));
}

test "Highway PHAST 64-key table image matches the pinned builder" {
    const keys = fixtureKeys(64, 0);
    const plan = try Plan.inspect(keys.len, 0);
    try std.testing.expectEqual(@as(usize, 8_693), plan.scratch_len);
    try std.testing.expectEqual(@as(usize, 8), plan.seeds_len);
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u32, plan.scratch_len);
    defer allocator.free(scratch);
    const seed_words = try allocator.alloc(u32, plan.seeds_len);
    defer allocator.free(seed_words);
    const data = try plan.build(scratch, seed_words, &keys);
    try std.testing.expectEqual(@as(usize, 65), data.config.num_slots);
    try std.testing.expectEqual(@as(usize, 32), data.config.numBuckets());
    try std.testing.expectEqual(@as(u32, 0x7aa5_332d), data.config.hash_key);
    try std.testing.expectEqual(@as(u32, 2), data.config.placement.num_slice_offsets);
    try std.testing.expectEqual(@as(u32, 63), data.config.placement.slice_mask);
    try std.testing.expectEqual(@as(usize, 0), data.config_index);
    try std.testing.expectEqual(@as(usize, 0), data.attempt_index);
    try std.testing.expectEqual(@as(usize, 32), try data.allocatedBytes(0));
    try std.testing.expectEqualSlices(u32, &.{
        0x0203_0000,
        0x0514_0600,
        0x032c_0e16,
        0x0a02_0000,
        0x0007_7c02,
        0x0020_1308,
        0x4960_6701,
        0x4307_020e,
    }, data.seeds.words);
    try std.testing.expectEqual(@as(u64, 0x40f9_1e97_5657_1114), digest(u32, data.seeds.words));
    const phast = try family.Phast.init(data);
    var positions: [keys.len]u32 = undefined;
    for (keys, &positions) |key, *position| position.* = phast.index(key);
    try std.testing.expectEqualSlices(u32, &.{
        13, 55, 33, 23, 45, 50, 27, 31,
        3,  16, 18, 40, 25, 2,  44, 24,
    }, positions[0..16]);
    try std.testing.expectEqual(@as(u64, 0x0dba_d93f_4650_dd0a), digest(u32, &positions));
    var occupied: [65]bool = @splat(false);
    for (positions) |position| {
        try std.testing.expect(position < occupied.len);
        try std.testing.expect(!occupied[position]);
        occupied[position] = true;
    }
    const D = tag.FixedTag(u32, 8);
    const paired = phast.twoVec(D, keys[0..8].*, keys[8..16].*);
    try std.testing.expect(@reduce(.And, paired.first == @as(D.Vector, positions[0..8].*)));
    try std.testing.expect(@reduce(.And, paired.second == @as(D.Vector, positions[8..16].*)));
    var batch: [33]u32 = undefined;
    for (0..batch.len + 1) |length| {
        try phast.indexBatch(D, keys[0..length], batch[0..length]);
        for (batch[0..length], keys[0..length]) |actual, key| {
            try std.testing.expectEqual(phast.index(key), actual);
        }
    }
    try std.testing.expectError(error.PlanMismatch, phast.indexBatch(D, keys[0..2], batch[0..1]));
}

test "Highway PHAST configuration ordering matches the pinned builder" {
    const keys = fixtureKeys(100, 0);
    const plan = try Plan.inspect(keys.len, 0);
    try std.testing.expectEqual(@as(usize, 8_877), plan.scratch_len);
    try std.testing.expectEqual(@as(usize, 16), plan.seeds_len);
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u32, plan.scratch_len);
    defer allocator.free(scratch);
    const seed_words = try allocator.alloc(u32, plan.seeds_len);
    defer allocator.free(seed_words);
    const data = try plan.build(scratch, seed_words, &keys);
    try std.testing.expectEqual(@as(usize, 102), data.config.num_slots);
    try std.testing.expectEqual(@as(usize, 64), data.config.numBuckets());
    try std.testing.expectEqual(@as(u32, 0x2db7_aa3d), data.config.hash_key);
    try std.testing.expectEqual(@as(u32, 39), data.config.placement.num_slice_offsets);
    try std.testing.expectEqual(@as(u32, 63), data.config.placement.slice_mask);
    try std.testing.expectEqual(@as(usize, 0), data.config_index);
    try std.testing.expectEqual(@as(usize, 0), data.attempt_index);
    try std.testing.expectEqual(@as(u64, 0x5a53_81c8_0a88_ff4e), digest(u32, data.seeds.words));
    const phast = try family.Phast.init(data);
    var positions: [keys.len]u32 = undefined;
    try phast.indexBatch(tag.FixedTag(u32, 8), &keys, &positions);
    try std.testing.expectEqualSlices(u32, &.{
        43, 93, 33, 65, 94, 36, 92, 27,
        46, 90, 74, 12, 61, 97, 22, 4,
    }, positions[0..16]);
    try std.testing.expectEqual(@as(u64, 0xb571_753a_626d_5579), digest(u32, &positions));
}

test "Highway PHAST builder matches a retried pinned table image" {
    const keys = fixtureKeys(50, 0x816);
    const plan = try Plan.inspect(keys.len, 0);
    try std.testing.expectEqual(@as(usize, 8_663), plan.scratch_len);
    try std.testing.expectEqual(@as(usize, 8), plan.seeds_len);
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u32, plan.scratch_len);
    defer allocator.free(scratch);
    const seed_words = try allocator.alloc(u32, plan.seeds_len);
    defer allocator.free(seed_words);
    const data = try plan.build(scratch, seed_words, &keys);
    try std.testing.expectEqual(@as(usize, 51), data.config.num_slots);
    try std.testing.expectEqual(@as(usize, 16), data.config.numBuckets());
    try std.testing.expectEqual(@as(u32, 0x7f8c_17b1), data.config.hash_key);
    try std.testing.expectEqual(@as(u32, 36), data.config.placement.num_slice_offsets);
    try std.testing.expectEqual(@as(u32, 15), data.config.placement.slice_mask);
    try std.testing.expectEqual(@as(usize, 1), data.config_index);
    try std.testing.expectEqual(@as(usize, 216), data.attempt_index);
    try std.testing.expectEqualSlices(u32, &.{
        0x3260_035a,
        0x2f14_13c2,
        0x003e_301c,
        0x0e00_b807,
    }, data.seeds.words);
    try std.testing.expectEqual(@as(u64, 0xace0_16b3_9ce4_5386), digest(u32, data.seeds.words));
    const phast = try family.Phast.init(data);
    var positions: [keys.len]u32 = undefined;
    try phast.indexBatch(tag.FixedTag(u32, 8), &keys, &positions);
    try std.testing.expectEqualSlices(u32, &.{
        24, 15, 31, 37, 18, 11, 26, 48,
        23, 42, 7,  36, 50, 25, 43, 39,
    }, positions[0..16]);
    try std.testing.expectEqual(@as(u64, 0x45a2_adf5_7dc4_cd42), digest(u32, &positions));
}

test "Highway PHAST plan enforces storage keys and empty input contracts" {
    const keys = fixtureKeys(8, 91);
    const plan = try Plan.inspect(keys.len, 4);
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u32, plan.scratch_len);
    defer allocator.free(scratch);
    const seed_words = try allocator.alloc(u32, plan.seeds_len);
    defer allocator.free(seed_words);
    try std.testing.expectError(
        error.ScratchTooSmall,
        plan.build(scratch[0 .. scratch.len - 1], seed_words, &keys),
    );
    try std.testing.expectError(
        error.SeedsTooSmall,
        plan.build(scratch, seed_words[0 .. seed_words.len - 1], &keys),
    );
    try std.testing.expectError(
        error.InputOutputOverlap,
        plan.build(scratch, scratch[0..plan.seeds_len], &keys),
    );
    try std.testing.expectError(
        error.InputOutputOverlap,
        plan.build(scratch, seed_words, scratch[0..keys.len]),
    );
    var duplicates = keys;
    duplicates[7] = duplicates[0];
    try std.testing.expectError(
        error.DuplicateKey,
        plan.build(scratch, seed_words, &duplicates),
    );
    const empty_plan = try Plan.inspect(0, std.math.maxInt(usize));
    const empty = try empty_plan.build(&.{}, &.{}, &.{});
    try std.testing.expect(empty.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), empty_plan.scratch_len);
    try std.testing.expectEqual(@as(usize, 0), empty_plan.seeds_len);
}

test "Highway PHAST placement and data reject malformed layouts" {
    try std.testing.expectError(error.InvalidData, family.Placement.init(8, 3));
    try std.testing.expectError(error.CapacityExceeded, family.Placement.init(3, 4));
    const words = [_]u32{0};
    const config = family.Config{
        .num_slots = 8,
        .hash_key = 7,
        .bucket_mask = 3,
        .placement = try family.Placement.init(8, 4),
    };
    _ = try family.Phast.init(.{ .config = config, .seeds = .{ .words = &words } });
    try std.testing.expectError(
        error.InvalidData,
        family.Phast.init(.{ .config = config, .seeds = .{} }),
    );
    var malformed = config;
    malformed.bucket_mask = 2;
    try std.testing.expectError(
        error.InvalidData,
        family.Phast.init(.{ .config = malformed, .seeds = .{ .words = &words } }),
    );
    malformed = config;
    malformed.placement.slice_mask = 2;
    try std.testing.expectError(
        error.InvalidData,
        family.Phast.init(.{ .config = malformed, .seeds = .{ .words = &words } }),
    );
    malformed = config;
    malformed.placement.num_slice_offsets -= 1;
    try std.testing.expectError(
        error.InvalidData,
        family.Phast.init(.{ .config = malformed, .seeds = .{ .words = &words } }),
    );
    try std.testing.expectError(error.BuildFailed, family.Phast.init(.{}));
}

test "Highway PHAST configuration slice thresholds match the pinned builder" {
    try expectSliceLengths(63, 16, 32);
    try expectSliceLengths(64, 64, 128);
    try expectSliceLengths(1_299, 64, 128);
    try expectSliceLengths(1_300, 128, 256);
    try expectSliceLengths(9_499, 128, 256);
    try expectSliceLengths(9_500, 256, 512);
    try expectSliceLengths(11_999, 256, 512);
    try expectSliceLengths(12_000, 512, 1_024);
    try expectSliceLengths(139_999, 512, 1_024);
    try expectSliceLengths(140_000, 2_048, 4_096);
}

test "Highway PHAST planning rejects unrepresentable capacities" {
    try std.testing.expectError(
        error.CapacityExceeded,
        Plan.inspect(std.math.maxInt(u32), 0),
    );
    try std.testing.expectError(
        error.CapacityExceeded,
        Plan.inspect(1, std.math.maxInt(usize)),
    );
    try std.testing.expectError(
        error.CapacityExceeded,
        (family.Config{ .num_slots = std.math.maxInt(usize) }).allocatedBytes(2),
    );
    try std.testing.expectError(
        error.CapacityExceeded,
        scratchLength(std.math.maxInt(usize), 0, 0),
    );
}
