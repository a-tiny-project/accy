const std = @import("std");

const entry = @import("entry.zig");

pub const max_thread_candidates: usize = 8;

pub const Grid2D = struct {
    rows: u64,
    cols: u64,
};

pub const ThreadCaps = struct {
    budget: u32,
    x_max: u32,
    y_max: u32,
    baseline_x_floor: u32 = 16,
    baseline_occupancy_numerator: u64 = 3,
    baseline_occupancy_denominator: u64 = 4,
};

pub const ThreadCandidates = struct {
    count: usize = 0,
    items: [max_thread_candidates]entry.Threads2D = @as(
        [max_thread_candidates]entry.Threads2D,
        @splat(.{}),
    ),

    pub fn slice(self: *const ThreadCandidates) []const entry.Threads2D {
        return self.items[0..self.count];
    }
};

pub fn threadsForGrid(grid: Grid2D, caps: ThreadCaps) entry.Threads2D {
    return threadCandidatesForGrid(grid, caps).items[0];
}

pub fn threadCandidatesForGrid(grid: Grid2D, caps: ThreadCaps) ThreadCandidates {
    const baseline = baselineThreadsForGrid(grid, caps);
    const ranked = rankedThreadCandidatesForGrid(grid, caps);
    const selected = if (threadOccupancyAtLeast(
        grid,
        baseline,
        caps.baseline_occupancy_numerator,
        caps.baseline_occupancy_denominator,
    ))
        baseline
    else if (ranked.count != 0)
        ranked.items[0]
    else
        baseline;

    var result = ThreadCandidates{};
    appendThreadCandidate(&result, selected);
    appendThreadCandidate(&result, baseline);
    for (ranked.slice()) |candidate| appendThreadCandidate(&result, candidate);
    return result;
}

pub fn threadCandidatesEqual(lhs: entry.Threads2D, rhs: entry.Threads2D) bool {
    return lhs.x == rhs.x and lhs.y == rhs.y;
}

fn baselineThreadsForGrid(grid: Grid2D, caps: ThreadCaps) entry.Threads2D {
    const ty: u32 = @intCast(@max(@as(u64, 1), @min(grid.rows, caps.y_max)));
    const budget = caps.budget / ty;
    const tx: u32 = @intCast(@max(
        @as(u64, 1),
        @min(grid.cols, @min(@max(@as(u64, budget), caps.baseline_x_floor), caps.x_max)),
    ));
    return .{ .x = tx, .y = ty };
}

fn rankedThreadCandidatesForGrid(grid: Grid2D, caps: ThreadCaps) ThreadCandidates {
    var candidates = ThreadCandidates{};
    var y: u32 = 1;
    while (y <= @min(@max(grid.rows, 1), caps.y_max)) : (y += 1) {
        var x: u32 = 1;
        while (x <= @min(@max(grid.cols, 1), caps.x_max)) : (x += 1) {
            if (x * y > caps.budget) continue;
            insertRankedThreadCandidate(&candidates, grid, .{ .x = x, .y = y });
        }
    }
    return candidates;
}

fn appendThreadCandidate(candidates: *ThreadCandidates, candidate: entry.Threads2D) void {
    for (candidates.slice()) |existing| {
        if (threadCandidatesEqual(existing, candidate)) return;
    }
    if (candidates.count >= max_thread_candidates) return;
    candidates.items[candidates.count] = candidate;
    candidates.count += 1;
}

fn insertRankedThreadCandidate(
    candidates: *ThreadCandidates,
    grid: Grid2D,
    candidate: entry.Threads2D,
) void {
    for (candidates.slice()) |existing| {
        if (threadCandidatesEqual(existing, candidate)) return;
    }

    var insert_index: usize = 0;
    while (insert_index < candidates.count and !threadCandidateBeats(
        grid,
        candidate,
        candidates.items[insert_index],
    )) {
        insert_index += 1;
    }
    if (insert_index >= max_thread_candidates) return;

    if (candidates.count < max_thread_candidates) candidates.count += 1;
    var index = candidates.count - 1;
    while (index > insert_index) : (index -= 1) {
        candidates.items[index] = candidates.items[index - 1];
    }
    candidates.items[insert_index] = candidate;
}

fn threadCandidateBeats(grid: Grid2D, candidate: entry.Threads2D, best: entry.Threads2D) bool {
    const candidate_score = threadScore(grid, candidate);
    const best_score = threadScore(grid, best);
    if (candidate_score.blocks != best_score.blocks) {
        return candidate_score.blocks < best_score.blocks;
    }
    if (candidate_score.waste != best_score.waste) return candidate_score.waste < best_score.waste;
    if (candidate_score.area != best_score.area) return candidate_score.area > best_score.area;
    if (candidate_score.balance != best_score.balance) {
        return candidate_score.balance < best_score.balance;
    }
    if (candidate.x != best.x) return candidate.x > best.x;
    return candidate.y > best.y;
}

const ThreadScore = struct {
    blocks: u64,
    waste: u64,
    area: u32,
    balance: u32,
};

fn threadScore(grid: Grid2D, threads: entry.Threads2D) ThreadScore {
    const grid_x = ceilDivU64(grid.cols, threads.x);
    const grid_y = ceilDivU64(grid.rows, threads.y);
    const blocks = grid_x *| grid_y;
    const launched = blocks *| threads.x *| threads.y;
    const useful = grid.rows *| grid.cols;
    return .{
        .blocks = blocks,
        .waste = launched -| useful,
        .area = threads.x * threads.y,
        .balance = if (threads.x > threads.y) threads.x - threads.y else threads.y - threads.x,
    };
}

