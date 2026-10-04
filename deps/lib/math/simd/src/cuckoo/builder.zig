const std = @import("std");
const simd = @import("../root.zig");

const random = simd.random;

pub const CuckooBuildError = error{
    BuildFailed,
    CapacityExceeded,
    DuplicateKey,
    EmptyKey,
    InputOutputOverlap,
    InvalidEpsilon,
    PlanMismatch,
    ScratchTooSmall,
    SlotsTooSmall,
    UnsupportedEpsilon,
};

pub const CuckooBuildStats = struct {
    success: bool = false,
    num_primary: u32 = 0,
    global_seed: u32 = 0,
    attempts: u32 = 0,
    num_unmatched_after_greedy: u32 = 0,
    collect_path_cost_stats: bool = false,
    paths_per_path_cost: []const u32 = &.{},
};

pub fn Plan(comptime Family: type) type {
    return struct {
        config: Family.Config,
        scratch_len: usize,
        slots_len: usize,

        const Self = @This();

        pub fn inspect(num_keys: usize, epsilon: f64) CuckooBuildError!Self {
            const config = Family.Config.init(num_keys, epsilon) catch |err| return err;
            _ = try dfsStepLimit(Family, config);
            return .{
                .config = config,
                .scratch_len = try scratchLength(Family, config),
                .slots_len = config.num_slots,
            };
        }

        pub fn build(
            self: Self,
            scratch: []u32,
            slots: []Family.Key,
            keys: []const Family.Key,
            max_attempts: u32,
            stats: ?*CuckooBuildStats,
        ) CuckooBuildError!Family.Table {
            resetStats(stats);
            if (!supportedEpsilon(self.config.epsilon)) return error.UnsupportedEpsilon;
            try self.validateBuffers(scratch, slots, keys);
            try validateKeys(Family, slots, keys);
            var cuckoo_builder = try Builder(Family).init(self.config, scratch);
            const engine = random.AesCtrEngine.initDeterministic();
            for (0..@as(usize, max_attempts)) |attempt_index| {
                const attempt: u32 = @intCast(attempt_index);
                const primary = Family.Hash.initSeed(&engine, @as(u64, attempt) * 2);
                const secondary = Family.Hash.initSeed(&engine, @as(u64, attempt) * 2 + 1);
                if (!try cuckoo_builder.build(keys, primary, secondary, stats)) continue;
                const table = try cuckoo_builder.take(keys, slots);
                if (stats) |build_stats| {
                    build_stats.success = true;
                    build_stats.num_primary = table.num_primary;
                    build_stats.global_seed = attempt;
                    build_stats.attempts = attempt + 1;
                }
                return table;
            }
            if (stats) |build_stats| build_stats.attempts = max_attempts;
            return error.BuildFailed;
        }

        pub fn buildWithHashes(
            self: Self,
            scratch: []u32,
            slots: []Family.Key,
            keys: []const Family.Key,
            hash_primary: Family.Hash,
            hash_secondary: Family.Hash,
            stats: ?*CuckooBuildStats,
        ) CuckooBuildError!Family.Table {
            resetStats(stats);
            try self.validateBuffers(scratch, slots, keys);
            try validateKeys(Family, slots, keys);
            var cuckoo_builder = try Builder(Family).init(self.config, scratch);
            if (!try cuckoo_builder.build(keys, hash_primary, hash_secondary, stats)) {
                if (stats) |build_stats| build_stats.attempts = 1;
                return error.BuildFailed;
            }
            const table = try cuckoo_builder.take(keys, slots);
            if (stats) |build_stats| {
                build_stats.success = true;
                build_stats.num_primary = table.num_primary;
                build_stats.attempts = 1;
            }
            return table;
        }

        fn validateBuffers(
            self: Self,
            scratch: []u32,
            slots: []Family.Key,
            keys: []const Family.Key,
        ) CuckooBuildError!void {
            if (keys.len != self.config.num_keys) return error.PlanMismatch;
            if (scratch.len < self.scratch_len) return error.ScratchTooSmall;
            if (slots.len < self.slots_len) return error.SlotsTooSmall;
            if (storageOverlaps(u32, scratch, Family.Key, slots) or
                storageOverlaps(u32, scratch, Family.Key, keys))
            {
                return error.InputOutputOverlap;
            }
        }
    };
}

