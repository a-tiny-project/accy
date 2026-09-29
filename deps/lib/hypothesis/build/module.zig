const std = @import("std");
const build_api = @import("build_api");

pub fn registered(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    alloc_phase: *std.Build.Module,
    pretty: *std.Build.Module,
) *std.Build.Module {
    return b.addModule("hypothesis", policy.createOptions(b, "src/root.zig", &.{
        .{ .name = "alloc_phase", .module = alloc_phase },
        .{ .name = "pretty", .module = pretty },
    }));
}

pub fn tests(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    alloc_phase: *std.Build.Module,
    pretty: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/test.zig", &.{
        .{ .name = "alloc_phase", .module = alloc_phase },
        .{ .name = "pretty", .module = pretty },
    }));
}

pub fn properties(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    hypothesis: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(policy.createOptions(
        b,
        "src/properties/test.zig",
        &.{.{ .name = "hypothesis", .module = hypothesis }},
    ));
}
