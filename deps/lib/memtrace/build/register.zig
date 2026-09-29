const std = @import("std");
const configuration = @import("configuration.zig");
const deps = @import("deps.zig");
const module = @import("module.zig");
const product = @import("product.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = configuration.resolve(b);
    const dependencies = deps.core(b, config);
    const memtrace = module.library(b, config.policy, dependencies);
    product.library(b, memtrace);
    _ = tests.unit(b, config, module.unit(b, config.policy, dependencies));

    if (!config.browserish) {
        const cli = module.cli(b, config.policy, memtrace, dependencies.sys);
        product.cli(b, cli);
    }
}
