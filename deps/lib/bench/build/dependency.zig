const std = @import("std");

pub const DependencyOptions = struct {
    tracy: bool = false,
    observe_allocations: bool = false,
};

pub fn dependencyOptions(b: *std.Build) DependencyOptions {
    return .{
        .tracy = b.option(bool, "tracy", "Enable native Tracy trace instrumentation") orelse false,
        .observe_allocations = b.option(
            bool,
            "bench-observe-allocations",
            "Compile allocator observation into producer vtables",
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
        return b.dependency("bench", .{
            .target = target,
            .optimize = optimize,
            .tracy = options.tracy,
        });
    }
    return b.dependency("bench", .{
        .target = target,
        .optimize = optimize,
        .tracy = options.tracy,
        .@"bench-observe-allocations" = true,
    });
}
