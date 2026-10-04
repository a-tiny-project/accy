const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");

pub const Product = struct {
    tldr: *std.Build.Module,
    tests: *std.Build.Module,
};

pub fn add(
    b: *std.Build,
    options: build_api.ModuleOptions,
    dependencies: deps.Requested,
) Product {
    const tldr = createModule(b, options, dependencies);
    build_api.registerModule(b, "tldr", tldr);
    const tests = b.createModule(options.createOptions(
        b,
        "src/test.zig",
        &.{
            .{ .name = "alloc", .module = dependencies.alloc },
            .{ .name = "alloc_arena", .module = dependencies.alloc_arena },
            .{ .name = "alloc_phase", .module = dependencies.alloc_phase },
            .{ .name = "coz", .module = dependencies.coz },
            .{ .name = "pretty", .module = dependencies.pretty },
            .{ .name = "sys", .module = dependencies.sys },
            .{ .name = "timing_runner_pretty", .module = dependencies.pretty },
            .{ .name = "timing_runner_sys", .module = dependencies.sys },
        },
    ));
    return .{ .tldr = tldr, .tests = tests };
}

/// Builds the module rooted at `src/root.zig` with the imports the sources it
/// reaches use: `alloc`, `alloc_arena`, `alloc_phase`, `coz`, `pretty` and
/// `sys`. `add` and the host-role test graph call it to build the module that
/// consumers import as `tldr`. The two imports `timing_runner_pretty` and
/// `timing_runner_sys` belong to `src/test.zig`. This module leaves both out
/// since no source reachable from `src/root.zig` imports them.
/// The test graph calls it a second time for the host target when the host and
/// product targets differ.
pub fn createModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    dependencies: deps.Requested,
) *std.Build.Module {
    return b.createModule(options.createOptions(
        b,
        "src/root.zig",
        &.{
            .{ .name = "alloc", .module = dependencies.alloc },
            .{ .name = "alloc_arena", .module = dependencies.alloc_arena },
            .{ .name = "alloc_phase", .module = dependencies.alloc_phase },
            .{ .name = "coz", .module = dependencies.coz },
            .{ .name = "pretty", .module = dependencies.pretty },
            .{ .name = "sys", .module = dependencies.sys },
        },
    ));
}
