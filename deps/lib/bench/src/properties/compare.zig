const std = @import("std");
const bench = @import("bench");
const hypothesis = @import("hypothesis");
const pretty = @import("pretty");

const Allocator = std.mem.Allocator;
const Comparison = bench.compare.ExecutionComparison;
const Effect = bench.compare.EffectInterval;
const Observation = bench.compare.ExecutionObservation;
const fs_io = std.Options.debug_io;
const max_observations: usize = 24;
const max_bootstrap_iterations: u32 = 63;

fn settings() hypothesis.Settings {
    return hypothesis.Settings.ci()
        .withSeed(0x4245_4e43_434f_4d50)
        .withDatabase("zig-out/hypothesis-failures/bench-compare");
}

fn drawUsize(
    data: *hypothesis.ConjectureData,
    min: usize,
    max: usize,
    towards: usize,
) !usize {
    return @intCast(try data.drawInteger(
        @intCast(min),
        @intCast(max),
        @intCast(towards),
    ));
}

fn drawScalar(data: *hypothesis.ConjectureData) !f64 {
    const edges = [_]u64{ 0, 1, 2, 3, 7, 99, 100, 1_000, 1_000_000, 2_000_000_000 };
    const numerator = if (try data.drawBoolean())
        edges[try drawUsize(data, 0, edges.len - 1, 0)]
    else
        try data.drawInteger(0, 2_000_000_000, 0);
    const value = @as(f64, @floatFromInt(numerator)) / 2.0;
    if (value == 0 and try data.drawBoolean()) return -0.0;
    return value;
}

fn drawObservation(data: *hypothesis.ConjectureData) !Observation {
    return .{
        .mean = try drawScalar(data),
        .median = try drawScalar(data),
    };
}

fn drawIterations(data: *hypothesis.ConjectureData) !u32 {
    const edges = [_]u32{ 1, 2, 3, 7, 31, max_bootstrap_iterations };
    if (try data.drawBoolean()) {
        return edges[try drawUsize(data, 0, edges.len - 1, 0)];
    }
    return @intCast(try drawUsize(data, 1, max_bootstrap_iterations, 1));
}

fn drawThreshold(data: *hypothesis.ConjectureData) !f64 {
    const per_mille = try drawUsize(data, 1000, 2000, 1050);
    return @as(f64, @floatFromInt(per_mille)) / 1000.0;
}

const Scenario = struct {
    baseline: [max_observations]Observation = undefined,
    candidate: [max_observations]Observation = undefined,
    baseline_len: usize,
    candidate_len: usize,
    threshold: f64,
    min_runs: u32,
    iterations: u32,

    fn draw(data: *hypothesis.ConjectureData) !Scenario {
        const baseline_len = try drawUsize(data, 1, max_observations, 4);
        const candidate_len = try drawUsize(data, 1, max_observations, 4);
        var scenario = Scenario{
            .baseline_len = baseline_len,
            .candidate_len = candidate_len,
            .threshold = try drawThreshold(data),
            .min_runs = @intCast(try drawUsize(
                data,
                1,
                max_observations + 1,
                1,
            )),
            .iterations = try drawIterations(data),
        };
        for (scenario.baseline[0..baseline_len]) |*item| {
            item.* = try drawObservation(data);
        }
        for (scenario.candidate[0..candidate_len]) |*item| {
            item.* = try drawObservation(data);
        }
        return scenario;
    }

    fn base(self: *const Scenario) []const Observation {
        return self.baseline[0..self.baseline_len];
    }

    fn cand(self: *const Scenario) []const Observation {
        return self.candidate[0..self.candidate_len];
    }
};

fn shuffle(
    data: *hypothesis.ConjectureData,
    values: []Observation,
) !void {
    var remaining = values.len;
    while (remaining > 1) {
        const selected = try drawUsize(data, 0, remaining - 1, 0);
        remaining -= 1;
        std.mem.swap(Observation, &values[remaining], &values[selected]);
    }
}

