const std = @import("std");
const configuration = @import("configuration.zig");

pub fn register(
    b: *std.Build,
    config: configuration.Configuration,
    alloc: *std.Build.Module,
    locked: *std.Build.Module,
    alloc_limit: *std.Build.Module,
) void {
    const alloc_tests = b.addTest(.{
        .root_module = alloc,
        .filters = config.test_filters,
    });
    const run_alloc_tests = b.addRunArtifact(alloc_tests);
    const test_step = b.step("test", "Run alloc tests");
    test_step.dependOn(&run_alloc_tests.step);

    const locked_tests = b.addTest(.{
        .root_module = locked,
        .filters = config.test_filters,
    });
    const run_locked_tests = b.addRunArtifact(locked_tests);
    test_step.dependOn(&run_locked_tests.step);

    const limit_tests = b.addTest(.{
        .root_module = alloc_limit,
        .filters = config.test_filters,
    });
    const run_limit_tests = b.addRunArtifact(limit_tests);
    test_step.dependOn(&run_limit_tests.step);
    const limit_test_step = b.step("limit-test", "Run limit allocator tests");
    limit_test_step.dependOn(&run_limit_tests.step);

    const loop_restriction = b.addExecutable(.{
        .name = "alloc-loop-restriction",
        .root_module = b.createModule(config.policy.createOptions(
            b,
            "src/limit/loop.zig",
            &.{},
        )),
    });
    const loop_restriction_step = b.step(
        "loop-restriction",
        "Compile the bounded loop restriction exemplar",
    );
    loop_restriction_step.dependOn(&loop_restriction.step);

    const no_dependence_restriction = b.addObject(.{
        .name = "alloc-no-dependence-restriction",
        .root_module = b.createModule(config.policy.createOptions(
            b,
            "src/limit/dependence.zig",
            &.{},
        )),
    });
    const no_dependence_restriction_step = b.step(
        "no-dependence-restriction",
        "Compile the semantic dependence restriction exemplar",
    );
    no_dependence_restriction_step.dependOn(&no_dependence_restriction.step);
}
