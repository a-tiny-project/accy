const std = @import("std");
const configuration = @import("configuration.zig");
const module = @import("module.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = configuration.resolve(b);
    _ = module.registered(b, config.policy, config.enabled);
    tests.register(
        b,
        module.testing(b, config.policy, true),
        module.testing(b, config.policy, false),
        config.test_filters,
    );
}
