const std = @import("std");
const build_api = @import("build_api");

pub const Inputs = struct {
    pretty: *std.Build.Module,
    sys: *std.Build.Module,
};

pub fn registered(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    inputs: Inputs,
) *std.Build.Module {
    return b.addModule("coz", policy.createOptions(b, "src/root.zig", &.{
        .{ .name = "pretty", .module = inputs.pretty },
        .{ .name = "sys", .module = inputs.sys },
    }));
}

pub fn tests(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    inputs: Inputs,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/test.zig", &.{
        .{ .name = "pretty", .module = inputs.pretty },
        .{ .name = "sys", .module = inputs.sys },
    }));
}
