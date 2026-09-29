const std = @import("std");
const build_api = @import("build_api");

pub const Configuration = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_filters: []const []const u8,
};

pub fn configure(b: *std.Build) Configuration {
    return .{
        .target = build_api.standardTargets(b).product,
        .optimize = b.standardOptimizeOption(.{}),
        .test_filters = build_api.focusedTestFilters(b),
    };
}

pub fn allocPhase(
    b: *std.Build,
    policy: build_api.ModuleOptions,
) *std.Build.Module {
    return b.dependency("alloc_phase", .{
        .target = policy.target,
        .optimize = policy.optimize,
    }).module("alloc_phase");
}

pub fn hypothesis(
    b: *std.Build,
    policy: build_api.ModuleOptions,
) *std.Build.Module {
    return b.dependency("hypothesis", .{
        .target = policy.target,
        .optimize = policy.optimize,
    }).module("hypothesis");
}
