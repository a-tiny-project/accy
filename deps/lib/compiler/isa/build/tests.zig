const std = @import("std");

pub fn add(
    b: *std.Build,
    module: *std.Build.Module,
    filters: []const []const u8,
) void {
    const artifact = b.addTest(.{
        .name = "isa-tests",
        .root_module = module,
        .filters = filters,
    });
    const run = b.addRunArtifact(artifact);
    const step = b.step("test", "Run instruction-set architecture tests");
    step.dependOn(&run.step);
}
