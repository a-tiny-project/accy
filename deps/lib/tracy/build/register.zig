const std = @import("std");
const configuration = @import("configuration.zig");
const deps = @import("deps.zig");
const module = @import("module.zig");
const product = @import("product.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = configuration.resolve(b);
    const dependencies = deps.resolve(b, config.policy);
    const tracy_module = module.create(b, config, dependencies);
    product.register(b, config, dependencies, tracy_module);
    tests.register(b, config, dependencies);
}
