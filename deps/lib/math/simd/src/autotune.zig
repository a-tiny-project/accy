const std = @import("std");

pub const CostDistribution = struct {
    num_values: usize = 0,
    pointer_padding: [8 - @sizeOf(usize)]u8 = @splat(0),
    online_n: f64 = 0,
    values: [max_values]f64 = @splat(0),

    pub const max_values: usize = 14;

    const m1_index: usize = 0;
    const m2_index: usize = 1;
    const mean_index: usize = 2;
    const standard_deviation_index: usize = 3;
    const lower_index: usize = 4;
    const upper_index: usize = 5;

    pub fn notify(self: *@This(), value: f64) void {
        if (value < 0) return;
        if (self.isOnline()) {
            self.onlineNotify(value);
            return;
        }
        std.debug.assert(self.num_values < max_values);
        self.values[self.num_values] = value;
        self.num_values += 1;
        if (self.num_values == max_values) self.warmUpOnline();
    }

    pub fn estimateCost(self: *@This()) f64 {
        std.debug.assert(self.num_values != 0);
        if (!self.isOnline()) self.warmUpOnline();
        return self.mean();
    }

    pub fn isOnline(self: *const @This()) bool {
        return self.online_n > 0;
    }

    pub fn bufferedCount(self: *const @This()) usize {
        return self.num_values;
    }

    pub fn onlineCount(self: *const @This()) f64 {
        return self.online_n;
    }

    pub fn m1(self: *const @This()) f64 {
        return self.values[m1_index];
    }

    pub fn m2(self: *const @This()) f64 {
        return self.values[m2_index];
    }

    pub fn mean(self: *const @This()) f64 {
        return self.values[mean_index];
    }

    pub fn standardDeviation(self: *const @This()) f64 {
        return self.values[standard_deviation_index];
    }

    pub fn lower(self: *const @This()) f64 {
        return self.values[lower_index];
    }

    pub fn upper(self: *const @This()) f64 {
        return self.values[upper_index];
    }

    fn median(to_sort: []f64) f64 {
        std.debug.assert(to_sort.len >= 2);
        std.mem.sort(f64, to_sort, {}, std.sort.asc(f64));
        const middle = to_sort.len / 2;
        if (to_sort.len % 2 != 0) return to_sort[middle];
        return (to_sort[middle] + to_sort[middle - 1]) * 0.5;
    }

    fn medianAbsoluteDeviation(values: []const f64, median_value: f64) f64 {
        var deviations: [max_values]f64 = undefined;
        for (values, deviations[0..values.len]) |value, *deviation| {
            deviation.* = @abs(value - median_value);
        }
        return median(deviations[0..values.len]);
    }

    fn removeOutliers(self: *@This()) void {
        if (self.num_values < 3) return;
        std.debug.assert(self.num_values <= max_values);
        const active = self.values[0..self.num_values];
        const median_value = median(active);
        const mad = medianAbsoluteDeviation(active, median_value);
        if (mad == 0) {
            const skewness = (active[active.len - 1] - median_value) -
                (median_value - active[0]);
            const trim = @max(self.num_values / 2, 2);
            const left = @max(if (skewness < 0) trim * 3 / 4 else trim / 4, 1);
            self.num_values -= trim;
            std.debug.assert(self.num_values >= 1);
            std.mem.copyForwards(
                f64,
                self.values[0..self.num_values],
                self.values[left .. left + self.num_values],
            );
            return;
        }

        const upper_bound = median_value + 5 * mad;
        const lower_bound = median_value - 5 * mad;
        var right = self.num_values - 1;
        while (self.values[right] > upper_bound) right -= 1;
        std.debug.assert(right >= self.num_values / 2);
        var left: usize = 0;
        while (left < right and self.values[left] < lower_bound) left += 1;
        std.debug.assert(left <= self.num_values / 2);
        self.num_values = right - left + 1;
        std.mem.copyForwards(
            f64,
            self.values[0..self.num_values],
            self.values[left .. left + self.num_values],
        );
    }

    fn sampleMean(self: *const @This()) f64 {
        std.debug.assert(!self.isOnline());
        std.debug.assert(self.num_values != 0);
        std.debug.assert(self.num_values <= max_values);
        var sum: f64 = 0;
        for (self.values[0..self.num_values]) |value| sum += value;
        return sum / @as(f64, @floatFromInt(self.num_values));
    }

    fn sampleVariance(self: *const @This(), sample_mean: f64) f64 {
        std.debug.assert(sample_mean >= 0);
        std.debug.assert(!self.isOnline());
        std.debug.assert(self.num_values != 0);
        std.debug.assert(self.num_values <= max_values);
        if (self.num_values == 1) return 0;
        var squared_sum: f64 = 0;
        for (self.values[0..self.num_values]) |value| {
            const difference = value - sample_mean;
            squared_sum += difference * difference;
        }
        return squared_sum / @as(f64, @floatFromInt(self.num_values - 1));
    }

    fn onlineNotify(self: *@This(), unbounded_value: f64) void {
        const value = @min(@max(self.lower(), unbounded_value), self.upper());
        const n_minus_one = self.online_n;
        self.online_n += 1;
        const difference = value - self.values[m1_index];
        const difference_div_n = difference / self.online_n;
        self.values[m1_index] += difference_div_n;
        std.debug.assert(self.values[m1_index] >= self.lower());
        self.values[m2_index] += difference * n_minus_one * difference_div_n;
        const standard_deviation = @sqrt(self.values[m2_index] / @max(1, n_minus_one));
        self.values[mean_index] = self.values[m1_index] * 0.2 + self.values[mean_index] * 0.8;
        self.values[standard_deviation_index] = standard_deviation * 0.2 +
            self.values[standard_deviation_index] * 0.8;
        self.values[lower_index] = self.values[mean_index] -
            3.5 * self.values[standard_deviation_index];
        self.values[upper_index] = self.values[mean_index] +
            3.5 * self.values[standard_deviation_index];
    }

    fn warmUpOnline(self: *@This()) void {
        self.removeOutliers();
        const sample_mean = self.sampleMean();
        const sample_variance = self.sampleVariance(sample_mean);
        var copy: [max_values]f64 = undefined;
        @memcpy(copy[0..self.num_values], self.values[0..self.num_values]);
        self.values[m1_index] = 0;
        self.values[m2_index] = 0;
        self.values[mean_index] = sample_mean;
        self.values[standard_deviation_index] = @sqrt(sample_variance);
        if (self.values[standard_deviation_index] == 0) {
            self.values[standard_deviation_index] = self.values[mean_index] / 2;
        }
        self.values[lower_index] = self.values[mean_index] -
            4 * self.values[standard_deviation_index];
        self.values[upper_index] = self.values[mean_index] +
            4 * self.values[standard_deviation_index];
        for (copy[0..self.num_values]) |value| self.onlineNotify(value);
        std.debug.assert(self.isOnline());
    }
};

