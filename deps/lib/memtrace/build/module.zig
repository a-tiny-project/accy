const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");

pub fn library(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    dependencies: deps.Core,
) *std.Build.Module {
    return b.addModule("memtrace", policy.createOptions(b, "src/root.zig", &.{
        .{ .name = "alloc_observe", .module = dependencies.alloc_observe },
        .{ .name = "alloc_phase", .module = dependencies.alloc_phase },
        .{ .name = "pretty", .module = dependencies.pretty.module("pretty") },
        .{ .name = "pretty_usage", .module = dependencies.pretty.module("pretty_usage") },
        .{ .name = "sys", .module = dependencies.sys },
        .{ .name = "timing_runner_pretty", .module = dependencies.pretty.module("pretty") },
        .{ .name = "timing_runner_sys", .module = dependencies.sys },
    }));
}

pub fn unit(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    dependencies: deps.Core,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/test.zig", &.{
        .{ .name = "alloc_observe", .module = dependencies.alloc_observe },
        .{ .name = "alloc_phase", .module = dependencies.alloc_phase },
        .{ .name = "pretty", .module = dependencies.pretty.module("pretty") },
        .{ .name = "pretty_usage", .module = dependencies.pretty.module("pretty_usage") },
        .{ .name = "sys", .module = dependencies.sys },
        .{ .name = "timing_runner_pretty", .module = dependencies.pretty.module("pretty") },
        .{ .name = "timing_runner_sys", .module = dependencies.sys },
    }));
}

pub fn cli(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    memtrace: *std.Build.Module,
    sys: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/main.zig", &.{
        .{ .name = "memtrace", .module = memtrace },
        .{ .name = "sys", .module = sys },
    }));
}
