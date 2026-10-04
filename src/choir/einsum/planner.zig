const std = @import("std");
const alloc_arena = @import("alloc_arena");
const builtin = @import("builtin");
const testing = std.testing;

const spec = @import("spec.zig");

const Equation = spec.Equation;
const IndexSet = spec.IndexSet;

pub const NodeId = u32;

pub const Strategy = enum {
    auto,
    left_to_right,
    greedy,
    beam,
    anytime,
    optimal,
};

pub const default_exact_state_limit: usize = 262_144;
pub const default_auto_beam_width: usize = 256;

pub const Options = struct {
    strategy: Strategy = .auto,
    max_exact_inputs: u8 = 18,
    exact_state_limit: usize = default_exact_state_limit,
    beam_width: usize = 64,
    auto_beam_width: usize = default_auto_beam_width,

    /// Returns the structural visits charged for one `createPlan` run over
    /// `input_count` inputs under these options, whatever pruning or cache hits
    /// happen during the run. The einsum pass calls this with the operand count
    /// to charge planning against its work budget. The charge covers the
    /// dimensions the cost model reads, scans of the kept sets, completion
    /// searches, ordering and the hash maps, and it leaves out parsing,
    /// lowering, allocator internals and tensor execution. One cost evaluation
    /// is charged as eight passes over 256 labels, plus scans of the inputs and
    /// fixed metadata. Partition work is charged by the number of ways to
    /// assign each input outside, left or right, and the greedy strategy adds
    /// its lookahead. Map work is charged for four maps with lookups, inserts,
    /// growth and collisions, with eight times as many buckets as entries. The
    /// automatic strategy is charged for the path it will take: exact search
    /// when the state count fits, widening plus beam above the exact input
    /// limit, and beam otherwise. The errors are `error.EmptyEquation`,
    /// `error.TooManyInputs` above 63, `error.ExactInputLimitExceeded` for
    /// exact search past its limit, and `error.WorkOverflow`.
    pub fn workBound(self: Options, input_count: usize) !u64 {
        if (input_count == 0) return error.EmptyEquation;
        if (input_count > 63) return error.TooManyInputs;
        var work: PlannerWork = .{ .inputs = input_count };
        if (precomputeStateCount(input_count)) |states| try work.add(16 * states);
        switch (self.strategy) {
            .left_to_right => try work.linear(false),
            .greedy => try work.linear(true),
            .optimal => try work.optimal(self.max_exact_inputs),
            .beam => try work.beam(@max(self.beam_width, 1), false),
            .anytime => try work.widening(@max(self.beam_width, 1)),
            .auto => {
                if (canUseExactPlan(input_count, self)) {
                    try work.optimal(self.max_exact_inputs);
                } else if (input_count > self.max_exact_inputs) {
                    const width = @max(self.auto_beam_width, 1);
                    try work.widening(width);
                    try work.beam(width, true);
                } else {
                    try work.beam(@max(self.beam_width, 1), false);
                }
            },
        }
        return work.visits;
    }

    /// Returns the bytes of allocator storage one `createPlan` run may request,
    /// counting list growth that is never reclaimed and the arenas of beam
    /// search. The einsum pass calls this with the operand count to charge
    /// planning's memory against its scratch budget. This bound leaves out
    /// parsing, lowering, the overhead of the caller's arena and stack storage.
    /// The figure follows the same strategy choice `createPlan` makes, and for
    /// a widening search it adds up the storage of every width tried. A test
    /// runs every strategy in a fixed buffer of this size that never frees.
    pub fn storageBound(self: Options, input_count: usize) !u64 {
        if (input_count == 0) return error.EmptyEquation;
        if (input_count > 63) return error.TooManyInputs;
        var storage: PlannerStorage = .{};
        if (precomputeStateCount(input_count)) |states| {
            try storage.slice(IndexSet, 2 * states);
        }
        switch (self.strategy) {
            .left_to_right, .greedy => try storage.linear(input_count),
            .optimal => try storage.optimal(input_count, self.max_exact_inputs),
            .beam => try storage.beam(input_count, @max(self.beam_width, 1), false),
            .anytime => try storage.widening(input_count, @max(self.beam_width, 1)),
            .auto => {
                if (canUseExactPlan(input_count, self)) {
                    try storage.optimal(input_count, self.max_exact_inputs);
                } else if (input_count > self.max_exact_inputs) {
                    const width = @max(self.auto_beam_width, 1);
                    try storage.widening(input_count, width);
                    try storage.beam(input_count, width, true);
                } else {
                    try storage.beam(input_count, @max(self.beam_width, 1), false);
                }
            },
        }
        return storage.bytes;
    }
};

const StorageError = error{WorkOverflow};

const PlannerWork = struct {
    inputs: usize,
    visits: u64 = 0,

    fn sum(a: u64, b: u64) StorageError!u64 {
        return std.math.add(u64, a, b) catch return error.WorkOverflow;
    }

    fn product(a: u64, b: u64) StorageError!u64 {
        return std.math.mul(u64, a, b) catch return error.WorkOverflow;
    }

    fn add(self: *PlannerWork, visits: u64) StorageError!void {
        self.visits = try sum(self.visits, visits);
    }

    fn costs(self: *PlannerWork, count: u64) StorageError!void {
        try self.add(try product(count, 64 + 8 * (256 + self.inputs)));
    }

    fn greedyEvaluations(count: usize) u64 {
        std.debug.assert(count >= 2);
        std.debug.assert(count <= 63);
        const pairs = candidatePairCount(count);
        return if (count == 2) pairs else pairs * (2 + candidatePairCount(count - 1));
    }

    fn linear(self: *PlannerWork, lookahead: bool) StorageError!void {
        try self.costs(4 * self.inputs);
        var count = self.inputs;
        while (count > 1) : (count -= 1) {
            try self.costs(if (lookahead) greedyEvaluations(count) else 1);
            try self.add(16 * count);
        }
    }

    fn partitions(count: usize) StorageError!u64 {
        std.debug.assert(count <= 20);
        var result: u64 = 1;
        for (0..count) |_| result = try product(result, 3);
        return result;
    }

    fn optimal(self: *PlannerWork, max_inputs: u8) !void {
        if (self.inputs > max_inputs or self.inputs > 20) {
            return error.ExactInputLimitExceeded;
        }
        try self.costs(try sum(try partitions(self.inputs), 4 * self.inputs));
    }

    fn completion(count: usize, exact_limit: usize) StorageError!u64 {
        if (count <= 1) return 0;
        if (count <= exact_limit) {
            return sum(try partitions(count), exact_completion_state_count);
        }
        var result: u64 = 4 * count;
        var remaining = count;
        while (remaining > 1) : (remaining -= 1) {
            result = try sum(result, candidatePairCount(remaining));
        }
        return result;
    }

    fn beam(self: *PlannerWork, width: usize, exploratory: bool) StorageError!void {
        std.debug.assert(width >= 1);
        if (self.inputs == 1) return self.costs(4);
        try self.linear(true);
        const refinement = @max(
            try product(width, default_beam_refinement_factor),
            beam_refinement_min,
        );
        const exact_limit: usize = if (exploratory)
            auto_exploration_completion_exact_limit
        else
            default_completion_exact_limit;
        const score_limit: usize = if (exploratory)
            auto_exploration_completion_score_limit
        else
            default_completion_score_limit;
        var frontier: u64 = 1;
        var total: u64 = 0;
        var count = self.inputs;
        while (count > 1) : (count -= 1) {
            const candidates = try product(frontier, candidatePairCount(count));
            total = try sum(total, candidates);
            try self.costs(try product(candidates, 2 + candidatePairCount(count - 1)));
            try self.add(try product(candidates, 16 * count));
            const ordering = try sum(candidates, 1);
            try self.add(try product(32, try product(ordering, ordering)));
            const refined = @min(candidates, refinement);
            if (count - 1 <= score_limit) {
                try self.costs(try product(refined, try completion(count - 1, exact_limit)));
            }
            frontier = @min(width, candidates);
        }
        try self.maps(total);
    }

    fn maps(self: *PlannerWork, entries: u64) StorageError!void {
        const padded = try sum(entries, 8);
        const probes = try product(512, try product(padded, padded));
        try self.add(try product(probes, try product(self.inputs + 1, self.inputs + 1)));
    }

    fn widening(self: *PlannerWork, final_width: usize) StorageError!void {
        var width: usize = 1;
        for (0..@bitSizeOf(usize) + 1) |_| {
            try self.beam(width, false);
            if (width == final_width) return;
            width = nextBeamWidth(width, final_width);
        }
        unreachable;
    }
};

const PlannerStorage = struct {
    bytes: u64 = 0,

    fn add(self: *PlannerStorage, bytes: u64) StorageError!void {
        self.bytes = std.math.add(u64, self.bytes, bytes) catch return error.WorkOverflow;
    }

    fn product(a: u64, b: u64) StorageError!u64 {
        return std.math.mul(u64, a, b) catch return error.WorkOverflow;
    }

    fn slice(self: *PlannerStorage, comptime T: type, count: u64) StorageError!void {
        if (count == 0) return;
        try self.add(try product(count, @sizeOf(T)));
        try self.add(128);
    }

    fn list(self: *PlannerStorage, comptime T: type, count: u64) StorageError!void {
        if (count == 0) return;
        const minimum = std.math.cast(usize, count) orelse return error.WorkOverflow;
        const grown: u64 = std.ArrayList(T).growCapacity(minimum);
        try self.slice(T, try product(4, grown));
    }

    fn map(
        self: *PlannerStorage,
        comptime K: type,
        comptime V: type,
        count: u64,
    ) StorageError!void {
        if (count == 0) return;
        const padded = std.math.add(u64, count, 8) catch return error.WorkOverflow;
        const buckets = try product(8, padded);
        try self.add(try product(buckets, @sizeOf(K) + @sizeOf(V) + 65));
    }

    fn beam(
        self: *PlannerStorage,
        inputs: usize,
        width: usize,
        exploratory: bool,
    ) StorageError!void {
        if (inputs == 1) return;
        const widened = try product(width, default_beam_refinement_factor);
        const refinement = @max(widened, beam_refinement_min);
        var scratch: PlannerStorage = .{};
        try scratch.slice(Active, inputs);
        try scratch.list(BeamState, 1);
        var frontier: u64 = 1;
        var steps: u64 = 0;
        var immediate: u64 = 0;
        var exact: u64 = 0;
        var greedy: u64 = 0;
        var count = inputs;
        while (count > 1) : (count -= 1) {
            const candidates = try product(frontier, candidatePairCount(count));
            steps = std.math.add(u64, steps, candidates) catch return error.WorkOverflow;
            try scratch.add(try product(candidates, (count - 1) * @sizeOf(Active) + 128));
            try scratch.list(BeamState, candidates);
            const refined = @min(candidates, refinement);
            const factor = default_beam_refinement_factor;
            const deduplicate = switch (inputs > beam_immediate_cache_min) {
                true => shouldDeduplicateBeamCandidates(true, count, factor),
                false => shouldDeduplicateBeamCandidates(false, count, factor),
            };
            if (deduplicate) {
                try scratch.map(GreedyCompletionKey, usize, refined);
            }
            if (inputs > beam_immediate_cache_min and count - 1 >= beam_immediate_cache_min) {
                immediate = std.math.add(u64, immediate, candidates) catch
                    return error.WorkOverflow;
            }
            const exact_limit: usize = switch (exploratory) {
                true => auto_exploration_completion_exact_limit,
                false => default_completion_exact_limit,
            };
            const score_limit: usize = switch (exploratory) {
                true => auto_exploration_completion_score_limit,
                false => default_completion_score_limit,
            };
            if (count - 1 <= score_limit) {
                const entries = if (count - 1 <= exact_limit) &exact else &greedy;
                entries.* = std.math.add(u64, entries.*, refined) catch return error.WorkOverflow;
            }
            frontier = @min(width, candidates);
        }
        try scratch.list(BeamStep, steps);
        try scratch.map(GreedyCompletionKey, u128, immediate);
        try scratch.map(ExactCompletionKey, u128, exact);
        try scratch.map(GreedyCompletionKey, u128, greedy);
        try self.add(try product(8, scratch.bytes));
        try self.slice(Step, inputs - 1);
    }

    fn widening(self: *PlannerStorage, inputs: usize, final_width: usize) StorageError!void {
        var width: usize = 1;
        for (0..@bitSizeOf(usize) + 1) |_| {
            try self.beam(inputs, width, false);
            if (width == final_width) return;
            width = nextBeamWidth(width, final_width);
        }
        unreachable;
    }

    fn optimal(self: *PlannerStorage, inputs: usize, max_inputs: u8) !void {
        if (inputs > max_inputs or inputs > 20) return error.ExactInputLimitExceeded;
        if (inputs == 1) return;
        try self.slice(DpState, @as(u64, 1) << @intCast(inputs));
        try self.list(Step, inputs - 1);
        try self.slice(Step, inputs - 1);
    }

    fn linear(self: *PlannerStorage, inputs: usize) StorageError!void {
        try self.slice(Active, inputs);
        try self.list(Step, inputs - 1);
        try self.slice(Step, inputs - 1);
    }
};

