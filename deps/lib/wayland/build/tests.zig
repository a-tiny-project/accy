const std = @import("std");
const configuration = @import("configuration.zig");
const sys_build = @import("sys");

pub fn unit(
    b: *std.Build,
    config: configuration.Configuration,
    module: *std.Build.Module,
    generated_check: *std.Build.Step,
) void {
    const artifact = b.addTest(.{
        .root_module = module,
        .filters = config.test_filters,
    });
    const run = b.addRunArtifact(artifact);
    const parent = b.step("test", "Run Wayland transport tests");
    parent.dependOn(&run.step);
    parent.dependOn(generated_check);
    if (sys_build.addNoLibcNeededCheck(b, .{
        .target = config.policy.target,
        .step_name = "no-libc-needed",
        .description = "Check the Wayland transport test artifact does not require libc",
        .label = "wayland-no-libc-needed",
        .artifacts = &.{artifact},
        .strict_undefined = .all,
    })) |step| parent.dependOn(step);
}

pub fn properties(
    b: *std.Build,
    config: configuration.Configuration,
    module: *std.Build.Module,
    generated_check: *std.Build.Step,
) void {
    const artifact = b.addTest(.{
        .root_module = module,
        .filters = config.test_filters,
    });
    const run = b.addRunArtifact(artifact);
    const parent = b.step("pbt", "Run Wayland transport property tests");
    parent.dependOn(&run.step);
    parent.dependOn(generated_check);
}
