const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const module = @import("module.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = build_api.resolvePackageConfiguration(b);
    const sys = deps.sys(b, config.policy);
    const stabilizer = module.registered(b, config.policy, sys);
    const stabilizer_tests = module.tests(b, config.policy, sys);

    _ = build_api.addStaticLibrary(b, .{
        .name = "stabilizer",
        .root_module = stabilizer,
    });
    tests.unit(b, stabilizer_tests, config.test_filters);

    const hypothesis = deps.hypothesis(b, config.policy);
    const properties = module.properties(b, config.policy, hypothesis, stabilizer);
    tests.properties(b, properties);
}
