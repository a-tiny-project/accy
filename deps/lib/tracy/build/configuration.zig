const std = @import("std");
const build_api = @import("build_api");
const dependency_owner = @import("dependency.zig");

pub const Configuration = struct {
    policy: build_api.ModuleOptions,
    test_filters: []const []const u8,
    enabled: bool,
};

pub fn resolve(b: *std.Build) Configuration {
    const dependency_options = dependency_owner.dependencyOptions(b);
    return .{
        .policy = .{
            .target = build_api.standardTargets(b).product,
            .optimize = b.standardOptimizeOption(.{}),
        },
        .test_filters = build_api.focusedTestFilters(b),
        .enabled = dependency_options.enabled,
    };
}
