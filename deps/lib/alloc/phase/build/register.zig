const std = @import("std");
const build_api = @import("build_api");
const module = @import("module.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = build_api.resolvePackageConfiguration(b);
    const capacity = module.capacityRegistered(b, config.policy);
    _ = module.registered(b, config.policy, capacity);
    tests.unit(
        b,
        module.testModule(b, config.policy, capacity),
        module.capacityTestModule(b, config.policy),
        module.metadataRegistered(b, config.policy, capacity),
        module.nativeCapacity(b, config.policy),
        config.policy.optimize,
        config.test_filters,
    );
}