fn options(scenario: Scenario) bench.compare.ExecutionAnalysisOptions {
    return .{
        .threshold = scenario.threshold,
        .min_runs = scenario.min_runs,
        .bootstrap_iterations = scenario.iterations,
    };
}

fn expectEffectEqual(expected: ?Effect, actual: ?Effect) !void {
    if ((expected == null) != (actual == null)) return error.EffectPresenceMismatch;
    if (expected) |value| {
        try std.testing.expectEqual(value.low_percent, actual.?.low_percent);
        try std.testing.expectEqual(value.high_percent, actual.?.high_percent);
    }
}

fn expectComparisonEqual(expected: Comparison, actual: Comparison) !void {
    try std.testing.expectEqual(expected.classification, actual.classification);
    try std.testing.expectEqual(expected.baseline, actual.baseline);
    try std.testing.expectEqual(expected.candidate, actual.candidate);
    try std.testing.expectEqual(expected.ratio, actual.ratio);
    try expectEffectEqual(expected.effect, actual.effect);
    try std.testing.expectEqual(expected.bootstrap_iterations, actual.bootstrap_iterations);
    try std.testing.expectEqualStrings(expected.evidence, actual.evidence);
}

fn expectEffectOrdered(effect: ?Effect) !void {
    if (effect) |interval| {
        try std.testing.expect(std.math.isFinite(interval.low_percent));
        try std.testing.expect(std.math.isFinite(interval.high_percent));
        try std.testing.expect(interval.low_percent <= interval.high_percent);
    }
}

fn canonicalMedians(
    observations: []const Observation,
    output: []f64,
) []const f64 {
    std.debug.assert(observations.len > 0);
    std.debug.assert(output.len >= observations.len);
    const values = output[0..observations.len];
    for (observations, values) |item, *value| {
        value.* = if (item.median == 0) 0 else item.median;
    }
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values;
}

fn resampleMedian(
    random: std.Random,
    sorted: []const f64,
    scratch: []f64,
) f64 {
    std.debug.assert(sorted.len > 0);
    std.debug.assert(scratch.len >= sorted.len);
    const sample = scratch[0..sorted.len];
    for (sample) |*value| {
        value.* = sorted[random.intRangeLessThan(usize, 0, sorted.len)];
    }
    std.mem.sort(f64, sample, {}, std.sort.asc(f64));
    const middle = sample.len / 2;
    if (sample.len % 2 == 1) return sample[middle];
    return sample[middle - 1] + (sample[middle] - sample[middle - 1]) / 2.0;
}

fn referenceEffect(
    baseline: []const Observation,
    candidate: []const Observation,
    iterations: u32,
) ?Effect {
    var baseline_values: [max_observations]f64 = undefined;
    var candidate_values: [max_observations]f64 = undefined;
    var scratch: [max_observations]f64 = undefined;
    var effects: [max_bootstrap_iterations]f64 = undefined;
    const base = canonicalMedians(baseline, &baseline_values);
    const cand = canonicalMedians(candidate, &candidate_values);
    var prng = std.Random.DefaultPrng.init(bench.compare.bootstrap_seed);
    const random = prng.random();
    for (effects[0..iterations]) |*value| {
        value.* = resampleMedian(random, base, &scratch);
    }
    for (effects[0..iterations]) |*value| {
        if (value.* == 0) return null;
        const ratio = resampleMedian(random, cand, &scratch) / value.*;
        if (!std.math.isFinite(ratio)) return null;
        value.* = ratio * 100.0 - 100.0;
        if (!std.math.isFinite(value.*)) return null;
    }
    const distribution = effects[0..iterations];
    std.mem.sort(f64, distribution, {}, std.sort.asc(f64));
    const tail: u16 = @intCast((1000 - bench.compare.confidence_per_mille) / 2);
    return .{
        .low_percent = referenceQuantile(distribution, tail, false),
        .high_percent = referenceQuantile(distribution, 1000 - tail, true),
    };
}

