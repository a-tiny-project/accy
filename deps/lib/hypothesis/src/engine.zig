const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const conjecture = @import("conjecture.zig");
const ConjectureData = conjecture.ConjectureData;
const ChoiceNode = conjecture.ChoiceNode;
const Status = conjecture.Status;
const DrawError = conjecture.DrawError;
const shrinker_mod = @import("shrinker.zig");
const database = @import("database.zig");

pub const TestFn = *const fn (data: *ConjectureData, allocator: Allocator) anyerror!void;
pub const TestFnWithContext = *const fn (
    data: *ConjectureData,
    allocator: Allocator,
    context: *anyopaque,
) anyerror!void;

pub const SeedCase = struct {
    choices: []const ChoiceNode,
    byte_blocks: ?[]const u8,
};

pub const Settings = struct {
    max_examples: usize = 100,
    max_replays: usize = 100,
    max_choices: usize = 4096,
    max_input_bytes: usize = conjecture.default_max_input_bytes,
    max_shrinks: usize = 5000,
    target_examples: usize = 100,
    seed: ?u64 = null,
    database_path: ?[]const u8 = null,
    database_namespace: ?[]const u8 = null,
    shrinking: bool = true,
    report_failure: bool = true,
    per_example_leak_check: bool = false,

    pub fn quick() Settings {
        return .{
            .max_examples = 25,
            .max_replays = 25,
            .max_choices = 2048,
            .max_input_bytes = 256 * 1024,
            .max_shrinks = 1000,
            .target_examples = 25,
        };
    }

    pub fn dev() Settings {
        return .{};
    }

    pub fn ci() Settings {
        return .{
            .max_examples = 1000,
            .max_replays = 1000,
            .max_choices = 8192,
            .max_input_bytes = 4 * 1024 * 1024,
            .max_shrinks = 20_000,
            .target_examples = 1000,
        };
    }

    pub fn withSeed(self: Settings, seed: ?u64) Settings {
        var out = self;
        out.seed = seed;
        return out;
    }

    pub fn withDatabase(self: Settings, path: ?[]const u8) Settings {
        var out = self;
        out.database_path = path;
        return out;
    }

    pub fn withNamespace(self: Settings, namespace: ?[]const u8) Settings {
        var out = self;
        out.database_namespace = namespace;
        return out;
    }

    pub fn withSeedFromEnv(self: Settings) Settings {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return self;
        const threaded = std.Options.debug_threaded_io orelse return self;
        const text = std.process.Environ.getPosix(
            threaded.environ.process_environ,
            seed_env_name,
        ) orelse return self;
        return self.withSeedText(text);
    }

    pub fn withSeedText(self: Settings, text: []const u8) Settings {
        var out = self;
        if (std.mem.eql(u8, text, "random")) {
            out.seed = null;
            return out;
        }
        out.seed = std.fmt.parseUnsigned(u64, text, 0) catch
            @panic(seed_env_name ++ " must be an unsigned integer or \"random\"");
        return out;
    }
};

pub const seed_env_name = "TINY_HYPOTHESIS_SEED";

pub const TestResult = struct {
    passed: bool,
    valid_examples: usize,
    invalid_examples: usize,
    replayed_examples: usize,
    database_entries_scanned: usize,
    database_failures_rejected: usize,
    replay_budget_saturated: bool,
    failing_choices: ?[]const ChoiceNode,
    failing_byte_blocks: ?[]const u8,
    seed: u64,
    failing_error: ?anyerror,
    database_path: ?[]const u8,
    database_namespace: ?[]const u8,
    max_examples: usize,
    max_replays: usize,
    max_choices: usize,
    max_input_bytes: usize,
    max_shrinks: usize,
    target_examples: usize,
    per_example_leak_check: bool,

    allocator: Allocator,

    pub fn initFailureReplay(self: *const TestResult, allocator: Allocator) ?ConjectureData {
        const choices = self.failing_choices orelse return null;
        var replay = ConjectureData.initReplay(
            allocator,
            choices,
            self.failing_byte_blocks,
        );
        replay.max_choices = self.max_choices;
        replay.max_input_bytes = self.max_input_bytes;
        return replay;
    }

    pub fn deinit(self: *TestResult) void {
        if (self.failing_choices) |fc| self.allocator.free(fc);
        if (self.failing_byte_blocks) |fbb| self.allocator.free(fbb);
    }
};

const DirectRunContext = struct {
    test_fn: TestFn,
};

const DirectRunThunk = struct {
    fn call(
        data: *ConjectureData,
        ctx_allocator: Allocator,
        context: *anyopaque,
    ) anyerror!void {
        const ctx: *const DirectRunContext = @ptrCast(@alignCast(context));
        return ctx.test_fn(data, ctx_allocator);
    }
};

pub fn run(allocator: Allocator, test_fn: TestFn, settings: Settings) !TestResult {
    var ctx = DirectRunContext{ .test_fn = test_fn };
    return runWithContext(allocator, DirectRunThunk.call, &ctx, settings);
}

pub fn runWithContext(
    allocator: Allocator,
    test_fn: TestFnWithContext,
    context: *anyopaque,
    settings: Settings,
) !TestResult {
    return runWithContextSeeded(allocator, test_fn, context, settings, &.{});
}

