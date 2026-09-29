const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const module = @import("module.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = build_api.resolvePackageConfiguration(b);
    const alloc_phase = deps.allocPhase(b, config.policy);
    const pretty = deps.pretty(b, config.policy);
    const hypothesis = module.registered(b, config.policy, alloc_phase, pretty);
    const hypothesis_tests = module.tests(b, config.policy, alloc_phase, pretty);
    _ = build_api.addStaticLibrary(b, .{
        .name = "hypothesis",
        .root_module = hypothesis,
    });

    const properties = module.properties(b, config.policy, hypothesis);
    tests.add(b, hypothesis_tests, properties, config.test_filters);
}