comptime {
    if (@sizeOf(CostDistribution) != 128) @compileError("CostDistribution must occupy 128 bytes");
}

pub fn NextWithSkip(comptime capacity: usize) type {
    comptime {
        if (capacity == 0) @compileError("NextWithSkip requires positive capacity");
        if (capacity >= Link.max_count) {
            @compileError("NextWithSkip capacity exceeds packed index range");
        }
    }

    return struct {
        links: [capacity]Link = @splat(.{}),
        count: usize = 0,

        const Self = @This();

        pub fn init(count: usize) Self {
            std.debug.assert(count != 0);
            std.debug.assert(count <= capacity);
            var self = Self{};
            self.count = count;
            for (self.links[0..count], 0..) |*link, position| {
                link.* = Link.init(position, count);
            }
            return self;
        }

        pub fn next(self: *const Self, position: usize) usize {
            std.debug.assert(position < self.count);
            std.debug.assert(!self.links[position].isRemoved());
            return self.links[position].next();
        }

        pub fn skip(self: *Self, position: usize) void {
            std.debug.assert(position < self.count);
            std.debug.assert(!self.links[position].isRemoved());
            const previous = self.links[position].previous();
            const next_position = self.links[position].next();
            if (previous == position or next_position == position) return;
            self.links[next_position].setPrevious(previous);
            self.links[previous].setNext(next_position);
            self.links[position].remove();
        }
    };
}

