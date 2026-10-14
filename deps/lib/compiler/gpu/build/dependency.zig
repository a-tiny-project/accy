const std = @import("std");
const tldr_build = @import("tldr");

pub const DependencyOptions = struct {
    gpu_tests: bool,
    vulkan_tests: bool,
    metal_tests: bool,
    alloc: tldr_build.DependencyOptions,
    observe_allocations: bool = false,
};

pub fn dependencyOptions(b: *std.Build) DependencyOptions {
    return dependencyOptionsWithAlloc(
        b,
        tldr_build.dependencyOptions(b),
    );
}

pub fn dependencyOptionsWithAlloc(
    b: *std.Build,
    alloc: tldr_build.DependencyOptions,
) DependencyOptions {
    return .{
        .gpu_tests = b.option(
            bool,
            "gpu-tests",
            "Enable CUDA smoke tests that require an NVIDIA driver and device",
        ) orelse false,
        .vulkan_tests = b.option(
            bool,
            "vulkan-tests",
            "Enable live Vulkan tests that require a loader and a timeline-capable device",
        ) orelse false,
        .metal_tests = b.option(
            bool,
            "metal-tests",
            "Enable live Metal tests that require an Apple Metal runtime",
        ) orelse false,
        .alloc = alloc,
        .observe_allocations = b.option(
            bool,
            "observe-allocations",
            "Compile allocator observation into owned dependencies",
        ) orelse false,
    };
}

pub fn dependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: DependencyOptions,
) *std.Build.Dependency {
    if (!options.observe_allocations) {
        return b.dependency("gpu", .{
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
    return b.dependency("gpu", .{
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
