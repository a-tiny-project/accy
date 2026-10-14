//! Recovers the frequency of a sampled tone. Sixteen samples of sin(3t), taken every quarter
//! time unit, are fitted by sin(f t) for an unknown angular frequency f (radians per time unit).
//! The mismatch between prediction and samples has several valleys, so eight starting guesses
//! descend at once, each by its own gradient, and two of them reach f = 3.

const std = @import("std");
const accy = @import("accy");

const tensor = accy.tensor;

pub const points = 16;
pub const spacing: f32 = 0.25;
pub const true_frequency: f32 = 3;
pub const guesses = 8;
pub const starts = [guesses]f32{ 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5 };
pub const rate: f32 = 0.005;
pub const updates = 100;

/// The sum over sample points of (sin(frequency * time) - sample)^2.
fn mismatch(_: *tensor.Builder, args: []const tensor.Value) !tensor.Value {
    const frequency = args[0];
    const time = args[1];
    const sample = args[2];
    const predicted = try (try frequency.mul(time)).sin();
    const difference = try predicted.sub(sample);
    return (try difference.mul(difference)).sum(.point);
}

/// One guess: a frequency with no axes, and times and samples along the axis `point`.
const one_guess = [_]tensor.Spec{
    tensor.spec(.f32, .{}),
    tensor.spec(.f32, .{ .point = points }),
    tensor.spec(.f32, .{ .point = points }),
};

/// Eight guesses: only the frequency's specification changes.
const eight_guesses = [_]tensor.Spec{
    tensor.spec(.f32, .{ .guess = guesses }),
    tensor.spec(.f32, .{ .point = points }),
    tensor.spec(.f32, .{ .point = points }),
};

const Tone = struct {
    time: [points]f32,
    sample: [points]f32,

    fn init() Tone {
        var tone: Tone = undefined;
        for (0..points) |i| {
            tone.time[i] = @as(f32, @floatFromInt(i)) * spacing;
            tone.sample[i] = @sin(true_frequency * tone.time[i]);
        }
        return tone;
    }
};

fn evaluate(
    allocator: std.mem.Allocator,
    program: *tensor.Graph,
    tone: *const Tone,
    frequency: []const f32,
    out: []f32,
) !void {
    try tensor.runCpu(allocator, program, &.{
        std.mem.sliceAsBytes(frequency),
        std.mem.sliceAsBytes(&tone.time),
        std.mem.sliceAsBytes(&tone.sample),
    }, &.{std.mem.sliceAsBytes(out)});
}

/// The guesses before one update: their frequencies, mismatches, and slopes.
const State = struct {
    frequency: [guesses]f32,
    value: [guesses]f32,
    slope: [guesses]f32,
};

