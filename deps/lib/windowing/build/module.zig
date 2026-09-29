const std = @import("std");
const build_api = @import("build_api");
const sys_build = @import("sys");

pub const Inputs = struct {
    alloc: *std.Build.Module,
    alloc_phase: *std.Build.Module,
    sys: *std.Build.Module,
    wayland: *std.Build.Module,
    xkb: *std.Build.Module,
};

pub const DesktopInputs = struct {
    sys: *std.Build.Module,
    windowing: *std.Build.Module,
};

pub fn createModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
) *std.Build.Module {
    return createModuleAt(b, options, inputs, "src/root.zig");
}

pub fn createTestModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
) *std.Build.Module {
    return createModuleAt(b, options, inputs, "src/test.zig");
}

fn createModuleAt(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
    root_source_file: []const u8,
) *std.Build.Module {
    const windowing = b.createModule(options.createOptions(b, root_source_file, &.{
        .{ .name = "alloc", .module = inputs.alloc },
        .{ .name = "alloc_phase", .module = inputs.alloc_phase },
        .{ .name = "sys", .module = inputs.sys },
        .{ .name = "wayland", .module = inputs.wayland },
        .{ .name = "xkb", .module = inputs.xkb },
    }));
    sys_build.linkNativeWindowing(windowing, options.target.result);
    sys_build.linkAppleGameController(windowing, options.target.result);
    return windowing;
}

pub fn createDesktopModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: DesktopInputs,
) *std.Build.Module {
    return b.createModule(options.createOptions(b, "src/desktop.zig", &.{
        .{ .name = "sys", .module = inputs.sys },
        .{ .name = "windowing", .module = inputs.windowing },
    }));
}
