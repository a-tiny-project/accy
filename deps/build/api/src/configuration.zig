const std = @import("std");
const filter = @import("filter.zig");
const module = @import("module.zig");
const target = @import("target.zig");

pub const PackageConfiguration = struct {
    policy: module.ModuleOptions,
    test_filters: []const []const u8,
};

pub fn resolvePackage(b: *std.Build) PackageConfiguration {
    return .{
        .policy = .{
            .target = target.standardTargets(b).product,
            .optimize = b.standardOptimizeOption(.{}),
        },
        .test_filters = filter.focused(b),
    };
}
