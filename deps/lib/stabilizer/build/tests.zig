const std = @import("std");

pub fn unit(
    b: *std.Build,
    stabilizer: *std.Build.Module,
    filters: []const []const u8,
) void {
    const artifact = b.addTest(.{
        .root_module = stabilizer,
        .filters = filters,
    });
    const run = b.addRunArtifact(artifact);
    const parent = b.step("test", "Run Stabilizer API tests");
    parent.dependOn(&run.step);
}

pub fn properties(b: *std.Build, module: *std.Build.Module) void {
    const artifact = b.addTest(.{
        .root_module = module,
        .filters = &.{"pbt:"},
    });
    const run = b.addRunArtifact(artifact);
    const parent = b.step("pbt", "Run Stabilizer property tests");
    parent.dependOn(&run.step);
}