const mask_precompute_limit: usize = 262_144;
const mask_precompute_min_inputs: usize = 11;

const PlanningContext = struct {
    equation: *const Equation,
    keep_sets: []IndexSet = &.{},

    fn init(allocator: std.mem.Allocator, equation: *const Equation) PlanError!PlanningContext {
        var context = PlanningContext{ .equation = equation };
        const state_count = precomputeStateCount(equation.inputs.len) orelse return context;
        const mask_sets = try allocator.alloc(IndexSet, state_count);
        defer allocator.free(mask_sets);
        context.keep_sets = try allocator.alloc(IndexSet, state_count);
        errdefer allocator.free(context.keep_sets);

        mask_sets[0] = .{};
        var mask: usize = 1;
        while (mask < state_count) : (mask += 1) {
            const previous = mask & (mask - 1);
            const input_index: usize = @intCast(@ctz(mask));
            mask_sets[mask] = mask_sets[previous].unioned(equation.inputs[input_index].index_set);
        }

        const all_mask = state_count - 1;
        mask = 0;
        while (mask < state_count) : (mask += 1) {
            context.keep_sets[mask] = equation.output_set.unioned(mask_sets[all_mask ^ mask]);
        }

        return context;
    }

    fn deinit(self: *PlanningContext, allocator: std.mem.Allocator) void {
        if (self.keep_sets.len != 0) allocator.free(self.keep_sets);
        self.* = undefined;
    }

    inline fn resultIndices(
        self: *const PlanningContext,
        combined_mask: u64,
        pair_indices: IndexSet,
    ) IndexSet {
        return pair_indices.intersected(self.keepSet(combined_mask));
    }

    inline fn keepSet(self: *const PlanningContext, mask: u64) IndexSet {
        if (self.keep_sets.len != 0) return self.keep_sets[@intCast(mask)];
        var keep = self.equation.output_set;
        for (self.equation.inputs, 0..) |input, index| {
            if ((mask & (@as(u64, 1) << @intCast(index))) != 0) continue;
            keep = keep.unioned(input.index_set);
        }
        return keep;
    }

    inline fn elementCount(self: *const PlanningContext, indices: IndexSet) u128 {
        return self.equation.elementCount(indices);
    }
};

pub const Step = struct {
    lhs: NodeId,
    rhs: NodeId,
    result: NodeId,
    lhs_inputs: u64,
    rhs_inputs: u64,
    result_inputs: u64,
    lhs_indices: IndexSet,
    rhs_indices: IndexSet,
    result_indices: IndexSet,
    summed_indices: IndexSet,
    scalar_cost: u128,
    flop_cost: u128,
    result_elements: u128,
    work_elements: u128,
};

pub const SearchStats = struct {
    candidate_contractions: u64 = 0,
    states_created: u64 = 0,
    states_kept: u64 = 0,
    states_pruned: u64 = 0,
    frontier_peak: u64 = 0,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    strategy: Strategy,
    steps: []Step,
    total_scalar_cost: u128,
    total_flop_cost: u128,
    peak_intermediate_elements: u128,
    peak_workspace_elements: u128,
    output_elements: u128,
    selected_beam_width: usize,
    search: SearchStats,

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.steps);
        self.* = undefined;
    }
};

pub const PlanError = error{
    EmptyEquation,
    TooManyInputs,
    ExactInputLimitExceeded,
    InvalidState,
} || std.mem.Allocator.Error;

const Active = struct {
    node: NodeId,
    input_mask: u64,
    indices: IndexSet,
};

const PairChoice = struct {
    lhs_index: usize,
    rhs_index: usize,
    cost: u128,
    flop_cost: u128,
    score: u128,
    result_elements: u128,
    work_elements: u128,
};

const StepCost = struct {
    scalar: u128,
    flop: u128,
    work: u128,
};

const DpState = struct {
    valid: bool = false,
    scalar_cost: u128 = 0,
    flop_cost: u128 = 0,
    peak: u128 = 0,
    indices: IndexSet = .{},
    left: u64 = 0,
    right: u64 = 0,
};

const BeamState = struct {
    active: []Active,
    active_count: usize,
    step_ref: ?usize = null,
    step_count: usize = 0,
    scalar_cost: u128 = 0,
    flop_cost: u128 = 0,
    score: u128 = 0,
    peak: u128 = 0,
    preserve: bool = false,
};

const BeamStep = struct {
    previous: ?usize,
    step: Step,
};

const BeamCandidateEstimate = struct {
    combined_mask: u64,
    pair_indices: IndexSet,
    result_indices: IndexSet,
    cost: StepCost,
    prefix_flop_cost: u128,
};

const CompletionState = struct {
    valid: bool = false,
    flop_cost: u128 = 0,
    indices: IndexSet = .{},
    input_mask: u64 = 0,
};

const ExactCompletionKey = struct {
    count: u8 = 0,
    masks: [beam_exact_completion_max_inputs]u64 = @as(
        [beam_exact_completion_max_inputs]u64,
        @splat(0),
    ),
};

const GreedyCompletionKey = struct {
    count: u8 = 0,
    masks: [max_completion_key_inputs]u64 = @as([max_completion_key_inputs]u64, @splat(0)),
};

const GreedyCompletionKeyContext = struct {
    pub fn hash(_: GreedyCompletionKeyContext, key: GreedyCompletionKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.count));
        const count: usize = key.count;
        for (key.masks[0..count]) |mask| {
            hasher.update(std.mem.asBytes(&mask));
        }
        return hasher.final();
    }

    pub fn eql(
        _: GreedyCompletionKeyContext,
        lhs: GreedyCompletionKey,
        rhs: GreedyCompletionKey,
    ) bool {
        if (lhs.count != rhs.count) return false;
        const count: usize = lhs.count;
        return std.mem.eql(u64, lhs.masks[0..count], rhs.masks[0..count]);
    }
};

const GreedyCompletionMap = std.HashMap(
    GreedyCompletionKey,
    u128,
    GreedyCompletionKeyContext,
    std.hash_map.default_max_load_percentage,
);
const BeamPartitionMap = std.HashMap(
    GreedyCompletionKey,
    usize,
    GreedyCompletionKeyContext,
    std.hash_map.default_max_load_percentage,
);

const CompletionCache = struct {
    exact: std.AutoHashMap(ExactCompletionKey, u128),
    greedy: GreedyCompletionMap,

    fn init(allocator: std.mem.Allocator) CompletionCache {
        return .{
            .exact = std.AutoHashMap(ExactCompletionKey, u128).init(allocator),
            .greedy = GreedyCompletionMap.init(allocator),
        };
    }

    fn deinit(self: *CompletionCache) void {
        self.exact.deinit();
        self.greedy.deinit();
    }
};

const ImmediateCompletionCache = GreedyCompletionMap;

const beam_exact_completion_max_inputs = 9;
const exact_completion_state_count = @as(usize, 1) << beam_exact_completion_max_inputs;
const beam_immediate_cache_min = 10;
const default_beam_refinement_factor = 32;
const beam_refinement_min = 512;
const beam_partition_dedup_max_inputs = 10;
const beam_refined_partition_dedup_max_inputs = 16;
const default_completion_exact_limit = 8;
const default_completion_score_limit = 15;
const auto_exploration_completion_exact_limit = 9;
const auto_exploration_completion_score_limit = 12;
const max_completion_key_inputs = 63;

pub fn createPlan(
    allocator: std.mem.Allocator,
    equation: *const Equation,
    options: Options,
) PlanError!Plan {
    if (equation.inputs.len == 0) return error.EmptyEquation;
    if (equation.inputs.len > 63) return error.TooManyInputs;
    var context = try PlanningContext.init(allocator, equation);
    defer context.deinit(allocator);
    return switch (options.strategy) {
        .auto => createAutoPlan(allocator, &context, options),
        .left_to_right => createLinearPlan(allocator, &context, .left_to_right),
        .greedy => createLinearPlan(allocator, &context, .greedy),
        .beam => createBeamPlan(allocator, &context, options.beam_width),
        .anytime => createAnytimePlan(allocator, &context, options.beam_width),
        .optimal => createOptimalPlan(allocator, &context, options.max_exact_inputs),
    };
}

fn createAutoPlan(
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    options: Options,
) PlanError!Plan {
    const equation = context.equation;
    if (canUseExactPlan(equation.inputs.len, options)) {
        return createOptimalPlan(allocator, context, options.max_exact_inputs);
    }
    if (equation.inputs.len > options.max_exact_inputs) {
        return createAutoBeamPlan(allocator, context, options.auto_beam_width);
    }
    return createBeamPlan(allocator, context, options.beam_width);
}

fn canUseExactPlan(input_count: usize, options: Options) bool {
    if (input_count > options.max_exact_inputs) return false;
    if (input_count > 20) return false;
    const state_count = exactStateCount(input_count) orelse return false;
    return state_count <= options.exact_state_limit;
}

fn exactStateCount(input_count: usize) ?usize {
    if (input_count >= @bitSizeOf(usize)) return null;
    return @as(usize, 1) << @intCast(input_count);
}

fn precomputeStateCount(input_count: usize) ?usize {
    if (input_count < mask_precompute_min_inputs) return null;
    const state_count = exactStateCount(input_count) orelse return null;
    if (state_count > mask_precompute_limit) return null;
    return state_count;
}

fn createLinearPlan(
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    strategy: Strategy,
) PlanError!Plan {
    const equation = context.equation;
    var steps = std.ArrayListUnmanaged(Step).empty;
    errdefer steps.deinit(allocator);
    var search: SearchStats = .{
        .states_created = @intCast(equation.inputs.len),
        .states_kept = @intCast(equation.inputs.len),
        .frontier_peak = @intCast(equation.inputs.len),
    };

    var active = try allocator.alloc(Active, equation.inputs.len);
    defer allocator.free(active);
    for (equation.inputs, 0..) |input, index| {
        active[index] = .{
            .node = @intCast(index),
            .input_mask = @as(u64, 1) << @intCast(index),
            .indices = input.index_set,
        };
    }

    var active_count = equation.inputs.len;
    while (active_count > 1) {
        const choice = switch (strategy) {
            .left_to_right => blk: {
                search.candidate_contractions += 1;
                break :blk pairChoice(context, active[0], active[1], 0, 1);
            },
            .greedy => bestGreedyPair(context, active[0..active_count], &search),
            .auto, .beam, .anytime, .optimal => unreachable,
        };
        const lhs = active[choice.lhs_index];
        const rhs = active[choice.rhs_index];
        const combined_mask = lhs.input_mask | rhs.input_mask;
        const pair_indices = lhs.indices.unioned(rhs.indices);
        const result_indices = resultIndices(context, combined_mask, pair_indices);
        const result_node: NodeId = @intCast(equation.inputs.len + steps.items.len);
        const step: Step = .{
            .lhs = lhs.node,
            .rhs = rhs.node,
            .result = result_node,
            .lhs_inputs = lhs.input_mask,
            .rhs_inputs = rhs.input_mask,
            .result_inputs = combined_mask,
            .lhs_indices = lhs.indices,
            .rhs_indices = rhs.indices,
            .result_indices = result_indices,
            .summed_indices = pair_indices.without(result_indices),
            .scalar_cost = choice.cost,
            .flop_cost = choice.flop_cost,
            .result_elements = choice.result_elements,
            .work_elements = choice.work_elements,
        };
        try steps.append(allocator, step);
        active[choice.lhs_index] = .{
            .node = result_node,
            .input_mask = combined_mask,
            .indices = result_indices,
        };
        removeActive(active[0..active_count], choice.rhs_index);
        active_count -= 1;
        search.states_created += 1;
        search.states_kept += 1;
    }

    const owned_steps = try steps.toOwnedSlice(allocator);
    return finishPlan(allocator, equation, strategy, owned_steps, search);
}