fn referenceQuantile(
    sorted: []const f64,
    per_mille: u16,
    upper: bool,
) f64 {
    std.debug.assert(sorted.len > 0);
    const numerator = (sorted.len - 1) * @as(usize, per_mille);
    const index = if (upper) (numerator + 999) / 1000 else numerator / 1000;
    return sorted[@min(index, sorted.len - 1)];
}

fn scale(
    source: []const Observation,
    output: []Observation,
    factor: f64,
) []const Observation {
    std.debug.assert(output.len >= source.len);
    std.debug.assert(factor >= 1);
    for (source, output[0..source.len]) |item, *scaled| {
        scaled.* = .{ .mean = item.mean * factor, .median = item.median * factor };
    }
    return output[0..source.len];
}

fn runScenario(
    data: *hypothesis.ConjectureData,
    scenario: Scenario,
    allocator: Allocator,
) !void {
    var storage = try bench.ComparisonStorage.init(allocator, .{
        .max_samples_per_series = @max(scenario.baseline_len, scenario.candidate_len),
        .max_bootstrap_iterations = scenario.iterations,
    });
    defer storage.deinit(allocator);
    storage.activate();
    const original = try bench.compare.analyzeExecutions(
        &storage,
        scenario.base(),
        scenario.cand(),
        options(scenario),
    );
    const repeated = try bench.compare.analyzeExecutions(
        &storage,
        scenario.base(),
        scenario.cand(),
        options(scenario),
    );
    try expectComparisonEqual(original, repeated);
    try expectEffectOrdered(original.effect);
    var shuffled_baseline: [max_observations]Observation = undefined;
    var shuffled_candidate: [max_observations]Observation = undefined;
    @memcpy(shuffled_baseline[0..scenario.baseline_len], scenario.base());
    @memcpy(shuffled_candidate[0..scenario.candidate_len], scenario.cand());
    try shuffle(data, shuffled_baseline[0..scenario.baseline_len]);
    try shuffle(data, shuffled_candidate[0..scenario.candidate_len]);
    const permuted = try bench.compare.analyzeExecutions(
        &storage,
        shuffled_baseline[0..scenario.baseline_len],
        shuffled_candidate[0..scenario.candidate_len],
        options(scenario),
    );
    try expectComparisonEqual(original, permuted);
    const enough = scenario.baseline_len >= scenario.min_runs and
        scenario.candidate_len >= scenario.min_runs;
    try expectEffectEqual(
        if (enough)
            referenceEffect(scenario.base(), scenario.cand(), scenario.iterations)
        else
            null,
        original.effect,
    );
    const swapped = try bench.compare.analyzeExecutions(
        &storage,
        scenario.cand(),
        scenario.base(),
        options(scenario),
    );
    try std.testing.expectEqual(original.baseline, swapped.candidate);
    try std.testing.expectEqual(original.candidate, swapped.baseline);
    try expectScaleInvariance(data, scenario, &storage, original);
    try expectConstantSwapSymmetry(&storage, scenario);
}

fn expectScaleInvariance(
    data: *hypothesis.ConjectureData,
    scenario: Scenario,
    storage: *bench.ComparisonStorage,
    original: Comparison,
) !void {
    const factor = @as(f64, @floatFromInt(@as(u8, 1) << @intCast(
        try drawUsize(data, 0, 3, 0),
    )));
    var scaled_baseline: [max_observations]Observation = undefined;
    var scaled_candidate: [max_observations]Observation = undefined;
    const scaled = try bench.compare.analyzeExecutions(
        storage,
        scale(scenario.base(), &scaled_baseline, factor),
        scale(scenario.cand(), &scaled_candidate, factor),
        options(scenario),
    );
    try std.testing.expectEqual(original.classification, scaled.classification);
    try std.testing.expectEqual(original.ratio, scaled.ratio);
    try expectEffectEqual(original.effect, scaled.effect);
}

