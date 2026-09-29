const std = @import("std");

pub fn unit(
    b: *std.Build,
    coz: *std.Build.Module,
    filters: []const []const u8,
) void {
    const artifact = b.addTest(.{
        .root_module = coz,
        .filters = filters,
    });
    artifact.rdynamic = true;
    const run = b.addRunArtifact(artifact);
    const parent = b.step("test", "Run Coz API tests");
    parent.dependOn(&run.step);
}