fn createBeamPlan(
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    beam_width: usize,
) PlanError!Plan {
    return createBeamPlanWithRefinement(
        allocator,
        context,
        beam_width,
        default_beam_refinement_factor,
    );
}

fn createBeamPlanWithRefinement(
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    beam_width: usize,
    refinement_factor: usize,
) PlanError!Plan {
    return createBeamPlanWithRefinementAndScoreLimit(
        allocator,
        context,
        beam_width,
        refinement_factor,
        default_completion_exact_limit,
        default_completion_score_limit,
    );
}

fn createBeamPlanWithRefinementAndScoreLimit(
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    beam_width: usize,
    refinement_factor: usize,
    completion_exact_limit: usize,
    completion_score_limit: usize,
) PlanError!Plan {
    if (context.equation.inputs.len > beam_immediate_cache_min) {
        return createBeamPlanMode(
            true,
            allocator,
            context,
            beam_width,
            refinement_factor,
            completion_exact_limit,
            completion_score_limit,
        );
    }
    return createBeamPlanMode(
        false,
        allocator,
        context,
        beam_width,
        refinement_factor,
        completion_exact_limit,
        completion_score_limit,
    );
}

fn createBeamPlanMode(
    comptime use_immediate_cache: bool,
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    beam_width: usize,
    refinement_factor: usize,
    completion_exact_limit: usize,
    completion_score_limit: usize,
) PlanError!Plan {
    const equation = context.equation;
    const width = @max(beam_width, 1);
    if (equation.inputs.len == 1) {
        const steps = try allocator.alloc(Step, 0);
        var plan = finishPlan(allocator, equation, .beam, steps, .{
            .states_created = 1,
            .states_kept = 1,
            .frontier_peak = 1,
        });
        plan.selected_beam_width = width;
        return plan;
    }

    var scratch_state = alloc_arena.Arena.init(allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const initial_active = try scratch.alloc(Active, equation.inputs.len);
    for (equation.inputs, 0..) |input, index| {
        initial_active[index] = .{
            .node = @intCast(index),
            .input_mask = @as(u64, 1) << @intCast(index),
            .indices = input.index_set,
        };
    }

    var beam = std.ArrayListUnmanaged(BeamState).empty;
    defer beam.deinit(scratch);
    try beam.append(scratch, .{
        .active = initial_active,
        .active_count = equation.inputs.len,
        .preserve = true,
    });
    var beam_steps = std.ArrayListUnmanaged(BeamStep).empty;
    defer beam_steps.deinit(scratch);
    var completion_cache = CompletionCache.init(scratch);
    defer completion_cache.deinit();
    var partition_cache = BeamPartitionMap.init(scratch);
    defer partition_cache.deinit();
    var immediate_cache: ImmediateCompletionCache = undefined;
    if (use_immediate_cache) immediate_cache = ImmediateCompletionCache.init(scratch);
    defer if (use_immediate_cache) immediate_cache.deinit();
    var search: SearchStats = .{
        .states_created = 1,
        .states_kept = 1,
        .frontier_peak = 1,
    };
    const incumbent_flop_bound = greedyUpperFlopCost(context);

    while (beam.items[0].active_count > 1) {
        var candidates = std.ArrayListUnmanaged(BeamState).empty;
        errdefer candidates.deinit(scratch);
        for (beam.items) |state| {
            for (0..state.active_count) |lhs_index| {
                for (lhs_index + 1..state.active_count) |rhs_index| {
                    const estimate = beamCandidateEstimate(context, state, lhs_index, rhs_index);
                    search.candidate_contractions += 1;
                    if (state.active_count > 2 and
                        estimate.prefix_flop_cost >= incumbent_flop_bound)
                    {
                        search.states_pruned += 1;
                        continue;
                    }
                    try candidates.append(scratch, try beamCandidate(
                        use_immediate_cache,
                        scratch,
                        context,
                        state,
                        lhs_index,
                        rhs_index,
                        estimate,
                        &beam_steps,
                        if (use_immediate_cache) &immediate_cache else null,
                    ));
                    search.states_created += 1;
                }
            }
        }
        if (candidates.items.len == 0) return error.InvalidState;
        if (use_immediate_cache) {
            retainBeamRefinementCandidates(
                &candidates,
                beamRefinementWidth(width, refinement_factor),
            );
        } else {
            std.mem.sort(BeamState, candidates.items, {}, beamStateLessThan);
            retainSortedBeamCandidates(&candidates, beamRefinementWidth(width, refinement_factor));
        }
        if (shouldDeduplicateBeamCandidates(
            use_immediate_cache,
            beam.items[0].active_count,
            refinement_factor,
        )) {
            try deduplicateBeamCandidates(&partition_cache, &candidates);
        }
        try scoreBeamCandidates(
            context,
            candidates.items,
            &completion_cache,
            completion_exact_limit,
            completion_score_limit,
        );
        if (use_immediate_cache) {
            retainBeamCandidates(&candidates, width);
        } else {
            std.mem.sort(BeamState, candidates.items, {}, beamStateLessThan);
            retainSortedBeamCandidates(&candidates, width);
            markPreservedBeamPath(candidates.items);
        }
        search.states_kept += @intCast(candidates.items.len);
        search.frontier_peak = @max(search.frontier_peak, @as(u64, @intCast(candidates.items.len)));
        beam.deinit(scratch);
        beam = candidates;
    }

    const best = beam.items[0];
    const steps = try allocator.alloc(Step, best.step_count);
    writeBeamSteps(steps, beam_steps.items, best.step_ref);
    var plan = finishPlan(allocator, equation, .beam, steps, search);
    plan.selected_beam_width = width;
    return plan;
}

fn createAnytimePlan(
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    max_beam_width: usize,
) PlanError!Plan {
    return createAnytimePlanWithRefinement(
        allocator,
        context,
        max_beam_width,
        default_beam_refinement_factor,
    );
}

fn createAutoBeamPlan(
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    max_beam_width: usize,
) PlanError!Plan {
    var best = try createAnytimePlanWithRefinement(
        allocator,
        context,
        max_beam_width,
        default_beam_refinement_factor,
    );
    errdefer best.deinit();
    var search = best.search;

    var exploratory = try createBeamPlanWithRefinementAndScoreLimit(
        allocator,
        context,
        max_beam_width,
        default_beam_refinement_factor,
        auto_exploration_completion_exact_limit,
        auto_exploration_completion_score_limit,
    );
    search = mergedSearchStats(search, exploratory.search);
    if (planBeats(exploratory, best)) {
        best.deinit();
        best = exploratory;
    } else {
        exploratory.deinit();
    }

    best.search = search;
    return best;
}

fn createAnytimePlanWithRefinement(
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    max_beam_width: usize,
    refinement_factor: usize,
) PlanError!Plan {
    const final_width = @max(max_beam_width, 1);
    var width: usize = 1;
    var best = try createBeamPlanWithRefinement(allocator, context, width, refinement_factor);
    errdefer best.deinit();
    var search = best.search;

    while (width != final_width) {
        width = nextBeamWidth(width, final_width);
        var candidate = try createBeamPlanWithRefinement(
            allocator,
            context,
            width,
            refinement_factor,
        );
        search = mergedSearchStats(search, candidate.search);
        if (planBeats(candidate, best)) {
            best.deinit();
            best = candidate;
        } else {
            candidate.deinit();
        }
    }

    best.strategy = .anytime;
    best.search = search;
    return best;
}

fn nextBeamWidth(width: usize, final_width: usize) usize {
    if (width >= final_width) return final_width;
    if (width > final_width / 2) return final_width;
    return @max(width * 2, width + 1);
}

fn planBeats(candidate: Plan, incumbent: Plan) bool {
    if (candidate.total_flop_cost != incumbent.total_flop_cost) {
        return candidate.total_flop_cost < incumbent.total_flop_cost;
    }
    if (candidate.peak_intermediate_elements != incumbent.peak_intermediate_elements) {
        return candidate.peak_intermediate_elements < incumbent.peak_intermediate_elements;
    }
    if (candidate.peak_workspace_elements != incumbent.peak_workspace_elements) {
        return candidate.peak_workspace_elements < incumbent.peak_workspace_elements;
    }
    return candidate.total_scalar_cost < incumbent.total_scalar_cost;
}

fn mergedSearchStats(lhs: SearchStats, rhs: SearchStats) SearchStats {
    return .{
        .candidate_contractions = saturatingAddU64(
            lhs.candidate_contractions,
            rhs.candidate_contractions,
        ),
        .states_created = saturatingAddU64(lhs.states_created, rhs.states_created),
        .states_kept = saturatingAddU64(lhs.states_kept, rhs.states_kept),
        .states_pruned = saturatingAddU64(lhs.states_pruned, rhs.states_pruned),
        .frontier_peak = @max(lhs.frontier_peak, rhs.frontier_peak),
    };
}

fn beamCandidateEstimate(
    context: *const PlanningContext,
    state: BeamState,
    lhs_index: usize,
    rhs_index: usize,
) BeamCandidateEstimate {
    const lhs = state.active[lhs_index];
    const rhs = state.active[rhs_index];
    const combined_mask = lhs.input_mask | rhs.input_mask;
    const pair_indices = lhs.indices.unioned(rhs.indices);
    const result_indices = resultIndices(context, combined_mask, pair_indices);
    const cost = stepCost(context, lhs.indices, rhs.indices, result_indices);
    return .{
        .combined_mask = combined_mask,
        .pair_indices = pair_indices,
        .result_indices = result_indices,
        .cost = cost,
        .prefix_flop_cost = saturatingAdd(state.flop_cost, cost.flop),
    };
}

fn beamCandidate(
    comptime use_immediate_cache: bool,
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    state: BeamState,
    lhs_index: usize,
    rhs_index: usize,
    estimate: BeamCandidateEstimate,
    beam_steps: *std.ArrayListUnmanaged(BeamStep),
    immediate_cache: ?*ImmediateCompletionCache,
) PlanError!BeamState {
    const equation = context.equation;
    const lhs = state.active[lhs_index];
    const rhs = state.active[rhs_index];
    const result_node: NodeId = @intCast(equation.inputs.len + state.step_count);
    const step: Step = .{
        .lhs = lhs.node,
        .rhs = rhs.node,
        .result = result_node,
        .lhs_inputs = lhs.input_mask,
        .rhs_inputs = rhs.input_mask,
        .result_inputs = estimate.combined_mask,
        .lhs_indices = lhs.indices,
        .rhs_indices = rhs.indices,
        .result_indices = estimate.result_indices,
        .summed_indices = estimate.pair_indices.without(estimate.result_indices),
        .scalar_cost = estimate.cost.scalar,
        .flop_cost = estimate.cost.flop,
        .result_elements = context.elementCount(estimate.result_indices),
        .work_elements = estimate.cost.work,
    };

    try beam_steps.append(allocator, .{
        .previous = state.step_ref,
        .step = step,
    });
    const step_ref = beam_steps.items.len - 1;

    const active = try allocator.alloc(Active, state.active_count - 1);
    writeBeamCandidateActive(
        active,
        state.active[0..state.active_count],
        lhs_index,
        rhs_index,
        .{
            .node = result_node,
            .input_mask = estimate.combined_mask,
            .indices = estimate.result_indices,
        },
    );

    const all_mask = allInputsMask(equation.inputs.len);
    const scalar_cost = saturatingAdd(state.scalar_cost, step.scalar_cost);
    const peak = @max(state.peak, stepPeakContribution(step, all_mask));
    const completion_score = if (use_immediate_cache and active.len >= beam_immediate_cache_min)
        try immediateCompletionFlopCostCached(context, active, immediate_cache.?)
    else
        immediateCompletionFlopCost(context, active);
    return .{
        .active = active,
        .active_count = active.len,
        .step_ref = step_ref,
        .step_count = state.step_count + 1,
        .scalar_cost = scalar_cost,
        .flop_cost = estimate.prefix_flop_cost,
        .score = saturatingAdd(estimate.prefix_flop_cost, completion_score),
        .peak = peak,
        .preserve = state.preserve,
    };
}

fn beamRefinementWidth(width: usize, refinement_factor: usize) usize {
    return @max(width * refinement_factor, beam_refinement_min);
}

fn writeBeamCandidateActive(
    active: []Active,
    source: []const Active,
    lhs_index: usize,
    rhs_index: usize,
    result: Active,
) void {
    var write: usize = 0;
    var inserted = false;
    for (source, 0..) |entry, index| {
        if (index == lhs_index or index == rhs_index) continue;
        if (!inserted and result.input_mask < entry.input_mask) {
            active[write] = result;
            write += 1;
            inserted = true;
        }
        active[write] = entry;
        write += 1;
    }
    if (!inserted) {
        active[write] = result;
    }
}

fn shouldDeduplicateBeamCandidates(
    comptime use_immediate_cache: bool,
    active_count: usize,
    refinement_factor: usize,
) bool {
    return (use_immediate_cache and refinement_factor == default_beam_refinement_factor and
        active_count <= beam_refined_partition_dedup_max_inputs) or
        active_count <= beam_partition_dedup_max_inputs;
}

fn retainBeamRefinementCandidates(
    candidates: *std.ArrayListUnmanaged(BeamState),
    width: usize,
) void {
    retainBestBeamCandidates(candidates, width, false);
}

fn scoreBeamCandidates(
    context: *const PlanningContext,
    candidates: []BeamState,
    cache: *CompletionCache,
    completion_exact_limit: usize,
    completion_score_limit: usize,
) PlanError!void {
    for (candidates) |*candidate| {
        if (candidate.active_count > completion_score_limit) continue;
        candidate.score = saturatingAdd(candidate.flop_cost, try completionFlopCost(
            context,
            candidate.active[0..candidate.active_count],
            cache,
            completion_exact_limit,
        ));
    }
}

fn deduplicateBeamCandidates(
    cache: *BeamPartitionMap,
    candidates: *std.ArrayListUnmanaged(BeamState),
) PlanError!void {
    cache.clearRetainingCapacity();
    var write: usize = 0;
    for (candidates.items) |candidate| {
        const key = greedyCompletionKey(candidate.active[0..candidate.active_count]);
        if (cache.get(key)) |index| {
            const preserve = candidates.items[index].preserve or candidate.preserve;
            if (beamStateSelectionLessThan(candidate, candidates.items[index])) {
                candidates.items[index] = candidate;
            }
            candidates.items[index].preserve = preserve;
        } else {
            candidates.items[write] = candidate;
            try cache.put(key, write);
            write += 1;
        }
    }
    candidates.items.len = write;
}

fn retainBeamCandidates(candidates: *std.ArrayListUnmanaged(BeamState), width: usize) void {
    retainBestBeamCandidates(candidates, width, true);
    markPreservedBeamPath(candidates.items);
}

fn retainSortedBeamCandidates(candidates: *std.ArrayListUnmanaged(BeamState), width: usize) void {
    const retained = @min(width, candidates.items.len);
    var preserved_index: ?usize = null;
    for (candidates.items, 0..) |candidate, index| {
        if (!candidate.preserve) continue;
        preserved_index = index;
        break;
    }
    if (preserved_index) |index| {
        if (index >= retained and retained > 0) {
            candidates.items[retained - 1] = candidates.items[index];
            std.mem.sort(BeamState, candidates.items[0..retained], {}, beamStateLessThan);
        }
    }
    candidates.items.len = retained;
}

fn retainBestBeamCandidates(
    candidates: *std.ArrayListUnmanaged(BeamState),
    width: usize,
    sort_retained: bool,
) void {
    const retained = @min(width, candidates.items.len);
    if (retained == 0) {
        candidates.items.len = 0;
        return;
    }
    if (candidates.items.len > retained) {
        const preserved = bestPreservedBeamCandidate(candidates.items);
        selectBestBeamPrefix(candidates.items, retained);
        candidates.items.len = retained;
        if (preserved) |candidate| {
            if (!beamCandidateRetained(candidates.items, candidate)) {
                candidates.items[retained - 1] = candidate;
            }
        }
    }
    candidates.items.len = retained;
    if (sort_retained) std.mem.sort(BeamState, candidates.items, {}, beamStateLessThan);
}

fn bestPreservedBeamCandidate(candidates: []const BeamState) ?BeamState {
    var best: ?BeamState = null;
    for (candidates) |candidate| {
        if (!candidate.preserve) continue;
        if (best == null or beamStateSelectionLessThan(candidate, best.?)) {
            best = candidate;
        }
    }
    return best;
}

fn beamCandidateRetained(candidates: []const BeamState, needle: BeamState) bool {
    for (candidates) |candidate| {
        if (sameBeamCandidate(candidate, needle)) return true;
    }
    return false;
}

fn sameBeamCandidate(lhs: BeamState, rhs: BeamState) bool {
    return lhs.step_ref == rhs.step_ref and lhs.step_count == rhs.step_count;
}

fn selectBestBeamPrefix(candidates: []BeamState, retained: usize) void {
    const target = retained - 1;
    var left: usize = 0;
    var right = candidates.len - 1;
    while (left < right) {
        const pivot = partitionBeamCandidates(candidates, left, right, left + (right - left) / 2);
        if (target == pivot) return;
        if (target < pivot) {
            if (pivot == 0) return;
            right = pivot - 1;
        } else {
            left = pivot + 1;
        }
    }
}

fn partitionBeamCandidates(
    candidates: []BeamState,
    left: usize,
    right: usize,
    pivot_index: usize,
) usize {
    const pivot = candidates[pivot_index];
    std.mem.swap(BeamState, &candidates[pivot_index], &candidates[right]);
    var store = left;
    for (left..right) |index| {
        if (beamStateSelectionLessThan(candidates[index], pivot)) {
            std.mem.swap(BeamState, &candidates[store], &candidates[index]);
            store += 1;
        }
    }
    std.mem.swap(BeamState, &candidates[store], &candidates[right]);
    return store;
}

fn markPreservedBeamPath(states: []BeamState) void {
    var preserved = false;
    for (states) |*state| {
        if (state.preserve and !preserved) {
            preserved = true;
        } else {
            state.preserve = false;
        }
    }
}

fn writeBeamSteps(steps: []Step, beam_steps: []const BeamStep, step_ref: ?usize) void {
    var cursor = step_ref;
    var write = steps.len;
    while (cursor) |index| {
        write -= 1;
        const beam_step = beam_steps[index];
        steps[write] = beam_step.step;
        cursor = beam_step.previous;
    }
}

fn beamStateLessThan(_: void, lhs: BeamState, rhs: BeamState) bool {
    if (lhs.score != rhs.score) return lhs.score < rhs.score;
    if (lhs.flop_cost != rhs.flop_cost) return lhs.flop_cost < rhs.flop_cost;
    if (lhs.peak != rhs.peak) return lhs.peak < rhs.peak;
    if (lhs.scalar_cost != rhs.scalar_cost) return lhs.scalar_cost < rhs.scalar_cost;
    return lhs.step_count < rhs.step_count;
}

fn beamStateSelectionLessThan(lhs: BeamState, rhs: BeamState) bool {
    if (beamStateLessThan({}, lhs, rhs)) return true;
    if (beamStateLessThan({}, rhs, lhs)) return false;
    const lhs_step_ref = lhs.step_ref orelse std.math.maxInt(usize);
    const rhs_step_ref = rhs.step_ref orelse std.math.maxInt(usize);
    return lhs_step_ref < rhs_step_ref;
}

fn createOptimalPlan(
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    max_exact_inputs: u8,
) PlanError!Plan {
    const equation = context.equation;
    const input_count = equation.inputs.len;
    if (input_count > max_exact_inputs) return error.ExactInputLimitExceeded;
    if (input_count > 20) return error.ExactInputLimitExceeded;
    if (input_count == 1) {
        const steps = try allocator.alloc(Step, 0);
        return finishPlan(allocator, equation, .optimal, steps, .{
            .states_created = 1,
            .states_kept = 1,
            .frontier_peak = 1,
        });
    }

    const state_count: usize = @as(usize, 1) << @intCast(input_count);
    var states = try allocator.alloc(DpState, state_count);
    defer allocator.free(states);
    @memset(states, .{});

    for (equation.inputs, 0..) |input, index| {
        const mask: u64 = @as(u64, 1) << @intCast(index);
        states[@intCast(mask)] = .{
            .valid = true,
            .scalar_cost = 0,
            .flop_cost = 0,
            .peak = 0,
            .indices = input.index_set,
        };
    }
    var search: SearchStats = .{
        .states_created = @intCast(input_count),
        .states_kept = @intCast(input_count),
        .frontier_peak = @intCast(input_count),
    };

    var mask: u64 = 1;
    const all_mask: u64 = (@as(u64, 1) << @intCast(input_count)) - 1;
    while (mask <= all_mask) : (mask += 1) {
        if (isSingleton(mask)) continue;
        var mask_had_state = false;
        var sub = (mask - 1) & mask;
        while (sub != 0) : (sub = (sub - 1) & mask) {
            const other = mask ^ sub;
            if (other == 0 or sub > other) continue;
            const left = states[@intCast(sub)];
            const right = states[@intCast(other)];
            if (!left.valid or !right.valid) continue;
            search.candidate_contractions += 1;
            const pair_indices = left.indices.unioned(right.indices);
            const result = resultIndices(context, mask, pair_indices);
            const cost = stepCost(context, left.indices, right.indices, result);
            const result_elements = context.elementCount(result);
            const scalar_cost = saturatingAdd(
                saturatingAdd(left.scalar_cost, right.scalar_cost),
                cost.scalar,
            );
            const flop_cost = saturatingAdd(
                saturatingAdd(left.flop_cost, right.flop_cost),
                cost.flop,
            );
            const peak = @max(
                @max(left.peak, right.peak),
                stepPeakContributionValues(result_elements, cost.work, mask, all_mask),
            );
            if (!states[@intCast(mask)].valid or flop_cost < states[@intCast(mask)].flop_cost or
                (flop_cost == states[@intCast(mask)].flop_cost and
                    peak < states[@intCast(mask)].peak) or
                (flop_cost == states[@intCast(mask)].flop_cost and peak == states[
                    @intCast(
                        mask,
                    )
                ].peak and scalar_cost < states[@intCast(mask)].scalar_cost))
            {
                if (!mask_had_state) {
                    search.states_created += 1;
                    mask_had_state = true;
                }
                states[@intCast(mask)] = .{
                    .valid = true,
                    .scalar_cost = scalar_cost,
                    .flop_cost = flop_cost,
                    .peak = peak,
                    .indices = result,
                    .left = sub,
                    .right = other,
                };
            }
        }
        if (mask_had_state) search.states_kept += 1;
    }
    if (!states[@intCast(all_mask)].valid) return error.InvalidState;
    search.frontier_peak = @max(search.frontier_peak, search.states_kept);

    var steps = std.ArrayListUnmanaged(Step).empty;
    errdefer steps.deinit(allocator);
    _ = try appendDpSteps(allocator, context, states, all_mask, &steps);
    const owned_steps = try steps.toOwnedSlice(allocator);
    return finishPlan(allocator, equation, .optimal, owned_steps, search);
}

fn appendDpSteps(
    allocator: std.mem.Allocator,
    context: *const PlanningContext,
    states: []const DpState,
    mask: u64,
    steps: *std.ArrayListUnmanaged(Step),
) PlanError!NodeId {
    const equation = context.equation;
    if (isSingleton(mask)) return @intCast(@ctz(mask));
    const state = states[@intCast(mask)];
    const lhs = try appendDpSteps(allocator, context, states, state.left, steps);
    const rhs = try appendDpSteps(allocator, context, states, state.right, steps);
    const lhs_state = states[@intCast(state.left)];
    const rhs_state = states[@intCast(state.right)];
    const pair_indices = lhs_state.indices.unioned(rhs_state.indices);
    const result = resultIndices(context, mask, pair_indices);
    const cost = stepCost(context, lhs_state.indices, rhs_state.indices, result);
    const result_node: NodeId = @intCast(equation.inputs.len + steps.items.len);
    try steps.append(allocator, .{
        .lhs = lhs,
        .rhs = rhs,
        .result = result_node,
        .lhs_inputs = state.left,
        .rhs_inputs = state.right,
        .result_inputs = mask,
        .lhs_indices = lhs_state.indices,
        .rhs_indices = rhs_state.indices,
        .result_indices = result,
        .summed_indices = pair_indices.without(result),
        .scalar_cost = cost.scalar,
        .flop_cost = cost.flop,
        .result_elements = context.elementCount(result),
        .work_elements = cost.work,
    });
    return result_node;
}

fn finishPlan(
    allocator: std.mem.Allocator,
    equation: *const Equation,
    strategy: Strategy,
    steps: []Step,
    search: SearchStats,
) Plan {
    var total: u128 = 0;
    var flops: u128 = 0;
    var peak: u128 = 0;
    var workspace: u128 = 0;
    const all_mask = allInputsMask(equation.inputs.len);
    for (steps) |step| {
        total = saturatingAdd(total, step.scalar_cost);
        flops = saturatingAdd(flops, step.flop_cost);
        peak = @max(peak, stepPeakContribution(step, all_mask));
        workspace = @max(workspace, step.work_elements);
    }
    if (steps.len == 0 and equation.inputs.len == 1) {
        const input_indices = equation.inputs[0].index_set;
        const summed = input_indices.without(equation.output_set);
        if (!summed.isEmpty()) {
            const reduction_cost = equation.elementCount(input_indices);
            total = saturatingAdd(total, reduction_cost);
            flops = saturatingAdd(flops, reduction_cost);
        }
    }
    return .{
        .allocator = allocator,
        .strategy = strategy,
        .steps = steps,
        .total_scalar_cost = total,
        .total_flop_cost = flops,
        .peak_intermediate_elements = peak,
        .peak_workspace_elements = workspace,
        .output_elements = equation.elementCount(equation.output_set),
        .selected_beam_width = 0,
        .search = search,
    };
}

fn bestGreedyPair(
    context: *const PlanningContext,
    active: []const Active,
    search: *SearchStats,
) PairChoice {
    search.candidate_contractions += candidatePairCount(active.len);
    return bestGreedyPairEstimate(context, active);
}

fn bestGreedyPairEstimate(context: *const PlanningContext, active: []const Active) PairChoice {
    var best = pairChoice(context, active[0], active[1], 0, 1);
    best.score = greedyScore(context, active, best);
    for (0..active.len) |lhs_index| {
        for (lhs_index + 1..active.len) |rhs_index| {
            if (lhs_index == 0 and rhs_index == 1) continue;
            var candidate = pairChoice(
                context,
                active[lhs_index],
                active[rhs_index],
                lhs_index,
                rhs_index,
            );
            candidate.score = greedyScore(context, active, candidate);
            if (candidate.score < best.score or
                (candidate.score == best.score and candidate.flop_cost < best.flop_cost) or
                (candidate.score == best.score and candidate.flop_cost == best.flop_cost and
                    choicePeak(candidate) < choicePeak(best)))
            {
                best = candidate;
            }
        }
    }
    return best;
}

fn greedyUpperFlopCost(context: *const PlanningContext) u128 {
    const equation = context.equation;
    if (equation.inputs.len <= 1) {
        const input_indices = equation.inputs[0].index_set;
        const summed = input_indices.without(equation.output_set);
        if (summed.isEmpty()) return 0;
        return context.elementCount(input_indices);
    }

    var active: [63]Active = undefined;
    for (equation.inputs, 0..) |input, index| {
        active[index] = .{
            .node = 0,
            .input_mask = @as(u64, 1) << @intCast(index),
            .indices = input.index_set,
        };
    }
    var active_count = equation.inputs.len;
    var total: u128 = 0;
    while (active_count > 1) {
        const choice = bestGreedyPairEstimate(context, active[0..active_count]);
        const lhs = active[choice.lhs_index];
        const rhs = active[choice.rhs_index];
        const combined_mask = lhs.input_mask | rhs.input_mask;
        const pair_indices = lhs.indices.unioned(rhs.indices);
        const result = resultIndices(context, combined_mask, pair_indices);
        total = saturatingAdd(total, choice.flop_cost);
        active[choice.lhs_index] = .{
            .node = 0,
            .input_mask = combined_mask,
            .indices = result,
        };
        removeActive(active[0..active_count], choice.rhs_index);
        active_count -= 1;
    }
    return total;
}

fn greedyCompletionFlopCost(context: *const PlanningContext, active: []const Active) u128 {
    if (active.len <= 1) return 0;

    var scratch: [63]Active = undefined;
    @memcpy(scratch[0..active.len], active);
    var active_count = active.len;
    var total: u128 = 0;
    while (active_count > 1) {
        const choice = bestImmediatePairEstimate(context, scratch[0..active_count]);
        const lhs = scratch[choice.lhs_index];
        const rhs = scratch[choice.rhs_index];
        const combined_mask = lhs.input_mask | rhs.input_mask;
        const pair_indices = lhs.indices.unioned(rhs.indices);
        const result = resultIndices(context, combined_mask, pair_indices);
        total = saturatingAdd(total, choice.flop_cost);
        scratch[choice.lhs_index] = .{
            .node = 0,
            .input_mask = combined_mask,
            .indices = result,
        };
        removeActive(scratch[0..active_count], choice.rhs_index);
        active_count -= 1;
    }
    return total;
}

fn immediateCompletionFlopCost(context: *const PlanningContext, active: []const Active) u128 {
    if (active.len <= 1) return 0;
    return bestImmediatePairEstimate(context, active).flop_cost;
}

fn immediateCompletionFlopCostCached(
    context: *const PlanningContext,
    active: []const Active,
    cache: *ImmediateCompletionCache,
) PlanError!u128 {
    std.debug.assert(active.len >= beam_immediate_cache_min);
    const key = greedyCompletionKey(active);
    if (cache.get(key)) |cost| return cost;
    const cost = immediateCompletionFlopCost(context, active);
    try cache.put(key, cost);
    return cost;
}

fn completionFlopCost(
    context: *const PlanningContext,
    active: []const Active,
    cache: *CompletionCache,
    completion_exact_limit: usize,
) PlanError!u128 {
    std.debug.assert(completion_exact_limit <= beam_exact_completion_max_inputs);
    if (active.len <= completion_exact_limit) {
        const key = exactCompletionKey(active);
        if (cache.exact.get(key)) |cost| return cost;
        const cost = exactCompletionFlopCost(context, active);
        try cache.exact.put(key, cost);
        return cost;
    }
    const key = greedyCompletionKey(active);
    if (cache.greedy.get(key)) |cost| return cost;
    const cost = greedyCompletionFlopCost(context, active);
    try cache.greedy.put(key, cost);
    return cost;
}

fn exactCompletionKey(active: []const Active) ExactCompletionKey {
    std.debug.assert(active.len <= beam_exact_completion_max_inputs);
    var key = ExactCompletionKey{ .count = @intCast(active.len) };
    writeCompletionMasks(key.masks[0..], active);
    return key;
}

fn greedyCompletionKey(active: []const Active) GreedyCompletionKey {
    std.debug.assert(active.len <= max_completion_key_inputs);
    var key = GreedyCompletionKey{ .count = @intCast(active.len) };
    writeCompletionMasks(key.masks[0..], active);
    return key;
}

fn writeCompletionMasks(masks: []u64, active: []const Active) void {
    for (active, 0..) |entry, index| {
        if (index > 0) std.debug.assert(active[index - 1].input_mask < entry.input_mask);
        masks[index] = entry.input_mask;
    }
}

fn exactCompletionFlopCost(context: *const PlanningContext, active: []const Active) u128 {
    if (active.len <= 1) return 0;
    std.debug.assert(active.len <= beam_exact_completion_max_inputs);

    var states: [exact_completion_state_count]CompletionState = undefined;
    @memset(&states, .{});
    for (active, 0..) |entry, index| {
        const mask: u64 = @as(u64, 1) << @intCast(index);
        states[@intCast(mask)] = .{
            .valid = true,
            .flop_cost = 0,
            .indices = entry.indices,
            .input_mask = entry.input_mask,
        };
    }

    const all_mask = (@as(u64, 1) << @intCast(active.len)) - 1;
    var mask: u64 = 1;
    while (mask <= all_mask) : (mask += 1) {
        if (isSingleton(mask)) continue;
        var sub = (mask - 1) & mask;
        while (sub != 0) : (sub = (sub - 1) & mask) {
            const other = mask ^ sub;
            if (other == 0 or sub > other) continue;
            const left = states[@intCast(sub)];
            const right = states[@intCast(other)];
            if (!left.valid or !right.valid) continue;
            const pair_indices = left.indices.unioned(right.indices);
            const input_mask = left.input_mask | right.input_mask;
            const result = resultIndices(context, input_mask, pair_indices);
            const cost = stepCost(context, left.indices, right.indices, result);
            const flop_cost = saturatingAdd(
                saturatingAdd(left.flop_cost, right.flop_cost),
                cost.flop,
            );
            if (!states[@intCast(mask)].valid or flop_cost < states[@intCast(mask)].flop_cost) {
                states[@intCast(mask)] = .{
                    .valid = true,
                    .flop_cost = flop_cost,
                    .indices = result,
                    .input_mask = input_mask,
                };
            }
        }
    }
    return states[@intCast(all_mask)].flop_cost;
}

fn bestImmediatePairEstimate(context: *const PlanningContext, active: []const Active) PairChoice {
    var best = pairChoice(context, active[0], active[1], 0, 1);
    for (0..active.len) |lhs_index| {
        for (lhs_index + 1..active.len) |rhs_index| {
            if (lhs_index == 0 and rhs_index == 1) continue;
            const candidate = pairChoice(
                context,
                active[lhs_index],
                active[rhs_index],
                lhs_index,
                rhs_index,
            );
            if (candidate.flop_cost < best.flop_cost or
                (candidate.flop_cost == best.flop_cost and
                    choicePeak(candidate) < choicePeak(best)))
            {
                best = candidate;
            }
        }
    }
    return best;
}

fn candidatePairCount(active_count: usize) u64 {
    if (active_count < 2) return 0;
    return @intCast((active_count * (active_count - 1)) / 2);
}

inline fn pairChoice(
    context: *const PlanningContext,
    lhs: Active,
    rhs: Active,
    lhs_index: usize,
    rhs_index: usize,
) PairChoice {
    const pair_indices = lhs.indices.unioned(rhs.indices);
    const combined_mask = lhs.input_mask | rhs.input_mask;
    const result = resultIndices(context, combined_mask, pair_indices);
    const cost = stepCost(context, lhs.indices, rhs.indices, result);
    return .{
        .lhs_index = lhs_index,
        .rhs_index = rhs_index,
        .cost = cost.scalar,
        .flop_cost = cost.flop,
        .score = cost.flop,
        .result_elements = context.elementCount(result),
        .work_elements = cost.work,
    };
}

inline fn stepCost(
    context: *const PlanningContext,
    lhs: IndexSet,
    rhs: IndexSet,
    result: IndexSet,
) StepCost {
    const pair_indices = lhs.unioned(rhs);
    const summed = pair_indices.without(result);
    const lhs_local = summed.intersected(lhs).without(rhs);
    const rhs_local = summed.intersected(rhs).without(lhs);
    const shared_summed = summed.intersected(lhs.intersected(rhs));
    const lhs_after = lhs.without(lhs_local);
    const rhs_after = rhs.without(rhs_local);
    const dot_indices = pair_indices.without(lhs_local).without(rhs_local);
    const dot_scalar = context.elementCount(dot_indices);
    var scalar = dot_scalar;
    var flops = flopCost(dot_scalar, shared_summed);
    var work: u128 = 0;
    if (!lhs_local.isEmpty()) {
        const reduction = context.elementCount(lhs);
        scalar = saturatingAdd(scalar, reduction);
        flops = saturatingAdd(flops, reduction);
        work = @max(work, context.elementCount(lhs_after));
    }
    if (!rhs_local.isEmpty()) {
        const reduction = context.elementCount(rhs);
        scalar = saturatingAdd(scalar, reduction);
        flops = saturatingAdd(flops, reduction);
        work = @max(work, context.elementCount(rhs_after));
    }
    if (!shared_summed.isEmpty() and !usesDotGeneralIndices(
        lhs_after,
        rhs_after,
        result,
        shared_summed,
    )) {
        work = @max(work, dot_scalar);
    }
    return .{
        .scalar = scalar,
        .flop = flops,
        .work = work,
    };
}

fn usesDotGeneralIndices(
    lhs: IndexSet,
    rhs: IndexSet,
    result: IndexSet,
    shared_summed: IndexSet,
) bool {
    const shared_result = lhs.intersected(rhs).intersected(result);
    return shared_result.isEmpty() and
        lhs.count() == 2 and
        rhs.count() == 2 and
        result.count() == 2 and
        shared_summed.count() == 1;
}

fn stepPeakContribution(step: Step, all_mask: u64) u128 {
    return stepPeakContributionValues(
        step.result_elements,
        step.work_elements,
        step.result_inputs,
        all_mask,
    );
}

fn stepPeakContributionValues(
    result_elements: u128,
    work_elements: u128,
    result_inputs: u64,
    all_mask: u64,
) u128 {
    const result_peak = if (result_inputs == all_mask) 0 else result_elements;
    return @max(result_peak, work_elements);
}

fn choicePeak(choice: PairChoice) u128 {
    return @max(choice.result_elements, choice.work_elements);
}

inline fn immediateFlopCost(context: *const PlanningContext, lhs: Active, rhs: Active) u128 {
    const pair_indices = lhs.indices.unioned(rhs.indices);
    const combined_mask = lhs.input_mask | rhs.input_mask;
    const result = resultIndices(context, combined_mask, pair_indices);
    return stepCost(context, lhs.indices, rhs.indices, result).flop;
}

inline fn resultIndices(
    context: *const PlanningContext,
    combined_mask: u64,
    pair_indices: IndexSet,
) IndexSet {
    return context.resultIndices(combined_mask, pair_indices);
}

fn removeActive(active: []Active, index: usize) void {
    var cursor = index;
    while (cursor + 1 < active.len) : (cursor += 1) {
        active[cursor] = active[cursor + 1];
    }
}

fn allInputsMask(input_count: usize) u64 {
    return (@as(u64, 1) << @intCast(input_count)) - 1;
}

fn isSingleton(mask: u64) bool {
    return mask != 0 and (mask & (mask - 1)) == 0;
}

fn saturatingAdd(lhs: u128, rhs: u128) u128 {
    const max = std.math.maxInt(u128);
    if (lhs > max - rhs) return max;
    return lhs + rhs;
}

fn saturatingAddU64(lhs: u64, rhs: u64) u64 {
    const max = std.math.maxInt(u64);
    if (lhs > max - rhs) return max;
    return lhs + rhs;
}

fn saturatingMul(lhs: u128, rhs: u128) u128 {
    if (lhs == 0 or rhs == 0) return 0;
    const max = std.math.maxInt(u128);
    if (lhs > max / rhs) return max;
    return lhs * rhs;
}

fn flopCost(scalar_cost: u128, summed_indices: IndexSet) u128 {
    if (summed_indices.isEmpty()) return scalar_cost;
    return saturatingMul(scalar_cost, 2);
}

fn expectSetContains(set: IndexSet, indices: []const u8) !void {
    for (indices) |index| try testing.expect(set.contains(index));
    try testing.expectEqual(@as(u32, @intCast(indices.len)), set.count());
}

fn greedyScore(context: *const PlanningContext, active: []const Active, choice: PairChoice) u128 {
    if (active.len <= 2) return choice.flop_cost;

    var next: [63]Active = undefined;
    const lhs = active[choice.lhs_index];
    const rhs = active[choice.rhs_index];
    const combined_mask = lhs.input_mask | rhs.input_mask;
    const pair_indices = lhs.indices.unioned(rhs.indices);
    const result = resultIndices(context, combined_mask, pair_indices);
    var next_count: usize = 0;
    for (active, 0..) |entry, index| {
        if (index == choice.rhs_index) continue;
        if (index == choice.lhs_index) {
            next[next_count] = .{
                .node = 0,
                .input_mask = combined_mask,
                .indices = result,
            };
        } else {
            next[next_count] = entry;
        }
        next_count += 1;
    }

    var best_next = immediateFlopCost(context, next[0], next[1]);
    for (0..next_count) |lhs_index| {
        for (lhs_index + 1..next_count) |rhs_index| {
            best_next = @min(
                best_next,
                immediateFlopCost(context, next[lhs_index], next[rhs_index]),
            );
        }
    }
    return saturatingAdd(choice.flop_cost, best_next);
}

test "einsum planner computes matrix product cost" {
    const shapes = [_][]const u64{ &.{ 2, 3 }, &.{ 3, 5 } };
    var equation = try spec.parse(testing.allocator, "ik,kj->ij", &shapes);
    defer equation.deinit();

    var plan = try createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer plan.deinit();

    try testing.expectEqual(Strategy.optimal, plan.strategy);
    try testing.expectEqual(@as(usize, 1), plan.steps.len);
    try testing.expectEqual(@as(u128, 30), plan.total_scalar_cost);
    try testing.expectEqual(@as(u128, 60), plan.total_flop_cost);
    try testing.expectEqual(@as(u128, 0), plan.peak_intermediate_elements);
    try testing.expectEqual(@as(u128, 0), plan.peak_workspace_elements);
    try testing.expectEqual(@as(u128, 10), plan.output_elements);
    try testing.expectEqual(@as(usize, 0), plan.selected_beam_width);
    try testing.expectEqual(@as(u64, 1), plan.search.candidate_contractions);
    try testing.expectEqual(@as(u64, 3), plan.search.states_created);
    try testing.expectEqual(@as(u64, 3), plan.search.states_kept);
    try testing.expectEqual(@as(u64, 0), plan.search.states_pruned);
    try testing.expectEqual(@as(u64, 3), plan.search.frontier_peak);
    try expectSetContains(plan.steps[0].summed_indices, "k");
    try expectSetContains(plan.steps[0].result_indices, "ij");
}

test "einsum planner handles scalar contraction output" {
    const shapes = [_][]const u64{ &.{7}, &.{7} };
    var equation = try spec.parse(testing.allocator, "i,i->", &shapes);
    defer equation.deinit();

    var plan = try createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 1), plan.steps.len);
    try testing.expectEqual(@as(u128, 7), plan.total_scalar_cost);
    try testing.expectEqual(@as(u128, 14), plan.total_flop_cost);
    try testing.expectEqual(@as(u128, 7), plan.peak_intermediate_elements);
    try testing.expectEqual(@as(u128, 7), plan.peak_workspace_elements);
    try testing.expectEqual(@as(u128, 1), plan.output_elements);
    try testing.expect(plan.steps[0].result_indices.isEmpty());
}