pub fn Placement(comptime Family: type) type {
    return struct {
        config: Family.Config,
        hash_primary: Family.Hash = undefined,
        hash_secondary: Family.Hash = undefined,
        primary_bucket: []u32,
        secondary_bucket: []u32,
        match_key_to_slot: []u32,
        match_slot_to_key: []u32,
        bucket_fill: []u32,
        matched: bool = false,

        const Self = @This();

        pub fn init(config: Family.Config, scratch: []u32) CuckooBuildError!Self {
            const required = try placementScratchLength(config);
            if (scratch.len < required) return error.ScratchTooSmall;
            var offset: usize = 0;
            const primary_bucket = takeWords(scratch, &offset, config.num_keys);
            const secondary_bucket = takeWords(scratch, &offset, config.num_keys);
            const match_key_to_slot = takeWords(scratch, &offset, config.num_keys);
            const match_slot_to_key = takeWords(scratch, &offset, config.num_slots);
            const bucket_fill = takeWords(scratch, &offset, config.num_buckets);
            std.debug.assert(offset == required);
            return .{
                .config = config,
                .primary_bucket = primary_bucket,
                .secondary_bucket = secondary_bucket,
                .match_key_to_slot = match_key_to_slot,
                .match_slot_to_key = match_slot_to_key,
                .bucket_fill = bucket_fill,
            };
        }

        pub fn prepare(
            self: *Self,
            keys: []const Family.Key,
            hash_primary: Family.Hash,
            hash_secondary: Family.Hash,
            stats: ?*CuckooBuildStats,
        ) CuckooBuildError!usize {
            return preparePlacement(
                Family,
                self,
                keys,
                hash_primary,
                hash_secondary,
                stats,
            );
        }

        pub fn take(
            self: Self,
            keys: []const Family.Key,
            slots: []Family.Key,
        ) CuckooBuildError!Family.Table {
            return takePlacement(Family, self, keys, slots);
        }
    };
}

