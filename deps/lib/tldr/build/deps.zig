const std = @import("std");
const alloc_build = @import("alloc");
const build_api = @import("build_api");

pub const Configuration = struct {
    targets: build_api.Targets,
    optimize: std.builtin.OptimizeMode,
    test_filters: []const []const u8,
    alloc_options: alloc_build.DependencyOptions,
    /// The flag is true when the build runs with `-Dobserve-allocations=true`.
    /// It compiles allocator observation into the arena the package links.
    observe_allocations: bool,
};

pub const Requested = struct {
    alloc: *std.Build.Module,
    alloc_phase: *std.Build.Module,
    alloc_arena: *std.Build.Module,
    coz: *std.Build.Module,
    pretty: *std.Build.Module,
    pretty_usage: *std.Build.Module,
    sys: *std.Build.Module,
};

pub fn configure(b: *std.Build) Configuration {
    const targets = build_api.standardTargets(b);
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = build_api.focusedTestFilters(b);
    const alloc_options = alloc_build.dependencyOptions(b);
    const observe_allocations = b.option(
        bool,
        "observe-allocations",
        "Compile allocator observation into producer vtables",
    ) orelse false;
    return .{
        .targets = targets,
        .optimize = optimize,
        .test_filters = test_filters,
        .alloc_options = alloc_options,
        .observe_allocations = observe_allocations,
    };
}

pub fn resolveRequested(
    b: *std.Build,
    configuration: Configuration,
) Requested {
    return resolveRole(
        b,
        configuration,
        configuration.targets.product,
        configuration.optimize,
    );
}

pub fn resolveRole(
    b: *std.Build,
    configuration: Configuration,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Requested {
    const alloc = alloc_build.dependency(
        b,
        target,
        optimize,
        configuration.alloc_options,
    );
    const alloc_arena = arenaDependency(
        b,
        target,
        optimize,
        configuration.observe_allocations,
    );
    const coz = b.dependency("coz", .{
        .target = target,
        .optimize = optimize,
    });
    const sys = b.dependency("sys", .{
        .target = target,
        .optimize = optimize,
    });
    const pretty = b.dependency("pretty", .{
        .target = target,
        .optimize = optimize,
    });
    return .{
        .alloc = alloc.module("alloc"),
        .alloc_phase = alloc.module("alloc_phase"),
        .alloc_arena = alloc_arena.module("alloc_arena"),
        .coz = coz.module("coz"),
        .pretty = pretty.module("pretty"),
        .pretty_usage = pretty.module("pretty_usage"),
        .sys = sys.module("sys"),
    };
}

fn arenaDependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    observe_allocations: bool,
) *std.Build.Dependency {
    if (!observe_allocations) {
        return b.dependency("alloc_arena", .{
            .target = target,
            .optimize = optimize,
        });
    }
    return b.dependency("alloc_arena", .{
        .target = target,
        .optimize = optimize,
        .@"observe-allocations" = true,
    });
}
