const std = @import("std");
const build_api = @import("build_api");

pub const Configuration = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_filters: []const []const u8,
};

pub const Runtime = struct {
    pretty_core: *std.Build.Module,
    sys: *std.Build.Module,
};

pub fn configure(b: *std.Build) Configuration {
    return .{
        .target = build_api.standardTargets(b).product,
        .optimize = b.standardOptimizeOption(.{}),
        .test_filters = build_api.focusedTestFilters(b),
    };
}

pub fn resolve(b: *std.Build, configuration: Configuration) Runtime {
    const pretty_core = b.dependency("pretty_core", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    const sys = b.dependency("sys", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    return .{
        .pretty_core = pretty_core.module("pretty"),
        .sys = if (isBrowserish(configuration.target.result))
            sys.module("sys_no_libc")
        else
            sys.module("sys"),
    };
}

fn isBrowserish(target: std.Target) bool {
    return target.cpu.arch.isWasm() and target.os.tag == .freestanding;
}