pub fn runWithContextSeeded(
    allocator: Allocator,
    test_fn: TestFnWithContext,
    context: *anyopaque,
    settings: Settings,
    seed_cases: []const SeedCase,
) !TestResult {
    const seed = settings.seed orelse seedU64(0);

    var valid_examples: usize = 0;
    var invalid_examples: usize = 0;
    var replayed_examples: usize = 0;
    var database_entries_scanned: usize = 0;
    var database_failures_rejected: usize = 0;
    var replay_budget_saturated = seed_cases.len > settings.max_replays;
    var failing_choices: ?[]ChoiceNode = null;
    var failing_byte_blocks: ?[]u8 = null;
    var failing_spans: ?[]conjecture.Span = null;
    var failing_error: ?anyerror = null;
    var target_choices: ?[]ChoiceNode = null;
    var target_byte_blocks: ?[]u8 = null;
    var target_score: f64 = -std.math.inf(f64);
    defer {
        if (target_choices) |choices| allocator.free(choices);
        if (target_byte_blocks) |byte_blocks| allocator.free(byte_blocks);
    }

    var example_runner = ReusableExampleRunner.init(allocator, test_fn, context, settings);
    defer example_runner.deinit();

    if (seed_cases.len > 0) {
        const seed_count = @min(seed_cases.len, settings.max_replays);
        for (seed_cases[0..seed_count]) |seed_case| {
            replayed_examples += 1;
            assertReplayBudget(replayed_examples, settings.max_replays);
            var outcome = try executeExample(
                allocator,
                &example_runner,
                test_fn,
                context,
                settings,
                .{ .replay = .{
                    .choices = seed_case.choices,
                    .byte_blocks = seed_case.byte_blocks,
                } },
                true,
            );
            defer outcome.deinit();

            if (outcome.status == .interesting) {
                failing_error = outcome.err;
                adoptFailure(&outcome, &failing_choices, &failing_byte_blocks, &failing_spans);
                break;
            } else {
                considerTargetOutcome(
                    allocator,
                    &outcome,
                    &target_choices,
                    &target_byte_blocks,
                    &target_score,
                );
            }
        }
    }

    if (failing_choices == null) {
        if (settings.database_path) |db_path| {
            const remaining_replays = settings.max_replays - replayed_examples;
            var saved = try database.ReplayCursor.init(
                allocator,
                .{
                    .db_path = db_path,
                    .namespace = settings.database_namespace,
                    .max_entries = remaining_replays,
                    .max_choices = settings.max_choices,
                    .max_byte_blocks = settings.max_input_bytes,
                },
            );
            defer saved.deinit(allocator);
            saved.activate();
            while (try saved.next()) |entry| {
                replayed_examples += 1;
                assertReplayBudget(replayed_examples, settings.max_replays);
                var outcome = try executeExample(
                    allocator,
                    &example_runner,
                    test_fn,
                    context,
                    settings,
                    .{ .replay = .{
                        .choices = entry.choices,
                        .byte_blocks = entry.byte_blocks,
                    } },
                    true,
                );
                defer outcome.deinit();

                if (outcome.status == .interesting) {
                    failing_error = outcome.err;
                    adoptFailure(&outcome, &failing_choices, &failing_byte_blocks, &failing_spans);
                    break;
                } else {
                    considerTargetOutcome(
                        allocator,
                        &outcome,
                        &target_choices,
                        &target_byte_blocks,
                        &target_score,
                    );
                }
            }
            const database_status = saved.status();
            database_entries_scanned = database_status.entries_scanned;
            database_failures_rejected = database_status.failures_rejected;
            replay_budget_saturated = replay_budget_saturated or
                database_status.scan_budget_saturated;
        }
    }

    replay_budget_saturated = replay_budget_saturated or
        (settings.max_replays > 0 and replayed_examples == settings.max_replays);

    if (failing_choices == null) {
        var prng_seed = seed;
        var examples_run: usize = 0;

        while (examples_run < settings.max_examples) : (examples_run += 1) {
            var outcome = try executeExample(
                allocator,
                &example_runner,
                test_fn,
                context,
                settings,
                .{ .generate = prng_seed },
                true,
            );
            defer outcome.deinit();
            prng_seed +%= 1;

            switch (outcome.status) {
                .valid => {
                    valid_examples += 1;
                    considerTargetOutcome(
                        allocator,
                        &outcome,
                        &target_choices,
                        &target_byte_blocks,
                        &target_score,
                    );
                },
                .invalid => invalid_examples += 1,
                .interesting => {
                    failing_error = outcome.err;
                    adoptFailure(&outcome, &failing_choices, &failing_byte_blocks, &failing_spans);
                    break;
                },
                .overrun => {
                    invalid_examples += 1;
                },
            }
        }
    }

    if (failing_choices == null and target_choices != null and settings.target_examples > 0) {
        try runTargetPhase(
            allocator,
            &example_runner,
            test_fn,
            context,
            settings,
            &target_choices,
            &target_byte_blocks,
            &target_score,
            &valid_examples,
            &invalid_examples,
            &failing_choices,
            &failing_byte_blocks,
            &failing_spans,
            &failing_error,
        );
    }

    if (failing_choices != null and settings.shrinking) {
        const replay_ctx = ReplayContext{
            .test_fn = test_fn,
            .context = context,
            .allocator = allocator,
            .max_choices = settings.max_choices,
            .max_input_bytes = settings.max_input_bytes,
            .per_example_leak_check = settings.per_example_leak_check,
            .runner = &example_runner,
        };
        var ctx = replay_ctx;

        var result = try shrinker_mod.shrink(
            allocator,
            failing_choices.?,
            failing_spans orelse &.{},
            failing_byte_blocks,
            &replayForShrink,
            @ptrCast(&ctx),
            settings.max_shrinks,
        );
        _ = &result;

        allocator.free(failing_choices.?);
        failing_choices = result.choices;
        if (failing_byte_blocks) |fbb| allocator.free(fbb);
        failing_byte_blocks = result.byte_blocks;
        if (failing_spans) |fs| allocator.free(fs);
        failing_spans = result.spans;
    }

    if (failing_choices != null) {
        if (settings.database_path) |db_path| {
            database.saveFailure(
                allocator,
                db_path,
                settings.database_namespace,
                failing_choices.?,
                failing_byte_blocks,
            ) catch {};
        }
    }

    if (failing_spans) |fs| allocator.free(fs);

    return .{
        .passed = failing_choices == null,
        .valid_examples = valid_examples,
        .invalid_examples = invalid_examples,
        .replayed_examples = replayed_examples,
        .database_entries_scanned = database_entries_scanned,
        .database_failures_rejected = database_failures_rejected,
        .replay_budget_saturated = replay_budget_saturated,
        .failing_choices = failing_choices,
        .failing_byte_blocks = failing_byte_blocks,
        .seed = seed,
        .failing_error = failing_error,
        .database_path = settings.database_path,
        .database_namespace = settings.database_namespace,
        .max_examples = settings.max_examples,
        .max_replays = settings.max_replays,
        .max_choices = settings.max_choices,
        .max_input_bytes = settings.max_input_bytes,
        .max_shrinks = settings.max_shrinks,
        .target_examples = settings.target_examples,
        .per_example_leak_check = settings.per_example_leak_check,
        .allocator = allocator,
    };
}

