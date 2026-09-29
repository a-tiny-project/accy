const std = @import("std");
const build_api = @import("build_api");
const graph = @import("build/root.zig");

pub const DependencyOptions = graph.DependencyOptions;
pub const dependency = graph.dependency;
pub const dependencyOptions = graph.dependencyOptions;

pub fn build(b: *std.Build) void {
    build_api.package(b, graph.build);
}
