const std = @import("std");
const build_api = @import("build_api");
const module = @import("module.zig");

pub fn runtime(
    b: *std.Build,
    policy: build_api.ModuleOptions,
) module.Inputs {
    const pretty = b.dependency("pretty_core", .{
        .target = policy.target,
        .optimize = policy.optimize,
    });
    const sys = b.dependency("sys", .{
        .target = policy.target,
        .optimize = policy.optimize,
    });
    return .{
        .pretty = pretty.module("pretty"),
        .sys = sys.module("sys"),
    };
}
