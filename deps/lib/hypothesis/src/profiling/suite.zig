const std = @import("std");
const bench = @import("bench");
const corpus = @import("corpus.zig");
const database = @import("database.zig");
const draw = @import("draw.zig");
const engine = @import("engine.zig");
const shrink = @import("shrink.zig");

test "bench: hypothesis shrinker and draw paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try corpus.build(arena_state.allocator());
    defer corpus.reset();
    var database_fixture = try database.Fixture.init(std.testing.allocator);
    defer database_fixture.deinit();
    database.activate(&database_fixture);
    defer database.deactivate();

    var suite = bench.Suite.init(std.testing.allocator, .{
        .min_time_ns = 10_000_000,
        .max_iterations = 2000,
    });
    defer suite.deinit();

    try suite.add("hypothesis shrink delete x1024", shrink.deleteLadder, .{});
    try suite.add("hypothesis shrink lattice x256", shrink.latticeSmall, .{});
    try suite.add("hypothesis shrink lattice x4096", shrink.latticeLarge, .{
        .min_iterations = 5,
        .max_iterations = 64,
    });
    try suite.add("hypothesis shrink stall x1024", shrink.stallSweep, .{
        .min_iterations = 5,
        .max_iterations = 128,
    });
    try suite.add("hypothesis engine find shrink x64", engine.findAndShrink, .{});
    try suite.add("hypothesis draw integers x4096", draw.integers, .{});
    try suite.add("hypothesis draw replay x4096", draw.replay, .{});
    try suite.add("hypothesis draw bytes x64", draw.blocks, .{});
    try suite.add("hypothesis database load 64x64", database.load, .{
        .min_iterations = 5,
        .max_iterations = 128,
        .allocation_attribution = .sample_call,
    });
    try suite.add("hypothesis database load replay 64x64", database.loadReplay, .{
        .min_iterations = 5,
        .max_iterations = 128,
        .allocation_attribution = .sample_call,
    });
    try suite.add(
        "hypothesis database bounded load 64 of 1024",
        database.loadBoundedOverflow,
        .{
            .min_iterations = 5,
            .max_iterations = 128,
            .allocation_attribution = .sample_call,
        },
    );
    try suite.add("hypothesis database save 64x128", database.save, .{
        .min_iterations = 5,
        .max_iterations = 128,
        .allocation_attribution = .sample_call,
    });
    try suite.run();
}
