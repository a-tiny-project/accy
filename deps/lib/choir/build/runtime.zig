const std = @import("std");
const build_api = @import("build_api");
const module = @import("module.zig");

pub const Configuration = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_filters: []const []const u8,
    observe_allocations: bool,
    browserish: bool,
};

pub fn configure(b: *std.Build) Configuration {
    const target = build_api.standardTargets(b).product;
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = build_api.focusedTestFilters(b);
    const observe_allocations = b.option(
        bool,
        "observe-allocations",
        "Compile allocator observation into owned Choir producers",
    ) orelse false;
    return .{
        .target = target,
        .optimize = optimize,
        .test_filters = test_filters,
        .observe_allocations = observe_allocations,
        .browserish = isBrowserish(target.result),
    };
}

/// Returns `configuration` retargeted to the profiling policy, which never builds the browser
/// system module.
pub fn profilingConfiguration(
    configuration: Configuration,
    policy: build_api.ModuleOptions,
) Configuration {
    var result = configuration;
    result.target = policy.target;
    result.optimize = policy.optimize;
    result.browserish = false;
    return result;
}

pub fn resolveRequested(b: *std.Build, configuration: Configuration) module.Inputs {
    const arena = arenaDependency(
        b,
        configuration.target,
        configuration.optimize,
        configuration.observe_allocations,
    ).module("alloc_arena");
    const alloc_observe = arena.import_table.get("alloc_observe") orelse
        @panic("arena module is missing alloc_observe");
    const fixed = fixedDependency(
        b,
        configuration.target,
        configuration.optimize,
        configuration.observe_allocations,
    ).module("alloc_fixed");
    build_api.requireImport(fixed, "alloc_observe", alloc_observe);
    const sys = b.dependency("sys", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    const pretty = b.dependency("pretty_core", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    return .{
        .alloc_arena = arena,
        .alloc_fixed = fixed,
        .alloc_observe = alloc_observe,
        .alloc_phase = b.dependency("alloc_phase", .{
            .target = configuration.target,
            .optimize = configuration.optimize,
        }).module("alloc_phase"),
        .gpu_abi = b.dependency("gpu_abi", .{
            .target = configuration.target,
            .optimize = configuration.optimize,
        }).module("gpu_abi"),
        .pretty = pretty.module("pretty"),
        .isa = b.dependency("isa", .{
            .target = configuration.target,
            .optimize = configuration.optimize,
        }).module("isa"),
        .simd = b.dependency("simd", .{
            .target = configuration.target,
            .optimize = configuration.optimize,
        }).module("simd"),
        .sys = if (configuration.browserish)
            sys.module("sys_no_libc")
        else
            sys.module("sys"),
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

fn fixedDependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    observe_allocations: bool,
) *std.Build.Dependency {
    if (!observe_allocations) {
        return b.dependency("alloc_fixed", .{
            .target = target,
            .optimize = optimize,
        });
    }
    return b.dependency("alloc_fixed", .{
        .target = target,
        .optimize = optimize,
        .@"observe-allocations" = true,
    });
}

fn isBrowserish(target: std.Target) bool {
    return target.cpu.arch.isWasm() and target.os.tag == .freestanding;
}