fn expectConstantSwapSymmetry(
    storage: *bench.ComparisonStorage,
    scenario: Scenario,
) !void {
    var lower: [max_observations]Observation = undefined;
    var upper: [max_observations]Observation = undefined;
    @memset(lower[0..scenario.baseline_len], .{ .mean = 256, .median = 256 });
    @memset(upper[0..scenario.candidate_len], .{ .mean = 512, .median = 512 });
    const symmetry_options = bench.compare.ExecutionAnalysisOptions{
        .threshold = 1.5,
        .min_runs = 1,
        .bootstrap_iterations = scenario.iterations,
    };
    const regression = try bench.compare.analyzeExecutions(
        storage,
        lower[0..scenario.baseline_len],
        upper[0..scenario.candidate_len],
        symmetry_options,
    );
    const improvement = try bench.compare.analyzeExecutions(
        storage,
        upper[0..scenario.candidate_len],
        lower[0..scenario.baseline_len],
        symmetry_options,
    );
    try std.testing.expectEqual(
        bench.compare.Classification.regression,
        regression.classification,
    );
    try std.testing.expectEqual(
        bench.compare.Classification.improvement,
        improvement.classification,
    );
    try std.testing.expectEqual(regression.baseline, improvement.candidate);
    try std.testing.expectEqual(regression.candidate, improvement.baseline);
}

fn drawU64(data: *hypothesis.ConjectureData) !u64 {
    const edges = [_]u64{
        0,
        1,
        2,
        7,
        99,
        100,
        1_000_000,
        (1 << 53) - 1,
        1 << 53,
        @as(u64, @intCast(std.math.maxInt(i64))),
        std.math.maxInt(u64),
    };
    if (try data.drawBoolean()) {
        return edges[try drawUsize(data, 0, edges.len - 1, 0)];
    }
    return try data.drawInteger(0, std.math.maxInt(u64), 0);
}

const U64Scenario = struct {
    baseline: [max_observations]u64 = undefined,
    candidate: [max_observations]u64 = undefined,
    baseline_len: usize,
    candidate_len: usize,
    iterations: u32,
    seed: u64,

    fn draw(data: *hypothesis.ConjectureData) !U64Scenario {
        const baseline_len = try drawUsize(data, 1, max_observations, 4);
        const candidate_len = try drawUsize(data, 1, max_observations, 4);
        var scenario = U64Scenario{
            .baseline_len = baseline_len,
            .candidate_len = candidate_len,
            .iterations = try drawIterations(data),
            .seed = try data.drawInteger(0, std.math.maxInt(u64), 0),
        };
        for (scenario.baseline[0..baseline_len]) |*value| {
            value.* = try drawU64(data);
        }
        for (scenario.candidate[0..candidate_len]) |*value| {
            value.* = try drawU64(data);
        }
        return scenario;
    }

    fn base(self: *const U64Scenario) []const u64 {
        return self.baseline[0..self.baseline_len];
    }

    fn cand(self: *const U64Scenario) []const u64 {
        return self.candidate[0..self.candidate_len];
    }
};

fn shuffleU64(data: *hypothesis.ConjectureData, values: []u64) !void {
    var remaining = values.len;
    while (remaining > 1) {
        const selected = try drawUsize(data, 0, remaining - 1, 0);
        remaining -= 1;
        std.mem.swap(u64, &values[remaining], &values[selected]);
    }
}

fn canonicalU64(values: []const u64, output: []u64) []const u64 {
    std.debug.assert(values.len > 0);
    std.debug.assert(output.len >= values.len);
    const sorted = output[0..values.len];
    @memcpy(sorted, values);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return sorted;
}

fn resampleU64Median(
    random: std.Random,
    sorted: []const u64,
    scratch: []u64,
) u64 {
    std.debug.assert(sorted.len > 0);
    std.debug.assert(scratch.len >= sorted.len);
    const sample = scratch[0..sorted.len];
    for (sample) |*value| {
        value.* = sorted[random.intRangeLessThan(usize, 0, sorted.len)];
    }
    std.mem.sort(u64, sample, {}, std.sort.asc(u64));
    return sample[sample.len / 2];
}