pub fn Builder(comptime Family: type) type {
    return struct {
        config: Family.Config,
        hash_primary: Family.Hash = undefined,
        hash_secondary: Family.Hash = undefined,
        primary_bucket: []u32,
        secondary_bucket: []u32,
        match_key_to_slot: []u32,
        match_slot_to_key: []u32,
        dist: []u32,
        bucket_fill: []u32,
        queue: []u32,
        cursor: []u32,
        dfs_step_limit: usize,
        matched: bool = false,

        const Self = @This();
        const unmatched = std.math.maxInt(u32);
        const edge_count = Family.bucket_size * 2;

        pub fn init(config: Family.Config, scratch: []u32) CuckooBuildError!Self {
            const required = try scratchLength(Family, config);
            if (scratch.len < required) return error.ScratchTooSmall;
            const key_count = config.num_keys;
            var offset: usize = 0;
            const primary_bucket = takeWords(scratch, &offset, key_count);
            const secondary_bucket = takeWords(scratch, &offset, key_count);
            const match_key_to_slot = takeWords(scratch, &offset, key_count);
            const match_slot_to_key = takeWords(scratch, &offset, config.num_slots);
            const dist = takeWords(scratch, &offset, key_count);
            const bucket_fill = takeWords(scratch, &offset, config.num_buckets);
            const queue = takeWords(scratch, &offset, key_count);
            const cursor = takeWords(scratch, &offset, key_count);
            std.debug.assert(offset == required);
            return .{
                .config = config,
                .primary_bucket = primary_bucket,
                .secondary_bucket = secondary_bucket,
                .match_key_to_slot = match_key_to_slot,
                .match_slot_to_key = match_slot_to_key,
                .dist = dist,
                .bucket_fill = bucket_fill,
                .queue = queue,
                .cursor = cursor,
                .dfs_step_limit = try dfsStepLimit(Family, config),
            };
        }

        pub fn build(
            self: *Self,
            keys: []const Family.Key,
            hash_primary: Family.Hash,
            hash_secondary: Family.Hash,
            stats: ?*CuckooBuildStats,
        ) CuckooBuildError!bool {
            const initial_matching_size = try self.prepare(
                keys,
                hash_primary,
                hash_secondary,
                stats,
            );
            return self.completeMaximumMatching(initial_matching_size);
        }

        pub fn prepare(
            self: *Self,
            keys: []const Family.Key,
            hash_primary: Family.Hash,
            hash_secondary: Family.Hash,
            stats: ?*CuckooBuildStats,
        ) CuckooBuildError!usize {
            return preparePlacement(
                Family,
                self,
                keys,
                hash_primary,
                hash_secondary,
                stats,
            );
        }

        pub fn completeMaximumMatching(
            self: *Self,
            initial_matching_size: usize,
        ) bool {
            var matching_size = initial_matching_size;
            if (matching_size == self.config.num_keys) {
                self.matched = true;
                return true;
            }
            for (0..self.config.num_keys) |_| {
                if (!self.breadthFirst()) break;
                const before = matching_size;
                for (0..self.config.num_keys) |key_index| {
                    if (self.match_key_to_slot[key_index] != unmatched) continue;
                    matching_size += @intFromBool(self.depthFirst(@intCast(key_index)));
                }
                std.debug.assert(matching_size > before);
                if (matching_size == self.config.num_keys) break;
            }
            self.matched = matching_size == self.config.num_keys;
            return self.matched;
        }

        pub fn take(
            self: Self,
            keys: []const Family.Key,
            slots: []Family.Key,
        ) CuckooBuildError!Family.Table {
            return takePlacement(Family, self, keys, slots);
        }

        fn breadthFirst(self: *Self) bool {
            @memset(self.dist, unmatched);
            var tail: usize = 0;
            for (self.match_key_to_slot, 0..) |slot, key_index| {
                if (slot != unmatched) continue;
                self.dist[key_index] = 0;
                self.queue[tail] = @intCast(key_index);
                tail += 1;
            }
            var head: usize = 0;
            var found = false;
            for (0..self.config.num_keys) |_| {
                if (head == tail) break;
                const key_index = self.queue[head];
                head += 1;
                for (0..edge_count) |edge_index| {
                    const slot = self.candidateSlot(key_index, edge_index);
                    const other_key = self.match_slot_to_key[slot];
                    if (other_key == unmatched) {
                        found = true;
                    } else if (self.dist[other_key] == unmatched and !found) {
                        self.dist[other_key] = self.dist[key_index] + 1;
                        std.debug.assert(tail < self.queue.len);
                        self.queue[tail] = other_key;
                        tail += 1;
                    }
                }
            }
            std.debug.assert(head == tail);
            return found;
        }

        fn depthFirst(self: *Self, root: u32) bool {
            var depth: usize = 1;
            self.queue[0] = root;
            self.cursor[0] = 0;
            for (0..self.dfs_step_limit) |_| {
                if (depth == 0) return false;
                const frame = depth - 1;
                const key_index = self.queue[frame];
                const edge_index = self.cursor[frame];
                if (edge_index == edge_count) {
                    self.dist[key_index] = unmatched;
                    depth -= 1;
                    continue;
                }
                self.cursor[frame] += 1;
                const slot = self.candidateSlot(key_index, edge_index);
                const other_key = self.match_slot_to_key[slot];
                if (other_key == unmatched) {
                    self.augment(depth, slot);
                    return true;
                }
                if (self.dist[other_key] != self.dist[key_index] +% 1) {
                    continue;
                }
                std.debug.assert(depth < self.queue.len);
                self.queue[depth] = other_key;
                self.cursor[depth] = 0;
                depth += 1;
            }
            std.debug.assert(false);
            return false;
        }

        fn augment(self: *Self, depth: usize, free_slot: u32) void {
            var assigned_slot = free_slot;
            for (0..depth) |reverse_index| {
                const frame = depth - reverse_index - 1;
                const key_index = self.queue[frame];
                const old_slot = self.match_key_to_slot[key_index];
                self.match_key_to_slot[key_index] = assigned_slot;
                self.match_slot_to_key[assigned_slot] = key_index;
                assigned_slot = old_slot;
            }
            std.debug.assert(assigned_slot == unmatched);
        }

        fn candidateSlot(self: Self, key_index: u32, edge_index: usize) u32 {
            const secondary = edge_index >= Family.bucket_size;
            const bucket = if (secondary)
                self.secondary_bucket[key_index]
            else
                self.primary_bucket[key_index];
            const within_bucket = edge_index & (Family.bucket_size - 1);
            return @intCast(@as(usize, bucket) * Family.bucket_size + within_bucket);
        }
    };
}

