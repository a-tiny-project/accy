const std = @import("std");
const build_api = @import("build_api");

pub const Dependencies = struct {
    pretty: *std.Build.Module,
    sys: *std.Build.Module,
};

pub fn resolve(b: *std.Build, policy: build_api.ModuleOptions) Dependencies {
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
