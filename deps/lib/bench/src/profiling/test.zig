const std = @import("std");
const bench = @import("bench");
const sys = @import("sys");

const allocation_count: usize = 1_000_000;
const allocation_sizes = [_]usize{ 16, 32, 64, 128 };

fn allocationWorkload(allocator: std.mem.Allocator) void {
    const phase = bench.phaseAt("stabilizer.pointer_validation.workload", @src());
    defer phase.end();

    var checksum: usize = 0;
    var index: usize = 0;
    while (index < allocation_count) : (index += 1) {
        const len = allocation_sizes[index % allocation_sizes.len];
        const memory = allocator.alloc(u8, len) catch @panic("stabilizer allocation failed");
        memory[0] = @truncate(index);
        memory[len - 1] = @truncate(index >> 8);
        checksum +%= memory[0];
        checksum +%= memory[len - 1];
        allocator.free(memory);
    }
    std.mem.doNotOptimizeAway(checksum);
    bench.coz.progressNamed("stabilizer.pointer_validation.sample");
}

fn layoutConfig(pointer_validation: bool) bench.stabilizer.Config {
    return .{
        .seed = bench.stabilizer.default_seed,
        .heap = .{
            .pointer_validation = pointer_validation,
            .shuffle_slots = 16,
            .min_class_size = 16,
            .max_shuffled_size = 128,
        },
        .stack = .{ .enabled = false },
        .code = .{ .enabled = false },
    };
}

test "bench: stabilizer pointer validation" {
    var suite = bench.Suite.init(sys.allocator.benchmarkAllocator(), .{
        .suite_name = "bench.stabilizer.pointer_validation",
        .max_iterations = 1,
        .min_iterations = 1,
        .evaluation = .{ .fixed = 1 },
        .warmup_iterations = 0,
        .allocation_attribution = .sample_call,
        .layout_randomization = null,
    });
    defer suite.deinit();
    try suite.add(
        "stabilizer.pointer_validation.candidate 1000000",
        allocationWorkload,
        .{ .layout_randomization = @as(?bench.stabilizer.Config, layoutConfig(false)) },
    );
    try suite.add(
        "stabilizer.pointer_validation.baseline 1000000",
        allocationWorkload,
        .{ .layout_randomization = @as(?bench.stabilizer.Config, layoutConfig(true)) },
    );
    try suite.run();
    bench.coz.progressNamed("stabilizer.pointer_validation.bench.complete");
}
