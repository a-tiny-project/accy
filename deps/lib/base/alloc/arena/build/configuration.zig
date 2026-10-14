const std = @import("std");
const build_api = @import("build_api");

pub const Configuration = struct {
    policy: build_api.ModuleOptions,
    observe_allocations: bool,
    test_filters: []const []const u8,
};

pub fn resolve(b: *std.Build) Configuration {
    return .{
        .policy = .{
            .target = build_api.standardTargets(b).product,
            .optimize = b.standardOptimizeOption(.{}),
        },
        .observe_allocations = b.option(
            bool,
            "observe-allocations",
            "Compile allocator observation into the arena vtable",
        ) orelse false,
        .test_filters = build_api.focusedTestFilters(b),
    };
}