pub fn AutoTune(
    comptime Config: type,
    comptime max_candidates: usize,
    comptime min_samples: usize,
) type {
    comptime {
        if (min_samples < 2) @compileError("AutoTune requires at least two samples");
    }
    const CandidateList = NextWithSkip(max_candidates);

    return struct {
        best_index: ?usize = null,
        candidate_values: [max_candidates]Config = undefined,
        cost_values: [max_candidates]CostDistribution = @splat(.{}),
        candidate_count: usize = 0,
        config_index: usize = 0,
        list: CandidateList = .{},
        rounds_complete: usize = 0,
        skip_if_above: f64 = 0,

        const Self = @This();
        pub const SetCandidatesError = error{
            NoCandidates,
            TooManyCandidates,
            AlreadyConfigured,
        };

        pub fn best(self: *const Self) ?*const Config {
            const index = self.best_index orelse return null;
            return &self.candidate_values[index];
        }

        pub fn hasCandidates(self: *const Self) bool {
            return self.candidate_count != 0;
        }

        pub fn setCandidates(
            self: *Self,
            candidates_to_copy: []const Config,
        ) SetCandidatesError!void {
            if (self.hasCandidates()) return error.AlreadyConfigured;
            if (candidates_to_copy.len == 0) return error.NoCandidates;
            if (candidates_to_copy.len > max_candidates) return error.TooManyCandidates;
            @memcpy(self.candidate_values[0..candidates_to_copy.len], candidates_to_copy);
            for (self.cost_values[0..candidates_to_copy.len]) |*cost| cost.* = .{};
            self.best_index = null;
            self.candidate_count = candidates_to_copy.len;
            self.config_index = 0;
            self.list = CandidateList.init(candidates_to_copy.len);
            self.rounds_complete = 0;
            self.skip_if_above = 0;
        }

        pub fn candidates(self: *const Self) []const Config {
            std.debug.assert(self.hasCandidates());
            return self.candidate_values[0..self.candidate_count];
        }

        pub fn costs(self: *Self) []CostDistribution {
            return self.cost_values[0..self.candidate_count];
        }

        pub fn costsConst(self: *const Self) []const CostDistribution {
            return self.cost_values[0..self.candidate_count];
        }

        pub fn nextConfig(self: *const Self) *const Config {
            std.debug.assert(self.hasCandidates());
            return &self.candidate_values[self.config_index];
        }

        pub fn currentIndex(self: *const Self) usize {
            std.debug.assert(self.hasCandidates());
            return self.config_index;
        }

        pub fn completedRounds(self: *const Self) usize {
            return self.rounds_complete;
        }

        pub fn skipThreshold(self: *const Self) f64 {
            return self.skip_if_above;
        }

        pub fn notifyCost(self: *Self, cost: u64) void {
            std.debug.assert(self.best() == null);
            std.debug.assert(self.hasCandidates());
            self.cost_values[self.config_index].notify(@floatFromInt(cost));
            const measured_index = self.config_index;
            const measured_cost = if (self.rounds_complete >= min_samples)
                self.cost_values[self.config_index].estimateCost()
            else
                0;
            self.config_index = self.list.next(self.config_index);
            if (measured_cost > self.skip_if_above) self.list.skip(measured_index);
            if (self.config_index <= measured_index) {
                self.rounds_complete += 1;
                if (self.rounds_complete >= min_samples) {
                    var best_cost = std.math.inf(f64);
                    var minimum_index: usize = 0;
                    for (self.cost_values[0..self.candidate_count], 0..) |*distribution, index| {
                        const estimate = distribution.estimateCost();
                        if (estimate < best_cost) {
                            best_cost = estimate;
                            minimum_index = index;
                        }
                    }
                    self.skip_if_above = best_cost * 1.25;
                    if (self.rounds_complete == 3 * min_samples / 2 + 1) {
                        self.best_index = minimum_index;
                    }
                }
            }
        }

        pub fn shouldPrint(self: *const Self) bool {
            return self.rounds_complete > min_samples;
        }
    };
}

const Link = struct {
    bits: u32 = 0,

    const index_bits: u5 = 14;
    const shift: u5 = 18;
    const max_count: u32 = 1 << index_bits;
    const removed_mask: u32 = max_count;
    const previous_mask: u32 = max_count - 1;
    const next_clear_mask: u32 = std.math.maxInt(u32) >> index_bits;

    fn init(position: usize, count: usize) Link {
        std.debug.assert(count < max_count);
        const previous_position = if (position == 0) count - 1 else position - 1;
        const next_position = if (position == count - 1) 0 else position + 1;
        const link = Link{ .bits = @as(u32, @intCast(next_position)) << shift |
            @as(u32, @intCast(previous_position)) };
        std.debug.assert(link.next() == next_position);
        std.debug.assert(link.previous() == previous_position);
        std.debug.assert(!link.isRemoved());
        return link;
    }

    fn isRemoved(self: Link) bool {
        return self.bits & removed_mask != 0;
    }

    fn remove(self: *Link) void {
        self.bits |= removed_mask;
    }

    fn next(self: Link) usize {
        return self.bits >> shift;
    }

    fn previous(self: Link) usize {
        return self.bits & previous_mask;
    }

    fn setNext(self: *Link, next_position: usize) void {
        std.debug.assert(next_position < max_count);
        self.bits &= next_clear_mask;
        self.bits |= @as(u32, @intCast(next_position)) << shift;
        std.debug.assert(self.next() == next_position);
        std.debug.assert(!self.isRemoved());
    }

    fn setPrevious(self: *Link, previous_position: usize) void {
        std.debug.assert(previous_position < max_count);
        self.bits &= ~previous_mask;
        self.bits |= @intCast(previous_position);
        std.debug.assert(self.previous() == previous_position);
        std.debug.assert(!self.isRemoved());
    }
};

fn expectDistribution(
    distribution: *const CostDistribution,
    expected: [6]f64,
) !void {
    try std.testing.expectEqual(expected[0], distribution.m1());
    try std.testing.expectEqual(expected[1], distribution.m2());
    try std.testing.expectEqual(expected[2], distribution.mean());
    try std.testing.expectEqual(expected[3], distribution.standardDeviation());
    try std.testing.expectEqual(expected[4], distribution.lower());
    try std.testing.expectEqual(expected[5], distribution.upper());
}
