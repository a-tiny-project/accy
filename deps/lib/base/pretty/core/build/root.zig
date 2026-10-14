const std = @import("std");
const build_api = @import("build_api");

pub fn build(b: *std.Build) void {
    const target = build_api.standardTargets(b).product;
    const optimize = b.standardOptimizeOption(.{});
    const options = build_api.ModuleOptions{
        .target = target,
        .optimize = optimize,
    };
    const alloc_phase = b.dependency("alloc_phase", .{
        .target = target,
        .optimize = optimize,
    }).module("alloc_phase");
    const pretty = b.addModule(
        "pretty",
        options.createOptions(b, "src/root.zig", &.{
            .{ .name = "alloc_phase", .module = alloc_phase },
        }),
    );
    const library = b.addLibrary(.{
        .linkage = .static,
        .name = "pretty-core",
        .root_module = pretty,
    });
    b.installArtifact(library);

    const tests = b.addTest(.{
        .root_module = b.createModule(options.createOptions(
            b,
            "src/test.zig",
            &.{.{ .name = "alloc_phase", .module = alloc_phase }},
        )),
        .filters = build_api.focusedTestFilters(b),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Pretty core tests");
    test_step.dependOn(&run_tests.step);
}