fn referenceU64Ratio(
    baseline: []const u64,
    candidate: []const u64,
    iterations: u32,
    seed: u64,
) bench.compare.U64MedianRatio {
    var baseline_values: [max_observations]u64 = undefined;
    var candidate_values: [max_observations]u64 = undefined;
    var scratch: [max_observations]u64 = undefined;
    var distribution: [max_bootstrap_iterations]f64 = undefined;
    const base = canonicalU64(baseline, &baseline_values);
    const cand = canonicalU64(candidate, &candidate_values);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (distribution[0..iterations]) |*value| {
        value.* = @floatFromInt(resampleU64Median(random, base, &scratch));
    }
    for (distribution[0..iterations]) |*value| {
        const candidate_median = resampleU64Median(random, cand, &scratch);
        value.* = referenceU64RatioValue(candidate_median, value.*);
    }
    const effects = distribution[0..iterations];
    std.mem.sort(f64, effects, {}, std.sort.asc(f64));
    const low_index = (effects.len * 25) / 1000;
    const high_index = (effects.len * 975) / 1000;
    return .{
        .baseline_median = base[base.len / 2],
        .candidate_median = cand[cand.len / 2],
        .ratio = referenceU64RatioValue(cand[cand.len / 2], @floatFromInt(base[base.len / 2])),
        .low_ratio = effects[@min(low_index, effects.len - 1)],
        .high_ratio = effects[@min(high_index, effects.len - 1)],
    };
}

fn referenceU64RatioValue(candidate: u64, baseline: f64) f64 {
    if (baseline == 0) return std.math.inf(f64);
    return @as(f64, @floatFromInt(candidate)) / baseline;
}

fn runU64Scenario(
    data: *hypothesis.ConjectureData,
    scenario: U64Scenario,
    allocator: Allocator,
) !void {
    var storage = try bench.ComparisonStorage.init(allocator, .{
        .max_samples_per_series = @max(scenario.baseline_len, scenario.candidate_len),
        .max_bootstrap_iterations = scenario.iterations,
    });
    defer storage.deinit(allocator);
    storage.activate();
    const original = try bench.compare.analyzeU64Medians(
        &storage,
        scenario.base(),
        scenario.cand(),
        scenario.iterations,
        scenario.seed,
    );
    const repeated = try bench.compare.analyzeU64Medians(
        &storage,
        scenario.base(),
        scenario.cand(),
        scenario.iterations,
        scenario.seed,
    );
    try std.testing.expectEqual(original, repeated);
    try std.testing.expect(original.low_ratio <= original.high_ratio);
    var shuffled_baseline: [max_observations]u64 = undefined;
    var shuffled_candidate: [max_observations]u64 = undefined;
    @memcpy(shuffled_baseline[0..scenario.baseline_len], scenario.base());
    @memcpy(shuffled_candidate[0..scenario.candidate_len], scenario.cand());
    try shuffleU64(data, shuffled_baseline[0..scenario.baseline_len]);
    try shuffleU64(data, shuffled_candidate[0..scenario.candidate_len]);
    const permuted = try bench.compare.analyzeU64Medians(
        &storage,
        shuffled_baseline[0..scenario.baseline_len],
        shuffled_candidate[0..scenario.candidate_len],
        scenario.iterations,
        scenario.seed,
    );
    try std.testing.expectEqual(original, permuted);
    try std.testing.expectEqual(
        referenceU64Ratio(
            scenario.base(),
            scenario.cand(),
            scenario.iterations,
            scenario.seed,
        ),
        original,
    );
}

