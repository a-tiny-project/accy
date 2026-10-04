const std = @import("std");
const build_api = @import("build_api");
const graph = @import("build/root.zig");

pub const StackSwitchArchitecture = graph.StackSwitchArchitecture;
pub const ThreadLocalPointer = graph.ThreadLocalPointer;
pub const NoLibcArtifactPolicy = graph.NoLibcArtifactPolicy;
pub const NoLibcNeededCheck = graph.NoLibcNeededCheck;
pub fn build(b: *std.Build) void {
    build_api.package(b, graph.build);
}
pub const installsFreedesktopAppAssets = graph.installsFreedesktopAppAssets;
pub const supportsTinyAotSmoke = graph.supportsTinyAotSmoke;
pub const stackSwitchArchitecture = graph.stackSwitchArchitecture;
pub const supportsStackfulPrompts = graph.supportsStackfulPrompts;
pub const linkNativeWindowing = graph.linkNativeWindowing;
pub const linkAppleMetal = graph.linkAppleMetal;
pub const linkAppleAudio = graph.linkAppleAudio;
pub const linkAppleGameController = graph.linkAppleGameController;
pub const addThreadLocalPointer = graph.addThreadLocalPointer;
pub const addNoLibcNeededCheck = graph.addNoLibcNeededCheck;
pub const linkLibc = graph.linkLibc;
