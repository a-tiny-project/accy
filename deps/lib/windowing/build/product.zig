const std = @import("std");
const build_api = @import("build_api");
const module = @import("module.zig");

pub fn addProduct(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: module.Inputs,
) *std.Build.Module {
    const windowing = module.createModule(b, options, inputs);
    build_api.registerModule(b, "windowing", windowing);

    const desktop = module.createDesktopModule(b, options, .{
        .sys = inputs.sys,
        .windowing = windowing,
    });
    build_api.registerModule(b, "windowing_desktop", desktop);

    const library = b.addLibrary(.{
        .linkage = .static,
        .name = "windowing",
        .root_module = windowing,
    });
    b.installArtifact(library);
    return windowing;
}