fn diagnose(allocator: Allocator, scenario: Scenario, err: anyerror) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var report = pretty.diagnostic.Report.init(
        arena_state.allocator(),
        "bench comparison property failed",
    ) catch return;
    defer report.deinit();
    report.field("error", "{s}", .{@errorName(err)}) catch return;
    report.field("baseline", "{any}", .{scenario.base()}) catch return;
    report.field("candidate", "{any}", .{scenario.cand()}) catch return;
    report.field("threshold", "{d}", .{scenario.threshold}) catch return;
    report.field("minimum runs", "{d}", .{scenario.min_runs}) catch return;
    report.field("bootstrap iterations", "{d}", .{scenario.iterations}) catch return;
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stderr().writer(fs_io, &buffer);
    report.write(&writer.interface, .{ .width = 100 }) catch return;
    writer.interface.writeByte('\n') catch return;
    writer.interface.flush() catch return;
}

fn diagnoseU64(allocator: Allocator, scenario: U64Scenario, err: anyerror) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var report = pretty.diagnostic.Report.init(
        arena_state.allocator(),
        "bench integer comparison property failed",
    ) catch return;
    defer report.deinit();
    report.field("error", "{s}", .{@errorName(err)}) catch return;
    report.field("baseline", "{any}", .{scenario.base()}) catch return;
    report.field("candidate", "{any}", .{scenario.cand()}) catch return;
    report.field("bootstrap iterations", "{d}", .{scenario.iterations}) catch return;
    report.field("seed", "{d}", .{scenario.seed}) catch return;
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stderr().writer(fs_io, &buffer);
    report.write(&writer.interface, .{ .width = 100 }) catch return;
    writer.interface.writeByte('\n') catch return;
    writer.interface.flush() catch return;
}

pub const ComparisonProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        const scenario = try Scenario.draw(data);
        runScenario(data, scenario, allocator) catch |err| {
            diagnose(allocator, scenario, err);
            return err;
        };
    }
};

pub const U64ComparisonProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        const scenario = try U64Scenario.draw(data);
        runU64Scenario(data, scenario, allocator) catch |err| {
            diagnoseU64(allocator, scenario, err);
            return err;
        };
    }
};

test "property: execution comparison follows canonical bootstrap model" {
    try hypothesis.checkNamed(
        ComparisonProperty,
        "bench-execution-comparison",
        settings(),
    );
}

test "property: integer median comparison follows canonical bootstrap model" {
    try hypothesis.checkNamed(
        U64ComparisonProperty,
        "bench-u64-median-comparison",
        settings().withSeed(0x4245_4e43_5536_3443),
    );
}

test "comparison verdict ignores execution order at a material boundary" {
    const baseline_source = [_]Observation{
        .{ .mean = 100, .median = 100 },
        .{ .mean = 105, .median = 105 },
        .{ .mean = 95, .median = 95 },
        .{ .mean = 102, .median = 102 },
        .{ .mean = 98, .median = 98 },
        .{ .mean = 101, .median = 101 },
        .{ .mean = 96, .median = 96 },
        .{ .mean = 104, .median = 104 },
    };
    const candidate_source = [_]Observation{
        .{ .mean = 120, .median = 120 },
        .{ .mean = 126, .median = 126 },
        .{ .mean = 114, .median = 114 },
        .{ .mean = 122, .median = 122 },
        .{ .mean = 118, .median = 118 },
        .{ .mean = 121, .median = 121 },
        .{ .mean = 115, .median = 115 },
        .{ .mean = 125, .median = 125 },
    };
    var baseline = baseline_source;
    var candidate = candidate_source;
    var storage = try bench.ComparisonStorage.init(std.testing.allocator, .{
        .max_samples_per_series = baseline.len,
        .max_bootstrap_iterations = bench.compare.default_bootstrap_iterations,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    const original = try bench.compare.analyzeExecutions(
        &storage,
        &baseline,
        &candidate,
        .{ .threshold = 1.141, .min_runs = baseline.len },
    );
    std.mem.reverse(Observation, &baseline);
    std.mem.reverse(Observation, &candidate);
    const reversed = try bench.compare.analyzeExecutions(
        &storage,
        &baseline,
        &candidate,
        .{ .threshold = 1.141, .min_runs = baseline.len },
    );
    try expectComparisonEqual(original, reversed);
}
