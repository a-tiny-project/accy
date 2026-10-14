const std = @import("std");
const build_api = @import("build_api");

pub fn registered(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    pretty: *std.Build.Module,
    sys: *std.Build.Module,
) *std.Build.Module {
    const deadalloc = b.createModule(policy.createOptions(b, "src/root.zig", &.{
        .{ .name = "sys", .module = sys },
        .{ .name = "timing_runner_pretty", .module = pretty },
        .{ .name = "timing_runner_sys", .module = sys },
    }));
    build_api.registerModule(b, "deadalloc", deadalloc);
    return deadalloc;
}

pub fn packageTest(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    sys: *std.Build.Module,
) *std.Build.Module {
    return createPackageModule(b, policy, "src/test.zig", sys);
}

fn createPackageModule(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    path: []const u8,
    sys: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, path, &.{
        .{ .name = "sys", .module = sys },
    }));
}
