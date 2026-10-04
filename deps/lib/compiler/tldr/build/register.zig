const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const product = @import("product.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const configuration = deps.configure(b);
    const module_options = build_api.ModuleOptions{
        .target = configuration.targets.product,
        .optimize = configuration.optimize,
    };
    const requested = deps.resolveRequested(b, configuration);
    const tldr = product.add(b, module_options, requested);
    tests.add(b, configuration, requested, tldr);
}
