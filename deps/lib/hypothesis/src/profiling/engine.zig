const std = @import("std");
const bench = @import("bench");
const hypothesis = @import("hypothesis");
const corpus = @import("corpus.zig");

fn overweightSum(data: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
    _ = allocator;
    var total: u64 = 0;
    var index: usize = 0;
    while (index < corpus.engine_list) : (index += 1) {
        total += try data.drawInteger(0, 1000, 0);
    }
    if (total > corpus.engine_sum_limit) return error.SumExceeded;
}

fn settings() hypothesis.Settings {
    return .{
        .max_examples = 50,
        .max_shrinks = 1000,
        .seed = corpus.seed,
        .report_failure = false,
    };
}

pub fn findAndShrink(sample_allocator: std.mem.Allocator) void {
    var result = hypothesis.engine.run(sample_allocator, &overweightSum, settings()) catch
        @panic("engine run failed");
    defer result.deinit();
    std.mem.doNotOptimizeAway(result.valid_examples);
    bench.coz.progressNamed("hypothesis.engine.find_shrink.complete");
}

test "bench: hypothesis engine witness" {
    var result = try hypothesis.engine.run(std.testing.allocator, &overweightSum, settings());
    defer result.deinit();
    try std.testing.expect(!result.passed);
    try std.testing.expect(result.failing_choices != null);
    var total: u64 = 0;
    for (result.failing_choices.?) |node| total += node.value;
    try std.testing.expect(total > corpus.engine_sum_limit);
}
