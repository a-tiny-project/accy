const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const module = @import("module.zig");

pub const Validation = struct {
    library: *std.Build.Step.Compile,
    desktop: *std.Build.Step.Compile,
    properties: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    property_step: *std.Build.Step,
};

pub fn add(
    b: *std.Build,
    options: build_api.ModuleOptions,
    configuration: deps.Configuration,
    dependencies: deps.Requested,
    windowing: *std.Build.Module,
) Validation {
    const library_module = module.createTestModule(b, options, dependencies.inputs);
    const library = b.addTest(.{
        .root_module = library_module,
        .filters = configuration.test_filters,
    });
    const run_library = b.addRunArtifact(library);

    const desktop_module = module.createDesktopModule(b, options, .{
        .sys = dependencies.inputs.sys,
        .windowing = windowing,
    });
    const desktop = b.addTest(.{
        .root_module = desktop_module,
        .filters = configuration.test_filters,
    });
    const run_desktop = b.addRunArtifact(desktop);

    const test_step = b.step("test", "Run windowing unit tests");
    test_step.dependOn(&run_library.step);
    test_step.dependOn(&run_desktop.step);

    const property_module = b.createModule(options.createOptions(
        b,
        "src/properties/test.zig",
        &.{
            .{ .name = "windowing", .module = windowing },
            .{ .name = "hypothesis", .module = dependencies.hypothesis },
        },
    ));
    const properties = b.addTest(.{
        .root_module = property_module,
        .filters = configuration.test_filters,
    });
    const run_properties = b.addRunArtifact(properties);

    const property_step = b.step("pbt", "Run windowing property tests");
    property_step.dependOn(&run_properties.step);
    return .{
        .library = library,
        .desktop = desktop,
        .properties = properties,
        .test_step = test_step,
        .property_step = property_step,
    };
}
