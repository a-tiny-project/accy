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
    // A release that strips its tests ships no test root, and so no test step.
    // The configuration depends on the root's directory entries, which a
    // missing root leaves trackable, unlike the root's own metadata.
    b.dependOnDirectoryContents(b.path(std.fs.path.dirname(module.test_root).?));
    b.root.access(b.graph.io, module.test_root, .{}) catch return;
    const unit = b.addTest(.{
        .root_module = module.createTestModule(b, graph.policy, graph.inputs),
        .filters = graph.configuration.test_filters,
        .test_runner = if (graph.configuration.wasm_node_path.len != 0) .{
            .path = b.path("build/qualification.zig"),
            .mode = .simple,
        } else null,
    });
    const run = b.addRunArtifact(unit);
    b.step("test", "Run Choir unit tests").dependOn(&run.step);
}
