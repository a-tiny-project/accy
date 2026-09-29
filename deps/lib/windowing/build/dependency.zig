const std = @import("std");
const alloc_build = @import("alloc");

pub const DependencyOptions = struct {
    alloc: alloc_build.DependencyOptions,
};

pub fn dependencyOptions(b: *std.Build) DependencyOptions {
    return .{ .alloc = alloc_build.dependencyOptions(b) };
}

pub fn dependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: DependencyOptions,
) *std.Build.Dependency {
    return b.dependency("windowing", .{
        .target = target,
        .optimize = optimize,
        .@"test-allocator" = options.alloc.test_allocator_mode,
        .@"allocator-diagnostics" = options.alloc.allocator_diagnostics,
        .@"allocator-phase" = options.alloc.allocator_phase,
    });
}
