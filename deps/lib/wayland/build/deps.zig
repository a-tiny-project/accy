const std = @import("std");
const build_api = @import("build_api");

pub fn sys(
    b: *std.Build,
    policy: build_api.ModuleOptions,
) *std.Build.Module {
    return b.dependency("sys", .{
        .target = policy.target,
        .optimize = policy.optimize,
    }).module("sys");
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