fn preparePlacement(
    comptime Family: type,
    placement: anytype,
    keys: []const Family.Key,
    hash_primary: Family.Hash,
    hash_secondary: Family.Hash,
    stats: ?*CuckooBuildStats,
) CuckooBuildError!usize {
    if (keys.len != placement.config.num_keys) return error.PlanMismatch;
    placement.hash_primary = hash_primary;
    placement.hash_secondary = hash_secondary;
    placement.matched = false;
    for (keys, 0..) |key, key_index| {
        if (key == Family.empty_key) return error.EmptyKey;
        placement.primary_bucket[key_index] = @intCast(
            placement.hash_primary.hash(key) & placement.config.bucket_mask,
        );
        placement.secondary_bucket[key_index] = @intCast(
            placement.hash_secondary.hash(key) & placement.config.bucket_mask,
        );
    }
    const matching_size = greedyPlacement(Family, placement);
    if (stats) |build_stats| {
        build_stats.num_unmatched_after_greedy = @intCast(keys.len - matching_size);
    }
    return matching_size;
}

fn greedyPlacement(comptime Family: type, placement: anytype) usize {
    const unmatched = std.math.maxInt(u32);
    @memset(placement.match_key_to_slot, unmatched);
    @memset(placement.match_slot_to_key, unmatched);
    @memset(placement.bucket_fill, 0);
    var matching_size: usize = 0;
    for (placement.primary_bucket, 0..) |bucket, key_index| {
        matching_size += @intFromBool(greedyPlace(Family, placement, key_index, bucket));
    }
    for (placement.secondary_bucket, 0..) |bucket, key_index| {
        if (placement.match_key_to_slot[key_index] != unmatched) continue;
        matching_size += @intFromBool(greedyPlace(Family, placement, key_index, bucket));
    }
    return matching_size;
}

fn greedyPlace(
    comptime Family: type,
    placement: anytype,
    key_index: usize,
    bucket: u32,
) bool {
    const bucket_index: usize = bucket;
    if (placement.bucket_fill[bucket_index] >= Family.bucket_size) return false;
    const slot = bucket_index * Family.bucket_size + placement.bucket_fill[bucket_index];
    placement.match_key_to_slot[key_index] = @intCast(slot);
    placement.match_slot_to_key[slot] = @intCast(key_index);
    placement.bucket_fill[bucket_index] += 1;
    return true;
}

fn takePlacement(
    comptime Family: type,
    placement: anytype,
    keys: []const Family.Key,
    slots: []Family.Key,
) CuckooBuildError!Family.Table {
    const unmatched = std.math.maxInt(u32);
    if (!placement.matched) return error.BuildFailed;
    if (keys.len != placement.config.num_keys) return error.PlanMismatch;
    if (slots.len < placement.config.num_slots) return error.SlotsTooSmall;
    const output = slots[0..placement.config.num_slots];
    if (slicesOverlap(Family.Key, output, keys)) return error.InputOutputOverlap;
    @memset(output, Family.empty_key);
    var num_primary: u32 = 0;
    for (keys, placement.match_key_to_slot, 0..) |key, slot_index, key_index| {
        std.debug.assert(slot_index != unmatched);
        std.debug.assert(output[slot_index] == Family.empty_key);
        output[slot_index] = key;
        const bucket: u32 = @intCast(slot_index / Family.bucket_size);
        num_primary += @intFromBool(bucket == placement.primary_bucket[key_index]);
    }
    return Family.Table.init(
        placement.config,
        placement.hash_primary,
        placement.hash_secondary,
        output,
        num_primary,
    ) catch unreachable;
}

pub fn placementScratchLength(config: anytype) CuckooBuildError!usize {
    const key_words = std.math.mul(usize, config.num_keys, 3) catch
        return error.CapacityExceeded;
    const keys_and_slots = std.math.add(usize, key_words, config.num_slots) catch
        return error.CapacityExceeded;
    return std.math.add(usize, keys_and_slots, config.num_buckets) catch
        return error.CapacityExceeded;
}

pub fn scratchLength(comptime Family: type, config: Family.Config) CuckooBuildError!usize {
    const key_words = std.math.mul(usize, config.num_keys, 6) catch
        return error.CapacityExceeded;
    const keys_and_slots = std.math.add(usize, key_words, config.num_slots) catch
        return error.CapacityExceeded;
    return std.math.add(usize, keys_and_slots, config.num_buckets) catch
        return error.CapacityExceeded;
}

