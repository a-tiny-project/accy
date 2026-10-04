const std = @import("std");
const build_api = @import("build_api");
const graph = @import("build/root.zig");

pub fn build(b: *std.Build) void {
    build_api.package(b, graph.build);
}