test "einsum planner accounts for single input reductions" {
    const shapes = [_][]const u64{&.{7}};
    var equation = try spec.parse(testing.allocator, "i->", &shapes);
    defer equation.deinit();

    var plan = try createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 0), plan.steps.len);
    try testing.expectEqual(@as(u128, 7), plan.total_scalar_cost);
    try testing.expectEqual(@as(u128, 7), plan.total_flop_cost);
    try testing.expectEqual(@as(u128, 0), plan.peak_intermediate_elements);
    try testing.expectEqual(@as(u128, 0), plan.peak_workspace_elements);
    try testing.expectEqual(@as(u128, 1), plan.output_elements);
}

test "einsum planner distinguishes matrix chain orderings" {
    const shapes = [_][]const u64{ &.{ 1000, 2 }, &.{ 2, 100 }, &.{ 100, 10 } };
    var equation = try spec.parse(testing.allocator, "ik,kl,lj->ij", &shapes);
    defer equation.deinit();

    var left = try createPlan(testing.allocator, &equation, .{ .strategy = .left_to_right });
    defer left.deinit();
    var greedy = try createPlan(testing.allocator, &equation, .{ .strategy = .greedy });
    defer greedy.deinit();
    var beam = try createPlan(testing.allocator, &equation, .{ .strategy = .beam });
    defer beam.deinit();
    var optimal = try createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer optimal.deinit();

    try testing.expectEqual(@as(u128, 1_200_000), left.total_scalar_cost);
    try testing.expectEqual(@as(u128, 22_000), greedy.total_scalar_cost);
    try testing.expectEqual(@as(u128, 22_000), beam.total_scalar_cost);
    try testing.expectEqual(@as(u128, 22_000), optimal.total_scalar_cost);
    try testing.expectEqual(Strategy.beam, beam.strategy);
    try testing.expectEqual(@as(u128, 44_000), optimal.total_flop_cost);
    try testing.expectEqual(@as(u64, 0b110), optimal.steps[0].result_inputs);
    try testing.expectEqual(@as(u128, 20), optimal.peak_intermediate_elements);
}

