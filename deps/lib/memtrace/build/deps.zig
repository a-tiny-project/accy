const std = @import("std");
const configuration = @import("configuration.zig");

pub const Core = struct {
    alloc_observe: *std.Build.Module,
    alloc_phase: *std.Build.Module,
    pretty: *std.Build.Dependency,
    sys: *std.Build.Module,
};

pub fn core(b: *std.Build, config: configuration.Configuration) Core {
    const alloc_observe = b.dependency("alloc_observe", .{
        .target = config.policy.target,
        .optimize = config.policy.optimize,
        .enabled = config.observe_allocations,
    }).module("alloc_observe");
    const alloc_phase = b.dependency("alloc_phase", .{
        .target = config.policy.target,
        .optimize = config.policy.optimize,
    }).module("alloc_phase");
    const pretty = b.dependency("pretty", .{
        .target = config.policy.target,
        .optimize = config.policy.optimize,
    });
    const sys = b.dependency("sys", .{
        .target = config.policy.target,
        .optimize = config.policy.optimize,
    });
    return .{
        .alloc_observe = alloc_observe,
        .alloc_phase = alloc_phase,
        .pretty = pretty,
        .sys = if (config.browserish) sys.module("sys_no_libc") else sys.module("sys"),
    };
}
