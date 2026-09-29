const std = @import("std");
const build_api = @import("build_api");

pub const RootInputs = struct {
    sys: *std.Build.Module,
    wayland_options: *std.Build.Module,
};

pub fn rootInputs(
    b: *std.Build,
    sys: *std.Build.Module,
    retained_entry_count: usize,
) RootInputs {
    const options = b.addOptions();
    options.addOption(
        usize,
        "process_environment_retained_entry_count",
        retained_entry_count,
    );
    return .{
        .sys = sys,
        .wayland_options = options.createModule(),
    };
}

pub fn registered(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    inputs: RootInputs,
) *std.Build.Module {
    return b.addModule("wayland", policy.createOptions(b, "src/root.zig", &.{
        .{ .name = "sys", .module = inputs.sys },
        .{ .name = "wayland_options", .module = inputs.wayland_options },
    }));
}

pub fn unit(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    inputs: RootInputs,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/test.zig", &.{
        .{ .name = "sys", .module = inputs.sys },
        .{ .name = "wayland_options", .module = inputs.wayland_options },
    }));
}

pub fn properties(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    hypothesis: *std.Build.Module,
    wayland: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/properties/test.zig", &.{
        .{ .name = "hypothesis", .module = hypothesis },
        .{ .name = "wayland", .module = wayland },
    }));
}
