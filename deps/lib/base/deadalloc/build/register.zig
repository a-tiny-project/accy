const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const module = @import("module.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = build_api.resolvePackageConfiguration(b);
    const dependencies = deps.resolve(b, config.policy);
    const deadalloc = module.registered(
        b,
        config.policy,
        dependencies.pretty,
        dependencies.sys,
    );
    _ = build_api.addStaticLibrary(b, .{
        .name = "deadalloc",
        .root_module = deadalloc,
    });
    const deadalloc_tests = module.packageTest(b, config.policy, dependencies.sys);
    tests.unit(b, deadalloc_tests, config.test_filters);
}
