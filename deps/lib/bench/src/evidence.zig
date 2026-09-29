const std = @import("std");
const pretty_json = @import("pretty").json;
const stabilizer = @import("stabilizer");

pub fn writeBenchmarkEvidence(object: pretty_json.Object, config: ?stabilizer.Config) !void {
    try object.field("schema", "tiny.profile-evidence/v1");
    try object.field("primary_user", "agent");
    try object.field("runner", "lib.bench");
    try object.field("decision_state", "distribution_measurement");
    const bias = try object.object("bias_repetition");
    try bias.field("build", "single_observed");
    try bias.field("process", "in_process_samples");
    try bias.field("sample_sequence", "measured_acquisition_order");
    try bias.field("sample_timestamps", "not_recorded");
    try bias.field("heap", layoutState(config, .heap));
    try bias.field("heap_pointer_validation", pointerValidationState(config));
    try bias.field("stack", layoutState(config, .stack));
    try bias.field("code", layoutState(config, .code));
    try bias.field("environment", "single_observed");
    try bias.end();
    const statistics = try object.object("statistics");
    try writeStrings(
        try statistics.array("primary"),
        &.{ "median_ns", "p75_ns", "p99_ns", "sample_ns" },
    );
    try writeStrings(
        try statistics.array("secondary"),
        &.{ "mean_ns", "stddev_ns", "min_ns", "max_ns" },
    );
    const intervals = try statistics.object("confidence_intervals");
    try intervals.field("field", "confidence_intervals");
    try intervals.field("method", "percentile_bootstrap");
    try intervals.field(
        "default_iterations",
        @import("stats/root.zig").default_bootstrap_iterations,
    );
    try intervals.field("default_confidence", 0.95);
    try intervals.end();
    try statistics.end();
    try writeStrings(try object.array("claim_limits"), &.{
        "single-process benchmark samples do not prove cross-build speedups",
        "code layout is not randomized by the default bench configuration",
        "mean and standard deviation are secondary for skewed timing distributions",
        "automatic eval calibration is discarded preconditioning, not an independent sample",
        "automatic eval selection requires two consecutive target-covering calibration batches",
        "fixed eval batches may remain timer-bound; inspect clock and sample_total_ns",
        "sample order exposes within-process shifts without attributing their cause",
    });
    try object.end();
}

const LayoutAxis = enum {
    heap,
    stack,
    code,
};

fn layoutState(config: ?stabilizer.Config, axis: LayoutAxis) []const u8 {
    const actual = config orelse return "not_recorded";
    return switch (axis) {
        .heap => if (actual.heap.enabled) "per_sample" else "disabled",
        .stack => if (actual.stack.enabled) "per_sample" else "disabled",
        .code => if (actual.code.enabled) "configured_not_verified" else "not_randomized",
    };
}

fn pointerValidationState(config: ?stabilizer.Config) []const u8 {
    const actual = config orelse return "not_recorded";
    return if (actual.heap.pointer_validation) "enabled" else "disabled";
}

fn writeStrings(array: pretty_json.Array, values: []const []const u8) !void {
    for (values) |value| try array.element(value);
    try array.end();
}

test "benchmark evidence records code layout limit" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var stream = pretty_json.Writer.init(&out.writer, .minified);
    try writeBenchmarkEvidence(try stream.object(), .{
        .heap = .{ .pointer_validation = false, .shuffle_slots = 5 },
        .code = .{ .enabled = false },
    });
    const json = out.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":\"not_randomized\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"heap_pointer_validation\":\"disabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"primary_user\":\"agent\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "\"sample_sequence\":\"measured_acquisition_order\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, json, "\"sample_timestamps\":\"not_recorded\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, json, "\"confidence_intervals\":{\"field\":\"confidence_intervals\"") != null);
}
