const std = @import("std");
const build_api = @import("build_api");
const graph = @import("build/root.zig");

pub const Inputs = graph.Inputs;
pub const createModule = graph.createModule;
pub const createTestModule = graph.createTestModule;
pub const createTimedTestModule = graph.createTimedTestModule;

pub fn build(b: *std.Build) void {
    build_api.package(b, graph.build);
}
pub const dependency = graph.dependency;
pub const DependencyOptions = graph.DependencyOptions;
pub const dependencyOptions = graph.dependencyOptions;