test "einsum exact planner optimizes four operand chain" {
    const shapes = [_][]const u64{ &.{ 20, 3 }, &.{ 3, 40 }, &.{ 40, 4 }, &.{ 4, 30 } };
    var equation = try spec.parse(testing.allocator, "ab,bc,cd,de->ae", &shapes);
    defer equation.deinit();

    var left = try createPlan(testing.allocator, &equation, .{ .strategy = .left_to_right });
    defer left.deinit();
    var greedy = try createPlan(testing.allocator, &equation, .{ .strategy = .greedy });
    defer greedy.deinit();
    var beam = try createPlan(
        testing.allocator,
        &equation,
        .{ .strategy = .beam, .beam_width = 3 },
    );
    defer beam.deinit();
    var optimal = try createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer optimal.deinit();

    try testing.expect(left.total_scalar_cost > optimal.total_scalar_cost);
    try testing.expectEqual(optimal.total_flop_cost, greedy.total_flop_cost);
    try testing.expectEqual(optimal.total_flop_cost, beam.total_flop_cost);
    try testing.expectEqual(@as(usize, 3), optimal.steps.len);
    try testing.expectEqual(@as(u128, 2_640), optimal.total_scalar_cost);
    try testing.expectEqual(@as(u128, 5_280), optimal.total_flop_cost);
    try testing.expectEqual(@as(u64, 25), optimal.search.candidate_contractions);
    try testing.expectEqual(@as(u64, 15), optimal.search.states_created);
    try testing.expectEqual(@as(u64, 15), optimal.search.states_kept);
    try testing.expectEqual(@as(u64, 15), optimal.search.frontier_peak);
}

