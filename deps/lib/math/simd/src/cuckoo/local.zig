const std = @import("std");
const matching = @import("builder.zig");
const simd = @import("../root.zig");

const random = simd.random;

pub fn Plan(comptime Family: type) type {
    return struct {
        config: Family.Config,
        scratch_len: usize,
        slots_len: usize,

        const Self = @This();

        pub fn inspect(num_keys: usize, epsilon: f64) matching.CuckooBuildError!Self {
            const config = Family.Config.init(num_keys, epsilon) catch |err| return err;
            _ = try moveLimit(config);
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
            stats: ?*matching.CuckooBuildStats,
        ) matching.CuckooBuildError!Family.Table {
            matching.resetStats(stats);
            if (!matching.supportedEpsilon(self.config.epsilon)) {
                return error.UnsupportedEpsilon;
            }
            try self.validateBuffers(scratch, slots, keys);
            try matching.validateKeys(Family, slots, keys);
            var search = try Search(Family).init(self.config, scratch);
            const engine = random.AesCtrEngine.initDeterministic();
            for (0..@as(usize, max_attempts)) |attempt_index| {
                const attempt: u32 = @intCast(attempt_index);
                const primary = Family.Hash.initSeed(&engine, @as(u64, attempt) * 2);
                const secondary = Family.Hash.initSeed(&engine, @as(u64, attempt) * 2 + 1);
                if (!try search.build(keys, primary, secondary, stats)) continue;
                const table = try search.take(keys, slots);
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
            stats: ?*matching.CuckooBuildStats,
        ) matching.CuckooBuildError!Family.Table {
            matching.resetStats(stats);
            try self.validateBuffers(scratch, slots, keys);
            try matching.validateKeys(Family, slots, keys);
            var search = try Search(Family).init(self.config, scratch);
            if (!try search.build(keys, hash_primary, hash_secondary, stats)) {
                if (stats) |build_stats| build_stats.attempts = 1;
                return error.BuildFailed;
            }
            const table = try search.take(keys, slots);
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
        ) matching.CuckooBuildError!void {
            if (keys.len != self.config.num_keys) return error.PlanMismatch;
            if (scratch.len < self.scratch_len) return error.ScratchTooSmall;
            if (slots.len < self.slots_len) return error.SlotsTooSmall;
            if (matching.storageOverlaps(u32, scratch, Family.Key, slots) or
                matching.storageOverlaps(u32, scratch, Family.Key, keys))
            {
                return error.InputOutputOverlap;
            }
        }
    };
}

pub fn Search(comptime Family: type) type {
    return struct {
        base: matching.Placement(Family),
        labels: []u32,
        move_limit: usize,
        moves_used: usize = 0,

        const Self = @This();
        const unmatched = std.math.maxInt(u32);

        pub fn init(
            config: Family.Config,
            scratch: []u32,
        ) matching.CuckooBuildError!Self {
            const base_len = try matching.placementScratchLength(config);
            const required = try scratchLength(Family, config);
            if (scratch.len < required) return error.ScratchTooSmall;
            return .{
                .base = try matching.Placement(Family).init(config, scratch[0..base_len]),
                .labels = scratch[base_len..required],
                .move_limit = try moveLimit(config),
            };
        }

        pub fn build(
            self: *Self,
            keys: []const Family.Key,
            hash_primary: Family.Hash,
            hash_secondary: Family.Hash,
            stats: ?*matching.CuckooBuildStats,
        ) matching.CuckooBuildError!bool {
            const matching_size = try self.base.prepare(
                keys,
                hash_primary,
                hash_secondary,
                stats,
            );
            return self.complete(matching_size);
        }

        pub fn take(
            self: Self,
            keys: []const Family.Key,
            slots: []Family.Key,
        ) matching.CuckooBuildError!Family.Table {
            return self.base.take(keys, slots);
        }

        fn complete(self: *Self, initial_matching_size: usize) bool {
            var matching_size = initial_matching_size;
            self.moves_used = 0;
            if (matching_size == self.base.config.num_keys) {
                self.base.matched = true;
                return true;
            }
            @memset(self.labels, 0);
            const engine = random.AesCtrEngine.initDeterministic();
            var rng = random.RngStream.init(&engine, 0);
            const max_label: u32 = if (self.base.config.num_buckets > 1)
                @intCast(self.base.config.num_buckets - 1)
            else
                1;
            for (self.base.match_key_to_slot, 0..) |slot, initial_key| {
                if (slot != unmatched) continue;
                var current_key: u32 = @intCast(initial_key);
                var placed = false;
                const remaining = self.move_limit - self.moves_used;
                for (0..remaining) |_| {
                    self.moves_used += 1;
                    if (self.moves_used >= self.move_limit) {
                        self.base.matched = false;
                        return false;
                    }
                    const primary = self.base.primary_bucket[current_key];
                    const secondary = self.base.secondary_bucket[current_key];
                    const selected = if (self.labels[primary] <= self.labels[secondary])
                        primary
                    else
                        secondary;
                    const alternate = if (selected == primary) secondary else primary;
                    if (self.labels[selected] >= max_label) {
                        self.base.matched = false;
                        return false;
                    }
                    if (self.base.bucket_fill[selected] == Family.bucket_size) {
                        self.labels[selected] = self.labels[alternate] +% 1;
                        const within_bucket: usize = @intCast(
                            rng.next() & (Family.bucket_size - 1),
                        );
                        const selected_slot: u32 = @intCast(
                            @as(usize, selected) * Family.bucket_size + within_bucket,
                        );
                        const evicted_key = self.base.match_slot_to_key[selected_slot];
                        std.debug.assert(evicted_key != unmatched);
                        self.base.match_key_to_slot[current_key] = selected_slot;
                        self.base.match_slot_to_key[selected_slot] = current_key;
                        current_key = evicted_key;
                    } else {
                        const selected_slot: u32 = @intCast(
                            @as(usize, selected) * Family.bucket_size +
                                self.base.bucket_fill[selected],
                        );
                        self.base.match_key_to_slot[current_key] = selected_slot;
                        self.base.match_slot_to_key[selected_slot] = current_key;
                        self.base.bucket_fill[selected] += 1;
                        matching_size += 1;
                        placed = true;
                        break;
                    }
                }
                if (!placed) {
                    self.base.matched = false;
                    return false;
                }
            }
            self.base.matched = matching_size == self.base.config.num_keys;
            return self.base.matched;
        }
    };
}

pub fn scratchLength(
    comptime Family: type,
    config: Family.Config,
) matching.CuckooBuildError!usize {
    const base_len = try matching.placementScratchLength(config);
    return std.math.add(usize, base_len, config.num_buckets) catch
        return error.CapacityExceeded;
}

fn moveLimit(config: anytype) matching.CuckooBuildError!usize {
    const moves = std.math.mul(usize, config.num_keys, 128) catch
        return error.CapacityExceeded;
    return std.math.add(usize, moves, 10_000) catch
        return error.CapacityExceeded;
}

test "Highway Cuckoo local search builds a deterministic complete table" {
    const Family = simd.cuckoo.DefaultCuckoo;
    const key_count = 1000;
    var keys: [key_count]u32 = undefined;
    const engine = random.AesCtrEngine.initDeterministic();
    const permutation = simd.hash.Triple32.initSeed(&engine, 0);
    for (&keys, 0..) |*key, key_index| {
        key.* = permutation.hash(@intCast(key_index));
        if (key.* == Family.empty_key) key.* = 0;
    }
    const plan = try Family.LocalBuildPlan.inspect(key_count, 0.01);
    try std.testing.expectEqual(
        plan.scratch_len,
        try simd.cuckooScratchLen(key_count, 0.01, .local_search),
    );
    try std.testing.expectEqual(
        plan.scratch_len,
        try simd.cuckooLocalScratchLen(key_count, 0.01),
    );
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u32, plan.scratch_len);
    defer allocator.free(scratch);
    const slots = try allocator.alloc(u32, plan.slots_len);
    defer allocator.free(slots);
    var stats: matching.CuckooBuildStats = .{};
    const table = try simd.buildCuckoo(
        scratch,
        slots,
        &keys,
        0.01,
        200,
        .local_search,
        &stats,
    );
    try std.testing.expect(stats.success);
    try std.testing.expectEqual(@as(usize, 4152), plan.scratch_len);
    try std.testing.expectEqual(@as(u32, 5), stats.global_seed);
    try std.testing.expectEqual(@as(u32, 6), stats.attempts);
    try std.testing.expectEqual(@as(u32, 824), stats.num_primary);
    try std.testing.expectEqual(@as(u32, 49), stats.num_unmatched_after_greedy);
    try std.testing.expectEqual(key_count, table.config.num_keys);
    try std.testing.expectEqualSlices(u32, &.{
        2_204_921_949,
        3_998_355_989,
        516_002_367,
        1_083_786_645,
        4_141_955_862,
        3_354_481_080,
        3_234_413_303,
        2_386_997_173,
        1_855_444_431,
        3_415_148_099,
        1_016_610_487,
        973_992_494,
        3_774_922_072,
        2_997_703_244,
        4_153_830_849,
        1_343_578_915,
    }, table.slots()[0..16]);
    var digest: u64 = 1_469_598_103_934_665_603;
    for (table.slots()) |slot| digest = (digest ^ slot) *% 1_099_511_628_211;
    try std.testing.expectEqual(@as(u64, 8_004_671_006_856_570_397), digest);
    for (keys) |key| try std.testing.expect(table.queryOne(key));
}