fn seedU64(fallback: u64) u64 {
    var seed: u64 = undefined;
    std.Io.Threaded.global_single_threaded.io().randomSecure(
        std.mem.asBytes(&seed),
    ) catch return fallback;
    return seed;
}

fn assertReplayBudget(actual: usize, maximum: usize) void {
    std.debug.assert(actual <= maximum);
}

const leak_failure = error.PerExampleLeak;
const ExampleDebugAllocator = std.heap.DebugAllocator(.{
    .enable_memory_limit = true,
    .safety = false,
});

const ExampleInput = union(enum) {
    generate: u64,
    replay: SeedCase,
};

const ExampleOutcome = struct {
    status: Status,
    choices: ?[]ChoiceNode = null,
    byte_blocks: ?[]u8 = null,
    spans: ?[]conjecture.Span = null,
    targets: ?[]conjecture.TargetObservation = null,
    err: ?anyerror = null,
    allocator: Allocator,

    fn deinit(self: *ExampleOutcome) void {
        self.clearCaptured();
        self.* = undefined;
    }

    fn clearCaptured(self: *ExampleOutcome) void {
        if (self.choices) |choices| self.allocator.free(choices);
        if (self.byte_blocks) |byte_blocks| self.allocator.free(byte_blocks);
        if (self.spans) |spans| self.allocator.free(spans);
        if (self.targets) |targets| freeTargetObservations(self.allocator, targets);
        self.choices = null;
        self.byte_blocks = null;
        self.spans = null;
        self.targets = null;
    }

    fn hasTargets(self: *const ExampleOutcome) bool {
        if (self.targets) |targets| return targets.len > 0;
        return false;
    }
};

const ReusableExampleRunner = struct {
    allocator: Allocator,
    test_fn: TestFnWithContext,
    context: *anyopaque,
    settings: Settings,
    data: ConjectureData,

    fn init(
        allocator: Allocator,
        test_fn: TestFnWithContext,
        context: *anyopaque,
        settings: Settings,
    ) ReusableExampleRunner {
        var data = ConjectureData.init(allocator, 0);
        data.max_choices = settings.max_choices;
        data.max_input_bytes = settings.max_input_bytes;
        return .{
            .allocator = allocator,
            .test_fn = test_fn,
            .context = context,
            .settings = settings,
            .data = data,
        };
    }

    fn deinit(self: *ReusableExampleRunner) void {
        self.data.deinit();
    }

    fn execute(
        self: *ReusableExampleRunner,
        input: ExampleInput,
        capture_interesting: bool,
    ) !ExampleOutcome {
        switch (input) {
            .generate => |seed| self.data.reset(seed),
            .replay => |seed_case| self.data.resetReplay(
                seed_case.choices,
                seed_case.byte_blocks,
            ),
        }
        self.data.max_choices = self.settings.max_choices;
        self.data.max_input_bytes = self.settings.max_input_bytes;

        var failing_error: ?anyerror = null;
        self.test_fn(&self.data, self.allocator, self.context) catch |err| {
            markInterestingUnlessOverrun(&self.data, err, &failing_error);
        };

        return try outcomeFromDataAlloc(
            self.allocator,
            &self.data,
            failing_error,
            self.data.status,
            capture_interesting and
                (self.data.status == .interesting or self.data.targets.items.len > 0),
        );
    }
};

