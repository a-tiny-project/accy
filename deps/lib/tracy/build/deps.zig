const std = @import("std");
const build_api = @import("build_api");

pub const Dependencies = struct {
    pretty: *std.Build.Dependency,
    sys: *std.Build.Dependency,
};

pub fn resolve(b: *std.Build, policy: build_api.ModuleOptions) Dependencies {
    return .{
        .pretty = b.dependency("pretty", .{
            .target = policy.target,
            .optimize = policy.optimize,
        }),
        .sys = b.dependency("sys", .{
            .target = policy.target,
            .optimize = policy.optimize,
        }),
    };
}
