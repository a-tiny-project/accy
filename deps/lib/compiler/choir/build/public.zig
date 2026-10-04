const std = @import("std");
const build_api = @import("build_api");
const module = @import("module.zig");
const product = @import("product.zig");
const runtime = @import("runtime.zig");

pub const Graph = struct {
    configuration: runtime.Configuration,
    policy: build_api.ModuleOptions,
    inputs: module.Inputs,
    choir: *std.Build.Module,
};

pub fn add(b: *std.Build) Graph {
    const configuration = runtime.configure(b);
    const policy = build_api.ModuleOptions{
        .target = configuration.target,
        .optimize = configuration.optimize,
    };
    const inputs = runtime.resolveRequested(b, configuration);
    return .{
        .configuration = configuration,
        .policy = policy,
        .inputs = inputs,
        .choir = product.add(b, policy, inputs),
    };
}

pub fn build(b: *std.Build) void {
    const graph = add(b);
    const unit = b.addTest(.{
        .root_module = module.createTestModule(b, graph.policy, graph.inputs),
        .filters = graph.configuration.test_filters,
    });
    const run = b.addRunArtifact(unit);
    b.step("test", "Run Choir unit tests").dependOn(&run.step);
}
