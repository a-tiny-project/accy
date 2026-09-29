const std = @import("std");

pub fn library(b: *std.Build, memtrace: *std.Build.Module) void {
    const artifact = b.addLibrary(.{
        .linkage = .static,
        .name = "memtrace",
        .root_module = memtrace,
    });
    b.installArtifact(artifact);
}

pub fn cli(b: *std.Build, module: *std.Build.Module) void {
    const artifact = b.addExecutable(.{
        .name = "memtrace",
        .root_module = module,
    });
    b.installArtifact(artifact);
}
