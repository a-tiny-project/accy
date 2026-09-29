const std = @import("std");
const alloc_build = @import("alloc");
const bench_build = @import("bench");
const build_api = @import("build_api");
const module = @import("module.zig");
const wayland_build = @import("wayland");

pub const Configuration = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_filters: []const []const u8,
    alloc_options: alloc_build.DependencyOptions,
    wayland_limits: wayland_build.environment.Limits,
};

pub const Requested = struct {
    inputs: module.Inputs,
    hypothesis: *std.Build.Module,
};

pub const Benchmark = struct {
    inputs: module.Inputs,
    bench: *std.Build.Module,
};

pub const Dependencies = struct {
    requested: Requested,
    benchmark: Benchmark,
};

pub fn configure(b: *std.Build) Configuration {
    const target = build_api.standardTargets(b).product;
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = build_api.focusedTestFilters(b);
    const alloc_options = alloc_build.dependencyOptions(b);
    const wayland_limits = wayland_build.environment.configuredLimits(b, .{});
    return .{
        .target = target,
        .optimize = optimize,
        .test_filters = test_filters,
        .alloc_options = alloc_options,
        .wayland_limits = wayland_limits,
    };
}

pub fn resolve(
    b: *std.Build,
    configuration: Configuration,
    benchmark_target: std.Build.ResolvedTarget,
    benchmark_optimize: std.builtin.OptimizeMode,
) Dependencies {
    const requested = resolveInputs(
        b,
        configuration.target,
        configuration.optimize,
        configuration.alloc_options,
        configuration.wayland_limits,
    );
    const benchmark = resolveInputs(
        b,
        benchmark_target,
        benchmark_optimize,
        configuration.alloc_options,
        configuration.wayland_limits,
    );
    const bench = bench_build.dependency(
        b,
        benchmark_target,
        benchmark_optimize,
        bench_build.dependencyOptions(b),
    );
    const hypothesis = b.dependency("hypothesis", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    return .{
        .requested = .{
            .inputs = requested,
            .hypothesis = hypothesis.module("hypothesis"),
        },
        .benchmark = .{
            .inputs = benchmark,
            .bench = bench.module("bench"),
        },
    };
}

fn resolveInputs(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    alloc_options: alloc_build.DependencyOptions,
    wayland_limits: wayland_build.environment.Limits,
) module.Inputs {
    const alloc = alloc_build.dependency(b, target, optimize, alloc_options);
    const sys = b.dependency("sys", .{
        .target = target,
        .optimize = optimize,
    });
    const wayland = wayland_build.environment.dependency(
        b,
        "wayland",
        target,
        optimize,
        wayland_limits,
    );
    const xkb = b.dependency("xkb", .{
        .target = target,
        .optimize = optimize,
    });
    return .{
        .alloc = alloc.module("alloc"),
        .alloc_phase = alloc.module("alloc_phase"),
        .sys = sys.module("sys"),
        .wayland = wayland.module("wayland"),
        .xkb = xkb.module("xkb"),
    };
}