fn executeExample(
    allocator: Allocator,
    runner: *ReusableExampleRunner,
    test_fn: TestFnWithContext,
    context: *anyopaque,
    settings: Settings,
    input: ExampleInput,
    capture_interesting: bool,
) !ExampleOutcome {
    if (!settings.per_example_leak_check) {
        return runner.execute(input, capture_interesting);
    }

    return try executeLeakCheckedExampleAlloc(
        allocator,
        test_fn,
        context,
        settings,
        input,
        capture_interesting,
    );
}

fn executeLeakCheckedExampleAlloc(
    allocator: Allocator,
    test_fn: TestFnWithContext,
    context: *anyopaque,
    settings: Settings,
    input: ExampleInput,
    capture_interesting: bool,
) !ExampleOutcome {
    var backing_arena = std.heap.ArenaAllocator.init(allocator);
    defer backing_arena.deinit();

    var debug_allocator: ExampleDebugAllocator = .{
        .backing_allocator = backing_arena.allocator(),
    };
    const example_allocator = debug_allocator.allocator();

    var data = initExampleData(example_allocator, input);
    var data_deinited = false;
    errdefer if (!data_deinited) data.deinit();
    var debug_deinited = false;
    errdefer if (!debug_deinited) {
        _ = debug_allocator.deinit();
    };
    data.max_choices = settings.max_choices;
    data.max_input_bytes = settings.max_input_bytes;

    var failing_error: ?anyerror = null;
    test_fn(&data, example_allocator, context) catch |err| {
        markInterestingUnlessOverrun(&data, err, &failing_error);
    };

    var outcome = try outcomeFromDataAlloc(
        allocator,
        &data,
        failing_error,
        data.status,
        capture_interesting,
    );
    errdefer outcome.deinit();
    data.deinit();
    data_deinited = true;

    const leaked = debug_allocator.total_requested_bytes != 0;
    _ = debug_allocator.deinit();
    debug_deinited = true;
    if (leaked) {
        if (outcome.status != .interesting) {
            outcome.status = .interesting;
            outcome.err = leak_failure;
        }
    } else if (outcome.status != .interesting and !outcome.hasTargets()) {
        outcome.clearCaptured();
    }
    return outcome;
}

fn initExampleData(allocator: Allocator, input: ExampleInput) ConjectureData {
    return switch (input) {
        .generate => |seed| ConjectureData.init(allocator, seed),
        .replay => |seed_case| ConjectureData.initReplay(
            allocator,
            seed_case.choices,
            seed_case.byte_blocks,
        ),
    };
}

fn outcomeFromDataAlloc(
    allocator: Allocator,
    data: *const ConjectureData,
    failing_error: ?anyerror,
    status: Status,
    capture: bool,
) !ExampleOutcome {
    var outcome = ExampleOutcome{
        .status = status,
        .err = failing_error,
        .allocator = allocator,
    };
    errdefer outcome.deinit();

    if (capture) {
        try captureDataAlloc(allocator, data, &outcome);
    }
    return outcome;
}

fn captureDataAlloc(
    allocator: Allocator,
    data: *const ConjectureData,
    outcome: *ExampleOutcome,
) !void {
    outcome.choices = try allocator.alloc(ChoiceNode, data.choices.items.len);
    @memcpy(outcome.choices.?, data.choices.items);

    if (data.byte_blocks.items.len > 0) {
        outcome.byte_blocks = try allocator.alloc(u8, data.byte_blocks.items.len);
        @memcpy(outcome.byte_blocks.?, data.byte_blocks.items);
    }

    outcome.spans = try allocator.alloc(conjecture.Span, data.spans.items.len);
    @memcpy(outcome.spans.?, data.spans.items);

    if (data.targets.items.len > 0) {
        outcome.targets = try allocator.alloc(conjecture.TargetObservation, data.targets.items.len);
        var filled: usize = 0;
        errdefer {
            for (outcome.targets.?[0..filled]) |target_observation| {
                allocator.free(target_observation.label);
            }
            allocator.free(outcome.targets.?);
            outcome.targets = null;
        }
        for (data.targets.items, 0..) |target_observation, idx| {
            const label = try allocator.dupe(u8, target_observation.label);
            outcome.targets.?[idx] = .{
                .label = label,
                .value = target_observation.value,
            };
            filled += 1;
        }
    }
}

fn adoptFailure(
    outcome: *ExampleOutcome,
    failing_choices: *?[]ChoiceNode,
    failing_byte_blocks: *?[]u8,
    failing_spans: *?[]conjecture.Span,
) void {
    failing_choices.* = outcome.choices;
    failing_byte_blocks.* = outcome.byte_blocks;
    failing_spans.* = outcome.spans;
    outcome.choices = null;
    outcome.byte_blocks = null;
    outcome.spans = null;
}

fn freeTargetObservations(allocator: Allocator, targets: []conjecture.TargetObservation) void {
    for (targets) |target_observation| {
        allocator.free(target_observation.label);
    }
    allocator.free(targets);
}

