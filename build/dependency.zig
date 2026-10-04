const std = @import("std");
const gpu_build = @import("gpu");

/// The device-test and allocator options belong to the gpu runtime; accy
/// declares them on its own builder and forwards them unchanged.
pub const DependencyOptions = gpu_build.DependencyOptions;
pub const dependencyOptions = gpu_build.dependencyOptions;
pub const dependencyOptionsWithAlloc = gpu_build.dependencyOptionsWithAlloc;

pub fn dependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: DependencyOptions,
) *std.Build.Dependency {
    if (!options.observe_allocations) {
        return b.dependency("accy", .{
            .target = target,
            .optimize = optimize,
            .@"gpu-tests" = options.gpu_tests,
            .@"vulkan-tests" = options.vulkan_tests,
            .@"metal-tests" = options.metal_tests,
            .@"test-allocator" = options.alloc.test_allocator_mode,
            .@"allocator-diagnostics" = options.alloc.allocator_diagnostics,
            .@"allocator-phase" = options.alloc.allocator_phase,
        });
    }
    return b.dependency("accy", .{
        .target = target,
        .optimize = optimize,
        .@"gpu-tests" = options.gpu_tests,
        .@"vulkan-tests" = options.vulkan_tests,
        .@"metal-tests" = options.metal_tests,
        .@"test-allocator" = options.alloc.test_allocator_mode,
        .@"allocator-diagnostics" = options.alloc.allocator_diagnostics,
        .@"allocator-phase" = options.alloc.allocator_phase,
        .@"observe-allocations" = true,
    });
}