pub fn dfsStepLimit(comptime Family: type, config: Family.Config) CuckooBuildError!usize {
    const steps_per_key = std.math.add(usize, Family.bucket_size * 2, 1) catch
        return error.CapacityExceeded;
    const all_steps = std.math.mul(usize, config.num_keys, steps_per_key) catch
        return error.CapacityExceeded;
    return std.math.add(usize, all_steps, 1) catch return error.CapacityExceeded;
}

pub fn takeWords(storage: []u32, offset: *usize, len: usize) []u32 {
    const begin = offset.*;
    const end = begin + len;
    offset.* = end;
    return storage[begin..end];
}

pub fn resetStats(stats: ?*CuckooBuildStats) void {
    if (stats) |build_stats| {
        const collect_path_cost_stats = build_stats.collect_path_cost_stats;
        build_stats.* = .{ .collect_path_cost_stats = collect_path_cost_stats };
    }
}

pub fn supportedEpsilon(epsilon: f64) bool {
    for ([_]f64{ 0.01, 0.05, 0.10, 0.25, 0.50, 0.75 }) |supported| {
        if (epsilon == supported) return true;
    }
    return false;
}

pub fn validateKeys(
    comptime Family: type,
    slots: []Family.Key,
    keys: []const Family.Key,
) CuckooBuildError!void {
    if (slicesOverlap(Family.Key, slots, keys)) return error.InputOutputOverlap;
    const sorted = slots[0..keys.len];
    for (keys, sorted) |key, *copy| {
        if (key == Family.empty_key) return error.EmptyKey;
        copy.* = key;
    }
    std.mem.sort(Family.Key, sorted, {}, std.sort.asc(Family.Key));
    if (sorted.len < 2) return;
    for (sorted[1..], sorted[0 .. sorted.len - 1]) |current, previous| {
        if (current == previous) return error.DuplicateKey;
    }
}

pub fn slicesOverlap(comptime T: type, mutable: []T, immutable: []const T) bool {
    if (mutable.len == 0 or immutable.len == 0) return false;
    const mutable_begin = @intFromPtr(mutable.ptr);
    const immutable_begin = @intFromPtr(immutable.ptr);
    const mutable_bytes = std.math.mul(usize, mutable.len, @sizeOf(T)) catch return true;
    const immutable_bytes = std.math.mul(usize, immutable.len, @sizeOf(T)) catch return true;
    const mutable_end = std.math.add(usize, mutable_begin, mutable_bytes) catch return true;
    const immutable_end = std.math.add(usize, immutable_begin, immutable_bytes) catch return true;
    return mutable_begin < immutable_end and immutable_begin < mutable_end;
}

pub fn storageOverlaps(
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

test "Highway generic Cuckoo builder completes maximum matching" {
    const Family = simd.cuckoo.DefaultCuckoo;
    const key_count = 1000;
    var keys: [key_count]u32 = undefined;
    const engine = random.AesCtrEngine.initDeterministic();
    const permutation = simd.hash.Triple32.initSeed(&engine, 0);
    for (&keys, 0..) |*key, key_index| {
        key.* = permutation.hash(@intCast(key_index));
        if (key.* == Family.empty_key) key.* = 0;
    }
    const plan = try Family.BuildPlan.inspect(key_count, 0.01);
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u32, plan.scratch_len);
    defer allocator.free(scratch);
    const slots = try allocator.alloc(u32, plan.slots_len);
    defer allocator.free(slots);
    var stats: CuckooBuildStats = .{};
    const table = try plan.build(scratch, slots, &keys, 200, &stats);
    try std.testing.expect(stats.success);
    try std.testing.expectEqual(@as(usize, 7088), plan.scratch_len);
    try std.testing.expectEqual(@as(usize, 1024), plan.slots_len);
    try std.testing.expectEqual(@as(u32, 916), stats.num_primary);
    try std.testing.expectEqual(@as(u32, 0), stats.global_seed);
    try std.testing.expectEqual(@as(u32, 1), stats.attempts);
    try std.testing.expectEqual(@as(u32, 47), stats.num_unmatched_after_greedy);
    try std.testing.expectEqual(key_count, table.config.num_keys);
    try std.testing.expectEqualSlices(u32, &.{
        0x1f66_f859, 0x0a9c_8235, 0x0814_b9d8, 0x13ae_2206,
        0xf399_d47d, 0xc57b_e2db, 0xfbcd_0050, 0x34c2_2bf3,
        0xefa8_2035, 0x2efc_254c, 0x8bb2_4319, 0xfe07_ee01,
        0x7fb0_0d51, 0xe858_34af, 0x31f9_ecbf, 0x9376_9934,
    }, table.slots()[0..16]);
    var digest: u64 = 1_469_598_103_934_665_603;
    for (table.slots()) |slot| digest = (digest ^ slot) *% 1_099_511_628_211;
    try std.testing.expectEqual(@as(u64, 0x911d_fe6f_4dc9_fc9b), digest);
    for (keys) |key| try std.testing.expect(table.queryOne(key));
}