test "einsum exact planner optimizes reported flop cost" {
    const shapes = [_][]const u64{ &.{ 5, 11 }, &.{ 5, 5 }, &.{ 11, 5, 19 }, &.{ 19, 5 } };
    var equation = try spec.parse(testing.allocator, "cd,ca,dae,ec->", &shapes);
    defer equation.deinit();

    var beam = try createPlan(testing.allocator, &equation, .{ .strategy = .beam });
    defer beam.deinit();
    var optimal = try createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer optimal.deinit();

    try testing.expectEqual(@as(u128, 5_595), optimal.total_scalar_cost);
    try testing.expectEqual(@as(u128, 10_915), optimal.total_flop_cost);
    try testing.expectEqual(optimal.total_flop_cost, beam.total_flop_cost);
}

test "einsum flop cost does not double pure outer-product steps" {
    const shapes = [_][]const u64{ &.{ 32, 4 }, &.{ 4, 64 }, &.{ 4, 3 }, &.{ 4, 16 } };
    var equation = try spec.parse(testing.allocator, "ab,bc,bd,be->acde", &shapes);
    defer equation.deinit();

    var greedy = try createPlan(testing.allocator, &equation, .{ .strategy = .greedy });
    defer greedy.deinit();
    var beam = try createPlan(testing.allocator, &equation, .{ .strategy = .beam });
    defer beam.deinit();
    var optimal = try createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer optimal.deinit();

    try testing.expectEqual(@as(u128, 396_032), optimal.total_scalar_cost);
    try testing.expectEqual(@as(u128, 789_248), optimal.total_flop_cost);
    try testing.expectEqual(optimal.total_flop_cost, greedy.total_flop_cost);
    try testing.expectEqual(optimal.total_flop_cost, beam.total_flop_cost);
}

