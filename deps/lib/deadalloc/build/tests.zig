const std = @import("std");

pub const Unit = struct {
    parent: *std.Build.Step,
    run: *std.Build.Step,
};

pub fn unit(
    b: *std.Build,
    deadalloc: *std.Build.Module,
    filters: []const []const u8,
) Unit {
    const artifact = b.addTest(.{
        .root_module = deadalloc,
        .filters = filters,
    });
    const run = b.addRunArtifact(artifact);
    const parent = b.step("test", "Run deadalloc unit tests");
    parent.dependOn(&run.step);
    return .{
        .parent = parent,
        .run = &run.step,
    };
}
