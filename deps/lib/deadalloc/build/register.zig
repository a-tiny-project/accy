const std = @import("std");
const build_api = @import("build_api");
const configuration = @import("configuration.zig");
const deps = @import("deps.zig");
const module = @import("module.zig");
const preload = @import("preload.zig");
const reference = @import("reference.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = configuration.resolve(b);
    const dependencies = deps.resolve(b, config.policies);
    const deadalloc = module.registered(
        b,
        config.policies.library,
        dependencies.library_pretty,
        dependencies.library_sys.module("sys"),
    );
    _ = build_api.addStaticLibrary(b, .{
        .name = "deadalloc",
        .root_module = deadalloc,
    });
    const deadalloc_tests = module.packageTest(
        b,
        config.policies.library,
        dependencies.library_sys.module("sys"),
    );
    const unit = tests.unit(b, deadalloc_tests, config.test_filters);

    const installs = preload.add(
        b,
        config.policies,
        .{
            .sys = dependencies.preload_sys,
            .coz = dependencies.preload_coz,
            .test_sys = dependencies.library_sys.module("sys"),
            .test_coz = dependencies.test_coz,
        },
        config.test_filters,
        unit.parent,
    );
    reference.add(b, config.reference_build, unit.run, installs);
}
