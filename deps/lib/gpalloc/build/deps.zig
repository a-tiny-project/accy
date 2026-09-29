const std = @import("std");
const build_api = @import("build_api");

pub const Requested = struct {
    sys: *std.Build.Module,
    pretty: *std.Build.Module,
};

pub fn resolveRequested(
    b: *std.Build,
    policy: build_api.ModuleOptions,
) Requested {
    const sys = b.dependency("sys", .{
        .target = policy.target,
        .optimize = policy.optimize,
    }).module("sys");
    const pretty = b.dependency("pretty", .{
        .target = policy.target,
        .optimize = policy.optimize,
    }).module("pretty");
    return .{
        .sys = sys,
        .pretty = pretty,
    };
}
