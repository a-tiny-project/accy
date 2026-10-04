const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const module = @import("module.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = build_api.resolvePackageConfiguration(b);
    const inputs = deps.runtime(b, config.policy);
    const coz = module.registered(b, config.policy, inputs);
    const coz_tests = module.tests(b, config.policy, inputs);
    _ = build_api.addStaticLibrary(b, .{
        .name = "coz",
        .root_module = coz,
    });
    tests.unit(b, coz_tests, config.test_filters);
}
