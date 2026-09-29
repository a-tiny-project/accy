const std = @import("std");
const bench = @import("bench");
const hypothesis = @import("hypothesis");
const corpus = @import("corpus.zig");

var context_slot: u8 = 0;

fn runShrink(
    sample_allocator: std.mem.Allocator,
    choices: []const hypothesis.ChoiceNode,
    spans: []const hypothesis.Span,
    replay_fn: hypothesis.shrinker.ReplayFn,
) hypothesis.shrinker.ShrinkResult {
    return hypothesis.shrinker.shrink(
        sample_allocator,
        choices,
        spans,
        null,
        replay_fn,
        @ptrCast(&context_slot),
        corpus.shrink_budget,
    ) catch @panic("shrink failed");
}

pub fn deleteLadder(sample_allocator: std.mem.Allocator) void {
    const built = corpus.get();
    var result = runShrink(sample_allocator, built.delete, built.delete_spans, corpus.survivorsPredicate);
    defer result.deinit(sample_allocator);
    std.mem.doNotOptimizeAway(result.choices.len);
    bench.coz.progressNamed("hypothesis.shrink.delete.complete");
}

pub fn latticeSmall(sample_allocator: std.mem.Allocator) void {
    const built = corpus.get();
    var result = runShrink(sample_allocator, built.lattice256, &.{}, corpus.latticePredicate);
    defer result.deinit(sample_allocator);
    std.mem.doNotOptimizeAway(result.choices.len);
    bench.coz.progressNamed("hypothesis.shrink.lattice.small.complete");
}

pub fn latticeLarge(sample_allocator: std.mem.Allocator) void {
    const built = corpus.get();
    var result = runShrink(sample_allocator, built.lattice4096, &.{}, corpus.latticePredicate);
    defer result.deinit(sample_allocator);
    std.mem.doNotOptimizeAway(result.choices.len);
    bench.coz.progressNamed("hypothesis.shrink.lattice.large.complete");
}

pub fn stallSweep(sample_allocator: std.mem.Allocator) void {
    const built = corpus.get();
    var result = runShrink(sample_allocator, built.stall, built.stall_spans, corpus.stallPredicate);
    defer result.deinit(sample_allocator);
    std.mem.doNotOptimizeAway(result.choices.len);
    bench.coz.progressNamed("hypothesis.shrink.stall.complete");
}

fn resultDigest(result: hypothesis.shrinker.ShrinkResult) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (result.choices) |node| {
        hasher.update(std.mem.asBytes(&node.value));
        hasher.update(std.mem.asBytes(&node.kind));
    }
    var len_bytes = std.mem.toBytes(@as(u64, result.choices.len));
    hasher.update(&len_bytes);
    return hasher.final();
}

test "bench: hypothesis shrink witnesses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try corpus.build(arena_state.allocator());
    defer corpus.reset();
    const built = corpus.get();
    const allocator = std.testing.allocator;

    var deleted = runShrink(allocator, built.delete, built.delete_spans, corpus.survivorsPredicate);
    defer deleted.deinit(allocator);
    try std.testing.expect(deleted.choices.len >= corpus.delete_survivors);
    try std.testing.expect(deleted.choices.len < corpus.delete_choices);
    try std.testing.expectEqual(@as(u64, 0x2d9bec33cf09a94a), resultDigest(deleted));

    var lattice = runShrink(allocator, built.lattice256, &.{}, corpus.latticePredicate);
    defer lattice.deinit(allocator);
    for (lattice.choices) |node| {
        try std.testing.expect(node.value >= corpus.lattice_floor);
    }
    try std.testing.expect(lattice.choices[0].value < (1 << 31));
    try std.testing.expectEqual(@as(u64, 0x94d875f874f0a53a), resultDigest(lattice));

    var stalled = runShrink(allocator, built.stall, built.stall_spans, corpus.stallPredicate);
    defer stalled.deinit(allocator);
    try std.testing.expectEqual(corpus.stall_choices, stalled.choices.len);
    for (stalled.choices) |node| {
        try std.testing.expectEqual(corpus.stall_value, node.value);
    }
    try std.testing.expectEqual(@as(u64, 0x552ae510f2a6375e), resultDigest(stalled));
}
