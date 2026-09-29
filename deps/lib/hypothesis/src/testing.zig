const std = @import("std");
const Allocator = std.mem.Allocator;
const conjecture = @import("conjecture.zig");
const ConjectureData = conjecture.ConjectureData;
const DrawError = conjecture.DrawError;
const strategy_mod = @import("strategy.zig");
const engine_mod = @import("engine.zig");
const report_mod = @import("report.zig");
const Settings = engine_mod.Settings;
const TestResult = engine_mod.TestResult;
const SeedCase = engine_mod.SeedCase;

pub const FuzzInputOptions = std.testing.FuzzInputOptions;

const default_max_input_size = 4096;

fn ForAllTestType(comptime Property: type, comptime strats: anytype) type {
    return struct {
        fn testFn(data: *ConjectureData, _: Allocator) anyerror!void {
            const Args = std.meta.ArgsTuple(@TypeOf(Property.property));
            var args: Args = undefined;

            inline for (@typeInfo(Args).@"struct".field_types, 0..) |Arg, idx| {
                args[idx] = try drawFromComptime(
                    Arg,
                    strats[idx],
                    data,
                );
            }

            const result = @call(.auto, Property.property, args);
            if (!result) {
                return error.PropertyFailed;
            }
        }
    };
}

fn FuzzContextType(comptime Context: type) type {
    return struct {
        user_context: Context,
        fuzz_fn: *const fn (context: Context, input: []const u8) anyerror!void,
        max_input_size: usize,
    };
}

fn FuzzTestType(comptime Context: type) type {
    return struct {
        fn testFn(
            data: *ConjectureData,
            _: Allocator,
            context_ptr: *anyopaque,
        ) anyerror!void {
            const ctx: *FuzzContextType(Context) = @ptrCast(@alignCast(context_ptr));
            const input = try data.drawBytes(0, ctx.max_input_size);
            return ctx.fuzz_fn(ctx.user_context, input);
        }
    };
}

pub fn check(comptime Property: type, settings: Settings) !void {
    const allocator = std.testing.allocator;

    const run_settings = applyNamespace(Property, settings, null);
    var result = try engine_mod.run(allocator, &Property.property, run_settings);
    defer result.deinit();

    if (!result.passed) {
        if (run_settings.report_failure) {
            printFailure(&result);
        }
        return error.PropertyFailed;
    }
}

pub fn checkNamed(comptime Property: type, name: []const u8, settings: Settings) !void {
    const allocator = std.testing.allocator;

    const run_settings = applyNamespace(Property, settings, name);
    var result = try engine_mod.run(allocator, &Property.property, run_settings);
    defer result.deinit();

    if (!result.passed) {
        if (run_settings.report_failure) {
            printFailure(&result);
        }
        return error.PropertyFailed;
    }
}

pub fn forAll(
    comptime Property: type,
    comptime strats: anytype,
    settings: Settings,
) !void {
    const allocator = std.testing.allocator;

    const run_settings = applyNamespace(Property, settings, null);
    var result = try engine_mod.run(
        allocator,
        &ForAllTestType(Property, strats).testFn,
        run_settings,
    );
    defer result.deinit();

    if (!result.passed) {
        if (run_settings.report_failure) {
            printFailure(&result);
        }
        return error.PropertyFailed;
    }
}

pub fn forAllNamed(
    comptime Property: type,
    comptime strats: anytype,
    name: []const u8,
    settings: Settings,
) !void {
    const allocator = std.testing.allocator;

    const run_settings = applyNamespace(Property, settings, name);
    var result = try engine_mod.run(
        allocator,
        &ForAllTestType(Property, strats).testFn,
        run_settings,
    );
    defer result.deinit();

    if (!result.passed) {
        if (run_settings.report_failure) {
            printFailure(&result);
        }
        return error.PropertyFailed;
    }
}

pub fn fuzz(
    context: anytype,
    comptime fuzzFn: fn (context: @TypeOf(context), input: []const u8) anyerror!void,
    options: FuzzInputOptions,
) anyerror!void {
    return fuzzWithSettings(context, fuzzFn, options, .{});
}

pub fn fuzzWithSettings(
    context: anytype,
    comptime fuzzFn: fn (context: @TypeOf(context), input: []const u8) anyerror!void,
    options: FuzzInputOptions,
    settings: Settings,
) anyerror!void {
    const allocator = std.testing.allocator;

    var seed_cases: []SeedCase = &.{};
    var seed_nodes: []conjecture.ChoiceNode = &.{};
    defer {
        if (seed_cases.len > 0) allocator.free(seed_cases);
        if (seed_nodes.len > 0) allocator.free(seed_nodes);
    }

    if (options.corpus.len > 0) {
        const corpus_count = @min(options.corpus.len, settings.max_replays);
        if (corpus_count > 0) {
            seed_cases = try allocator.alloc(SeedCase, corpus_count);
            seed_nodes = try allocator.alloc(conjecture.ChoiceNode, corpus_count);

            for (options.corpus[0..corpus_count], 0..) |input, idx| {
                const max_len: usize = if (input.len > default_max_input_size)
                    input.len
                else
                    default_max_input_size;
                seed_nodes[idx] = .{
                    .kind = .integer,
                    .value = @intCast(input.len),
                    .min = 0,
                    .max = @intCast(max_len),
                    .shrink_towards = 0,
                };
                seed_cases[idx] = .{
                    .choices = seed_nodes[idx .. idx + 1],
                    .byte_blocks = input,
                };
            }
        }
    }

    var wrapper_ctx = FuzzContextType(@TypeOf(context)){
        .user_context = context,
        .fuzz_fn = fuzzFn,
        .max_input_size = default_max_input_size,
    };

    var result = try engine_mod.runWithContextSeeded(
        allocator,
        &FuzzTestType(@TypeOf(context)).testFn,
        @ptrCast(&wrapper_ctx),
        settings,
        seed_cases,
    );
    defer result.deinit();

    if (!result.passed) {
        if (settings.report_failure) {
            printFailure(&result);
        }
        return error.PropertyFailed;
    }
}