test "Highway generic Cuckoo build plan enforces caller storage and key contracts" {
    const Family = simd.cuckoo.DefaultCuckoo;
    const keys = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const plan = try Family.BuildPlan.inspect(keys.len, 0.25);
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u32, plan.scratch_len);
    defer allocator.free(scratch);
    const slots = try allocator.alloc(u32, plan.slots_len);
    defer allocator.free(slots);
    try std.testing.expectError(
        error.ScratchTooSmall,
        plan.build(scratch[0 .. scratch.len - 1], slots, &keys, 1, null),
    );
    try std.testing.expectError(
        error.SlotsTooSmall,
        plan.build(scratch, slots[0 .. slots.len - 1], &keys, 1, null),
    );
    try std.testing.expectError(
        error.PlanMismatch,
        plan.build(scratch, slots, keys[0..7], 1, null),
    );
    const duplicate = [_]u32{ 1, 2, 3, 3, 5, 6, 7, 8 };
    try std.testing.expectError(error.DuplicateKey, plan.build(
        scratch,
        slots,
        &duplicate,
        1,
        null,
    ));
    const with_empty = [_]u32{ 1, 2, 3, 4, 5, 6, 7, Family.empty_key };
    try std.testing.expectError(error.EmptyKey, plan.build(
        scratch,
        slots,
        &with_empty,
        1,
        null,
    ));
}

test "Highway generic Cuckoo build plan rejects overlap unsupported epsilon and no attempts" {
    const Family = simd.cuckoo.DefaultCuckoo;
    const keys = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const plan = try Family.BuildPlan.inspect(keys.len, 0.25);
    var scratch: [65]u32 = undefined;
    var aliased: [16]u32 = undefined;
    @memcpy(aliased[0..keys.len], &keys);
    try std.testing.expectError(error.InputOutputOverlap, plan.build(
        &scratch,
        &aliased,
        aliased[0..keys.len],
        1,
        null,
    ));
    try std.testing.expectError(error.InputOutputOverlap, plan.build(
        &scratch,
        scratch[0..plan.slots_len],
        &keys,
        1,
        null,
    ));
    const unsupported = try Family.BuildPlan.inspect(keys.len, 0.20);
    try std.testing.expectError(
        error.UnsupportedEpsilon,
        unsupported.build(&.{}, &.{}, &keys, 1, null),
    );
    var slots: [16]u32 = undefined;
    var stats: CuckooBuildStats = .{};
    try std.testing.expectError(
        error.BuildFailed,
        plan.build(&scratch, &slots, &keys, 0, &stats),
    );
    try std.testing.expect(!stats.success);
    try std.testing.expectEqual(@as(u32, 0), stats.attempts);
}

test "Highway generic Cuckoo builder represents the empty set" {
    const Family = simd.cuckoo.DefaultCuckoo;
    const plan = try Family.BuildPlan.inspect(0, 0.25);
    var scratch: [17]u32 = undefined;
    var slots: [16]u32 = undefined;
    var stats: CuckooBuildStats = .{};
    const table = try plan.build(&scratch, &slots, &.{}, 1, &stats);
    try std.testing.expect(table.isEmpty());
    try std.testing.expect(stats.success);
    try std.testing.expectEqual(@as(u32, 1), stats.attempts);
    try std.testing.expectEqual(@as(u32, 0), stats.num_primary);
    for (table.slots()) |slot| try std.testing.expectEqual(Family.empty_key, slot);
}

