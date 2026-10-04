const std = @import("std");
const model = @import("model.zig");

pub fn dependencyOptions(b: *std.Build) model.DependencyOptions {
    return .{
        .test_allocator_mode = b.option([]const u8, "test-allocator", "Test allocator mode") orelse "fast",
        .allocator_diagnostics = b.option([]const u8, "allocator-diagnostics", "Allocator diagnostics mode") orelse "off",
        .allocator_phase = b.option([]const u8, "allocator-phase", "Process allocator phase enforcement mode") orelse "off",
    };
}

pub fn dependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: model.DependencyOptions,
) *std.Build.Dependency {
    return b.dependency("alloc", .{
        .target = target,
        .optimize = optimize,
        .@"test-allocator" = options.test_allocator_mode,
        .@"allocator-diagnostics" = options.allocator_diagnostics,
        .@"allocator-phase" = options.allocator_phase,
    });
}
