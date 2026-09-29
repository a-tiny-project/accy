const std = @import("std");
const build_api = @import("build_api");

pub fn registered(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    alloc_observe: *std.Build.Module,
) *std.Build.Module {
    return b.addModule(
        "alloc_fixed",
        policy.createOptions(b, "src/root.zig", &.{
            .{ .name = "alloc_observe", .module = alloc_observe },
        }),
    );
}

pub fn testing(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    alloc_observe: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/test.zig", &.{
        .{ .name = "alloc_observe", .module = alloc_observe },
    }));
}