test "einsum planner prices operand-local reductions before product" {
    const shapes = [_][]const u64{ &.{ 2, 3 }, &.{ 5, 7 } };
    var equation = try spec.parse(testing.allocator, "ab,cd->ac", &shapes);
    defer equation.deinit();

    var plan = try createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 1), plan.steps.len);
    try testing.expectEqual(@as(u128, 51), plan.steps[0].scalar_cost);
    try testing.expectEqual(@as(u128, 51), plan.steps[0].flop_cost);
    try testing.expectEqual(@as(u128, 5), plan.steps[0].work_elements);
    try testing.expectEqual(@as(u128, 51), plan.total_scalar_cost);
    try testing.expectEqual(@as(u128, 51), plan.total_flop_cost);
    try testing.expectEqual(@as(u128, 5), plan.peak_intermediate_elements);
    try testing.expectEqual(@as(u128, 5), plan.peak_workspace_elements);
}

test "einsum planner accounts for non-matmul contraction workspace" {
    const shapes = [_][]const u64{ &.{ 2, 3, 5 }, &.{ 2, 7, 5 } };
    var equation = try spec.parse(testing.allocator, "bqd,bkd->bqk", &shapes);
    defer equation.deinit();

    var plan = try createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 1), plan.steps.len);
    try testing.expectEqual(@as(u128, 210), plan.steps[0].scalar_cost);
    try testing.expectEqual(@as(u128, 420), plan.steps[0].flop_cost);
    try testing.expectEqual(@as(u128, 210), plan.steps[0].work_elements);
    try testing.expectEqual(@as(u128, 210), plan.peak_intermediate_elements);
    try testing.expectEqual(@as(u128, 210), plan.peak_workspace_elements);
}

test "einsum beam width controls retained frontier" {
    const shapes = [_][]const u64{ &.{ 32, 4 }, &.{ 4, 64 }, &.{ 4, 3 }, &.{ 4, 16 } };
    var equation = try spec.parse(testing.allocator, "ab,bc,bd,be->acde", &shapes);
    defer equation.deinit();

    var narrow = try createPlan(
        testing.allocator,
        &equation,
        .{ .strategy = .beam, .beam_width = 2 },
    );
    defer narrow.deinit();
    var wide = try createPlan(testing.allocator, &equation, .{ .strategy = .beam });
    defer wide.deinit();

    try testing.expectEqual(@as(u128, 789_248), narrow.total_flop_cost);
    try testing.expectEqual(@as(u128, 789_248), wide.total_flop_cost);
    try testing.expectEqual(@as(usize, 2), narrow.selected_beam_width);
    try testing.expectEqual(@as(usize, 64), wide.selected_beam_width);
    try testing.expectEqual(@as(u64, 14), narrow.search.candidate_contractions);
    try testing.expectEqual(@as(u64, 15), narrow.search.states_created);
    try testing.expectEqual(@as(u64, 6), narrow.search.states_kept);
    try testing.expectEqual(@as(u64, 0), narrow.search.states_pruned);
    try testing.expectEqual(@as(u64, 2), narrow.search.frontier_peak);
}

test "einsum beam ranking uses greedy completion estimate" {
    const shapes = [_][]const u64{
        &.{ 32, 4 },
        &.{ 4, 64 },
        &.{ 4, 3 },
        &.{ 4, 16 },
        &.{ 4, 5 },
        &.{ 4, 8 },
    };
    var equation = try spec.parse(testing.allocator, "ab,bc,bd,be,bf,bg->acdefg", &shapes);
    defer equation.deinit();

    var narrow = try createPlan(
        testing.allocator,
        &equation,
        .{ .strategy = .beam, .beam_width = 2 },
    );
    defer narrow.deinit();
    var optimal = try createPlan(testing.allocator, &equation, .{ .strategy = .optimal });
    defer optimal.deinit();

    try testing.expectEqual(@as(u128, 31_473_504), optimal.total_flop_cost);
    try testing.expectEqual(optimal.total_flop_cost, narrow.total_flop_cost);
    try testing.expectEqual(@as(u64, 55), narrow.search.candidate_contractions);
    try testing.expectEqual(@as(u64, 2), narrow.search.frontier_peak);
    try testing.expectEqual(@as(u64, 0), narrow.search.states_pruned);
}

test "einsum beam prunes states above greedy incumbent bound" {
    const shapes = [_][]const u64{
        &.{ 32, 32, 7 },
        &.{ 11, 16 },
        &.{ 64, 32, 16, 32 },
        &.{ 7, 32, 64, 11 },
        &.{ 16, 32, 4 },
        &.{ 4, 16 },
    };
    var equation = try spec.parse(testing.allocator, "dfh,ae,cgeb,hfca,efi,ie->d", &shapes);
    defer equation.deinit();

    var plan = try createPlan(testing.allocator, &equation, .{ .strategy = .beam });
    defer plan.deinit();

    try testing.expectEqual(@as(u128, 2_108_928), plan.total_flop_cost);
    try testing.expect(plan.search.states_pruned > 0);
    try testing.expect(plan.search.candidate_contractions > plan.search.states_created);
}

test "einsum anytime planner keeps best widening result" {
    const shapes = [_][]const u64{
        &.{ 32, 4 },
        &.{ 4, 64 },
        &.{ 4, 3 },
        &.{ 4, 16 },
        &.{ 4, 5 },
        &.{ 4, 8 },
    };
    var equation = try spec.parse(testing.allocator, "ab,bc,bd,be,bf,bg->acdefg", &shapes);
    defer equation.deinit();

    var beam = try createPlan(
        testing.allocator,
        &equation,
        .{ .strategy = .beam, .beam_width = 8 },
    );
    defer beam.deinit();
    var anytime = try createPlan(
        testing.allocator,
        &equation,
        .{ .strategy = .anytime, .beam_width = 8 },
    );
    defer anytime.deinit();

    try testing.expectEqual(Strategy.anytime, anytime.strategy);
    try testing.expect(anytime.selected_beam_width > 0);
    try testing.expect(anytime.selected_beam_width <= 8);
    try testing.expect(anytime.total_flop_cost <= beam.total_flop_cost);
    try testing.expect(anytime.search.candidate_contractions > beam.search.candidate_contractions);
    try testing.expectEqual(@as(u64, 8), anytime.search.frontier_peak);
}

test "einsum auto planner selects exact plan within state budget" {
    const shapes = [_][]const u64{
        &.{ 7, 5, 7 },
        &.{ 11, 4, 7 },
        &.{ 7, 5, 11 },
        &.{ 8, 3, 7, 5 },
        &.{ 7, 8, 7 },
        &.{ 5, 7 },
        &.{ 7, 16, 7, 5 },
        &.{ 5, 16, 7, 11 },
        &.{ 8, 5, 11, 5 },
        &.{ 8, 3, 7, 5 },
    };
    var equation = try spec.parse(
        testing.allocator,
        "hik,jak,hfj,edhg,hek,bh,kchb,gckj,egjf,edhf->acgi",
        &shapes,
    );
    defer equation.deinit();

    var plan = try createPlan(testing.allocator, &equation, .{ .strategy = .auto });
    defer plan.deinit();

    try testing.expectEqual(Strategy.optimal, plan.strategy);
    try testing.expectEqual(@as(usize, 0), plan.selected_beam_width);
    try testing.expectEqual(@as(u128, 622_020), plan.total_flop_cost);
    try testing.expectEqual(@as(u128, 172_480), plan.peak_workspace_elements);
}

test "einsum auto planner falls back to beam outside exact state budget" {
    const shapes = [_][]const u64{
        &.{ 7, 5, 7 },
        &.{ 11, 4, 7 },
        &.{ 7, 5, 11 },
        &.{ 8, 3, 7, 5 },
        &.{ 7, 8, 7 },
        &.{ 5, 7 },
        &.{ 7, 16, 7, 5 },
        &.{ 5, 16, 7, 11 },
        &.{ 8, 5, 11, 5 },
        &.{ 8, 3, 7, 5 },
    };
    var equation = try spec.parse(
        testing.allocator,
        "hik,jak,hfj,edhg,hek,bh,kchb,gckj,egjf,edhf->acgi",
        &shapes,
    );
    defer equation.deinit();

    var plan = try createPlan(testing.allocator, &equation, .{
        .strategy = .auto,
        .exact_state_limit = 1,
    });
    defer plan.deinit();

    try testing.expectEqual(Strategy.beam, plan.strategy);
    try testing.expectEqual(@as(usize, 64), plan.selected_beam_width);
    try testing.expectEqual(@as(u128, 622_020), plan.total_flop_cost);
    try testing.expectEqual(@as(u128, 172_480), plan.peak_workspace_elements);
}

test "einsum auto planner uses anytime beyond exact input boundary" {
    const shapes = [_][]const u64{
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
        &.{ 2, 2 },
    };
    var equation = try spec.parse(
        testing.allocator,
        "ab,bc,cd,de,ef,fg,gh,hi,ij,jk,kl,lm,mn,no,op,pq,qr,rs,st->at",
        &shapes,
    );
    defer equation.deinit();

    var plan = try createPlan(testing.allocator, &equation, .{
        .strategy = .auto,
        .auto_beam_width = 2,
    });
    defer plan.deinit();

    try testing.expectEqual(Strategy.anytime, plan.strategy);
    try testing.expect(plan.selected_beam_width > 0);
    try testing.expect(plan.selected_beam_width <= 2);
    try testing.expectEqual(@as(usize, 18), plan.steps.len);
}

test "einsum auto planner optimizes seventeen input tail fixture" {
    if (builtin.mode != .fast) return error.SkipZigTest;

    const shapes = [_][]const u64{
        &.{ 3, 4, 8, 8 },
        &.{ 7, 8, 5 },
        &.{ 3, 8, 2, 5 },
        &.{ 7, 8, 3, 8 },
        &.{ 7, 8, 4 },
        &.{ 8, 2, 8, 4 },
        &.{ 8, 3, 7, 8 },
        &.{ 2, 11, 3, 5 },
        &.{ 2, 5, 7, 2 },
        &.{ 5, 8, 8, 2 },
        &.{ 5, 4, 8, 8 },
        &.{ 11, 3, 8 },
        &.{ 11, 4, 3, 3 },
        &.{ 4, 11, 7, 2 },
        &.{ 8, 11, 8, 8 },
        &.{ 8, 11, 7, 8 },
        &.{ 3, 8, 7, 8 },
    };
    var equation = try spec.parse(
        testing.allocator,
        "Abot,ktz,Vcjz,IJVp,ILs,MOcs,MSho,OPSg,Ogkw,Hapw,Hbpu,deu,PQUe,QXhj,FXac,FPhn,Ackn->HUX",
        &shapes,
    );
    defer equation.deinit();

    var plan = try createPlan(testing.allocator, &equation, .{ .strategy = .auto });
    defer plan.deinit();

    try testing.expectEqual(Strategy.optimal, plan.strategy);
    try testing.expectEqual(@as(u128, 142_374_072), plan.total_flop_cost);
}

