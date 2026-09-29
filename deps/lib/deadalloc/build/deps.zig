const std = @import("std");
const configuration = @import("configuration.zig");

pub const Dependencies = struct {
    library_pretty: *std.Build.Module,
    library_sys: *std.Build.Dependency,
    preload_sys: *std.Build.Module,
    preload_coz: *std.Build.Module,
    test_coz: *std.Build.Module,
};

pub fn resolve(
    b: *std.Build,
    policies: configuration.Policies,
) Dependencies {
    const library_sys = b.dependency("sys", .{
        .target = policies.library.target,
        .optimize = policies.library.optimize,
    });
    const library_pretty = b.dependency("pretty", .{
        .target = policies.library.target,
        .optimize = policies.library.optimize,
    });
    const preload_sys = b.dependency("sys", .{
        .target = policies.preload.target,
        .optimize = policies.preload.optimize,
    });
    const preload_coz = b.dependency("coz", .{
        .target = policies.preload.target,
        .optimize = policies.preload.optimize,
    });
    const test_coz = b.dependency("coz", .{
        .target = policies.library.target,
        .optimize = policies.library.optimize,
    });
    return .{
        .library_pretty = library_pretty.module("pretty"),
        .library_sys = library_sys,
        .preload_sys = preload_sys.module("sys"),
        .preload_coz = preload_coz.module("coz"),
        .test_coz = test_coz.module("coz"),
    };
}
