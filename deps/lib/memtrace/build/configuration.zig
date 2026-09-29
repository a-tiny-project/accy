const std = @import("std");
const build_api = @import("build_api");

pub const Configuration = struct {
    policy: build_api.ModuleOptions,
    test_filters: []const []const u8,
    browserish: bool,
    observe_allocations: bool,
};

pub fn resolve(b: *std.Build) Configuration {
    const policy = build_api.ModuleOptions{
        .target = build_api.standardTargets(b).product,
        .optimize = b.standardOptimizeOption(.{}),
    };
    return .{
        .policy = policy,
        .test_filters = build_api.focusedTestFilters(b),
        .browserish = isBrowserish(policy.target.result),
        .observe_allocations = b.option(
            bool,
            "observe-allocations",
            "Compile allocator observation into producer vtables",
        ) orelse false,
    };
}

fn isBrowserish(target: std.Target) bool {
    return target.cpu.arch.isWasm() and target.os.tag == .freestanding;
}
