const std = @import("std");
const build_api = @import("build_api");
const configuration = @import("configuration.zig");
const model = @import("model.zig");
const module = @import("module.zig");

pub const Resolved = struct {
    alloc: *std.Build.Module,
    locked: *std.Build.Module,
    tests: *std.Build.Module,
    locked_tests: *std.Build.Module,
    limit_tests: *std.Build.Module,
};

pub fn resolve(b: *std.Build, config: configuration.Configuration) Resolved {
    const alloc_phase_dependency = b.dependency("alloc_phase", .{
        .target = config.policy.target,
        .optimize = config.policy.optimize,
    });
    const alloc_phase = alloc_phase_dependency.module("alloc_phase");
    build_api.registerModule(b, "alloc_phase", alloc_phase);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "test_allocator_mode", config.dependency.test_allocator_mode);
    build_options.addOption([]const u8, "allocator_diagnostics", config.dependency.allocator_diagnostics);
    build_options.addOption([]const u8, "allocator_phase", config.dependency.allocator_phase);

    const sys_dependency = b.dependency("sys", .{
        .target = config.policy.target,
        .optimize = config.policy.optimize,
    });
    const limit_sys = if (config.policy.target.result.cpu.arch.isWasm() and
        config.policy.target.result.os.tag == .freestanding)
        sys_dependency.module("sys_no_libc")
    else
        sys_dependency.module("sys");
    const limit = b.createModule(config.policy.createOptions(
        b,
        "src/limit/root.zig",
        &.{.{ .name = "sys", .module = limit_sys }},
    ));
    build_api.registerModule(b, "alloc_limit", limit);
    const locked = module.createLockedModule(
        b,
        config.policy,
        limit_sys,
    );
    build_api.registerModule(b, "alloc_locked", locked);

    const deadalloc_dependency = b.dependency("deadalloc", .{
        .target = config.policy.target,
        .optimize = config.policy.optimize,
    });
    const gpalloc_dependency = b.dependency("gpalloc", .{
        .target = config.policy.target,
        .optimize = config.policy.optimize,
    });
    const sys = sys_dependency.module("sys");
    const deadalloc = deadalloc_dependency.module("deadalloc");
    const gpalloc = gpalloc_dependency.module("gpalloc");
    build_api.requireImport(deadalloc, "sys", sys);
    build_api.requireImport(gpalloc, "sys", sys);
    const inputs = model.Inputs{
        .alloc_locked = locked,
        .alloc_limit = limit,
        .alloc_phase = alloc_phase,
        .build_options = build_options.createModule(),
        .deadalloc = deadalloc,
        .gpalloc = gpalloc,
        .sys = sys,
    };
    const alloc = module.createModule(b, config.policy, inputs);
    build_api.registerModule(b, "alloc", alloc);
    return .{
        .alloc = alloc,
        .locked = locked,
        .tests = module.createTestModule(b, config.policy, inputs),
        .locked_tests = b.createModule(config.policy.createOptions(
            b,
            "src/locked/allocator.zig",
            &.{.{ .name = "sys", .module = limit_sys }},
        )),
        .limit_tests = b.createModule(config.policy.createOptions(
            b,
            "src/limit/test.zig",
            &.{.{ .name = "alloc_limit", .module = limit }},
        )),
    };
}
