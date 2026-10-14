const std = @import("std");
const alloc_build = @import("alloc");

pub const DependencyOptions = alloc_build.DependencyOptions;

pub const dependencyOptions = alloc_build.dependencyOptions;

pub fn dependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: DependencyOptions,
) *std.Build.Dependency {
    return dependencyWithAllocationObservation(
        b,
        target,
        optimize,
        options,
        false,
    );
}

pub fn dependencyWithAllocationObservation(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: DependencyOptions,
    observe_allocations: bool,
) *std.Build.Dependency {
    if (!observe_allocations) {
        return b.dependency("tldr", .{
            .target = target,
            .optimize = optimize,
            .@"test-allocator" = options.test_allocator_mode,
            .@"allocator-diagnostics" = options.allocator_diagnostics,
            .@"allocator-phase" = options.allocator_phase,
        });
    }
    return b.dependency("tldr", .{
        .target = target,
        .optimize = optimize,
        .@"test-allocator" = options.test_allocator_mode,
        .@"allocator-diagnostics" = options.allocator_diagnostics,
        .@"allocator-phase" = options.allocator_phase,
        .@"observe-allocations" = true,
    });
}
