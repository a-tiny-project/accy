const std = @import("std");
const build_api = @import("build_api");

pub const Configuration = struct {
    policy: build_api.ModuleOptions,
    test_filters: []const []const u8,
};

pub fn resolve(b: *std.Build) Configuration {
    return .{
        .policy = .{
            .target = build_api.standardTargets(b).product,
            .optimize = b.standardOptimizeOption(.{}),
        },
        .test_filters = build_api.focusedTestFilters(b),
    };
}