test "einsum auto planner uses exact boundary for fifteen inputs" {
    if (builtin.mode != .fast) return error.SkipZigTest;

    const shapes = [_][]const u64{
        &.{ 8, 11, 13 },
        &.{ 8, 4 },
        &.{ 11, 11 },
        &.{ 11, 13, 13, 11 },
        &.{ 13, 11, 11, 4 },
        &.{ 7, 7, 4 },
        &.{ 7, 11, 3 },
        &.{ 4, 2, 13 },
        &.{ 13, 4, 11, 3 },
        &.{ 7, 4, 3 },
        &.{ 3, 11 },
        &.{ 4, 13, 7, 4 },
        &.{ 8, 13 },
        &.{ 4, 13, 7, 3 },
        &.{ 3, 2, 3, 7 },
    };
    var equation = try spec.parse(
        testing.allocator,
        "bam,bj,ka,alik,moaf,pdj,dkc,jhe,ijkc,djc,ca,jidf,bm,jeng,ghcn->nlio",
        &shapes,
    );
    defer equation.deinit();

    var beam = try createPlan(testing.allocator, &equation, .{ .strategy = .beam });
    defer beam.deinit();
    var auto = try createPlan(testing.allocator, &equation, .{ .strategy = .auto });
    defer auto.deinit();
    var capped = try createPlan(testing.allocator, &equation, .{
        .strategy = .auto,
        .exact_state_limit = 16_384,
    });
    defer capped.deinit();

    try testing.expectEqual(Strategy.optimal, auto.strategy);
    try testing.expectEqual(Strategy.beam, capped.strategy);
    try testing.expectEqual(@as(u128, 4_434_221), auto.total_flop_cost);
    try testing.expectEqual(beam.total_flop_cost, capped.total_flop_cost);
    try testing.expect(beam.total_flop_cost > auto.total_flop_cost);
}

test "einsum exact state default covers eighteen inputs" {
    try testing.expect(canUseExactPlan(16, .{}));
    try testing.expect(canUseExactPlan(17, .{}));
    try testing.expect(canUseExactPlan(18, .{}));
    try testing.expect(!canUseExactPlan(19, .{}));
    try testing.expect(!canUseExactPlan(18, .{ .exact_state_limit = 131_072 }));
}

test "einsum auto planner uses exact boundary for sixteen inputs" {
    if (builtin.mode != .fast) return error.SkipZigTest;

    const shapes = [_][]const u64{
        &.{ 11, 7, 3, 8 },
        &.{ 3, 7, 3, 11 },
        &.{ 13, 3, 2 },
        &.{ 8, 5, 2, 13 },
        &.{ 8, 5, 13, 8 },
        &.{ 3, 13, 11, 2 },
        &.{ 13, 11, 3 },
        &.{ 11, 8, 13, 4 },
        &.{ 11, 8, 13, 4 },
        &.{ 13, 11, 7, 8 },
        &.{ 13, 8, 13, 8 },
        &.{ 8, 3, 8 },
        &.{ 3, 11, 7 },
        &.{ 13, 11, 8, 11 },
        &.{ 13, 5, 13, 2 },
        &.{ 5, 11, 7, 8 },
    };
    var equation = try spec.parse(
        testing.allocator,
        "XZab,YZas,CYn,bhnu,fhkz,cksx,JPc,Pbiw,Dfuw,ADZp,AGip,GMl,MSU,QSfs,ALQx,LXZz->QXw",
        &shapes,
    );
    defer equation.deinit();

    var auto = try createPlan(testing.allocator, &equation, .{ .strategy = .auto });
    defer auto.deinit();
    var capped = try createPlan(testing.allocator, &equation, .{
        .strategy = .auto,
        .exact_state_limit = 32_768,
    });
    defer capped.deinit();

    try testing.expectEqual(Strategy.optimal, auto.strategy);
    try testing.expectEqual(Strategy.beam, capped.strategy);
    try testing.expectEqual(@as(u128, 754_408_598), auto.total_flop_cost);
    try testing.expectEqual(@as(u128, 2_835_181_970), capped.total_flop_cost);
}

test "einsum planner work bound includes every greedy lookahead pair" {
    for (2..17) |count| {
        var evaluations: u64 = 0;
        for (0..count) |left| {
            for (left + 1..count) |_| {
                evaluations += 1;
                if (count == 2) continue;
                evaluations += 1;
                for (0..count - 1) |next_left| {
                    for (next_left + 1..count - 1) |_| evaluations += 1;
                }
            }
        }
        try testing.expectEqual(evaluations, PlannerWork.greedyEvaluations(count));
        const linear = try (Options{ .strategy = .left_to_right }).workBound(count);
        const greedy = try (Options{ .strategy = .greedy }).workBound(count);
        try testing.expect(greedy >= linear);
        if (count > 2) try testing.expect(greedy > linear);
    }
}

test "einsum planner work bound covers finite partition enumeration" {
    for (0..11) |count| {
        const states = @as(u64, 1) << @intCast(count);
        var assignments: u64 = 0;
        for (0..states) |mask| {
            var subset = mask;
            for (0..states) |_| {
                assignments += 1;
                if (subset == 0) break;
                subset = (subset - 1) & mask;
            } else unreachable;
        }
        try testing.expectEqual(assignments, try PlannerWork.partitions(count));
        if (count > 1) {
            try testing.expect(try PlannerWork.completion(count, count) >= assignments);
        }
    }
}

test "einsum planner work bound follows exact automatic and widening choices" {
    const shapes = [_][]const u64{ &.{ 32, 4 }, &.{ 4, 64 }, &.{ 4, 3 }, &.{ 4, 16 } };
    var equation = try spec.parse(testing.allocator, "ab,bc,bd,be->acde", &shapes);
    defer equation.deinit();
    for (comptime std.meta.tags(Strategy)) |strategy| {
        const options: Options = .{ .strategy = strategy, .beam_width = 3 };
        var plan = try createPlan(testing.allocator, &equation, options);
        defer plan.deinit();
        try testing.expect(try options.workBound(4) > plan.search.candidate_contractions);
        try testing.expect(try options.workBound(1) > 0);
    }
    const exact = try (Options{ .strategy = .optimal }).workBound(4);
    try testing.expectEqual(exact, try (Options{}).workBound(4));
    try testing.expectEqual(exact, try (Options{
        .strategy = .optimal,
        .exact_state_limit = 0,
    }).workBound(4));
    const beam = try (Options{ .strategy = .beam, .beam_width = 0 }).workBound(4);
    try testing.expectEqual(beam, try (Options{ .exact_state_limit = 0, .beam_width = 0 })
        .workBound(4));
    var widening: u64 = 0;
    for ([_]usize{ 1, 2, 3 }) |width| {
        widening += try (Options{ .strategy = .beam, .beam_width = width }).workBound(4);
    }
    try testing.expectEqual(widening, try (Options{ .strategy = .anytime, .beam_width = 3 })
        .workBound(4));
    try testing.expect(try (Options{ .max_exact_inputs = 2, .auto_beam_width = 3 })
        .workBound(4) > widening);
}

test "einsum planner work bound handles table boundaries and checked overflow" {
    const linear: Options = .{ .strategy = .left_to_right };
    for ([_]usize{ 10, 11, 18, 19, 63 }) |count| {
        try testing.expect(try linear.workBound(count) > count);
    }
    try testing.expect(try linear.workBound(18) > try linear.workBound(19));
    try testing.expectError(error.EmptyEquation, linear.workBound(0));
    try testing.expectError(error.TooManyInputs, linear.workBound(64));
    const exact: Options = .{ .strategy = .optimal, .max_exact_inputs = 63 };
    try testing.expectError(error.ExactInputLimitExceeded, exact.workBound(21));
    const enormous: Options = .{ .strategy = .beam, .beam_width = std.math.maxInt(usize) };
    try testing.expectError(error.WorkOverflow, enormous.workBound(11));
    try testing.expectError(error.WorkOverflow, PlannerWork.product(std.math.maxInt(u64), 2));
    try testing.expectError(error.WorkOverflow, PlannerWork.sum(std.math.maxInt(u64), 1));
}

fn storagePlanWitness(text: []const u8, shapes: []const []const u64, options: Options) !void {
    var equation = try spec.parse(testing.allocator, text, shapes);
    defer equation.deinit();
    var expected = try createPlan(testing.allocator, &equation, options);
    defer expected.deinit();
    try testing.expect(try options.workBound(shapes.len) > expected.search.candidate_contractions);
    const bound = try options.storageBound(shapes.len);
    const bytes = try testing.allocator.alloc(u8, @intCast(bound));
    defer testing.allocator.free(bytes);
    var buffer = std.heap.FixedBufferAllocator.init(bytes);
    const base = buffer.allocator();
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = base.vtable.alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    };
    const allocator: std.mem.Allocator = .{ .ptr = base.ptr, .vtable = &vtable };
    var plan = try createPlan(allocator, &equation, options);
    defer plan.deinit();
    try testing.expectEqual(expected.strategy, plan.strategy);
    try testing.expectEqual(expected.selected_beam_width, plan.selected_beam_width);
    try testing.expectEqualDeep(expected.steps, plan.steps);
    try testing.expectEqualDeep(expected.search, plan.search);
    try testing.expectEqual(expected.total_flop_cost, plan.total_flop_cost);
    try testing.expect(buffer.end_index <= bound);
}

test "einsum planner storage bound covers every strategy and automatic branch" {
    const shapes = [_][]const u64{ &.{ 32, 4 }, &.{ 4, 64 }, &.{ 4, 3 }, &.{ 4, 16 } };
    for (comptime std.meta.tags(Strategy)) |strategy| {
        try storagePlanWitness("ab,bc,bd,be->acde", &shapes, .{
            .strategy = strategy,
            .beam_width = 3,
        });
        try storagePlanWitness("ab->a", &.{&.{ 2, 3 }}, .{ .strategy = strategy });
    }
    try storagePlanWitness("ab,bc,bd,be->acde", &shapes, .{
        .exact_state_limit = 0,
        .beam_width = 0,
    });
    try storagePlanWitness("ab,bc,bd,be->acde", &shapes, .{
        .max_exact_inputs = 2,
        .auto_beam_width = 3,
    });
    const exact = try (Options{ .strategy = .optimal }).storageBound(4);
    try testing.expectEqual(exact, try (Options{}).storageBound(4));
    try testing.expectEqual(exact, try (Options{
        .strategy = .optimal,
        .exact_state_limit = 0,
    }).storageBound(4));
}

test "einsum planner storage bound covers completion caches and widening" {
    const shapes: [19][]const u64 = @splat(&.{ 2, 2 });
    const short = "ab,bc,cd,de,ef,fg,gh,hi,ij,jk,kl->al";
    for ([_]Strategy{ .beam, .anytime, .optimal }) |strategy| {
        try storagePlanWitness(short, shapes[0..11], .{
            .strategy = strategy,
            .beam_width = 3,
        });
    }
    try storagePlanWitness(
        "ab,bc,cd,de,ef,fg,gh,hi,ij,jk,kl,lm,mn,no,op,pq,qr,rs,st->at",
        &shapes,
        .{ .auto_beam_width = 2 },
    );
    const beam = try (Options{ .strategy = .beam, .beam_width = 3 }).storageBound(11);
    const anytime = try (Options{ .strategy = .anytime, .beam_width = 3 }).storageBound(11);
    try testing.expect(anytime > beam);
}

test "einsum planner storage bound covers precomputation and input boundaries" {
    const shapes: [63][]const u64 = @splat(&.{2});
    var text: [129]u8 = undefined;
    for (0..63) |index| {
        text[index * 2] = 'i';
        text[index * 2 + 1] = ',';
    }
    for ([_]usize{ 10, 11, 18, 19, 63 }) |count| {
        var equation = text;
        @memcpy(equation[count * 2 - 1 ..][0..3], "->i");
        try storagePlanWitness(equation[0 .. count * 2 + 2], shapes[0..count], .{
            .strategy = .left_to_right,
        });
    }
    const linear: Options = .{ .strategy = .left_to_right };
    const with_tables = try linear.storageBound(18);
    try testing.expect(with_tables >= 2 * (1 << 18) * @sizeOf(IndexSet));
    try testing.expect(try linear.storageBound(19) < with_tables);
    try testing.expectError(error.EmptyEquation, linear.storageBound(0));
    try testing.expectError(error.TooManyInputs, linear.storageBound(64));
    try testing.expectError(error.ExactInputLimitExceeded, (Options{
        .strategy = .optimal,
        .max_exact_inputs = 63,
    }).storageBound(21));
    try testing.expectError(error.WorkOverflow, (Options{
        .strategy = .beam,
        .beam_width = std.math.maxInt(usize),
    }).storageBound(2));
}