test "Highway Cuckoo local search plans enforce caller storage" {
    const Family = simd.cuckoo.DefaultCuckoo;
    const keys = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const plan = try Family.LocalBuildPlan.inspect(keys.len, 0.25);
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
        error.InputOutputOverlap,
        plan.build(scratch, scratch[0..plan.slots_len], &keys, 1, null),
    );
    var stats: matching.CuckooBuildStats = .{};
    try std.testing.expectError(error.BuildFailed, plan.build(
        scratch,
        slots,
        &keys,
        0,
        &stats,
    ));
    try std.testing.expectEqual(@as(u32, 0), stats.attempts);
    const unsupported = try Family.LocalBuildPlan.inspect(keys.len, 0.20);
    try std.testing.expectError(
        error.UnsupportedEpsilon,
        unsupported.build(scratch, slots, &keys, 1, null),
    );
}

fn expectLocalFamily(comptime Family: type) !void {
    const key_count = 64;
    var keys: [key_count]Family.Key = undefined;
    for (&keys, 0..) |*key, key_index| {
        key.* = @as(Family.Key, @intCast(key_index)) *% 37 +% 1;
    }
    const plan = try Family.LocalBuildPlan.inspect(key_count, 0.01);
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u32, plan.scratch_len);
    defer allocator.free(scratch);
    const slots = try allocator.alloc(Family.Key, plan.slots_len);
    defer allocator.free(slots);
    var stats: matching.CuckooBuildStats = .{};
    const table = try plan.build(scratch, slots, &keys, 200, &stats);
    try std.testing.expect(stats.success);
    try std.testing.expectEqual(key_count, table.config.num_keys);
    for (keys) |key| try std.testing.expect(table.queryOne(key));
}

test "Highway Cuckoo local search supports all bucket sizes and u64 keys" {
    inline for ([_]usize{ 1, 2, 4, 8, 16, 32 }) |bucket_size| {
        const Family = simd.cuckoo.CuckooFamily(simd.hash.WeakTwoMul, bucket_size, 1);
        try expectLocalFamily(Family);
    }
    const Wide = simd.cuckoo.CuckooFamily(simd.hash.Moremur, 16, 1);
    try expectLocalFamily(Wide);
}

test "Highway Cuckoo local search handles an empty table" {
    const Family = simd.cuckoo.DefaultCuckoo;
    const plan = try Family.LocalBuildPlan.inspect(0, 0.25);
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u32, plan.scratch_len);
    defer allocator.free(scratch);
    const slots = try allocator.alloc(u32, plan.slots_len);
    defer allocator.free(slots);
    var stats: matching.CuckooBuildStats = .{};
    const table = try plan.build(scratch, slots, &.{}, 1, &stats);
    try std.testing.expect(table.isEmpty());
    try std.testing.expect(stats.success);
    try std.testing.expectEqual(@as(u32, 1), stats.attempts);
}
