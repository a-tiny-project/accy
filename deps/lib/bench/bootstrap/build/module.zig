const std = @import("std");
const build_api = @import("build_api");

/// The primitives import only `std`, so capture takes them without linking
/// bench and its profiler closure.
pub fn registered(b: *std.Build, policy: build_api.ModuleOptions) *std.Build.Module {
    return b.addModule("bench_bootstrap", policy.createOptions(b, "src/root.zig", &.{}));
}

pub fn testing(b: *std.Build, policy: build_api.ModuleOptions) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/test.zig", &.{}));
}
