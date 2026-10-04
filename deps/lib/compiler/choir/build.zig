const std = @import("std");
const build_api = @import("build_api");
const graph = @import("build/root.zig");

pub const Configuration = graph.Configuration;
pub const Inputs = graph.Inputs;
pub const createModule = graph.createModule;
pub const resolveRequested = graph.resolveRequested;
pub const profilingConfiguration = graph.profilingConfiguration;

pub fn build(b: *std.Build) void {
    build_api.package(b, graph.build);
}
