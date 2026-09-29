const std = @import("std");
const build_api = @import("build_api");
const module = @import("module.zig");

pub fn add(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    inputs: module.TimedInputs,
) *std.Build.Module {
    const gpalloc = module.createTimedModule(b, policy, inputs);
    build_api.registerModule(b, "gpalloc", gpalloc);
    const library = b.addLibrary(.{
        .linkage = .static,
        .name = "gpalloc",
        .root_module = gpalloc,
    });
    b.installArtifact(library);
    return gpalloc;
}