fn considerTargetOutcome(
    allocator: Allocator,
    outcome: *ExampleOutcome,
    target_choices: *?[]ChoiceNode,
    target_byte_blocks: *?[]u8,
    target_score: *f64,
) void {
    if (outcome.status != .valid) return;
    const score = outcomeTargetScore(outcome) orelse return;
    if (outcome.choices == null) return;
    if (target_choices.* != null and score <= target_score.*) return;

    if (target_choices.*) |choices| allocator.free(choices);
    if (target_byte_blocks.*) |byte_blocks| allocator.free(byte_blocks);

    target_choices.* = outcome.choices;
    target_byte_blocks.* = outcome.byte_blocks;
    target_score.* = score;
    outcome.choices = null;
    outcome.byte_blocks = null;
}

fn outcomeTargetScore(outcome: *const ExampleOutcome) ?f64 {
    const targets = outcome.targets orelse return null;
    if (targets.len == 0) return null;
    var score: f64 = 0.0;
    for (targets) |target_observation| {
        score += target_observation.value;
    }
    return score;
}

fn runTargetPhase(
    allocator: Allocator,
    runner: *ReusableExampleRunner,
    test_fn: TestFnWithContext,
    context: *anyopaque,
    settings: Settings,
    target_choices: *?[]ChoiceNode,
    target_byte_blocks: *?[]u8,
    target_score: *f64,
    valid_examples: *usize,
    invalid_examples: *usize,
    failing_choices: *?[]ChoiceNode,
    failing_byte_blocks: *?[]u8,
    failing_spans: *?[]conjecture.Span,
    failing_error: *?anyerror,
) !void {
    var attempts: usize = 0;
    while (attempts < settings.target_examples and
        failing_choices.* == null) : (attempts += 1)
    {
        const base_choices = target_choices.* orelse return;
        const candidate = (try mutateTargetCandidate(
            allocator,
            base_choices,
            attempts,
        )) orelse continue;
        defer allocator.free(candidate);

        var outcome = try executeExample(
            allocator,
            runner,
            test_fn,
            context,
            settings,
            .{ .replay = .{
                .choices = candidate,
                .byte_blocks = target_byte_blocks.*,
            } },
            true,
        );
        defer outcome.deinit();

        switch (outcome.status) {
            .valid => {
                valid_examples.* += 1;
                considerTargetOutcome(
                    allocator,
                    &outcome,
                    target_choices,
                    target_byte_blocks,
                    target_score,
                );
            },
            .invalid, .overrun => invalid_examples.* += 1,
            .interesting => {
                failing_error.* = outcome.err;
                adoptFailure(&outcome, failing_choices, failing_byte_blocks, failing_spans);
                return;
            },
        }
    }
}

fn mutateTargetCandidate(
    allocator: Allocator,
    choices: []const ChoiceNode,
    attempt: usize,
) !?[]ChoiceNode {
    if (choices.len == 0) return null;
    const index = attempt % choices.len;
    const mode = (attempt / choices.len) % 6;
    const node = mutateChoiceForTarget(choices[index], mode) orelse return null;
    if (node.value == choices[index].value) return null;

    const candidate = try allocator.alloc(ChoiceNode, choices.len);
    @memcpy(candidate, choices);
    candidate[index] = node;
    return candidate;
}

fn mutateChoiceForTarget(node: ChoiceNode, mode: usize) ?ChoiceNode {
    if (node.was_forced) return null;
    var out = node;
    switch (node.kind) {
        .integer, .boolean => {
            out.value = targetIntegerCandidate(node, mode) orelse return null;
        },
        .float => {
            out.value = targetFloatCandidate(node, mode) orelse return null;
        },
        .bytes => return null,
    }
    return out;
}

fn targetIntegerCandidate(node: ChoiceNode, mode: usize) ?u64 {
    return switch (mode) {
        0 => node.max,
        1 => if (node.max > node.value)
            node.value + @max(@as(u64, 1), (node.max - node.value) / 2)
        else
            null,
        2 => node.min,
        3 => node.shrink_towards,
        4 => if (node.value < node.max) node.value + 1 else null,
        5 => if (node.value > node.min) node.value - 1 else null,
        else => null,
    };
}

fn targetFloatCandidate(node: ChoiceNode, mode: usize) ?u64 {
    const min: f64 = @bitCast(node.min);
    const max: f64 = @bitCast(node.max);
    const current: f64 = @bitCast(node.value);
    if (!std.math.isFinite(current)) return null;

    const candidate = switch (mode) {
        0 => max,
        1 => min,
        2 => 0.0,
        3 => 1.0,
        4 => -1.0,
        5 => if (std.math.isFinite(max)) current + (max - current) * 0.5 else return null,
        else => return null,
    };
    if (!std.math.isFinite(candidate)) return null;
    if (candidate < min or candidate > max) return null;
    if (candidate == current) return null;
    return @bitCast(candidate);
}

const ReplayContext = struct {
    test_fn: TestFnWithContext,
    context: *anyopaque,
    allocator: Allocator,
    max_choices: usize,
    max_input_bytes: usize,
    per_example_leak_check: bool,
    runner: *ReusableExampleRunner,
};

