const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const sys_build = @import("sys");

pub fn add(
    b: *std.Build,
    options: build_api.ModuleOptions,
    configuration: deps.Configuration,
    xkb_tests: *std.Build.Module,
    xkb: *std.Build.Module,
    generated_check: *std.Build.Step,
) void {
    const tests = b.addTest(.{
        .root_module = xkb_tests,
        .filters = configuration.test_filters,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run XKB keysym, keymap, state, and Compose tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(generated_check);

    const properties_module = b.createModule(options.createOptions(b, "src/properties/test.zig", &.{
        .{ .name = "hypothesis", .module = deps.hypothesis(b, options) },
        .{ .name = "xkb", .module = xkb },
    }));
    const property_tests = b.addTest(.{
        .root_module = properties_module,
        .filters = configuration.test_filters,
    });
    const run_property_tests = b.addRunArtifact(property_tests);
    const property_step = b.step("pbt", "Run XKB state and Compose property tests");
    property_step.dependOn(&run_property_tests.step);
    property_step.dependOn(generated_check);

    if (sys_build.addNoLibcNeededCheck(b, .{
        .target = options.target,
        .step_name = "no-libc-needed",
        .description = "Check the XKB test artifacts do not require libc",
        .label = "xkb-no-libc-needed",
        .artifacts = &.{ tests, property_tests },
        .strict_undefined = .all,
    })) |step| {
        test_step.dependOn(step);
        property_step.dependOn(step);
    }
}