const family_test_key_count: usize = 1000;
const family_test_scratch_count: usize = 10_096;
const family_test_slot_count: usize = 2048;

var family_test_keys32: [family_test_key_count]u32 = undefined;
var family_test_keys64: [family_test_key_count]u64 = undefined;
var family_test_scratch: [family_test_scratch_count]u32 = undefined;
var family_test_slots32: [family_test_slot_count]u32 = undefined;
var family_test_slots64: [family_test_slot_count]u64 = undefined;

fn expectFamilyBuild(
    comptime Family: type,
    keys: []Family.Key,
    scratch: []u32,
    slots: []Family.Key,
    epsilon: f64,
) !void {
    for (keys, 0..) |*key, key_index| {
        key.* = @as(Family.Key, @intCast(key_index)) *% 37 +% 1;
    }
    const plan = try Family.BuildPlan.inspect(keys.len, epsilon);
    try std.testing.expect(plan.scratch_len <= scratch.len);
    try std.testing.expect(plan.slots_len <= slots.len);
    var stats: CuckooBuildStats = .{};
    const table = try plan.build(scratch, slots, keys, 200, &stats);
    try std.testing.expect(stats.success);
    try std.testing.expectEqual(keys.len, table.config.num_keys);
    for (keys) |key| try std.testing.expect(table.queryOne(key));
}

test "Highway generic Cuckoo builder supports upstream bucket sizes and u64 keys" {
    inline for ([_]usize{ 1, 2, 4, 8, 16, 32 }) |bucket_size| {
        const Family = simd.cuckoo.CuckooFamily(simd.hash.WeakTwoMul, bucket_size, 1);
        try expectFamilyBuild(
            Family,
            &family_test_keys32,
            &family_test_scratch,
            &family_test_slots32,
            0.75,
        );
    }
    const Wide = simd.cuckoo.CuckooFamily(simd.hash.Moremur, 16, 1);
    try expectFamilyBuild(
        Wide,
        &family_test_keys64,
        &family_test_scratch,
        &family_test_slots64,
        0.05,
    );
}

const default_test_max_keys: usize = 10_000;
const default_test_scratch_count: usize = 77_408;
const default_test_slot_count: usize = 16_384;

var default_test_keys: [default_test_max_keys]u32 = undefined;
var default_test_scratch: [default_test_scratch_count]u32 = undefined;
var default_test_slots: [default_test_slot_count]u32 = undefined;

fn expectDefaultBuild(key_count: usize, epsilon: f64) !void {
    const keys = default_test_keys[0..key_count];
    const engine = random.AesCtrEngine.initDeterministic();
    const permutation = simd.hash.Triple32.initSeed(&engine, 0);
    for (keys, 0..) |*key, key_index| {
        key.* = permutation.hash(@intCast(key_index));
        if (key.* == simd.DefaultCuckoo.empty_key) key.* = 0;
    }
    const scratch_len = try simd.cuckooScratchLen(key_count, epsilon, .hopcroft_karp);
    const slots_len = try simd.cuckooSlotsLen(key_count, epsilon);
    try std.testing.expect(scratch_len <= default_test_scratch.len);
    try std.testing.expect(slots_len <= default_test_slots.len);
    var stats: CuckooBuildStats = .{};
    const table = try simd.buildCuckoo(
        default_test_scratch[0..scratch_len],
        default_test_slots[0..slots_len],
        keys,
        epsilon,
        200,
        .hopcroft_karp,
        &stats,
    );
    try std.testing.expect(stats.success);
    try std.testing.expect(stats.attempts >= 1);
    try std.testing.expect(stats.attempts <= 200);
    try std.testing.expectEqual(scratch_len, table.config.num_keys * 6 +
        table.config.num_slots + table.config.num_buckets);
    for (keys) |key| try std.testing.expect(table.queryOne(key));
}

test "Highway generic Cuckoo top-level builder covers upstream sizes and epsilons" {
    try expectDefaultBuild(100, 0.25);
    try expectDefaultBuild(10_000, 0.25);
    for ([_]f64{ 0.01, 0.05, 0.10, 0.25, 0.50, 0.75 }) |epsilon| {
        try expectDefaultBuild(1000, epsilon);
    }
}