fn replayForShrink(
    choices: []const ChoiceNode,
    byte_blocks: ?[]const u8,
    context: *anyopaque,
) Status {
    const ctx: *const ReplayContext = @ptrCast(@alignCast(context));
    var outcome = executeExample(
        ctx.allocator,
        ctx.runner,
        ctx.test_fn,
        ctx.context,
        .{
            .max_choices = ctx.max_choices,
            .max_input_bytes = ctx.max_input_bytes,
            .per_example_leak_check = ctx.per_example_leak_check,
        },
        .{ .replay = .{
            .choices = choices,
            .byte_blocks = byte_blocks,
        } },
        false,
    ) catch return .overrun;
    defer outcome.deinit();
    return outcome.status;
}

fn markInterestingUnlessOverrun(
    data: *ConjectureData,
    err: anyerror,
    failing_error: ?*?anyerror,
) void {
    if (data.status == .overrun) return;
    data.markInteresting();
    if (failing_error) |ptr| ptr.* = err;
}

const AlwaysPassingProperty = struct {
    fn prop(data: *ConjectureData, _: Allocator) !void {
        _ = try data.drawInteger(0, 100, 0);
    }
};

const AlwaysFailingProperty = struct {
    fn prop(_: *ConjectureData, _: Allocator) !void {
        return error.AlwaysFails;
    }
};

const PassingNoopProperty = struct {
    fn prop(_: *ConjectureData, _: Allocator) !void {}
};

const ShrinkThresholdProperty = struct {
    fn prop(data: *ConjectureData, _: Allocator) !void {
        const x = try data.drawInteger(0, 1000, 0);
        if (x > 100) return error.TooLarge;
    }
};

const TargetMaximumProperty = struct {
    fn prop(data: *ConjectureData, _: Allocator, _: *anyopaque) !void {
        const x = try data.drawInteger(0, 1000, 0);
        try data.target(x, "x");
        if (x == 1000) return error.TargetReached;
    }
};

const DuplicateTargetProperty = struct {
    fn prop(data: *ConjectureData, _: Allocator) !void {
        _ = try data.drawInteger(0, 10, 0);
        try data.target(1, "score");
        try data.target(2, "score");
    }
};

const LeakOnlyProperty = struct {
    fn prop(data: *ConjectureData, allocator: Allocator, _: *anyopaque) !void {
        const x = try data.drawInteger(0, 10, 0);
        if (x > 0) {
            _ = try allocator.alloc(u8, 1);
        }
    }
};

const SeedFailureContext = struct {
    target: u8,
    max_size: usize,
};

const SeedFailureProperty = struct {
    fn testFn(
        data: *ConjectureData,
        _: Allocator,
        context_ptr: *anyopaque,
    ) anyerror!void {
        const ctx: *SeedFailureContext = @ptrCast(@alignCast(context_ptr));
        const input = try data.drawBytes(0, ctx.max_size);
        if (input.len > 0 and input[0] == ctx.target) {
            return error.PropertyFailed;
        }
    }
};

const DatabaseFailureProperty = struct {
    fn prop(_: *ConjectureData, _: Allocator) !void {
        return error.PropertyFailed;
    }
};

const DatabasePassingProperty = struct {
    fn prop(data: *ConjectureData, _: Allocator) !void {
        _ = try data.drawInteger(0, 10, 0);
    }
};

const ReplayFailureProperty = struct {
    fn prop(data: *ConjectureData, _: Allocator) !void {
        _ = try data.drawInteger(0, 10, 0);
        return error.PropertyFailed;
    }
};

const ReplayOverrunProperty = struct {
    fn prop(data: *ConjectureData, _: Allocator) !void {
        _ = try data.drawInteger(0, 10, 0);
        _ = try data.drawInteger(0, 10, 0);
    }
};

const ReplayCountContext = struct {
    calls: usize = 0,
};

const ReplayCountProperty = struct {
    fn prop(data: *ConjectureData, _: Allocator, context_ptr: *anyopaque) !void {
        const context: *ReplayCountContext = @ptrCast(@alignCast(context_ptr));
        context.calls += 1;
        _ = try data.drawInteger(0, 10, 0);
    }
};

test "always-passing property passes" {
    const allocator = std.testing.allocator;

    var result = try run(allocator, &AlwaysPassingProperty.prop, .{
        .max_examples = 10,
        .seed = 42,
    });
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(10, result.valid_examples);
}

test "settings presets scale property budgets" {
    const quick = Settings.quick();
    const dev = Settings.dev();
    const ci = Settings.ci();

    try std.testing.expect(quick.max_examples < dev.max_examples);
    try std.testing.expect(dev.max_examples < ci.max_examples);
    try std.testing.expect(quick.max_replays < dev.max_replays);
    try std.testing.expect(dev.max_replays < ci.max_replays);
    try std.testing.expect(quick.max_input_bytes < dev.max_input_bytes);
    try std.testing.expect(dev.max_input_bytes < ci.max_input_bytes);
    try std.testing.expect(quick.max_shrinks < ci.max_shrinks);
    try std.testing.expect(!dev.per_example_leak_check);
}

