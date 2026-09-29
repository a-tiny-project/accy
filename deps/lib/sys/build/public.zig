const std = @import("std");
const build_api = @import("build_api");
const nolibc = @import("nolibc.zig");
const platform = @import("platform.zig");

pub const StackSwitchArchitecture = platform.StackSwitchArchitecture;
pub const ThreadLocalPointer = platform.ThreadLocalPointer;
pub const NoLibcArtifactPolicy = nolibc.NoLibcArtifactPolicy;
pub const NoLibcNeededCheck = nolibc.NoLibcNeededCheck;
pub const installsFreedesktopAppAssets = platform.installsFreedesktopAppAssets;
pub const supportsTinyAotSmoke = platform.supportsTinyAotSmoke;
pub const stackSwitchArchitecture = platform.stackSwitchArchitecture;
pub const supportsStackfulPrompts = platform.supportsStackfulPrompts;
pub const linkNativeWindowing = platform.linkNativeWindowing;
pub const linkAppleMetal = platform.linkAppleMetal;
pub const linkAppleAudio = platform.linkAppleAudio;
pub const linkAppleGameController = platform.linkAppleGameController;
pub const linkAppleProcess = platform.linkAppleProcess;
pub const addThreadLocalPointer = platform.addThreadLocalPointer;
pub const addNoLibcNeededCheck = nolibc.addNoLibcNeededCheck;
pub const linkLibc = platform.linkLibc;

pub const Graph = struct {
    targets: build_api.Targets,
    options: build_api.ModuleOptions,
    alloc_phase: *std.Build.Module,
    channel: *std.Build.Module,
    sys: *std.Build.Module,
    sys_no_libc: *std.Build.Module,
};

pub fn add(b: *std.Build) Graph {
    const targets = build_api.standardTargets(b);
    const target = targets.product;
    const optimize = b.standardOptimizeOption(.{});
    const module_options = build_api.ModuleOptions{
        .target = target,
        .optimize = optimize,
    };
    const alloc_phase_dep = b.dependency("alloc_phase", .{
        .target = target,
        .optimize = optimize,
    });

    const alloc_phase_mod = alloc_phase_dep.module("alloc_phase");
    const channel_mod = b.dependency("alloc_observe_channel", .{
        .target = target,
        .optimize = optimize,
    }).module("alloc_observe_channel");
    const sys_options = module_options.createOptions(b, "src/root.zig", &.{
        .{ .name = "alloc_observe_channel", .module = channel_mod },
        .{ .name = "alloc_phase", .module = alloc_phase_mod },
    });
    const sys_mod = b.addModule("sys", sys_options);
    _ = b.addModule("sys_semantic", sys_options);
    linkAppleProcess(sys_mod, target.result);
    linkAppleAudio(sys_mod, target.result);
    linkAppleGameController(sys_mod, target.result);
    const sys_no_libc_mod = b.addModule(
        "sys_no_libc",
        module_options.createOptions(b, "src/nolibc.zig", &.{
            .{ .name = "alloc_observe_channel", .module = channel_mod },
        }),
    );

    return .{
        .targets = targets,
        .options = module_options,
        .alloc_phase = alloc_phase_mod,
        .channel = channel_mod,
        .sys = sys_mod,
        .sys_no_libc = sys_no_libc_mod,
    };
}

pub fn build(b: *std.Build) void {
    _ = add(b);
}
