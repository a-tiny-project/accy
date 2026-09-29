const std = @import("std");

pub const default_retained_entry_count: usize = 32 * 1024;

pub const Limits = struct {
    retained_entry_count: usize = default_retained_entry_count,
};

pub fn configuredLimits(b: *std.Build, defaults: Limits) Limits {
    return .{
        .retained_entry_count = b.option(
            usize,
            "wayland-process-environment-retained-entries",
            "Process environment entries retained after claiming WAYLAND_SOCKET",
        ) orelse defaults.retained_entry_count,
    };
}

pub fn dependency(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    limits: Limits,
) *std.Build.Dependency {
    return b.dependency(name, .{
        .target = target,
        .optimize = optimize,
        .@"wayland-process-environment-retained-entries" = limits.retained_entry_count,
    });
}