test "result carries replay settings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    var result = try run(allocator, &AlwaysFailingProperty.prop, Settings.quick()
        .withSeed(99)
        .withDatabase(tmp_path)
        .withNamespace("engine-result-replay-settings"));
    defer result.deinit();

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(@as(u64, 99), result.seed);
    try std.testing.expectEqualStrings(tmp_path, result.database_path.?);
    try std.testing.expectEqualStrings(
        "engine-result-replay-settings",
        result.database_namespace.?,
    );
    try std.testing.expectEqual(Settings.quick().max_examples, result.max_examples);
    try std.testing.expectEqual(Settings.quick().max_replays, result.max_replays);
    try std.testing.expectEqual(Settings.quick().max_input_bytes, result.max_input_bytes);
}

test "explicit seeds stop at the replay budget" {
    var node = ChoiceNode{ .kind = .integer, .value = 1, .min = 0, .max = 10 };
    const seed = SeedCase{ .choices = (&node)[0..1], .byte_blocks = null };
    const seeds = [_]SeedCase{ seed, seed, seed };
    var context = ReplayCountContext{};
    var result = try runWithContextSeeded(
        std.testing.allocator,
        &ReplayCountProperty.prop,
        @ptrCast(&context),
        .{
            .max_examples = 0,
            .max_replays = 2,
            .target_examples = 0,
            .shrinking = false,
            .seed = 1,
        },
        &seeds,
    );
    defer result.deinit();
    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 2), context.calls);
    try std.testing.expectEqual(@as(usize, 2), result.replayed_examples);
    try std.testing.expect(result.replay_budget_saturated);
}

test "explicit seeds and database scans share the replay budget" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);
    for (0..3) |value| {
        try database.saveFailure(
            allocator,
            tmp_path,
            "shared-budget",
            &.{.{ .kind = .integer, .value = value, .min = 0, .max = 10 }},
            null,
        );
    }
    var seed_node = ChoiceNode{ .kind = .integer, .value = 9, .min = 0, .max = 10 };
    const seeds = [_]SeedCase{.{
        .choices = (&seed_node)[0..1],
        .byte_blocks = null,
    }};
    var context = ReplayCountContext{};
    var result = try runWithContextSeeded(
        allocator,
        &ReplayCountProperty.prop,
        @ptrCast(&context),
        .{
            .max_examples = 0,
            .max_replays = 2,
            .max_choices = 1,
            .max_input_bytes = 0,
            .target_examples = 0,
            .shrinking = false,
            .seed = 1,
            .database_path = tmp_path,
            .database_namespace = "shared-budget",
        },
        &seeds,
    );
    defer result.deinit();
    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(usize, 2), context.calls);
    try std.testing.expectEqual(@as(usize, 2), result.replayed_examples);
    try std.testing.expectEqual(@as(usize, 1), result.database_entries_scanned);
    try std.testing.expect(result.replay_budget_saturated);
}

test "always-failing property finds failure" {
    const allocator = std.testing.allocator;

    var result = try run(allocator, &AlwaysFailingProperty.prop, .{
        .max_examples = 10,
        .seed = 42,
    });
    defer result.deinit();

    try std.testing.expect(!result.passed);
}

test "passing result has no failure replay" {
    const allocator = std.testing.allocator;

    var result = try run(allocator, &PassingNoopProperty.prop, .{
        .max_examples = 1,
        .target_examples = 0,
        .seed = 42,
    });
    defer result.deinit();

    try std.testing.expect(result.passed);
    try std.testing.expect(result.initFailureReplay(allocator) == null);
}

test "failure replay restores minimized choices bytes and choice bound" {
    const allocator = std.testing.allocator;

    var minimized_choices = [_]ChoiceNode{
        .{
            .kind = .integer,
            .value = 7,
            .min = 0,
            .max = 10,
            .shrink_towards = 0,
        },
        .{
            .kind = .integer,
            .value = 3,
            .min = 1,
            .max = 4,
            .shrink_towards = 1,
        },
    };
    const minimized_bytes = [_]u8{ 0x5a, 0x1c, 0xe7 };
    const result = TestResult{
        .passed = false,
        .valid_examples = 4,
        .invalid_examples = 1,
        .replayed_examples = 2,
        .database_entries_scanned = 3,
        .database_failures_rejected = 1,
        .replay_budget_saturated = false,
        .failing_choices = minimized_choices[0..],
        .failing_byte_blocks = minimized_bytes[0..],
        .seed = 42,
        .failing_error = error.PropertyFailed,
        .database_path = null,
        .database_namespace = null,
        .max_examples = 25,
        .max_replays = 25,
        .max_choices = minimized_choices.len,
        .max_input_bytes = minimized_bytes.len,
        .max_shrinks = 1000,
        .target_examples = 25,
        .per_example_leak_check = false,
        .allocator = allocator,
    };

    var replay = result.initFailureReplay(allocator).?;
    defer replay.deinit();

    try std.testing.expectEqual(minimized_choices.len, replay.max_choices);
    try std.testing.expectEqual(@as(u64, 7), try replay.drawInteger(0, 10, 0));
    try std.testing.expectEqualSlices(u8, &minimized_bytes, try replay.drawBytes(1, 4));
    try std.testing.expectEqualSlices(ChoiceNode, &minimized_choices, replay.choices.items);
    try std.testing.expectError(DrawError.Overrun, replay.drawBoolean());
}

