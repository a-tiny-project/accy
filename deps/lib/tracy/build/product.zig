const std = @import("std");
const configuration = @import("configuration.zig");
const deps = @import("deps.zig");

pub fn register(
    b: *std.Build,
    config: configuration.Configuration,
    dependencies: deps.Dependencies,
    tracy_module: *std.Build.Module,
) void {
    const library = b.addLibrary(.{
        .linkage = .static,
        .name = "tracy",
        .root_module = tracy_module,
    });
    b.installArtifact(library);

    const main_module = b.createModule(config.policy.createOptions(b, "src/main.zig", &.{
        .{ .name = "sys", .module = dependencies.sys.module("sys") },
        .{ .name = "tracy", .module = tracy_module },
    }));
    const executable = b.addExecutable(.{
        .name = "tracy-agent",
        .root_module = main_module,
    });
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Run tracy-agent").dependOn(&run.step);
}