fn threadOccupancyAtLeast(
    grid: Grid2D,
    threads: entry.Threads2D,
    numerator: u64,
    denominator: u64,
) bool {
    const grid_x = ceilDivU64(grid.cols, threads.x);
    const grid_y = ceilDivU64(grid.rows, threads.y);
    const launched = grid_x *| grid_y *| threads.x *| threads.y;
    const useful = grid.rows *| grid.cols;
    return useful *| denominator >= launched *| numerator;
}

fn ceilDivU64(numerator: u64, denominator: u32) u64 {
    return numerator / denominator + @as(u64, @intFromBool(numerator % denominator != 0));
}

const test_caps = ThreadCaps{ .budget = 256, .x_max = 64, .y_max = 16 };

fn testOccupancy(grid: Grid2D, threads: entry.Threads2D) f64 {
    const grid_x = (grid.cols + threads.x - 1) / threads.x;
    const grid_y = (grid.rows + threads.y - 1) / threads.y;
    const launched = grid_x * grid_y * threads.x * threads.y;
    return @as(f64, @floatFromInt(grid.rows * grid.cols)) / @as(f64, @floatFromInt(launched));
}

fn expectThreadCandidatesLegal(candidates: ThreadCandidates, grid: Grid2D, caps: ThreadCaps) !void {
    try std.testing.expect(candidates.count != 0);
    for (candidates.slice(), 0..) |candidate, index| {
        try std.testing.expect(candidate.x != 0);
        try std.testing.expect(candidate.y != 0);
        try std.testing.expect(candidate.x <= @min(@max(grid.cols, 1), caps.x_max));
        try std.testing.expect(candidate.y <= @min(@max(grid.rows, 1), caps.y_max));
        try std.testing.expect(candidate.x * candidate.y <= caps.budget);
        for (candidates.slice()[0..index]) |previous| {
            try std.testing.expect(!threadCandidatesEqual(previous, candidate));
        }
    }
}

pub const ThreadCaps1D = struct {
    budget: u32 = 1024,
    preferred: u32 = 256,
    lane_quantum: u32 = 32,
};

pub const Thread1DCandidates = struct {
    count: usize = 0,
    items: [max_thread_candidates]u32 = @as([max_thread_candidates]u32, @splat(0)),

    pub fn slice(self: *const Thread1DCandidates) []const u32 {
        return self.items[0..self.count];
    }
};

pub fn threadsForExtent(extent: u64, caps: ThreadCaps1D) u32 {
    return threadCandidatesForExtent(extent, caps).items[0];
}

pub fn threadCandidatesForExtent(extent: u64, caps: ThreadCaps1D) Thread1DCandidates {
    var result = Thread1DCandidates{};
    const extent_cap: u64 = @max(extent, 1);
    if (extent_cap < caps.lane_quantum) {
        insertRanked1DCandidate(&result, extent, caps, @intCast(extent_cap));
        return result;
    }
    var threads: u32 = caps.lane_quantum;
    while (threads <= caps.budget and @as(u64, threads) <= extent_cap) : (threads *= 2) {
        insertRanked1DCandidate(&result, extent, caps, threads);
    }
    if (result.count == 0) insertRanked1DCandidate(&result, extent, caps, caps.lane_quantum);
    return result;
}

fn insertRanked1DCandidate(
    candidates: *Thread1DCandidates,
    extent: u64,
    caps: ThreadCaps1D,
    candidate: u32,
) void {
    for (candidates.slice()) |existing| {
        if (existing == candidate) return;
    }

    var insert_index: usize = 0;
    while (insert_index < candidates.count and !thread1DCandidateBeats(
        extent,
        caps,
        candidate,
        candidates.items[insert_index],
    )) {
        insert_index += 1;
    }
    if (insert_index >= max_thread_candidates) return;

    if (candidates.count < max_thread_candidates) candidates.count += 1;
    var index = candidates.count - 1;
    while (index > insert_index) : (index -= 1) {
        candidates.items[index] = candidates.items[index - 1];
    }
    candidates.items[insert_index] = candidate;
}

fn thread1DCandidateBeats(extent: u64, caps: ThreadCaps1D, candidate: u32, best: u32) bool {
    const candidate_waste = lane1DWaste(extent, caps, candidate);
    const best_waste = lane1DWaste(extent, caps, best);
    if (candidate_waste != best_waste) return candidate_waste < best_waste;
    const candidate_distance = preferredDistance(candidate, caps.preferred);
    const best_distance = preferredDistance(best, caps.preferred);
    if (candidate_distance != best_distance) return candidate_distance < best_distance;
    return candidate > best;
}

fn lane1DWaste(extent: u64, caps: ThreadCaps1D, threads: u32) u64 {
    const lanes = laneRoundUp(@as(u64, threads), caps.lane_quantum);
    const blocks = ceilDivU64(@max(extent, 1), threads);
    return blocks *| lanes -| @max(extent, 1);
}

fn laneRoundUp(value: u64, quantum: u32) u64 {
    return ceilDivU64(value, quantum) *| quantum;
}

fn preferredDistance(threads: u32, preferred: u32) u32 {
    return if (threads > preferred) threads - preferred else preferred - threads;
}

const test_caps_1d = ThreadCaps1D{};