test "shrinks x > 100 to 101" {
    const allocator = std.testing.allocator;

    var result = try run(allocator, &ShrinkThresholdProperty.prop, .{
        .max_examples = 200,
        .seed = 42,
        .shrinking = true,
    });
    defer result.deinit();

    try std.testing.expect(!result.passed);
    if (result.failing_choices) |fc| {
        try std.testing.expect(fc.len > 0);
        try std.testing.expectEqual(101, fc[0].value);
    }
}

test "target phase mutates valid seeds toward higher scores" {
    const allocator = std.testing.allocator;

    var node = ChoiceNode{
        .kind = .integer,
        .value = 1,
        .min = 0,
        .max = 1000,
        .shrink_towards = 0,
    };
    const seed_cases = [_]SeedCase{
        .{
            .choices = (&node)[0..1],
            .byte_blocks = null,
        },
    };
    var unused_context: u8 = 0;

    var result = try runWithContextSeeded(
        allocator,
        &TargetMaximumProperty.prop,
        @ptrCast(&unused_context),
        .{
            .max_examples = 0,
            .target_examples = 4,
            .shrinking = false,
            .seed = 1,
        },
        seed_cases[0..],
    );
    defer result.deinit();

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(error.TargetReached, result.failing_error.?);
    try std.testing.expectEqual(@as(u64, 1000), result.failing_choices.?[0].value);
}

test "duplicate target labels fail the property" {
    const allocator = std.testing.allocator;

    var result = try run(allocator, &DuplicateTargetProperty.prop, .{
        .max_examples = 1,
        .target_examples = 0,
        .shrinking = false,
        .seed = 1,
    });
    defer result.deinit();

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(
        conjecture.TargetError.DuplicateTargetLabel,
        result.failing_error.?,
    );
}

test "per-example leak check shrinks leak-only failures" {
    const allocator = std.testing.allocator;

    var node = ChoiceNode{
        .kind = .integer,
        .value = 7,
        .min = 0,
        .max = 10,
        .shrink_towards = 0,
    };
    const seed_cases = [_]SeedCase{
        .{
            .choices = (&node)[0..1],
            .byte_blocks = null,
        },
    };
    var unused_context: u8 = 0;

    var result = try runWithContextSeeded(
        allocator,
        &LeakOnlyProperty.prop,
        @ptrCast(&unused_context),
        .{
            .max_examples = 0,
            .max_shrinks = 100,
            .seed = 1,
            .per_example_leak_check = true,
            .report_failure = false,
        },
        seed_cases[0..],
    );
    defer result.deinit();

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(leak_failure, result.failing_error.?);
    try std.testing.expect(result.failing_choices != null);
    try std.testing.expectEqual(@as(u64, 1), result.failing_choices.?[0].value);
}

test "runWithContextSeeded: seed case triggers failure with max_examples = 0" {
    const allocator = std.testing.allocator;

    var ctx = SeedFailureContext{ .target = 0xAC, .max_size = 8 };
    var node = ChoiceNode{
        .kind = .integer,
        .value = 1,
        .min = 0,
        .max = 8,
        .shrink_towards = 0,
    };
    const seed_cases = [_]SeedCase{
        .{
            .choices = (&node)[0..1],
            .byte_blocks = &.{0xAC},
        },
    };

    var result = try runWithContextSeeded(
        allocator,
        &SeedFailureProperty.testFn,
        @ptrCast(&ctx),
        .{ .max_examples = 0, .seed = 1 },
        seed_cases[0..],
    );
    defer result.deinit();

    try std.testing.expect(!result.passed);
    try std.testing.expect(result.failing_byte_blocks != null);
    try std.testing.expect(result.failing_choices != null);
}

test "database namespaces isolate failures" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    var fail_result = try run(allocator, &DatabaseFailureProperty.prop, .{
        .max_examples = 1,
        .seed = 1,
        .shrinking = false,
        .database_path = tmp_path,
        .database_namespace = "prop-a",
    });
    defer fail_result.deinit();
    try std.testing.expect(!fail_result.passed);

    var pass_result = try run(allocator, &DatabasePassingProperty.prop, .{
        .max_examples = 1,
        .seed = 2,
        .shrinking = false,
        .database_path = tmp_path,
        .database_namespace = "prop-b",
    });
    defer pass_result.deinit();
    try std.testing.expect(pass_result.passed);
}

test "replay overrun does not fail the property" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    var fail_result = try run(allocator, &ReplayFailureProperty.prop, .{
        .max_examples = 1,
        .seed = 3,
        .shrinking = false,
        .database_path = tmp_path,
        .database_namespace = "shared",
    });
    defer fail_result.deinit();
    try std.testing.expect(!fail_result.passed);

    var replay_result = try run(allocator, &ReplayOverrunProperty.prop, .{
        .max_examples = 0,
        .seed = 4,
        .shrinking = false,
        .database_path = tmp_path,
        .database_namespace = "shared",
    });
    defer replay_result.deinit();
    try std.testing.expect(replay_result.passed);
}

test "seed text selects fixed, hex, and fresh-entropy seeds" {
    const base = Settings.quick().withSeed(7);
    try std.testing.expectEqual(@as(?u64, 12345), base.withSeedText("12345").seed);
    try std.testing.expectEqual(@as(?u64, 0xabc), base.withSeedText("0xabc").seed);
    try std.testing.expectEqual(@as(?u64, null), base.withSeedText("random").seed);
}
