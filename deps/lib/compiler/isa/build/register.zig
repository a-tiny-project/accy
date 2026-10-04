const std = @import("std");
const build_api = @import("build_api");
const configuration = @import("configuration.zig");
const module = @import("module.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = configuration.resolve(b);
    const isa = module.registered(b, config.policy);
    _ = build_api.addStaticLibrary(b, .{
        .name = "isa",
        .root_module = isa,
    });
    tests.add(b, module.tests(b, config.policy), config.filters);
}
