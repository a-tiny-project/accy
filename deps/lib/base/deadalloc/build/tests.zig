const std = @import("std");

pub fn unit(
    b: *std.Build,
    deadalloc: *std.Build.Module,
    filters: []const []const u8,
) void {
    const artifact = b.addTest(.{
        .root_module = deadalloc,
        .filters = filters,
    });
    const run = b.addRunArtifact(artifact);
    const step = b.step("test", "Run deadalloc unit tests");
    step.dependOn(&run.step);
}
