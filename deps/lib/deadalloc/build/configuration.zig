const std = @import("std");
const build_api = @import("build_api");

pub const Policies = struct {
    library: build_api.ModuleOptions,
    preload: build_api.ModuleOptions,
};

pub const Configuration = struct {
    policies: Policies,
    test_filters: []const []const u8,
    reference_build: []const u8,
};

pub fn resolve(b: *std.Build) Configuration {
    const target = build_api.standardTargets(b).product;
    const optimize = b.standardOptimizeOption(.{});
    const policies = Policies{
        .library = .{
            .target = target,
            .optimize = optimize,
        },
        .preload = .{
            .target = target,
            .optimize = .fast,
        },
    };
    const test_filters = build_api.focusedTestFilters(b);
    const reference_build = b.option(
        []const u8,
        "diehard-reference-build",
        "Path to a built Emery Berger DieHard checkout",
    ) orelse "";
    return .{
        .policies = policies,
        .test_filters = test_filters,
        .reference_build = reference_build,
    };
}
