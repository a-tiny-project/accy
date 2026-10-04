const std = @import("std");
const build_api = @import("build_api");
const configuration = @import("configuration.zig");
const graph = @import("graph.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = configuration.resolve(b);
    const resolved = graph.resolve(b, config);
    _ = build_api.addStaticLibrary(b, .{
        .name = "alloc",
        .root_module = resolved.alloc,
    });
    tests.register(
        b,
        config,
        resolved.tests,
        resolved.locked_tests,
        resolved.limit_tests,
    );
}