/// Moves every guess against its own slope, `updates` times, from `starts`. `states[k]` holds
/// the guesses before update `k`, and `states[updates]` the guesses after the last update.
fn descend(allocator: std.mem.Allocator, tone: *const Tone, states: *[updates + 1]State) !void {
    var f = try tensor.Function.define(allocator, "mismatch", &one_guess, mismatch);
    defer f.deinit();
    const each = try (try f.valueAndGrad(.{ .wrt = &.{0} })).vmap(.{
        .axis_size = guesses,
        .in_axes = &.{ tensor.mappedAxis(0), .none, .none },
        .axis_name = "guess",
    });
    var cpu = try each.compileCpu();
    defer cpu.deinit();

    var frequency = starts;
    for (states, 0..) |*state, update| {
        state.frequency = frequency;
        try cpu.launch(allocator, &.{
            std.mem.sliceAsBytes(&frequency),
            std.mem.sliceAsBytes(&tone.time),
            std.mem.sliceAsBytes(&tone.sample),
        }, &.{ std.mem.sliceAsBytes(&state.value), std.mem.sliceAsBytes(&state.slope) });
        if (update == updates) break;
        for (&frequency, state.slope) |*guess, slope| guess.* -= rate * slope;
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;

    if (!accy.target.native_cpu_artifacts_supported) {
        try out.writeAll("This host has no CPU backend for compiled Accy programs.\n");
        return out.flush();
    }
    const tone = Tone.init();
    const states = try allocator.create([updates + 1]State);
    defer allocator.destroy(states);
    try descend(allocator, &tone, states);

    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    if (arguments.next()) |argument| {
        if (!std.mem.eql(u8, argument, "--figure-data")) return error.UnknownArgument;
        try writeFigureData(allocator, out, &tone, states);
        return out.flush();
    }

    var one = try tensor.define(allocator, "mismatch", &one_guess, mismatch);
    defer one.deinit();
    for ([_]f32{ 2.5, 3 }) |frequency| {
        var value: [1]f32 = undefined;
        try evaluate(allocator, &one, &tone, &.{frequency}, &value);
        try out.print("mismatch({d}) = {d}\n", .{ frequency, value[0] });
    }

    var eight = try tensor.define(allocator, "mismatch", &eight_guesses, mismatch);
    defer eight.deinit();
    var values: [guesses]f32 = undefined;
    try evaluate(allocator, &eight, &tone, &starts, &values);
    try out.print("eight guesses {any}\n  mismatch {any}\n  slope {any}\n", .{
        starts,
        values,
        states[0].slope,
    });
    try out.print("after {d} updates {any}\n  mismatch {any}\n", .{
        updates,
        states[updates].frequency,
        states[updates].value,
    });
    try out.flush();
}

/// Frequencies at which `--figure-data` reports the mismatch curve: -0.5, -0.475, ..., 8.5.
const curve_guesses = 361;

/// Prints, as JSON, the data behind the README's figures: the samples, the mismatch curve
/// (one recording with `curve_guesses` guesses), and every state of the descent.
fn writeFigureData(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    tone: *const Tone,
    states: *const [updates + 1]State,
) !void {
    var curve = try tensor.define(allocator, "mismatch", &.{
        tensor.spec(.f32, .{ .guess = curve_guesses }),
        tensor.spec(.f32, .{ .point = points }),
        tensor.spec(.f32, .{ .point = points }),
    }, mismatch);
    defer curve.deinit();
    var frequency: [curve_guesses]f32 = undefined;
    for (&frequency, 0..) |*f, i| f.* = -0.5 + 0.025 * @as(f32, @floatFromInt(i));
    var value: [curve_guesses]f32 = undefined;
    try evaluate(allocator, &curve, tone, &frequency, &value);

    try out.print("{f}\n", .{std.json.fmt(.{
        .time = tone.time,
        .sample = tone.sample,
        .curve = .{ .frequency = frequency, .mismatch = value },
        .rate = rate,
        .states = states.*,
    }, .{})});
}

fn requireCpu() !void {
    if (!accy.target.native_cpu_artifacts_supported) return error.SkipZigTest;
}

/// The mismatch and its derivative in f64, computed directly from the definition.
fn reference(tone: *const Tone, frequency: f64) struct { value: f64, slope: f64 } {
    var value: f64 = 0;
    var slope: f64 = 0;
    for (tone.time, tone.sample) |time32, sample| {
        const time: f64 = time32;
        const difference = @sin(frequency * time) - sample;
        value += difference * difference;
        slope += 2 * difference * @cos(frequency * time) * time;
    }
    return .{ .value = value, .slope = slope };
}

test "one guess measures its mismatch, which vanishes at the true frequency" {
    try requireCpu();
    const allocator = std.testing.allocator;
    const tone = Tone.init();
    var one = try tensor.define(allocator, "mismatch", &one_guess, mismatch);
    defer one.deinit();
    var value: [1]f32 = undefined;
    try evaluate(allocator, &one, &tone, &.{2.5}, &value);
    try std.testing.expectApproxEqRel(reference(&tone, 2.5).value, value[0], 1e-5);
    try evaluate(allocator, &one, &tone, &.{3}, &value);
    try std.testing.expectApproxEqAbs(@as(f32, 0), value[0], 1e-9);
}

test "eight guesses give the eight separate mismatches" {
    try requireCpu();
    const allocator = std.testing.allocator;
    const tone = Tone.init();
    var one = try tensor.define(allocator, "mismatch", &one_guess, mismatch);
    defer one.deinit();
    var eight = try tensor.define(allocator, "mismatch", &eight_guesses, mismatch);
    defer eight.deinit();
    var together: [guesses]f32 = undefined;
    try evaluate(allocator, &eight, &tone, &starts, &together);
    for (starts, together) |start, value| {
        var alone: [1]f32 = undefined;
        try evaluate(allocator, &one, &tone, &.{start}, &alone);
        try std.testing.expectApproxEqRel(alone[0], value, 1e-6);
    }
}

test "names keep guesses and points apart when their lengths are equal" {
    var program = try tensor.define(std.testing.allocator, "mismatch", &.{
        tensor.spec(.f32, .{ .guess = points }),
        tensor.spec(.f32, .{ .point = points }),
        tensor.spec(.f32, .{ .point = points }),
    }, mismatch);
    defer program.deinit();
    const result = program.typeOf(program.outputs[0]);
    try std.testing.expectEqual(1, result.dims.len);
    try std.testing.expectEqualStrings("guess", result.dims[0].name);
    try std.testing.expectEqual(points, result.dims[0].extent);
}

test "samples and times of different lengths are refused while recording" {
    try std.testing.expectError(error.AxisExtentMismatch, tensor.define(std.testing.allocator, "mismatch", &.{
        tensor.spec(.f32, .{}),
        tensor.spec(.f32, .{ .point = points }),
        tensor.spec(.f32, .{ .point = points - 1 }),
    }, mismatch));
}

test "a gradient needs one number, so eight mismatches are refused" {
    var eight = try tensor.define(std.testing.allocator, "mismatch", &eight_guesses, mismatch);
    defer eight.deinit();
    try std.testing.expectError(
        error.GradientRequiresScalarOutput,
        tensor.grad(std.testing.allocator, &eight, .{ .wrt = &.{0} }),
    );
}

test "each guess's slope matches the derivative and a finite difference" {
    try requireCpu();
    const allocator = std.testing.allocator;
    const tone = Tone.init();
    const states = try allocator.create([updates + 1]State);
    defer allocator.destroy(states);
    try descend(allocator, &tone, states);
    const value = states[0].value;
    const slope = states[0].slope;

    var eight = try tensor.define(allocator, "mismatch", &eight_guesses, mismatch);
    defer eight.deinit();
    const step: f32 = 1.0 / 64.0;
    var above: [guesses]f32 = undefined;
    var below: [guesses]f32 = undefined;
    var shifted: [guesses]f32 = undefined;
    for (&shifted, starts) |*s, start| s.* = start + step;
    try evaluate(allocator, &eight, &tone, &shifted, &above);
    for (&shifted, starts) |*s, start| s.* = start - step;
    try evaluate(allocator, &eight, &tone, &shifted, &below);

    for (starts, value, slope, above, below) |start, v, s, a, b| {
        const exact = reference(&tone, start);
        try std.testing.expectApproxEqRel(exact.value, v, 1e-5);
        try std.testing.expectApproxEqAbs(exact.slope, s, 1e-3 * (1 + @abs(exact.slope)));
        const difference = (a - b) / (2 * step);
        try std.testing.expectApproxEqAbs(s, difference, 0.02 * (1 + @abs(s)));
    }
}

test "only the guesses that start near the true frequency reach it" {
    try requireCpu();
    const tone = Tone.init();
    const states = try std.testing.allocator.create([updates + 1]State);
    defer std.testing.allocator.destroy(states);
    try descend(std.testing.allocator, &tone, states);
    const last = states[updates];
    for (starts, last.frequency, last.value) |start, frequency, value| {
        if (start == 2.5 or start == 3.5) {
            try std.testing.expectApproxEqAbs(true_frequency, frequency, 1e-3);
            try std.testing.expect(value < 1e-6);
        } else {
            try std.testing.expect(@abs(frequency - true_frequency) > 1);
            try std.testing.expect(value > 7);
        }
    }
}