fn drawFromComptime(
    comptime T: type,
    comptime strat: anytype,
    data: *ConjectureData,
) DrawError!T {
    const S = @TypeOf(strat);
    if (@hasField(S, "min") and @hasField(S, "max") and @hasField(S, "shrink_towards")) {
        const raw = try data.drawInteger(
            strategy_mod.intToU64(T, strat.min),
            strategy_mod.intToU64(T, strat.max),
            strategy_mod.intToU64(T, strat.shrink_towards),
        );
        return strategy_mod.u64ToInt(T, raw);
    }
    if (T == bool) {
        return data.drawBoolean();
    }
    @compileError("Unsupported strategy type for forAll. Use check() with ConjectureData instead.");
}

fn applyNamespace(
    comptime Property: type,
    settings: Settings,
    explicit: ?[]const u8,
) Settings {
    var run_settings = settings;
    if (explicit) |name| {
        run_settings.database_namespace = name;
        return run_settings;
    }

    if (run_settings.database_path != null and run_settings.database_namespace == null) {
        run_settings.database_namespace = @typeName(Property);
    }
    return run_settings;
}

pub fn printFailure(result: *const TestResult) void {
    report_mod.printPropertyFailure(result);
}

const DirectConjectureProperty = struct {
    pub fn property(data: *ConjectureData, _: Allocator) !void {
        const a = try data.drawInteger(0, 1000, 0);
        const b = try data.drawInteger(0, 1000, 0);
        if (a +% b != b +% a) return error.PropertyFailed;
    }
};

const CommutativeAdditionProperty = struct {
    pub fn property(a: i32, b: i32) bool {
        return a +% b == b +% a;
    }
};

const BooleanIdentityProperty = struct {
    pub fn property(b: bool) bool {
        return b == b;
    }
};

const CustomMaxExamplesProperty = struct {
    pub fn property(a: u8) bool {
        _ = a;
        return true;
    }
};

const CorpusFailureContext = struct {
    target: u8,
};

const CorpusFailureFuzz = struct {
    pub fn fuzzFn(ctx: CorpusFailureContext, input: []const u8) anyerror!void {
        if (input.len > 0 and input[0] == ctx.target) {
            return error.PropertyFailed;
        }
    }
};

const PassingFuzz = struct {
    pub fn fuzzFn(_: void, _: []const u8) anyerror!void {}
};

test "check: direct conjecture property" {
    try check(DirectConjectureProperty, .{ .seed = 42 });
}

test "forAll: commutative addition" {
    try forAll(CommutativeAdditionProperty, .{
        strategy_mod.integers(i32, -1000, 1000),
        strategy_mod.integers(i32, -1000, 1000),
    }, .{ .seed = 42 });
}

test "forAll: boolean identity" {
    try forAll(BooleanIdentityProperty, .{
        strategy_mod.booleans(),
    }, .{ .seed = 42 });
}

test "forAll: custom max_examples" {
    try forAll(CustomMaxExamplesProperty, .{
        strategy_mod.integers(u8, 0, 255),
    }, .{ .max_examples = 50, .seed = 42 });
}

test "fuzz: corpus failure reports property failed" {
    const corpus = [_][]const u8{
        &.{0x00},
        &.{ 0xAB, 0xCD },
    };

    try std.testing.expectError(
        error.PropertyFailed,
        fuzzWithSettings(
            CorpusFailureContext{ .target = 0xAB },
            CorpusFailureFuzz.fuzzFn,
            .{ .corpus = corpus[0..] },
            .{ .report_failure = false },
        ),
    );
}

test "fuzz: no failures passes" {
    const corpus = [_][]const u8{
        "alpha",
        "beta",
    };

    try fuzz({}, PassingFuzz.fuzzFn, .{ .corpus = corpus[0..] });
}

test "fuzz: corpus admission stops at the replay budget" {
    const corpus = [_][]const u8{
        &.{0x00},
        &.{0x01},
        &.{0xAB},
    };
    try fuzzWithSettings(
        CorpusFailureContext{ .target = 0xAB },
        CorpusFailureFuzz.fuzzFn,
        .{ .corpus = &corpus },
        .{
            .max_examples = 0,
            .max_replays = 2,
            .target_examples = 0,
            .report_failure = false,
        },
    );
}
