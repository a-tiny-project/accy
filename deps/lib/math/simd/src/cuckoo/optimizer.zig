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
            if (config.num_keys >= std.math.maxInt(i32)) return error.CapacityExceeded;
            _ = try breadthFirstStepLimit(config);
            _ = try depthFirstStepLimit(Family, config);
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
            var optimizer = try Optimizer(Family).init(self.config, scratch);
            const engine = random.AesCtrEngine.initDeterministic();
            for (0..@as(usize, max_attempts)) |attempt_index| {
                const attempt: u32 = @intCast(attempt_index);
                const primary = Family.Hash.initSeed(&engine, @as(u64, attempt) * 2);
                const secondary = Family.Hash.initSeed(&engine, @as(u64, attempt) * 2 + 1);
                if (!try optimizer.build(keys, primary, secondary, stats)) continue;
                const table = try optimizer.take(keys, slots);
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
            var optimizer = try Optimizer(Family).init(self.config, scratch);
            if (!try optimizer.build(keys, hash_primary, hash_secondary, stats)) {
                if (stats) |build_stats| build_stats.attempts = 1;
                return error.BuildFailed;
            }
            const table = try optimizer.take(keys, slots);
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

pub fn Optimizer(comptime Family: type) type {
    return struct {
        base: matching.Builder(Family),
        cost_l: []u32,
        layer_r: []u32,
        cost_r: []u32,
        visited_r: []u8,
        prim_offset: []u32,
        sec_offset: []u32,
        frontier_l: []u32,
        frontier_r: []u32,
        targets_r: []u32,
        path_counts: []u32,
        breadth_first_step_limit: usize,
        depth_first_step_limit: usize,
        path_counts_len: usize = 0,

        const Self = @This();
        const unmatched: u32 = std.math.maxInt(u32);
        const pending = @as(u32, 1) << 31;
        const cost_mask = pending - 1;
        const inf_cost: u32 = 1_000_000;

        pub fn init(
            config: Family.Config,
            scratch: []u32,
        ) matching.CuckooBuildError!Self {
            if (config.num_keys >= std.math.maxInt(i32)) return error.CapacityExceeded;
            const required = try scratchLength(Family, config);
            if (scratch.len < required) return error.ScratchTooSmall;
            const base_len = try matching.scratchLength(Family, config);
            var offset = base_len;
            const cost_l = matching.takeWords(scratch, &offset, config.num_keys);
            const layer_r = matching.takeWords(scratch, &offset, config.num_slots);
            const cost_r = matching.takeWords(scratch, &offset, config.num_slots);
            const visited_words = matching.takeWords(
                scratch,
                &offset,
                visitedWordLength(config.num_slots),
            );
            const visited_r = std.mem.sliceAsBytes(visited_words)[0..config.num_slots];
            const prim_offset = matching.takeWords(
                scratch,
                &offset,
                config.num_buckets + 1,
            );
            const sec_offset = matching.takeWords(
                scratch,
                &offset,
                config.num_buckets + 1,
            );
            const frontier_l = matching.takeWords(scratch, &offset, config.num_keys);
            const frontier_r = matching.takeWords(scratch, &offset, config.num_slots);
            const targets_r = matching.takeWords(scratch, &offset, config.num_slots);
            const path_counts = matching.takeWords(scratch, &offset, config.num_keys + 1);
            std.debug.assert(offset == required);
            std.debug.assert(config.num_slots > config.num_keys);
            return .{
                .base = try matching.Builder(Family).init(config, scratch[0..base_len]),
                .cost_l = cost_l,
                .layer_r = layer_r,
                .cost_r = cost_r,
                .visited_r = visited_r,
                .prim_offset = prim_offset,
                .sec_offset = sec_offset,
                .frontier_l = frontier_l,
                .frontier_r = frontier_r,
                .targets_r = targets_r,
                .path_counts = path_counts,
                .breadth_first_step_limit = try breadthFirstStepLimit(config),
                .depth_first_step_limit = try depthFirstStepLimit(Family, config),
            };
        }

        pub fn build(
            self: *Self,
            keys: []const Family.Key,
            hash_primary: Family.Hash,
            hash_secondary: Family.Hash,
            stats: ?*matching.CuckooBuildStats,
        ) matching.CuckooBuildError!bool {
            @memset(self.path_counts, 0);
            self.path_counts_len = 0;
            if (stats) |build_stats| build_stats.paths_per_path_cost = &.{};
            var matching_size = try self.base.prepare(
                keys,
                hash_primary,
                hash_secondary,
                stats,
            );
            if (matching_size == self.base.config.num_keys) {
                self.base.matched = true;
                return true;
            }
            self.buildGraph();
            for (0..self.base.config.num_keys) |cost_index| {
                const path_cost: u32 = @intCast(cost_index + 1);
                var found_for_cost = true;
                for (0..self.base.config.num_keys + 1) |_| {
                    if (!found_for_cost or matching_size == self.base.config.num_keys) break;
                    const target_count = self.breadthFirst(path_cost);
                    if (target_count == 0) break;
                    @memset(self.visited_r, 0);
                    var paths_found: u32 = 0;
                    for (self.targets_r[0..target_count]) |target| {
                        if (self.visited_r[target] != 0) continue;
                        if (!self.depthFirst(target)) continue;
                        matching_size += 1;
                        paths_found += 1;
                    }
                    found_for_cost = paths_found != 0;
                    self.recordPathCost(path_cost, paths_found, stats);
                }
                if (matching_size == self.base.config.num_keys) break;
            }
            self.base.matched = matching_size == self.base.config.num_keys;
            self.publishPathCosts(stats);
            return self.base.matched;
        }

        pub fn take(
            self: Self,
            keys: []const Family.Key,
            slots: []Family.Key,
        ) matching.CuckooBuildError!Family.Table {
            return self.base.take(keys, slots);
        }

        fn buildGraph(self: *Self) void {
            @memset(self.prim_offset, 0);
            @memset(self.sec_offset, 0);
            for (self.base.primary_bucket, self.base.secondary_bucket) |primary, secondary| {
                self.prim_offset[@as(usize, primary) + 1] += 1;
                if (primary != secondary) {
                    self.sec_offset[@as(usize, secondary) + 1] += 1;
                }
            }
            for (0..self.base.config.num_buckets) |bucket| {
                self.prim_offset[bucket + 1] += self.prim_offset[bucket];
                self.sec_offset[bucket + 1] += self.sec_offset[bucket];
            }
            @memset(self.base.bucket_fill, 0);
            for (self.base.primary_bucket, 0..) |bucket, key_index| {
                const bucket_index: usize = bucket;
                const target = self.prim_offset[bucket_index] +
                    self.base.bucket_fill[bucket_index];
                self.base.queue[target] = @intCast(key_index);
                self.base.bucket_fill[bucket_index] += 1;
            }
            @memset(self.base.bucket_fill, 0);
            for (
                self.base.primary_bucket,
                self.base.secondary_bucket,
                0..,
            ) |primary, secondary, key_index| {
                if (primary == secondary) continue;
                const bucket_index: usize = secondary;
                const target = self.sec_offset[bucket_index] +
                    self.base.bucket_fill[bucket_index];
                self.base.cursor[target] = @intCast(key_index);
                self.base.bucket_fill[bucket_index] += 1;
            }
        }

        fn breadthFirst(self: *Self, path_cost: u32) usize {
            @memset(self.base.dist, unmatched);
            @memset(self.layer_r, unmatched);
            @memset(self.cost_l, inf_cost);
            @memset(self.cost_r, inf_cost);
            @memset(self.visited_r, 0);
            var left_count: usize = 0;
            for (self.base.match_key_to_slot, 0..) |slot, key_index| {
                if (slot != unmatched) continue;
                self.base.dist[key_index] = 0;
                self.cost_l[key_index] = pending;
                self.frontier_l[left_count] = @intCast(key_index);
                left_count += 1;
            }
            var right_count: usize = 0;
            var target_count: usize = 0;
            var target_layer = unmatched;
            for (0..self.breadth_first_step_limit) |_| {
                if (left_count == 0) {
                    std.debug.assert(right_count == 0);
                    return target_count;
                }
                const current_left_count = left_count;
                left_count = 0;
                for (self.frontier_l[0..current_left_count]) |key_index| {
                    self.cost_l[key_index] &= cost_mask;
                    const current_layer = self.base.dist[key_index];
                    const current_cost = self.cost_l[key_index];
                    if (target_layer != unmatched and current_layer >= target_layer) continue;
                    std.debug.assert(current_layer < unmatched);
                    std.debug.assert(current_cost < cost_mask);
                    const new_layer = current_layer + 1;
                    const primary = self.base.primary_bucket[key_index];
                    self.relaxBucket(
                        key_index,
                        primary,
                        new_layer,
                        current_cost,
                        path_cost,
                        &right_count,
                        &target_count,
                        &target_layer,
                    );
                    const secondary = self.base.secondary_bucket[key_index];
                    if (primary == secondary) continue;
                    self.relaxBucket(
                        key_index,
                        secondary,
                        new_layer,
                        current_cost + 1,
                        path_cost,
                        &right_count,
                        &target_count,
                        &target_layer,
                    );
                }
                if (right_count == 0) return target_count;
                const current_right_count = right_count;
                right_count = 0;
                for (self.frontier_r[0..current_right_count]) |slot_index| {
                    self.cost_r[slot_index] &= cost_mask;
                    const current_layer = self.layer_r[slot_index];
                    const current_cost = self.cost_r[slot_index];
                    if (target_layer != unmatched and current_layer >= target_layer) continue;
                    const matched_left = self.base.match_slot_to_key[slot_index];
                    if (matched_left == unmatched) continue;
                    const bucket: u32 = @intCast(slot_index / Family.bucket_size);
                    const secondary_edge = bucket == self.base.secondary_bucket[matched_left] and
                        self.base.primary_bucket[matched_left] !=
                            self.base.secondary_bucket[matched_left];
                    if (secondary_edge and current_cost == 0) continue;
                    const new_cost = current_cost - @intFromBool(secondary_edge);
                    const old_cost = self.cost_l[matched_left] & cost_mask;
                    if (self.base.dist[matched_left] != unmatched and new_cost >= old_cost) {
                        continue;
                    }
                    std.debug.assert(current_layer < unmatched);
                    self.base.dist[matched_left] = current_layer + 1;
                    const already_pending = self.cost_l[matched_left] & pending != 0;
                    self.cost_l[matched_left] = new_cost | pending;
                    if (already_pending) continue;
                    std.debug.assert(left_count < self.frontier_l.len);
                    self.frontier_l[left_count] = matched_left;
                    left_count += 1;
                }
            }
            std.debug.assert(false);
            return target_count;
        }

        fn relaxBucket(
            self: *Self,
            key_index: u32,
            bucket: u32,
            new_layer: u32,
            new_cost: u32,
            path_cost: u32,
            right_count: *usize,
            target_count: *usize,
            target_layer: *u32,
        ) void {
            const base_slot = @as(usize, bucket) * Family.bucket_size;
            for (base_slot..base_slot + Family.bucket_size) |slot| {
                if (self.base.match_key_to_slot[key_index] == slot) continue;
                const old_cost = self.cost_r[slot] & cost_mask;
                if (self.layer_r[slot] != unmatched and new_cost >= old_cost) continue;
                self.layer_r[slot] = new_layer;
                if (self.base.match_slot_to_key[slot] == unmatched) {
                    self.cost_r[slot] = new_cost;
                    if (new_cost != path_cost) continue;
                    if (target_layer.* == unmatched) target_layer.* = new_layer;
                    if (new_layer != target_layer.* or self.visited_r[slot] != 0) continue;
                    std.debug.assert(target_count.* < self.targets_r.len);
                    self.visited_r[slot] = 1;
                    self.targets_r[target_count.*] = @intCast(slot);
                    target_count.* += 1;
                    continue;
                }
                const already_pending = self.cost_r[slot] & pending != 0;
                self.cost_r[slot] = new_cost | pending;
                if (already_pending) continue;
                std.debug.assert(right_count.* < self.frontier_r.len);
                self.frontier_r[right_count.*] = @intCast(slot);
                right_count.* += 1;
            }
        }

        fn depthFirst(self: *Self, root: u32) bool {
            std.debug.assert(self.base.match_slot_to_key[root] == unmatched);
            self.visited_r[root] = 1;
            var depth: usize = 1;
            self.frontier_r[0] = root;
            self.frontier_l[0] = 0;
            for (0..self.depth_first_step_limit) |_| {
                const frame = depth - 1;
                const slot = self.frontier_r[frame];
                const bucket = @as(usize, slot) / Family.bucket_size;
                const primary_count = self.prim_offset[bucket + 1] -
                    self.prim_offset[bucket];
                const secondary_count = self.sec_offset[bucket + 1] -
                    self.sec_offset[bucket];
                const edge_index = self.frontier_l[frame];
                if (edge_index == primary_count + secondary_count) {
                    if (depth == 1) return false;
                    const failed_slot = slot;
                    depth -= 1;
                    const parent_slot = self.frontier_r[depth - 1];
                    const moved_key = self.base.match_slot_to_key[parent_slot];
                    std.debug.assert(moved_key != unmatched);
                    std.debug.assert(self.base.match_key_to_slot[moved_key] == parent_slot);
                    std.debug.assert(self.base.match_slot_to_key[failed_slot] == unmatched);
                    self.base.match_key_to_slot[moved_key] = failed_slot;
                    self.base.match_slot_to_key[failed_slot] = moved_key;
                    self.base.match_slot_to_key[parent_slot] = unmatched;
                    continue;
                }
                self.frontier_l[frame] += 1;
                const primary_edge = edge_index < primary_count;
                const key_index = if (primary_edge)
                    self.base.queue[self.prim_offset[bucket] + edge_index]
                else
                    self.base.cursor[
                        self.sec_offset[bucket] + edge_index - primary_count
                    ];
                const right_layer = self.layer_r[slot];
                if (right_layer == 0 or self.base.dist[key_index] != right_layer - 1) {
                    continue;
                }
                if (depth > 1) {
                    const parent_slot = self.frontier_r[frame - 1];
                    if (self.base.match_slot_to_key[parent_slot] == key_index) continue;
                } else if (self.base.match_key_to_slot[key_index] == slot) {
                    continue;
                }
                const edge_cost: u32 = @intFromBool(!primary_edge);
                if ((self.cost_l[key_index] & cost_mask) + edge_cost !=
                    (self.cost_r[slot] & cost_mask))
                {
                    continue;
                }
                const old_slot = self.base.match_key_to_slot[key_index];
                if (old_slot == unmatched) {
                    self.base.match_key_to_slot[key_index] = slot;
                    self.base.match_slot_to_key[slot] = key_index;
                    return true;
                }
                if (self.visited_r[old_slot] != 0 or self.layer_r[old_slot] == unmatched) {
                    continue;
                }
                std.debug.assert(self.base.match_slot_to_key[slot] == unmatched);
                self.base.match_key_to_slot[key_index] = slot;
                self.base.match_slot_to_key[slot] = key_index;
                self.base.match_slot_to_key[old_slot] = unmatched;
                self.visited_r[old_slot] = 1;
                std.debug.assert(depth < self.frontier_l.len);
                std.debug.assert(depth < self.frontier_r.len);
                self.frontier_r[depth] = old_slot;
                self.frontier_l[depth] = 0;
                depth += 1;
            }
            std.debug.assert(false);
            return false;
        }

        fn recordPathCost(
            self: *Self,
            path_cost: u32,
            paths_found: u32,
            stats: ?*matching.CuckooBuildStats,
        ) void {
            if (paths_found == 0) return;
            const build_stats = stats orelse return;
            if (!build_stats.collect_path_cost_stats) return;
            self.path_counts[path_cost] += paths_found;
            self.path_counts_len = @max(self.path_counts_len, @as(usize, path_cost) + 1);
            build_stats.paths_per_path_cost = self.path_counts[0..self.path_counts_len];
        }

        fn publishPathCosts(self: Self, stats: ?*matching.CuckooBuildStats) void {
            const build_stats = stats orelse return;
            if (!build_stats.collect_path_cost_stats) return;
            build_stats.paths_per_path_cost = self.path_counts[0..self.path_counts_len];
        }
    };
}

pub fn scratchLength(
    comptime Family: type,
    config: Family.Config,
) matching.CuckooBuildError!usize {
    var words = try matching.scratchLength(Family, config);
    try addWords(&words, config.num_keys);
    try addWords(&words, config.num_slots);
    try addWords(&words, config.num_slots);
    try addWords(&words, visitedWordLength(config.num_slots));
    const offsets = std.math.add(usize, config.num_buckets, 1) catch
        return error.CapacityExceeded;
    try addWords(&words, offsets);
    try addWords(&words, offsets);
    try addWords(&words, config.num_keys);
    try addWords(&words, config.num_slots);
    try addWords(&words, config.num_slots);
    const path_counts = std.math.add(usize, config.num_keys, 1) catch
        return error.CapacityExceeded;
    try addWords(&words, path_counts);
    return words;
}

fn addWords(words: *usize, additional: usize) matching.CuckooBuildError!void {
    words.* = std.math.add(usize, words.*, additional) catch
        return error.CapacityExceeded;
}

fn visitedWordLength(num_slots: usize) usize {
    return std.math.divCeil(usize, num_slots, @sizeOf(u32)) catch unreachable;
}

fn breadthFirstStepLimit(
    config: anytype,
) matching.CuckooBuildError!usize {
    const nodes = std.math.add(usize, config.num_keys, config.num_slots) catch
        return error.CapacityExceeded;
    const cost_states = std.math.add(usize, config.num_keys, 2) catch
        return error.CapacityExceeded;
    const relaxations = std.math.mul(usize, nodes, cost_states) catch
        return error.CapacityExceeded;
    return std.math.add(usize, relaxations, 1) catch return error.CapacityExceeded;
}

fn depthFirstStepLimit(
    comptime Family: type,
    config: Family.Config,
) matching.CuckooBuildError!usize {
    const key_edges = std.math.mul(usize, config.num_keys, Family.bucket_size * 2) catch
        return error.CapacityExceeded;
    const with_pops = std.math.add(usize, key_edges, config.num_slots) catch
        return error.CapacityExceeded;
    return std.math.add(usize, with_pops, 1) catch return error.CapacityExceeded;
}

fn expectOptimizedFamily(comptime Family: type) !void {
    const key_count = 64;
    var keys: [key_count]Family.Key = undefined;
    for (&keys, 0..) |*key, key_index| {
        key.* = @as(Family.Key, @intCast(key_index)) *% 37 +% 1;
    }
    const plan = try Family.OptimizedBuildPlan.inspect(key_count, 0.01);
    const allocator = std.testing.allocator;
    const scratch = try allocator.alloc(u32, plan.scratch_len);
    defer allocator.free(scratch);
    const slots = try allocator.alloc(Family.Key, plan.slots_len);
    defer allocator.free(slots);
    var stats: matching.CuckooBuildStats = .{ .collect_path_cost_stats = true };
    const table = try plan.build(scratch, slots, &keys, 200, &stats);
    try std.testing.expect(stats.success);
    try std.testing.expectEqual(key_count, table.config.num_keys);
    for (keys) |key| try std.testing.expect(table.queryOne(key));
}
