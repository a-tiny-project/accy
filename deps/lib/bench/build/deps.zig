const std = @import("std");
const build_api = @import("build_api");
const dependency_contract = @import("dependency.zig");
const module = @import("module.zig");
const tracy_build = @import("tracy");

pub const Configuration = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_filters: []const []const u8,
    dependency_options: dependency_contract.DependencyOptions,
};

pub const Requested = struct {
    inputs: module.Inputs,
    hypothesis: *std.Build.Module,
};

pub fn configure(b: *std.Build) Configuration {
    return .{
        .target = build_api.standardTargets(b).product,
        .optimize = b.standardOptimizeOption(.{}),
        .test_filters = build_api.focusedTestFilters(b),
        .dependency_options = dependency_contract.dependencyOptions(b),
    };
}

pub fn resolve(
    b: *std.Build,
    configuration: Configuration,
) Requested {
    const alloc_phase = b.dependency("alloc_phase", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    const bootstrap = b.dependency("bench_bootstrap", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    const coz = b.dependency("coz", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    const pretty = b.dependency("pretty", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    const hypothesis = b.dependency("hypothesis", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    const memtrace = if (configuration.dependency_options.observe_allocations)
        b.dependency("memtrace", .{
            .target = configuration.target,
            .optimize = configuration.optimize,
            .@"observe-allocations" = true,
        })
    else
        b.dependency("memtrace", .{
            .target = configuration.target,
            .optimize = configuration.optimize,
        });
    const stabilizer = b.dependency("stabilizer", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    const sys = b.dependency("sys", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    const tracy = tracy_build.dependency(
        b,
        configuration.target,
        configuration.optimize,
        .{ .enabled = configuration.dependency_options.tracy },
    );
    return .{
        .inputs = .{
            .alloc_phase = alloc_phase.module("alloc_phase"),
            .bootstrap = bootstrap.module("bench_bootstrap"),
            .coz = coz.module("coz"),
            .memtrace = memtrace.module("memtrace"),
            .pretty = pretty.module("pretty"),
            .stabilizer = stabilizer.module("stabilizer"),
            .sys = sys.module("sys"),
            .tracy = tracy.module("tracy"),
        },
        .hypothesis = hypothesis.module("hypothesis"),
    };
}
