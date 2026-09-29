const std = @import("std");
const build_api = @import("build_api");

pub const Product = struct {
    module: *std.Build.Module,
    library: *std.Build.Step.Compile,
};

pub fn addProduct(
    b: *std.Build,
    options: build_api.ModuleOptions,
    alloc_phase: *std.Build.Module,
) Product {
    const module = createModuleFrom(b, options, alloc_phase, "src/root.zig", "xkb");
    const library = b.addLibrary(.{
        .linkage = .static,
        .name = "xkb",
        .root_module = module,
    });
    return .{ .module = module, .library = library };
}

pub fn createTestModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    alloc_phase: *std.Build.Module,
) *std.Build.Module {
    return createModuleFrom(b, options, alloc_phase, "src/test.zig", null);
}

fn createModuleFrom(
    b: *std.Build,
    options: build_api.ModuleOptions,
    alloc_phase: *std.Build.Module,
    root_source_file: []const u8,
    name: ?[]const u8,
) *std.Build.Module {
    const module_options = options.createOptions(b, root_source_file, &.{
        .{ .name = "alloc_phase", .module = alloc_phase },
    });
    return if (name) |registered|
        b.addModule(registered, module_options)
    else
        b.createModule(module_options);
}
