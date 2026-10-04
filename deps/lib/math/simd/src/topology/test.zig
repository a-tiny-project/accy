const std = @import("std");
const alloc_phase = @import("alloc_phase");
const builtin = @import("builtin");
const model = @import("model.zig");
const native = @import("native.zig");
const parsing = @import("parse/root.zig");
const parsing_tests = @import("parse/test.zig");
const topology_api = @import("root.zig");
const platform_tests = if (builtin.target.os.tag == .linux)
    @import("linux/test.zig")
else if (builtin.target.os.tag.isDarwin())
    @import("apple/test.zig")
else if (builtin.target.os.tag == .windows)
    @import("windows/test.zig")
else if (builtin.target.os.tag == .freebsd)
    @import("freebsd/test.zig")
else if (builtin.target.os.tag == .emscripten)
    @import("wasm/test.zig")
else
    struct {};

const max_logical_processors = topology_api.max_logical_processors;
const LogicalProcessorSet = topology_api.LogicalProcessorSet;
const Cache = topology_api.Cache;
const totalLogicalProcessors = topology_api.totalLogicalProcessors;
const getThreadAffinity = topology_api.getThreadAffinity;
const init = topology_api.init;
const dataCaches = topology_api.dataCaches;

test "Highway native topology surfaces preserve availability contracts" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Topology, "simd_topology_native"),
        );
    }

    try std.testing.expect(totalLogicalProcessors() >= 1);
    try std.testing.expect(
        totalLogicalProcessors() <= max_logical_processors,
    );
    var affinity = LogicalProcessorSet{};
    if (getThreadAffinity(&affinity)) {
        try std.testing.expect(affinity.any());
        try std.testing.expect(
            affinity.count() <= totalLogicalProcessors(),
        );
    }
    var topology = try init(std.testing.allocator);
    defer topology.deinit(std.testing.allocator);
    if (topology.packages.len == 0) return;
    try std.testing.expectEqual(
        totalLogicalProcessors(),
        topology.lps.len,
    );
    for (topology.lps) |lp| {
        try std.testing.expect(lp.package < topology.packages.len);
        const package = topology.packages[lp.package];
        try std.testing.expect(lp.cluster < package.clusters.len);
        try std.testing.expect(lp.core < package.cores.len);
    }
}

test "Highway native data caches are internally consistent when available" {
    const caches = dataCaches() orelse return;
    for (caches[1..4], 1..) |cache, level| {
        if (level == 3 and cache.size_kib == 0) {
            try std.testing.expectEqual(Cache{}, cache);
            continue;
        }
        try std.testing.expect(cache.size_kib != 0);
        try std.testing.expect(cache.sets != 0);
        try std.testing.expect(cache.associativity >= 2);
        try std.testing.expect(
            cache.associativity <= Cache.max_associativity,
        );
        try std.testing.expect(
            std.math.isPowerOfTwo(cache.bytes_per_line),
        );
        try std.testing.expect(cache.bytes_per_line >= 32);
        try std.testing.expect(cache.bytes_per_line <= 1024);
        try std.testing.expect(cache.cores_sharing >= 1);
        try std.testing.expect(
            cache.cores_sharing <= totalLogicalProcessors() + 1,
        );
    }
}

test {
    _ = model;
    _ = native;
    _ = parsing;
    _ = parsing_tests;
    _ = platform_tests;
}
