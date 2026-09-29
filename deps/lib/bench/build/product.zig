const std = @import("std");
const build_api = @import("build_api");
const module = @import("module.zig");

pub fn addProduct(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: module.Inputs,
) *std.Build.Module {
    const bench = module.createModule(b, options, inputs);
    build_api.registerModule(b, "bench", bench);
    const floor = bench.import_table.get(module.floor_name).?;
    build_api.registerModule(b, module.floor_name, floor);
    const library = b.addLibrary(.{
        .linkage = .static,
        .name = "bench",
        .root_module = bench,
    });
    b.installArtifact(library);
    return bench;
}
