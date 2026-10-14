const std = @import("std");
const configuration = @import("configuration.zig");
const module = @import("module.zig");

pub fn build(b: *std.Build) void {
    const config = configuration.resolve(b);
    const alloc_observe = b.dependency("alloc_observe", .{
        .target = config.policy.target,
        .optimize = config.policy.optimize,
        .enabled = config.observe_allocations,
    }).module("alloc_observe");
    _ = module.registered(b, config.policy, alloc_observe);
    const artifact = b.addTest(.{
        .root_module = module.testing(b, config.policy, alloc_observe),
        .filters = config.test_filters,
    });
    const parent = b.step("test", "Run owned arena tests");
    parent.dependOn(&b.addRunArtifact(artifact).step);
}
