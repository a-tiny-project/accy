const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const product = @import("product.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const policy = build_api.ModuleOptions{
        .target = build_api.standardTargets(b).product,
        .optimize = b.standardOptimizeOption(.{}),
        .sanitize_thread = false,
    };
    const requested = deps.resolveRequested(b, policy);
    _ = product.add(b, policy, .{
        .pretty = requested.pretty,
        .sys = requested.sys,
    });
    tests.add(b, policy, requested.sys, build_api.focusedTestFilters(b));
}
