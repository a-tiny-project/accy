const std = @import("std");
const build_api = @import("build_api");

pub fn allocPhase(
    b: *std.Build,
    policy: build_api.ModuleOptions,
) *std.Build.Module {
    return b.dependency("alloc_phase", .{
        .target = policy.target,
        .optimize = policy.optimize,
    }).module("alloc_phase");
}

pub fn pretty(
    b: *std.Build,
    policy: build_api.ModuleOptions,
) *std.Build.Module {
    return b.dependency("pretty_core", .{
        .target = policy.target,
        .optimize = policy.optimize,
    }).module("pretty");
}
