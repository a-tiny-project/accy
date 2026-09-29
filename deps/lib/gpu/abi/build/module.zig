const std = @import("std");
const build_api = @import("build_api");

/// The interface imports only `std`, so Choir's code generators and gpu's
/// runtimes each link it without linking the other.
pub fn registered(b: *std.Build, policy: build_api.ModuleOptions) *std.Build.Module {
    return b.addModule("gpu_abi", policy.createOptions(b, "src/root.zig", &.{}));
}

pub fn testing(b: *std.Build, policy: build_api.ModuleOptions) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/test.zig", &.{}));
}
