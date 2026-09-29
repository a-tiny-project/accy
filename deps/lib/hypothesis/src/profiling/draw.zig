const std = @import("std");
const bench = @import("bench");
const hypothesis = @import("hypothesis");
const corpus = @import("corpus.zig");

pub fn integers(sample_allocator: std.mem.Allocator) void {
    var data = hypothesis.ConjectureData.init(sample_allocator, corpus.seed);
    defer data.deinit();
    var total: u64 = 0;
    var index: usize = 0;
    while (index < corpus.draw_choices) : (index += 1) {
        total +%= data.drawInteger(0, 1 << 32, 0) catch @panic("draw overrun");
    }
    std.mem.doNotOptimizeAway(total);
    bench.coz.progressNamed("hypothesis.draw.integers.complete");
}

pub fn replay(sample_allocator: std.mem.Allocator) void {
    const built = corpus.get();
    var data = hypothesis.ConjectureData.initReplay(sample_allocator, built.replay, null);
    defer data.deinit();
    var total: u64 = 0;
    var index: usize = 0;
    while (index < corpus.draw_choices) : (index += 1) {
        total +%= data.drawInteger(0, 1 << 32, 0) catch @panic("replay overrun");
    }
    std.mem.doNotOptimizeAway(total);
    bench.coz.progressNamed("hypothesis.draw.replay.complete");
}

pub fn blocks(sample_allocator: std.mem.Allocator) void {
    var data = hypothesis.ConjectureData.init(sample_allocator, corpus.seed);
    defer data.deinit();
    var total: usize = 0;
    var index: usize = 0;
    while (index < corpus.draw_blocks) : (index += 1) {
        const bytes = data.drawBytes(16, 256) catch @panic("bytes overrun");
        total +%= bytes.len;
    }
    std.mem.doNotOptimizeAway(total);
    bench.coz.progressNamed("hypothesis.draw.blocks.complete");
}
