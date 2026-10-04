const std = @import("std");
const build_api = @import("build_api");

pub const StackSwitchArchitecture = enum {
    x86_64,
    aarch64,
};

pub const ThreadLocalPointer = struct {
    name: []const u8,
};
pub fn installsFreedesktopAppAssets(target: std.Target) bool {
    return target.os.tag == .linux;
}

pub fn supportsTinyAotSmoke(target: std.Target) bool {
    return target.cpu.arch == .x86_64 and target.os.tag == .linux;
}

pub fn stackSwitchArchitecture(target: std.Target) ?StackSwitchArchitecture {
    if (target.os.tag == .windows) return null;
    return switch (target.cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        else => null,
    };
}

pub fn supportsStackfulPrompts(target: std.Target) bool {
    return switch (target.os.tag) {
        .wasi, .freestanding => false,
        else => stackSwitchArchitecture(target) != null,
    };
}

pub fn linkNativeWindowing(module: *std.Build.Module, target: std.Target) void {
    switch (target.os.tag) {
        .macos => {
            module.linkFramework("AppKit", .{});
            module.linkFramework("CoreFoundation", .{});
            module.linkFramework("Foundation", .{});
            module.linkFramework("CoreGraphics", .{});
            module.linkFramework("QuartzCore", .{});
        },
        else => {},
    }
}

pub fn linkAppleMetal(module: *std.Build.Module, target: std.Target) void {
    if (target.os.tag != .macos) return;
    module.linkFramework("Metal", .{});
    module.linkFramework("Foundation", .{});
    module.linkFramework("QuartzCore", .{});
}

pub fn linkAppleAudio(module: *std.Build.Module, target: std.Target) void {
    if (target.os.tag != .macos) return;
    module.linkFramework("AudioToolbox", .{});
    module.linkFramework("CoreAudio", .{});
}

pub fn linkAppleGameController(module: *std.Build.Module, target: std.Target) void {
    if (target.os.tag != .macos) return;
    module.linkFramework("GameController", .{});
    module.linkFramework("Foundation", .{});
}

pub fn linkAppleProcess(module: *std.Build.Module, target: std.Target) void {
    if (target.os.tag != .macos) return;
    module.linkSystemLibrary("proc", .{});
}

pub fn addThreadLocalPointer(
    b: *std.Build,
    module: *std.Build.Module,
    pointer: ThreadLocalPointer,
) void {
    const target = module.resolved_target orelse @panic("thread-local pointer module requires a target");
    const optimize = module.optimize orelse @panic("thread-local pointer module requires an optimize mode");
    const files = b.addWriteFiles();
    const source = files.add(b.fmt("{s}.zig", .{pointer.name}),
        \\threadlocal var value: ?*anyopaque = null;
        \\
        \\pub inline fn load() ?*anyopaque {
        \\    return value;
        \\}
        \\
        \\pub inline fn store(new_value: ?*anyopaque) void {
        \\    value = new_value;
        \\}
        \\
    );
    const module_options = build_api.ModuleOptions{
        .target = target,
        .optimize = optimize,
    };
    var source_options = module_options.createOptionsWithRoot(source, &.{});
    source_options.pic = true;
    const source_module = b.createModule(source_options);
    module.addImport(pointer.name, source_module);
}

pub fn linkLibc(module: *std.Build.Module) void {
    module.link_libc = true;
}
