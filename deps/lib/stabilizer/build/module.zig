const std = @import("std");
const build_api = @import("build_api");

pub fn registered(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    sys: *std.Build.Module,
) *std.Build.Module {
    return b.addModule("stabilizer", policy.createOptions(b, "src/root.zig", &.{
        .{ .name = "sys", .module = sys },
    }));
}

pub fn tests(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    sys: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/test.zig", &.{
        .{ .name = "sys", .module = sys },
    }));
}

pub fn properties(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    hypothesis: *std.Build.Module,
    stabilizer: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/properties/test.zig", &.{
        .{ .name = "hypothesis", .module = hypothesis },
        .{ .name = "stabilizer", .module = stabilizer },
    }));
}
