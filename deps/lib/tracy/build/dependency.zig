const std = @import("std");

pub const DependencyOptions = struct {
    enabled: bool,
};

pub fn dependencyOptions(b: *std.Build) DependencyOptions {
    return .{
        .enabled = b.option(
            bool,
            "enabled",
            "Enable native Tracy trace instrumentation",
        ) orelse false,
    };
}

pub fn dependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: DependencyOptions,
) *std.Build.Dependency {
    return b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
        .enabled = options.enabled,
    });
}
